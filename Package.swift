// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeKit", targets: ["VibeKit"]),
        .executable(name: "VibeKitLidHelper", targets: ["VibeKitLidHelper"]),
    ],
    dependencies: [
        // Auto-updates. Only the GUI app starts it; see Sources/VibeKit/Updater.swift.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // The lid sleep helper's rules, with no system calls of their own. Re-exported by VibeKitCore.
        .target(name: "VibeKitLidCore"),
        .target(name: "VibeKitCore", dependencies: ["VibeKitLidCore"]),
        .executableTarget(name: "VibeKit", dependencies: [
            "VibeKitCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        // The root LaunchDaemon behind "Stay awake after closing the lid". System frameworks only,
        // and only the lid sleep rules: linking all of VibeKitCore made it five times the size,
        // too big for the installer to carry to root inside one command.
        .executableTarget(name: "VibeKitLidHelper", dependencies: ["VibeKitLidCore"]),
        .testTarget(name: "VibeKitCoreTests", dependencies: ["VibeKitCore"]),
        // The helper is a dependency so `swift test` builds the binary its tests run.
        .testTarget(name: "VibeKitTests", dependencies: ["VibeKit", "VibeKitLidHelper"]),
    ]
)
