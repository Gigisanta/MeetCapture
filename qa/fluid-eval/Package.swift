// swift-tools-version: 6.0
// fluid-eval: FluidAudio candidates for qa/asr_eval.py (Fase 3a).
//
// Separate package, not a target of the app. It builds the same way the app
// would consume FluidAudio: Swift 5 language mode with strict concurrency, so
// a clean build here answers "does FluidAudio fit the app's toolchain?".
//
//   swift build -c release   → .build/release/fluid-eval
//
// FluidAudio is pinned by revision: no tagged release (latest v0.9.1) has
// CustomVocabulary or Parakeet ultra.
import PackageDescription

let package = Package(
    name: "fluid-eval",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "bd11ac8da17a944a7291a2c76e9a172eb275f629"
        ),
    ],
    targets: [
        .executableTarget(
            name: "fluid-eval",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
