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
        // Exactly WhisperKit 1.1.1 (v1.1.1), not a moving branch. The release's
        // Swift 6.2 manifest uses unsafe library-evolution flags, which SwiftPM
        // permits for a revision-pinned dependency but not a version requirement.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git",
                 revision: "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4"),
    ],
    targets: [
        .target(
            name: "MeetCaptureCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
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
