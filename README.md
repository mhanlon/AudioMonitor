# AudioMonitor

This is a little Swift Package that allows you to listen to the microphone and report it's volume and pitch.

It is taken almost wholesale from the Sensor Arcade Playground Book's `ToneOutput` class.

## Usage
### `AudioMonitor`
 `AudioMonitor` requires that you've specified that your app, either in the Info.plist in Xcode or in the capabilities in Swift Playgrounds 4, that you make use of the microphone.

### `MeterView`
`MeterView` is a handy, pre-built view for you to use in your SwiftUI app where you can feed it a `Double` value between 0.0 and 1.0 and it will display a not super complex meter.
