//
//  File.swift
//  AudioMonitor
//
//  Created by Matthew Hanlon on 4/7/22.
//

import Foundation
import AVFoundation
import CoreAudio
import UIKit
import Accelerate

@objc public protocol AURenderCallbackDelegate {
    func performRender(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                       timeStamp: UnsafePointer<AudioTimeStamp>,
                       busNumber: UInt32,
                       numberFrames: UInt32,
                       ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus
}

private let AudioController_RenderCallback: AURenderCallback = {(inRefCon, ioActionFlags, timeStamp, busNumber, numberFrames, ioData) -> OSStatus in
    let delegate = unsafeBitCast(inRefCon, to: AURenderCallbackDelegate.self)
    
    let result = delegate.performRender(ioActionFlags,
                                        timeStamp: timeStamp,
                                        busNumber: busNumber,
                                        numberFrames: numberFrames,
                                        ioData: ioData!)
    return result
}

public class AudioMonitor: AURenderCallbackDelegate {
    let sampleRate = 44100.0
    let autocorrelationDepth:UInt = 512
    var accumulationLength:UInt = 16384
    let accumulationBuffer:UnsafeMutablePointer<Float>
    var accumulationBufferOffset:Int
    var audioComponent:AudioComponentInstance?
    var didUpdateToneHandler: ((_ tone: Tone) -> Void)?
    var axOverrideTimer: Timer? = nil
    var backgroundDisableTimer: Timer? = nil
    public var backgroundDisableTimerDelay = 10*60 // 10 minutes
    var isRunning = false
    var wasRunningBeforeBackgrounding = false
    
    public init() {
        var status = noErr
        
        accumulationBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(accumulationLength))
        accumulationBufferOffset = 0
        
        AVAudioSession.sharedInstance().requestRecordPermission () { allowed in
            if allowed {
                // Set up the audio session.
                let sessionInstance = AVAudioSession.sharedInstance()
                
                do {
                    try sessionInstance.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .mixWithOthers]) // Support play and record to work well with ToneOutput.
                    try sessionInstance.setPreferredIOBufferDuration(0.005)
                    try sessionInstance.setPreferredSampleRate(self.sampleRate)
                    
                    try sessionInstance.setActive(true)
                } catch {
                    print("Exception configuring the audio session instance.")
                }
                
                // Find an audio component.
                var componentDescription = AudioComponentDescription()
                
                componentDescription.componentType = kAudioUnitType_Output
                componentDescription.componentSubType = kAudioUnitSubType_RemoteIO
                componentDescription.componentManufacturer = kAudioUnitManufacturer_Apple
                componentDescription.componentFlags = 0
                componentDescription.componentFlagsMask = 0
                
                let component = AudioComponentFindNext(nil, &componentDescription)
                guard component != nil else {
                    print("AudioComponentFindNext() failed with a nil component.")
                    return
                }
                
                if let component = component {
                    // Set up the audio unit.
                    status = AudioComponentInstanceNew(component, &self.audioComponent)
                    guard status == noErr else {
                        print("AudioComponentInstanceNew() failed, status = \(status)")
                        return
                    }
                    
                    if let audioComponent = self.audioComponent {
                        let uInt32Size = UInt32(MemoryLayout<UInt32>.size)
                        var one:UInt32 = 1
                        
                        // Support input and output (microphone and speaker).
                        status = AudioUnitSetProperty(audioComponent, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, uInt32Size)
                        guard status == noErr else {
                            print("AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input) failed, status = \(status)")
                            return
                        }
                        status = AudioUnitSetProperty(audioComponent, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, uInt32Size)
                        guard status == noErr else {
                            print("AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output) failed, status = \(status)")
                            return
                        }
                        
                        var ioFormat = AudioStreamBasicDescription()
                        
                        ioFormat.mSampleRate = self.sampleRate
                        ioFormat.mFormatID = kAudioFormatLinearPCM
                        ioFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved
                        ioFormat.mChannelsPerFrame = 1
                        ioFormat.mBitsPerChannel = 32
                        ioFormat.mBytesPerPacket = 4
                        ioFormat.mFramesPerPacket = 1
                        ioFormat.mBytesPerFrame = 4
                        
                        let audioStreamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
                        
                        status = AudioUnitSetProperty(audioComponent, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &ioFormat, audioStreamSize)
                        guard status == noErr else {
                            print("AudioUnitSetProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input) failed, status = \(status)")
                            return
                        }
                        status = AudioUnitSetProperty(audioComponent, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &ioFormat, audioStreamSize)
                        guard status == noErr else {
                            print("AudioUnitSetProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output) failed, status = \(status)")
                            return
                        }
                        
                        var maxFramesPerSlice = 4096
                        status = AudioUnitSetProperty(audioComponent, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, uInt32Size)
                        guard status == noErr else {
                            print("AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global) failed, status = \(status)")
                            return
                        }
                        
                        var renderCallback = AURenderCallbackStruct(inputProc: AudioController_RenderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
                        
                        status = AudioUnitSetProperty(audioComponent, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
                        guard status == noErr else {
                            print("AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input) failed, status = \(status)")
                            return
                        }
                        
                        status = AudioUnitInitialize(audioComponent)
                        guard status == noErr else {
                            print("AudioUnitInitialize() failed, status = \(status)")
                            return
                        }
                        
                        self.start()
                    }
                }
                                
                let nc = NotificationCenter.default
                
                nc.addObserver(forName: .NSExtensionHostDidEnterBackground, object: nil, queue: .main) { _ in
                    UIDevice.current.isBatteryMonitoringEnabled = true

                    self.backgroundDisableTimer = Timer.scheduledTimer(withTimeInterval: Double(self.backgroundDisableTimerDelay), repeats: true, block: { _ in
                        if self.isRunning && UIDevice.current.batteryState == .unplugged {
                            self.stop()
                            
                            print("AudioMonitor was disabled while unplugged after a \(self.backgroundDisableTimerDelay) second timeout. Set AudioMonitor.backgroundDisableTimerDelay to adjust this delay.")
                            
                            self.wasRunningBeforeBackgrounding = true
                            
                            self.backgroundDisableTimer?.invalidate()
                            self.backgroundDisableTimer = nil
                        }
                    })
                }
                
                
                nc.addObserver(forName: .NSExtensionHostWillEnterForeground, object: nil, queue: .main) { _ in
                    UIDevice.current.isBatteryMonitoringEnabled = false
                    
                    if self.wasRunningBeforeBackgrounding {
                        self.start()
                        
                        self.wasRunningBeforeBackgrounding = false
                    }
                    
                    self.backgroundDisableTimer?.invalidate()
                    self.backgroundDisableTimer = nil
                }
            } else {
                print("AVAudioSession.sharedInstance().requestRecordPermission, permission was disallowed.")
            }
        }
    }
    
    deinit {
        stop()
    }
    
    /// Takes the current sample of sound and collects its pitch and volume data.
    ///
    /// - localizationKey: AudioMonitor.currentSample
    public var currentSample: Tone {
        var tone: Tone
        
        if axOverrideTimer != nil {
            tone = inputSimTone
        } else {
            let pitch = Double(self.frequency(buffer: accumulationBuffer, accumulationLength: accumulationLength, samplingFrequency: sampleRate, autocorrelationDepth: autocorrelationDepth))
            let volume = Double(self.volume(buffer: accumulationBuffer, accumulationLength: accumulationLength))
            
            tone = Tone(pitch: pitch, volume: volume)
        }
        
        return tone
    }
    
    /// Tells the AudioMonitor to start collecting data.
    ///
    /// - localizationKey: AudioMonitor.start()
    public func start() {
        let component = audioComponent!,
            status = AudioOutputUnitStart(component)
        guard status == noErr else {
            print("AudioOutputUnitStart() failed, status = \(status)")
            return
        }
        
        isRunning = true
    }
    
    /// Tells the AudioMonitor to stop collecting data.
    ///
    /// - localizationKey: AudioMonitor.stop()
    public func stop() {
        let component = audioComponent!,
            status = AudioOutputUnitStop(component)
        guard status == noErr else {
            print("AudioOutputUnitStop() failed, status = \(status)")
            return
        }
        
        isRunning = false
    }
    
    /// Sets the function that's called when the tone sensor is updated.
    /// - parameter handler: The function to be called whenever the tone data is updated.
    ///
    /// - localizationKey: AudioMonitor.setOnUpdateHandler(_:)
    public func setOnUpdateHandler(_ handler: @escaping ((Tone) -> Void)) {
        didUpdateToneHandler = handler
    }
    
    var inputSimTone = Tone(pitch: 0.0, volume: 0.0) {
        didSet {
            axOverrideTimer?.invalidate()
                        
            axOverrideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                self.axOverrideTimer?.invalidate()
                self.axOverrideTimer = nil
            }
        }
    }
    
    public func performRender(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                       timeStamp: UnsafePointer<AudioTimeStamp>,
                       busNumber: UInt32,
                       numberFrames: UInt32,
                       ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus
    {
        if let audioComponent = audioComponent {
            let ioPtr = UnsafeMutableAudioBufferListPointer(ioData)
            let channel = Int(busNumber)
            let buffer = ioPtr[channel].mData!.assumingMemoryBound(to: Float.self)
            
            let status = AudioUnitRender(audioComponent, ioActionFlags, timeStamp, 1, numberFrames, ioData)
            guard status == noErr else {
                print("AudioUnitRender() failed, status = \(status)")
                
                return status
            }
            
            accumulate(buffer:buffer, frameCount: numberFrames)
            
            // Wipe rendered microphone audio.
            for i in 0 ..< ioPtr.count {
                memset( ioPtr[i].mData!, 0, Int(ioPtr[i].mDataByteSize))
            }
            
            if let didUpdateToneHandler = self.didUpdateToneHandler {
                DispatchQueue.main.async {
                    didUpdateToneHandler(self.currentSample)
                }
            }
        }
        
        return noErr
    }
    
    func accumulate(buffer:UnsafePointer<Float>, frameCount: UInt32) {
        let frameMemorySize = MemoryLayout<Float>.size*Int(frameCount)
        
        if accumulationBufferOffset + frameMemorySize >= accumulationLength {
            accumulationBufferOffset = 0
        }
        
        memmove(accumulationBuffer.advanced(by: accumulationBufferOffset), buffer, frameMemorySize);
        accumulationBufferOffset = accumulationBufferOffset + Int(frameMemorySize)
    }
    
    func frequency(buffer:UnsafePointer<Float>, accumulationLength:UInt, samplingFrequency:Double, autocorrelationDepth:UInt) -> Float {
        var resultHz:Float = 0.0
        let bufferLength = accumulationLength - accumulationLength%4 // Round down to a multiple of 4 for Accelerate routines.
        let autocorrelationResult = UnsafeMutablePointer<Float>.allocate(capacity: Int(autocorrelationDepth))
        
        // autocorrelate.
        vDSP_conv(buffer, 1, buffer, 1, autocorrelationResult, 1, autocorrelationDepth, bufferLength/2)
        
        var firstPeakIndex = 0
        
        for i in 1 ..< Int(autocorrelationDepth) {
            let previous:Int = i - 1
            let next:Int = i + 1
            let previousResult = autocorrelationResult[previous]
            let currentResult = autocorrelationResult[i]
            let nextResult = autocorrelationResult[next]
            
            if currentResult > previousResult && currentResult > nextResult {
                firstPeakIndex = i
                
                break
            }
        }
        
        autocorrelationResult.deallocate()
        
        if autocorrelationResult[firstPeakIndex] > 0.3 {
            resultHz = Float(sampleRate/Double(firstPeakIndex))
        }
        
        if resultHz > 5000.0 {
            resultHz = 0.0
        }
        
        return resultHz
    }
    
    func volume(buffer:UnsafePointer<Float>, accumulationLength:UInt) -> Float {
        var resultMax:Float = 0.0
        let bufferLength = accumulationLength - accumulationLength%4 // Round down to a multiple of 4 for Accelerate routines.
        
        // autocorrelate.
        vDSP_maxv(buffer, 1, &resultMax, bufferLength)
        
        return resultMax
    }
}

/// Tone is a struct that holds the pitch and volume.
///
/// - localizationKey: Tone
public struct Tone: Codable {
    public var pitch: Double
    public var volume: Double
    
    /// Tone is a struct that holds the pitch and volume.
    ///
    /// - Parameter pitch: A tone’s highness or lowness.
    /// - Parameter volume: A tone’s loudness or softness.
    ///
    /// - localizationKey: Tone(pitch:volume:)
    public init(pitch: Double, volume: Double) {
        self.pitch = pitch
        self.volume = volume
    }
}
