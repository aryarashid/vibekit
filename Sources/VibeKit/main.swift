import AppKit

let arguments = ProcessInfo.processInfo.arguments

if arguments.contains("--list") {
    // `VibeKit --list` prints what the menu would show, for scripts and debugging.
    ListCommand.run(all: arguments.contains("--all"))
    exit(0)
}

if arguments.contains("--toggle") {
    // `--toggle prompts` opens on the Prompts tab.
    let tab = arguments.firstIndex(of: "--toggle").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.toggleNotification, object: nil, userInfo: tab.map { ["tab": $0] }, deliverImmediately: true)
    exit(0)
}

if let index = arguments.firstIndex(of: "--bench") {
    let seconds = index + 1 < arguments.count ? Int(arguments[index + 1]) ?? 40 : 40
    Bench.run(seconds: seconds, panelOpen: arguments.contains("--open"))
    exit(0)
}

if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
    MainActor.assumeIsolated { Snapshot.render(to: arguments[index + 1]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
