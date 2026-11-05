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
    targets: [
        .target(
            name: "MyHomeCore",
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
