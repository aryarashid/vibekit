import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class Settings {
    private let defaults = UserDefaults.standard

    /// Show apps and system services that listen on a port, not only dev servers.
    var showOtherListeners: Bool { didSet { defaults.set(showOtherListeners, forKey: "showOtherListeners") } }
    var showCountInMenuBar: Bool { didSet { defaults.set(showCountInMenuBar, forKey: "showCountInMenuBar") } }
    var hotKeyEnabled: Bool { didSet { defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    var editorID: String? { didSet { defaults.set(editorID, forKey: "editorID") } }
    var terminalID: String? { didSet { defaults.set(terminalID, forKey: "terminalID") } }

    private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    init() {
        defaults.register(defaults: ["showCountInMenuBar": true, "hotKeyEnabled": true])
        showOtherListeners = defaults.bool(forKey: "showOtherListeners")
        showCountInMenuBar = defaults.bool(forKey: "showCountInMenuBar")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
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

    /// Turn on launch at login the first time the app runs from /Applications.
    func enableLaunchAtLoginOnFirstRun() {
        guard !defaults.bool(forKey: "didOfferLaunchAtLogin"), Bundle.main.bundlePath.hasSuffix(".app") else { return }
        defaults.set(true, forKey: "didOfferLaunchAtLogin")
        setLaunchAtLogin(true)
    }
}
