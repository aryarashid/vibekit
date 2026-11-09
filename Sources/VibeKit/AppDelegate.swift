import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private lazy var store = ServerStore(settings: settings)
    private let prompts = PromptStore()
    private lazy var panel = PanelController(store: store, prompts: prompts)
    private var statusItem: NSStatusItem!
    private let hotKey = HotKey()
    private var observation: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "VibeKit"
        if let button = statusItem.button {
            button.image = Glyph.statusImage(live: false)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Vibe Kit"
        }

        store.onCountChange = { [weak self] count in self?.updateStatusItem(count: count) }
        panel.onVisibilityChange = { [weak self] visible in
            self?.statusItem.button?.highlight(visible)
        }
        store.start()
        settings.enableLaunchAtLoginOnFirstRun()
        applyHotKey()
        observeSettings()
        // `VibeKit --toggle` opens or closes the panel of the running copy, for scripts and launchers.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(toggleRequested), name: AppDelegate.toggleNotification, object: nil)
        // Services › Add to Vibe Kit, in the right-click menu of selected text in any app.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // Load SwiftUI before the first click, once launch has settled.
        DispatchQueue.main.async { [weak self] in self?.panel.prewarm() }
    }

    /// The Services menu item. Saves the selected text as a prompt and opens it so you can name it.
    @objc func addPrompt(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        let prompt = prompts.add(text: text)
        settings.lastTab = .prompts
        panel.show(from: statusItem.button, tab: .prompts, route: .prompt(prompt.id))
    }

    static let toggleNotification = Notification.Name("dev.vibekit.toggle")

    @objc private func toggleRequested(_ notification: Notification) {
        let tab = (notification.userInfo?["tab"] as? String).flatMap(PanelTab.init(rawValue:))
        panel.toggle(from: statusItem.button, tab: tab)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.hotKeyEnabled
            _ = settings.promptsHotKeyEnabled
            _ = settings.showCountInMenuBar
            _ = settings.showOtherListeners
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyHotKey()
                self.updateStatusItem(count: self.store.devServers.count)
                self.store.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func applyHotKey() {
        var taken: Set<String> = []
        if !hotKey.set(.panel, enabled: settings.hotKeyEnabled, action: { [weak self] in self?.togglePanel(tab: .servers) }) {
            taken.insert("⌃⌥⌘V")
        }
        if !hotKey.set(.prompts, enabled: settings.promptsHotKeyEnabled, action: { [weak self] in self?.togglePanel(tab: .prompts) }) {
            taken.insert("⌃⌥⌘P")
        }
        if settings.takenShortcuts != taken { settings.takenShortcuts = taken }
    }

    private func updateStatusItem(count: Int) {
        guard let button = statusItem.button else { return }
        button.image = Glyph.statusImage(live: count > 0)
        if settings.showCountInMenuBar && count > 0 {
            button.attributedTitle = NSAttributedString(string: "\(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
                .baselineOffset: 0.5,
            ])
        } else {
            button.attributedTitle = NSAttributedString()
        }
        button.setAccessibilityLabel(count == 1 ? "Vibe Kit, 1 dev server running" : "Vibe Kit, \(count) dev servers running")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel(tab: PanelTab? = nil) {
        panel.toggle(from: statusItem.button, tab: tab)
    }

    private func showMenu() {
        panel.close()
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Vibe Kit", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        let logs = NSMenuItem(title: "Show Logs Folder", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Vibe Kit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() { panel.show(from: statusItem.button) }
    @objc private func toggleLaunchAtLogin() { settings.setLaunchAtLogin(!settings.launchAtLogin) }
    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: ServerStore.logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ServerStore.logsDirectory)
    }
}
