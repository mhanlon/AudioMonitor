//
//  File.swift
//  AudioMonitor
//
//  Created by Matthew Hanlon on 4/7/22.
//

import SwiftUI

public struct MeterView: View {
    public var volume: Double = 0.0
    public var stepByValue: Double = 0.075
    public var volumes: [Double] {
        Array(stride(from: 0.0, to: 1.0, by: stepByValue))
    }
    
    public init(volume: Double = 0.0, stepByValue: Double = 0.075) {
        self.volume = volume
        self.stepByValue = stepByValue
    }
    
    public var body: some View {
        HStack {
            ForEach(volumes, id: \.self) { value in 
                RoundedRectangle(cornerRadius: 5)
                    .foregroundColor(value < volume ? .green : .red)
                    .frame(minWidth: 10, maxHeight: 30)
            }
        }
        .padding()
    }
    
}
