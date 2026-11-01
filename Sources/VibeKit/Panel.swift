import AppKit
import SwiftUI

/// A borderless panel that drops from the menu bar like a system menu.
/// It never activates Vibe Kit, so the app you were using stays frontmost.
final class Panel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PanelMetrics {
    static let width: CGFloat = 384
    static let cornerRadius: CGFloat = 16
    static let maxHeight: CGFloat = 640
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel = Panel()
    private let store: ServerStore
    private var monitor: Any?
    private var placement: Placement?
    private var contentHeight: CGFloat = 200

    /// True while the panel fades out after `close()`.
    private var closing = false

    var isVisible: Bool { panel.isVisible && !closing }
    var onVisibilityChange: ((Bool) -> Void)?

    init(store: ServerStore) {
        self.store = store
        super.init()
        panel.delegate = self
    }

    func toggle(from button: NSStatusBarButton?) {
        if isVisible { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton?) {
        placement = Placement(button: button)
        closing = false
        // Build the SwiftUI tree fresh on every open and drop it on close, so nothing renders while hidden.
        let root = PanelRootView(store: store, onHeightChange: { [weak self] height in self?.resize(to: height) }, close: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = makeBackground(containing: hosting)

        store.isPanelOpen = true
        position(height: contentHeight)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        onVisibilityChange?(true)

        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard panel.isVisible, !closing else { return }
        closing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // The panel may have been reopened while it faded out.
                guard let self, self.closing else { return }
                self.closing = false
                self.panel.orderOut(nil)
                self.panel.contentView = nil
                self.store.isPanelOpen = false
            }
        })
        onVisibilityChange?(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makeBackground(containing content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        // Liquid Glass needs the macOS 26 SDK (Swift 6.2). Older toolchains build the material fallback only.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = PanelMetrics.cornerRadius
            glass.contentView = content
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = PanelMetrics.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    private func resize(to height: CGFloat) {
        let clamped = min(max(height, 120), maxHeight())
        guard abs(clamped - contentHeight) > 0.5 || !panel.isVisible else { return }
        contentHeight = clamped
        position(height: clamped)
    }

    private func maxHeight() -> CGFloat {
        guard let placement else { return PanelMetrics.maxHeight }
        return min(PanelMetrics.maxHeight, placement.top - placement.screen.visibleFrame.minY - 12)
    }

    private func position(height: CGFloat) {
        guard let placement else { return }
        let width = PanelMetrics.width
        let visible = placement.screen.frame
        let x = min(max(placement.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        panel.setFrame(NSRect(x: x, y: placement.top - height, width: width, height: height), display: true)
    }
}

/// Where the panel hangs, worked out once when it opens. Keeping it fixed means the panel does not jump
/// when an auto-hiding menu bar slides away, and it opens in the right place from the keyboard shortcut
/// while the menu bar is hidden, on another display, or when the icon is hidden behind the notch.
@MainActor
struct Placement {
    let screen: NSScreen
    /// Horizontal center: under the icon when it is on this screen, else near the right edge.
    let midX: CGFloat
    /// Top edge of the panel, just below where the menu bar sits even if it is hidden right now.
    let top: CGFloat

    init(button: NSStatusBarButton?) {
        let screens = NSScreen.screens
        let pointer = NSEvent.mouseLocation
        let pointerScreen = screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? screens[0]

        var iconFrame: NSRect?
        if let button, let window = button.window, window.isVisible {
            iconFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        // The icon's screen is the one it sits above. An auto-hidden menu bar moves the icon just past the top edge.
        let iconScreen = iconFrame.flatMap { icon in
            screens.first { icon.midX >= $0.frame.minX && icon.midX < $0.frame.maxX && abs(icon.maxY - $0.frame.maxY) < 80 }
        }
        let opensFromClick = NSApp.currentEvent.map { $0.type == .leftMouseUp || $0.type == .rightMouseUp } ?? false
        screen = (opensFromClick ? iconScreen : nil) ?? pointerScreen

        let menuBar = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        let underMenuBar = screen.frame.maxY - menuBar
        if let icon = iconFrame, iconScreen == screen, !Self.isUnderNotch(icon, on: screen) {
            midX = icon.midX
            // Below the icon when the menu bar is showing; where the menu bar would end when it is hidden.
            top = min(icon.minY, underMenuBar) - 6
        } else {
            midX = screen.frame.maxX - PanelMetrics.width / 2 - 12
            top = underMenuBar - 6
        }
    }

    /// Menu bar icons that do not fit beside the notch are hidden behind it.
    private static func isUnderNotch(_ icon: NSRect, on screen: NSScreen) -> Bool {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
        return icon.midX > left.maxX && icon.midX < right.minX
    }
}
