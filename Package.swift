// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcessKit",
    // Mac only: it starts other programs, which iOS doesn't allow.
    platforms: [.macOS(.v14)],
    products: [
        // Running a command: run, runSync, lines, locate. No SwiftUI.
        .library(name: "ProcessKit", targets: ["ProcessKit"]),
    ],
    targets: [
        .target(name: "ProcessKit"),
        .testTarget(name: "ProcessKitTests", dependencies: ["ProcessKit"]),
    ]
)
