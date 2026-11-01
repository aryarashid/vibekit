import AppKit
import SwiftUI
import VibeKitCore

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

    /// The panel sits exactly where it was put. AppKit must not nudge it, for example when the menu bar hides.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
    private let prompts: PromptStore
    private var monitor: Any?
    private var placement: Placement?
    private var contentHeight: CGFloat = 200

    /// True while the panel fades out after `close()`.
    private var closing = false
    /// True while the panel is open off screen to warm up. It does not count as visible.
    private var prewarming = false
    private weak var hostingView: NSView?
    private var positioning = false
    private var deferredHeight: CGFloat?

    var isVisible: Bool { panel.isVisible && !closing && !prewarming }
    var onVisibilityChange: ((Bool) -> Void)?

    init(store: ServerStore, prompts: PromptStore) {
        self.store = store
        self.prompts = prompts
        super.init()
        panel.delegate = self
        // Displays come and go, and the menu bar can change height. Keep the open panel under it and on screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Opens on `tab`, or on the tab used last. A second press of the same shortcut closes the panel;
    /// a different tab's shortcut switches to it.
    func toggle(from button: NSStatusBarButton?, tab: PanelTab? = nil) {
        if isVisible {
            if let tab, tab != store.settings.lastTab { show(from: button, tab: tab) } else { close() }
        } else {
            show(from: button, tab: tab)
        }
    }

    func show(from button: NSStatusBarButton?, tab: PanelTab? = nil, route: Route = .list) {
        if prewarming {
            prewarming = false
            panel.orderOut(nil)
        }
        let wasVisible = isVisible
        if !wasVisible { placement = Placement(button: button) }
        closing = false
        var initial = PanelRootView.InitialState()
        initial.tab = tab ?? store.settings.lastTab
        initial.route = route
        // Build the SwiftUI tree fresh on every open and drop it on close, so nothing renders while hidden.
        let hosting = NSHostingView(rootView: makeRoot(initial: initial))
        hosting.sizingOptions = []
        hostingView = hosting
        panel.contentView = makeBackground(containing: hosting)

        store.isPanelOpen = true
        position(height: contentHeight)
        if wasVisible {
            panel.alphaValue = 1
            panel.makeKey()
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        onVisibilityChange?(true)

        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func makeRoot(initial: PanelRootView.InitialState) -> PanelRootView {
        PanelRootView(store: store, prompts: prompts,
                      onHeightChange: { [weak self] height in self?.resize(to: height) },
                      onUsePrompt: { [weak self] prompt in self?.use(prompt) },
                      close: { [weak self] in self?.close() },
                      initial: initial)
    }

    /// Copies the prompt, closes, and pastes it into the app in front when that is on and allowed.
    private func use(_ prompt: Prompt) {
        prompts.copy(prompt)
        guard store.settings.pasteOnUse && PromptStore.canPaste else { return close() }
        close {
            // Give the app in front a moment to take keyboard focus back from the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { PromptStore.pasteIntoFrontApp() }
        }
    }

    /// The first open after launch loads SwiftUI's code and sets up the window, which can take most of a second.
    /// Opening the panel once, invisible and off every screen, shortly after launch moves that cost out of the first click.
    func prewarm() {
        guard !panel.isVisible else { return }
        prewarming = true
        let hosting = NSHostingView(rootView: makeRoot(initial: .init(tab: store.settings.lastTab)))
        hosting.sizingOptions = []
        panel.contentView = makeBackground(containing: hosting)
        panel.alphaValue = 0
        panel.setFrame(NSRect(x: -30_000, y: -30_000, width: PanelMetrics.width, height: contentHeight), display: false)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.prewarming else { return }
            self.prewarming = false
            self.panel.orderOut(nil)
            self.panel.contentView = nil
        }
    }

    func close(then completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard isVisible else { return }
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
                completion?()
            }
        })
        onVisibilityChange?(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// The panel's glass with the SwiftUI content inside. Frames, not Auto Layout: the glass does not resize its
    /// content view by itself, and a stale content size showed the panel's content shifted or cut off.
    /// `position` sets the content's frame on every resize.
    private func makeBackground(containing content: NSView) -> NSView {
        let bounds = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: contentHeight)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        content.frame = bounds
        // Liquid Glass needs the macOS 26 SDK (Swift 6.2). Older toolchains build the material fallback only.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = PanelMetrics.cornerRadius
            glass.contentView = content
            return glass
        }
        #endif
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = PanelMetrics.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        return effect
    }

    /// Makes the SwiftUI view exactly fill the panel.
    private func syncContentFrame() {
        guard let background = panel.contentView, let content = hostingView, content.superview != nil else { return }
        if content.frame != background.bounds { content.frame = background.bounds }
    }

    private func screensChanged() {
        guard isVisible, let old = placement else { return }
        // Keep the spot the panel opened at, but move it if that display is gone or its menu bar grew.
        let fresh = Placement(button: nil, on: NSScreen.screens.contains(old.screen) ? old.screen : nil)
        placement = Placement(screen: fresh.screen, midX: fresh.screen == old.screen ? old.midX : fresh.midX,
                              top: min(fresh.screen == old.screen ? old.top : fresh.top, fresh.safeTop))
        position(height: min(contentHeight, maxHeight()))
    }

    /// SwiftUI can report a new height while the panel is being resized, from inside `setFrame`. Applying it
    /// there nests one resize in another, and the window and its content end up at different heights.
    /// Such a report waits for the outer resize to finish.
    private func resize(to height: CGFloat) {
        guard !positioning else {
            let first = deferredHeight == nil
            deferredHeight = height
            if first {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let height = self.deferredHeight else { return }
                    self.deferredHeight = nil
                    self.resize(to: height)
                }
            }
            return
        }
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
        positioning = true
        defer { positioning = false }
        let width = PanelMetrics.width
        let visible = placement.screen.frame
        let x = min(max(placement.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        panel.setFrame(NSRect(x: x, y: placement.top - height, width: width, height: height), display: false)
        syncContentFrame()
        panel.displayIfNeeded()
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

    /// The lowest the top edge may sit: under the menu bar and the camera housing, shown or hidden.
    var safeTop: CGFloat { screen.frame.maxY - Self.menuBarHeight(on: screen) - 6 }

    init(screen: NSScreen, midX: CGFloat, top: CGFloat) {
        self.screen = screen
        self.midX = midX
        self.top = top
    }

    static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
    }

    init(button: NSStatusBarButton?, on fixedScreen: NSScreen? = nil) {
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
        screen = fixedScreen ?? (opensFromClick ? iconScreen : nil) ?? pointerScreen

        let menuBar = Self.menuBarHeight(on: screen)
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
