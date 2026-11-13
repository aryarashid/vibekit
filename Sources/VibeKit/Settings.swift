import Foundation
import Observation
import ServiceManagement

enum PanelTab: String {
    case servers, prompts
}

@MainActor @Observable
final class Settings {
    private let defaults: UserDefaults

    /// Show apps and system services that listen on a port, not only dev servers.
    var showOtherListeners: Bool { didSet { defaults.set(showOtherListeners, forKey: "showOtherListeners") } }
    var showCountInMenuBar: Bool { didSet { defaults.set(showCountInMenuBar, forKey: "showCountInMenuBar") } }
    var hotKeyEnabled: Bool { didSet { defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    var promptsHotKeyEnabled: Bool { didSet { defaults.set(promptsHotKeyEnabled, forKey: "promptsHotKeyEnabled") } }
    /// Paste a prompt into the app in front when you pick it, not only copy it. Needs Accessibility access.
    var pasteOnUse: Bool { didSet { defaults.set(pasteOnUse, forKey: "pasteOnUse") } }
    /// The tab the panel showed last, so a click on the icon returns to it.
    var lastTab: PanelTab { didSet { defaults.set(lastTab.rawValue, forKey: "lastTab") } }
    var editorID: String? { didSet { defaults.set(editorID, forKey: "editorID") } }
    var terminalID: String? { didSet { defaults.set(terminalID, forKey: "terminalID") } }

    private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    /// Shortcuts that are on but owned by another app, so Settings can say so. Not saved.
    var takenShortcuts: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["showCountInMenuBar": true, "hotKeyEnabled": true, "promptsHotKeyEnabled": true])
        showOtherListeners = defaults.bool(forKey: "showOtherListeners")
        showCountInMenuBar = defaults.bool(forKey: "showCountInMenuBar")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        promptsHotKeyEnabled = defaults.bool(forKey: "promptsHotKeyEnabled")
        pasteOnUse = defaults.bool(forKey: "pasteOnUse")
        lastTab = defaults.string(forKey: "lastTab").flatMap(PanelTab.init(rawValue:)) ?? .servers
        editorID = defaults.string(forKey: "editorID")
        terminalID = defaults.string(forKey: "terminalID")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Vibe Kit: launch at login change failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Turn on launch at login the first time the app runs from where it is installed.
    func enableLaunchAtLoginOnFirstRun() {
        guard !defaults.bool(forKey: "didOfferLaunchAtLogin"), Self.isInstalled(at: Bundle.main.bundlePath) else { return }
        defaults.set(true, forKey: "didOfferLaunchAtLogin")
        setLaunchAtLogin(true)
    }

    /// False for a copy opened straight from the disk image, or one macOS runs from a randomized
    /// read-only path because it was not moved out of Downloads. A login item would point at a copy
    /// that goes away, so wait until the app runs from Applications.
    nonisolated static func isInstalled(at bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".app") && !bundlePath.hasPrefix("/Volumes/") && !bundlePath.contains("/AppTranslocation/")
    }
}
