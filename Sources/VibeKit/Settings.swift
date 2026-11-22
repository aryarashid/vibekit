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
    /// How long the Mac stays awake after the lid closes, when that is on. Kept while it is off.
    var lidSleepMinutes: Int { didSet { defaults.set(lidSleepMinutes, forKey: "lidSleepMinutes") } }
    /// Whether the lid sleep helper is installed and has a delay set. Read from disk, not saved.
    private(set) var lidStayAwake = false
    /// The helper is on this Mac, even if its delay is off.
    private(set) var lidHelperInstalled = false
    /// The installed helper is older than the one in this copy of the app.
    private(set) var lidHelperOutdated = false
    /// The admin prompt is up or the helper is installing.
    private(set) var lidHelperBusy = false
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
        let minutes = defaults.integer(forKey: "lidSleepMinutes")
        lidSleepMinutes = LidSleep.choices.contains(minutes) ? minutes : LidSleep.defaultMinutes
    }

    /// Turns lid sleep delay on or off. The first time it installs the helper, which asks for an
    /// administrator password; if that is cancelled the switch stays off. Off keeps the helper
    /// and writes 0, so turning it back on needs no password.
    func setLidStayAwake(_ on: Bool) async {
        guard !lidHelperBusy else { return }
        if on && LidSleep.helperState() != .current {
            let wasOn = lidStayAwake
            lidHelperBusy = true
            let installed = await LidSleep.install(minutes: lidSleepMinutes)
            lidHelperBusy = false
            // A failed install may have left a config behind; don't show it as on.
            if !installed && !wasOn { _ = LidSleep.writeMinutes(0) }
        } else if LidSleep.helperState() != .missing {
            _ = LidSleep.writeMinutes(on ? lidSleepMinutes : 0)
        }
        refreshLidStayAwake()
    }

    func setLidSleepMinutes(_ minutes: Int) {
        lidSleepMinutes = minutes
        if lidStayAwake { _ = LidSleep.writeMinutes(minutes) }
        refreshLidStayAwake()
    }

    /// Removes the helper entirely, for people who no longer want it on their Mac.
    func removeLidHelper() async {
        guard !lidHelperBusy else { return }
        lidHelperBusy = true
        _ = await LidSleep.uninstall()
        lidHelperBusy = false
        refreshLidStayAwake()
    }

    func refreshLidStayAwake() {
        let state = LidSleep.helperState()
        let on = state != .missing && LidSleep.readMinutes() > 0
        if lidStayAwake != on { lidStayAwake = on }
        if lidHelperInstalled != (state != .missing) { lidHelperInstalled = state != .missing }
        if lidHelperOutdated != (state == .outdated) { lidHelperOutdated = state == .outdated }
        // Show the delay the helper actually uses, in case the file was changed by hand.
        let minutes = LidSleep.readMinutes()
        if on && minutes != lidSleepMinutes { lidSleepMinutes = minutes }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Vibe Kit: launch at login change failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    /// Re-reads the system Login Items state in case it was changed in System Settings.
    func refreshLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin != enabled { launchAtLogin = enabled }
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
