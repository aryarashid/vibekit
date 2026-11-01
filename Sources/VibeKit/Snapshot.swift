import AppKit
import SwiftUI
import VibeKitCore

/// `VibeKit --snapshot out.png [--dark] [--select] [--expand] [--select-port N] [--expand-port N] [--settings]
/// [--prompts] [--edit-prompt] [--query text] [--demo] [--transparent]` renders the panel to a PNG, for design review and the README.
/// `--demo` shows sample servers instead of yours. Glass cannot be captured offscreen, so the panel sits on the
/// window background color, or on nothing with `--transparent` for compositing.
@MainActor
enum Snapshot {
    static func render(to path: String) {
        let args = ProcessInfo.processInfo.arguments
        let store = ServerStore(settings: Settings())
        let prompts = PromptStore(persists: !args.contains("--demo"))
        if args.contains("--demo") {
            DemoData.load(into: store)
            DemoData.load(into: prompts)
        } else {
            store.isPanelOpen = true
            pump(seconds: 5)
        }
        func port(after flag: String) -> UInt16? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? UInt16(args[$0 + 1]) : nil }
        }

        var initial = PanelRootView.InitialState()
        initial.selectFirst = args.contains("--select")
        initial.expandFirst = args.contains("--expand")
        if args.contains("--settings") { initial.route = .settings }
        if args.contains("--prompts") { initial.tab = .prompts }
        if args.contains("--edit-prompt") { initial.route = .prompt(prompts.prompts.first?.id) }
        if let index = args.firstIndex(of: "--query"), index + 1 < args.count { initial.query = args[index + 1] }
        initial.selectPort = port(after: "--select-port")
        initial.expandPort = port(after: "--expand-port")

        var height: CGFloat = 400
        let root = PanelRootView(store: store, prompts: prompts,
                                 onHeightChange: { height = min(max($0, 120), PanelMetrics.maxHeight) },
                                 onUsePrompt: { _ in }, close: {}, initial: initial)
        let background = args.contains("--transparent") ? Color.clear : Color(nsColor: .windowBackgroundColor)
        let hosting = NSHostingView(rootView: root.background(background))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: PanelMetrics.width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        pump(seconds: 0.6)
        window.setContentSize(NSSize(width: PanelMetrics.width, height: height))
        pump(seconds: 0.6)

        let scale: CGFloat = 2
        let bounds = hosting.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path) (\(Int(bounds.width))x\(Int(bounds.height)))")
    }

    private static func pump(seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }
}
