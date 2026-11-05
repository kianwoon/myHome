// swift-tools-version:5.9
// baseline-guard:allow new package scaffold, no prior baseline

import PackageDescription

let package = Package(
    name: "MyHomeApp",
    platforms: [
        .macOS(.v13)
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
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8")
    ],
    targets: [
        .target(
            name: "MyHomeCore",
            dependencies: [
                .product(name: "sherpa-onnx", package: "sherpa-onnx")
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
            path: "Tests/MyHomeCoreTests"
        ),
        .executableTarget(
            name: "BridgePingTest",
            dependencies: ["MyHomeCore"],
            path: "Sources/BridgePingTest"
        )
    ]
)
