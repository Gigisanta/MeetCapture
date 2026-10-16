// swift-tools-version: 6.0
// MeetCapture: macOS menu-bar app (Apple Silicon, macOS 14.4+).
//
//   swift build -c release --product MeetCapture   → .build/release/MeetCapture
//   swift test                                     → MeetCaptureCoreTests
//   ./build.sh                                     → wraps the release build in MeetCapture.app
//
// Sources are Swift 5 language mode with strict concurrency checking enabled
// (the same diagnostics the old swiftc invocation used via
// -strict-concurrency=complete), not full Swift 6 data-race enforcement.
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "MeetCapture",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "MeetCapture", targets: ["MeetCapture"]),
        .library(name: "MeetCaptureCore", targets: ["MeetCaptureCore"]),
    ],
    dependencies: [
        // Parakeet ASR + offline diarization on the ANE. Pinned by revision:
        // no tagged release has the Parakeet ultra model yet.
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "bd11ac8da17a944a7291a2c76e9a172eb275f629"),
    ],
    targets: [
        .target(
            name: "MeetCaptureCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MeetCaptureCore",
            swiftSettings: strictConcurrency,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MeetCapture",
            dependencies: ["MeetCaptureCore"],
            path: "Sources/MeetCapture",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "MeetCaptureCoreTests",
            dependencies: ["MeetCaptureCore"],
            path: "Tests/MeetCaptureCoreTests",
            swiftSettings: strictConcurrency
        ),
    ]
)
