// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeKit", targets: ["VibeKit"]),
    ],
    targets: [
        .target(name: "VibeKitCore"),
        .executableTarget(name: "VibeKit", dependencies: ["VibeKitCore"]),
        .testTarget(name: "VibeKitCoreTests", dependencies: ["VibeKitCore"]),
        .testTarget(name: "VibeKitTests", dependencies: ["VibeKit"]),
    ]
)
