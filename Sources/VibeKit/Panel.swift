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
        animationBehavior = .none
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

    /// True while the panel is open off screen to warm up. It does not count as visible.
    private var prewarming = false
    private var hostingView: NSHostingView<PanelContent>?
    private var preferredHeight: CGFloat = 200
    private var deferredHeight: CGFloat?
    /// Counts opens, so work scheduled for one open can tell when the panel has opened again since.
    private var opens = 0
    /// Runs while an auto-hiding menu bar is showing under the pointer, to give the panel its focus back after.
    private var menuBarWatch: Timer?

    var isVisible: Bool { panel.isVisible && !prewarming }
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
        opens += 1
        deferredHeight = nil
        var initial = PanelRootView.InitialState()
        initial.tab = tab ?? store.settings.lastTab
        initial.route = route
        // The view only reports tab changes made inside it. `toggle` needs to know the tab it opened on.
        store.settings.lastTab = initial.tab
        // Reuse the AppKit window and hosting infrastructure, but give each opening fresh view state.
        let hosting = prepareHosting()
        hosting.rootView = PanelContent(root: makeRoot(initial: initial), generation: opens)
        position(height: preferredHeight)
        hosting.layoutSubtreeIfNeeded()
        applyPendingResize()

        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        // Scanning stays off the critical path and never blocks showing the cached list.
        store.isPanelOpen = true
        if Self.pointerIsInMenuBar() { watchMenuBar(front: NSWorkspace.shared.frontmostApplication) }
        onVisibilityChange?(true)

        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func makeRoot(initial: PanelRootView.InitialState) -> PanelRootView {
        let generation = opens
        return PanelRootView(store: store, prompts: prompts,
                      onHeightChange: { [weak self] height in
                          guard let self, self.opens == generation else { return }
                          self.resize(to: height)
                      },
                      onUsePrompt: { [weak self] prompt in self?.use(prompt) },
                      close: { [weak self] in self?.close() },
                      initial: initial)
    }

    /// Copies the prompt, closes, and pastes it into the app in front when that is on and allowed.
    private func use(_ prompt: Prompt) {
        prompts.copy(prompt)
        guard store.settings.pasteOnUse && PromptStore.canPaste else { return close() }
        close { [weak self] in
            guard let self else { return }
            let open = self.opens
            // Give the app in front a moment to take keyboard focus back from the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    // Opened again meanwhile: the keystroke would land in the panel, not the app the prompt was for.
                    guard let self, self.opens == open, !self.panel.isVisible else { return }
                    PromptStore.pasteIntoFrontApp()
                }
            }
        }
    }

    private func prepareHosting() -> NSHostingView<PanelContent> {
        if let hostingView { return hostingView }
        let hosting = NSHostingView(rootView: PanelContent(root: nil, generation: opens))
        hosting.sizingOptions = []
        hostingView = hosting
        panel.contentView = makeBackground(containing: hosting)
        return hosting
    }

    /// Prime SwiftUI and AppKit once. Keep only an empty hosting view while closed:
    /// no server rows, observations, log readers or animations remain active.
    func prewarm() {
        guard !panel.isVisible, hostingView == nil else { return }
        prewarming = true
        let hosting = prepareHosting()
        hosting.rootView = PanelContent(root: makeRoot(initial: .init(tab: store.settings.lastTab)), generation: opens)
        panel.alphaValue = 0
        panel.setFrame(NSRect(x: -30_000, y: -30_000, width: PanelMetrics.width, height: contentHeight), display: false)
        syncContentFrame()
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.prewarming else { return }
            self.prewarming = false
            self.panel.orderOut(nil)
            self.hostingView?.rootView = PanelContent(root: nil, generation: self.opens)
        }
    }

    func close(then completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard isVisible else { return }
        opens += 1
        deferredHeight = nil
        stopMenuBarWatch()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        hostingView?.rootView = PanelContent(root: nil, generation: opens)
        store.isPanelOpen = false
        onVisibilityChange?(false)
        completion?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        // An auto-hiding menu bar takes the keyboard while it slides in under the pointer. That is not you leaving:
        // stay open, so a click on the icon closes the panel instead of reopening it. Clicks elsewhere still close it.
        if Self.pointerIsInMenuBar() {
            watchMenuBar(front: NSWorkspace.shared.frontmostApplication)
        } else {
            close()
        }
    }

    func windowDidResize(_ notification: Notification) {
        syncContentFrame()
    }

    private static func pointerIsInMenuBar() -> Bool {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return false }
        return pointer.y >= screen.frame.maxY - Placement.menuBarHeight(on: screen) - 4
    }

    /// Once the pointer leaves the menu bar, the panel takes the keyboard back, unless you switched apps meanwhile.
    private func watchMenuBar(front: NSRunningApplication?) {
        stopMenuBarWatch()
        menuBarWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !Self.pointerIsInMenuBar() else { return }
                self.stopMenuBarWatch()
                guard self.isVisible, !self.panel.isKeyWindow else { return }
                if NSWorkspace.shared.frontmostApplication == front {
                    self.panel.makeKey()
                } else {
                    self.close()
                }
            }
        }
    }

    private func stopMenuBarWatch() {
        menuBarWatch?.invalidate()
        menuBarWatch = nil
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
        position(height: preferredHeight)
    }

    /// Preferences arrive inside SwiftUI's layout transaction. Resize outside that transaction:
    /// changing the window from it can leave the rendered layers at their previous offsets.
    func resize(to height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let first = deferredHeight == nil
        deferredHeight = height
        guard first else { return }
        let generation = opens
        DispatchQueue.main.async { [weak self] in
            guard let self, self.opens == generation else { return }
            self.applyPendingResize()
        }
    }

    private func applyPendingResize() {
        guard let height = deferredHeight else { return }
        deferredHeight = nil
        preferredHeight = height
        position(height: height)
    }

    private func position(height: CGFloat) {
        guard let placement else { return }
        let frame = PanelGeometry.frame(midX: placement.midX, top: placement.top,
                                        visibleFrame: placement.screen.visibleFrame, preferredHeight: height)
        contentHeight = frame.height
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.contentView?.layoutSubtreeIfNeeded()
        syncContentFrame()
        hostingView?.layoutSubtreeIfNeeded()
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
            // The icon moves during auto-hide. Only its x coordinate is an anchor; the screen owns y.
            top = underMenuBar - 6
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

/// Geometry shared by initial presentation, live resizing and display changes.
/// Use the usable horizontal bounds too, so a side Dock cannot cover panel actions.
enum PanelGeometry {
    static func frame(midX: CGFloat, top: CGFloat, visibleFrame: CGRect, preferredHeight: CGFloat) -> CGRect {
        let width = min(PanelMetrics.width, max(1, visibleFrame.width - 16))
        let safeTop = min(top, visibleFrame.maxY - 6)
        let availableHeight = max(1, safeTop - visibleFrame.minY - 12)
        let height = min(max(preferredHeight, 120), PanelMetrics.maxHeight, availableHeight)
        let x = min(max(midX - width / 2, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        return CGRect(x: x, y: safeTop - height, width: width, height: height)
    }
}

/// Removing the root releases the live content without discarding SwiftUI's hosting infrastructure.
private struct PanelContent: View {
    let root: PanelRootView?
    let generation: Int

    var body: some View {
        Group {
            if let root { root.id(generation) }
        }
    }
}
