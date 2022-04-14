// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AudioMonitor",
    products: [
        .library(
            name: "AudioMonitor",
            targets: ["AudioMonitor"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AudioMonitor",
            dependencies: []),
        .testTarget(
            name: "AudioMonitorTests",
            dependencies: ["AudioMonitor"]),
    ]
)
