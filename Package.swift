// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeKit", targets: ["VibeKit"]),
    ],
    dependencies: [
        // Auto-updates. Only the GUI app starts it; see Sources/VibeKit/Updater.swift.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "VibeKitCore"),
        .executableTarget(name: "VibeKit", dependencies: [
            "VibeKitCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "VibeKitCoreTests", dependencies: ["VibeKitCore"]),
        .testTarget(name: "VibeKitTests", dependencies: ["VibeKit"]),
    ]
)
