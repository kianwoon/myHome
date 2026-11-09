// swift-tools-version:5.9
// baseline-guard:allow new package scaffold, no prior baseline

import PackageDescription

let package = Package(
    name: "MyHomeApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MyHomeApp", targets: ["MyHomeApp"]),
        // Library product so the Xcode app target (MyHome.xcodeproj, generated
        // from project.yml) can depend on the same core the SwiftPM app uses.
        .library(name: "MyHomeCore", targets: ["MyHomeCore"])
    ],
    dependencies: [
        // Offline speech-to-text, the same engine stack the Pop app ships:
        // sherpa-onnx's SwiftPM product (static macOS XCFramework + the
        // `SherpaOnnx` Swift wrapper) runs Qwen3-ASR, SenseVoice and Silero VAD.
        // PINNED exact: the binary target's checksum is version-specific.
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
        // Google Cast (Chromecast / Google Home Mini) sender, pure Swift on
        // Network.framework. PINNED exact; requires macOS 14.
        .package(url: "https://github.com/CreatureSurvive/SwiftCast.git", exact: "1.0.1"),
        // Qwen3-ASR on MLX (Apple-silicon GPU), optional decode backend. Community
        // Swift port, the same revision Pop pins; PINNED (a moving branch would
        // change the build under us).
        .package(url: "https://github.com/Neywa-Labs/mlx-audio-swift.git", revision: "0e03fee81e87e6d6a186fb72610589bd92fc87cd")
    ],
    targets: [
        .target(
            name: "MyHomeCore",
            dependencies: [
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "SwiftCast", package: "SwiftCast"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift")
            ],
            path: "Sources/MyHomeCore"
        ),
        .executableTarget(
            name: "MyHomeApp",
            dependencies: ["MyHomeCore"],
            path: "Sources/MyHomeApp"
        ),
        .testTarget(
            name: "MyHomeCoreTests",
            dependencies: ["MyHomeCore"],
            path: "Tests/MyHomeCoreTests",
            // Jev decision envelopes (shapes from Pop's fixtures, fake ids only).
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "BridgePingTest",
            dependencies: ["MyHomeCore"],
            path: "Sources/BridgePingTest"
        ),
        // Read-only KEF qualification probe: `swift run KEFProbe <ipv4>`.
        .executableTarget(
            name: "KEFProbe",
            dependencies: ["MyHomeCore"],
            path: "Sources/KEFProbe"
        ),
        // Read-only Cast qualification probe: `swift run CastProbe [seconds]`.
        .executableTarget(
            name: "CastProbe",
            dependencies: ["MyHomeCore"],
            path: "Sources/CastProbe"
        )
    ]
)
