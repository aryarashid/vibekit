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
    /// Put back whatever was on the clipboard after pasting a prompt into the front app.
    var restoreClipboardAfterPaste: Bool { didSet { defaults.set(restoreClipboardAfterPaste, forKey: "restoreClipboardAfterPaste") } }
    /// Servers opted out of HTTP status checks, keyed by `Server.httpCheckKey`.
    var skippedHTTPChecks: Set<String> { didSet { defaults.set(Array(skippedHTTPChecks).sorted(), forKey: "skippedHTTPChecks") } }
    /// The tab the panel showed last, so a click on the icon returns to it.
    var lastTab: PanelTab { didSet { defaults.set(lastTab.rawValue, forKey: "lastTab") } }
    var editorID: String? { didSet { defaults.set(editorID, forKey: "editorID") } }
    var terminalID: String? { didSet { defaults.set(terminalID, forKey: "terminalID") } }

    private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    /// How long the Mac stays awake after the lid closes, when that is on. Kept while it is off.
    var lidSleepMinutes: Int { didSet { defaults.set(lidSleepMinutes, forKey: "lidSleepMinutes") } }
    /// While the Mac stays awake with the lid closed, turn on your iPhone's hotspot and join it
    /// when Wi-Fi is down. Off unless you turn it on, since it uses your cellular data. See
    /// `HotspotRescue`.
    var hotspotRescue: Bool { didSet { defaults.set(hotspotRescue, forKey: "hotspotRescue") } }
    /// When Vibe Kit joined your iPhone's hotspot, while the Mac is still on it. Not saved.
    var hotspotJoinedAt: Date?
    /// Whether a lid sleep helper is running with a delay set, so the Mac really does stay
    /// awake after the lid closes. Read from the system, not saved.
    private(set) var lidStayAwake = false
    /// The helper is on this Mac, even if its delay is off.
    private(set) var lidHelperInstalled = false
    /// A delay is set but no helper is acting on it: it is not loaded, or the app it was set
    /// up for is gone. Switching on sets it up again.
    private(set) var lidHelperPaused = false
    /// The helper keeping the Mac awake is not the one this copy ships: an earlier version's,
    /// such as the shell script before the native helper, or another copy's. It still works and
    /// still obeys the switch and the delay. `updateLidHelper()` replaces it.
    private(set) var lidHelperOutdatedActive = false
    /// Why the last change failed, shown until the next one.
    private(set) var lidHelperError: String?
    /// The admin prompt is up or the helper is installing.
    private(set) var lidHelperBusy = false
    /// Shortcuts that are on but owned by another app, so Settings can say so. Not saved.
    var takenShortcuts: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "showCountInMenuBar": true,
            "hotKeyEnabled": true,
            "promptsHotKeyEnabled": true,
            "restoreClipboardAfterPaste": true,
        ])
        showOtherListeners = defaults.bool(forKey: "showOtherListeners")
        showCountInMenuBar = defaults.bool(forKey: "showCountInMenuBar")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        promptsHotKeyEnabled = defaults.bool(forKey: "promptsHotKeyEnabled")
        pasteOnUse = defaults.bool(forKey: "pasteOnUse")
        restoreClipboardAfterPaste = defaults.bool(forKey: "restoreClipboardAfterPaste")
        hotspotRescue = defaults.bool(forKey: "hotspotRescue")
        skippedHTTPChecks = Set(defaults.stringArray(forKey: "skippedHTTPChecks") ?? [])
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
        lidHelperError = nil
        defer { refreshLidStayAwake() }
        guard on else {
            if LidSleep.helperState() != .missing && !LidSleep.writeMinutes(0) {
                lidHelperError = "Couldn't switch it off. Press Remove to take the helper away."
            }
            return
        }
        // Already set up for this copy and running: just say how long.
        if LidSleep.helperState() == .current, LidSleep.isLoaded(), LidSleep.writeMinutes(lidSleepMinutes) { return }
        await installLidHelper()
    }

    /// Replaces a helper from an earlier version, or another copy, with this copy's. One
    /// administrator prompt. The old one keeps working if it is cancelled.
    func updateLidHelper() async {
        guard !lidHelperBusy else { return }
        lidHelperError = nil
        defer { refreshLidStayAwake() }
        let wasActive = lidHelperOutdatedActive
        await installLidHelper(keepingOnFailure: wasActive)
    }

    /// `keepingOnFailure` leaves a working older helper alone when its replacement does not go in.
    private func installLidHelper(keepingOnFailure: Bool = false) async {
        #if !DEBUG
        guard Self.isInstalled(at: Bundle.main.bundlePath) else {
            lidHelperError = "Move Vibe Kit to Applications first, then switch this on."
            return
        }
        #endif
        lidHelperBusy = true
        let installed = await LidSleep.install(minutes: lidSleepMinutes)
        lidHelperBusy = false
        guard !installed else { return }
        if keepingOnFailure, LidSleep.helperState() != .missing, LidSleep.isLoaded() {
            lidHelperError = "The helper wasn't updated. The earlier one is still running."
            return
        }
        lidHelperError = "The helper wasn't installed, so the Mac will sleep when the lid closes."
        // A failed install may have left a config behind; don't leave it half on.
        if LidSleep.helperState() != .missing { _ = LidSleep.writeMinutes(0) }
    }

    func setLidSleepMinutes(_ minutes: Int) {
        lidSleepMinutes = minutes
        if lidStayAwake && !LidSleep.writeMinutes(minutes) {
            lidHelperError = "Couldn't change the delay."
        }
        refreshLidStayAwake()
    }

    /// Removes the helper entirely, for people who no longer want it on their Mac.
    func removeLidHelper() async {
        guard !lidHelperBusy else { return }
        lidHelperError = nil
        lidHelperBusy = true
        let removed = await LidSleep.uninstall()
        lidHelperBusy = false
        if !removed { lidHelperError = "The helper wasn't removed." }
        refreshLidStayAwake()
    }

    func refreshLidStayAwake() {
        let state = LidSleep.helperState()
        let minutes = LidSleep.readMinutes()
        let loaded = state != .missing && LidSleep.isLoaded()
        let appExists = state == .missing || LidSleep.installedAppExists()
        applyLidStayAwake(state: state, minutes: minutes, loaded: loaded, appExists: appExists)
    }

    /// Refreshes lid sleep state without blocking launch. When no helper files exist, no `launchctl` process runs.
    func refreshLidStayAwakeLazily() {
        guard LidSleep.isSupported else { return }
        let state = LidSleep.helperState()
        let minutes = LidSleep.readMinutes()
        guard state != .missing else {
            applyLidStayAwake(state: state, minutes: minutes, loaded: false, appExists: true)
            return
        }
        let appExists = LidSleep.installedAppExists()
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { LidSleep.isLoaded() }.value
            self?.applyLidStayAwake(state: state, minutes: minutes, loaded: loaded, appExists: appExists)
        }
    }

    private func applyLidStayAwake(state: LidSleep.HelperState, minutes: Int, loaded: Bool, appExists: Bool) {
        let flags = Self.lidFlags(state: state, loaded: loaded, minutes: minutes, appExists: appExists)
        if lidStayAwake != flags.on { lidStayAwake = flags.on }
        if lidHelperInstalled != (state != .missing) { lidHelperInstalled = state != .missing }
        if lidHelperPaused != flags.paused { lidHelperPaused = flags.paused }
        if lidHelperOutdatedActive != flags.outdatedActive { lidHelperOutdatedActive = flags.outdatedActive }
        // Show the delay the helper actually uses, in case the file was changed by hand.
        if flags.on && minutes != lidSleepMinutes { lidSleepMinutes = minutes }
    }

    /// What Settings should say about the helper.
    ///
    /// A loaded helper with a delay keeps the Mac awake whichever version it is, as long as the
    /// app it was installed for still exists. So an outdated helper that is doing that counts as
    /// on, not paused: saying "paused" while the Mac stays awake in a bag would be wrong.
    nonisolated static func lidFlags(state: LidSleep.HelperState, loaded: Bool, minutes: Int, appExists: Bool)
        -> (on: Bool, paused: Bool, outdatedActive: Bool) {
        let on = state != .missing && loaded && minutes > 0 && appExists
        return (on, state != .missing && minutes > 0 && !on, on && state == .outdated)
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
