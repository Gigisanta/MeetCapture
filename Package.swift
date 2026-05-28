// swift-tools-version:5.9
// MeetCapture v4 — Swift Package Manager manifest

import PackageDescription

let package = Package(
    name: "MeetCapture",
    platforms: [
        .macOS(.v14)  // macOS 14 Sonoma minimum (ScreenCaptureKit, MenuBarExtra)
    ],
    products: [
        .executable(name: "MeetCapture", targets: ["MeetCapture"])
    ],
    targets: [
        .executableTarget(
            name: "MeetCapture",
            path: "Sources/MeetCapture",
            resources: [
                // Info.plist is handled by build.sh, not SPM resources
            ]
        )
    ]
)
