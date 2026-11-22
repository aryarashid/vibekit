import AppKit
import Observation
import Security
import Sparkle

/// Decides whether this copy of Vibe Kit may run Sparkle at all. Pure, so tests cover every case.
///
/// The CLI flags, `--snapshot` and the test runner never reach `Updater.start()`, so they never get
/// here. This is the second line: a build that is not a signed, installed release with a real feed
/// and key stays quiet and says why in Settings.
struct UpdaterConfiguration: Equatable, Sendable {
    enum Gate: Equatable, Sendable {
        case enabled
        case disabled(String)
    }

    struct Environment: Sendable {
        var info: [String: String]
        var bundlePath: String
        var isDebugBuild: Bool
        var isRunningTests: Bool
        /// The Developer ID team that signed the app. Nil for an ad hoc local build.
        var teamIdentifier: String?
        /// `VIBEKIT_UPDATER_ALLOW_UNSIGNED=1`, to try updates from an ad hoc build on purpose.
        var allowUnsigned: Bool
    }

    static let feedKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    /// An https feed that the build script filled in. Placeholders like `__SPARKLE_FEED_URL__` don't count.
    static func feedURL(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !isPlaceholder(value), let url = URL(string: value),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Sparkle's EdDSA public key is a base64 Ed25519 key: exactly 32 bytes.
    static func isValidPublicKey(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !isPlaceholder(value),
              let data = Data(base64Encoded: value) else { return false }
        return data.count == 32
    }

    static func isPlaceholder(_ value: String) -> Bool {
        value.hasPrefix("__") && value.hasSuffix("__")
    }

    static func gate(_ env: Environment) -> Gate {
        if env.isRunningTests { return .disabled("Updates are off while tests run.") }
        if env.isDebugBuild { return .disabled("Updates are off in debug builds.") }
        guard env.bundlePath.hasSuffix(".app") else { return .disabled("Updates work in the Vibe Kit app, not a bare binary.") }
        guard feedURL(env.info[feedKey]) != nil else { return .disabled("This build has no update feed.") }
        guard isValidPublicKey(env.info[publicKeyKey]) else { return .disabled("This build has no update signing key.") }
        guard env.teamIdentifier != nil || env.allowUnsigned else {
            return .disabled("This is a local build, so it doesn't update itself. Releases do.")
        }
        guard Settings.isInstalled(at: env.bundlePath) else { return .disabled("Move Vibe Kit to Applications to get updates.") }
        return .enabled
    }
}

/// Wraps Sparkle's standard updater for the menu, Settings and launch.
///
/// Creating it does nothing. Only `start()`, called from `applicationDidFinishLaunching`, may make a
/// Sparkle object, and only when `UpdaterConfiguration` allows it. Until then the state is inert,
/// which is what the CLI, `--snapshot` and tests see.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// Sparkle is running and can check.
    private(set) var isAvailable = false
    /// Why updates are off in this build, or nil when they are on.
    private(set) var statusNote: String? = "Updates start with the app."
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false

    /// Runs right before Sparkle shows a window. The panel floats at pop-up menu level, so it closes
    /// first, or the update window would sit under it.
    @ObservationIgnored var willShowUpdateUI: (() -> Void)?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var delegate: SparkleDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {}

    func start(environment: UpdaterConfiguration.Environment = .current) {
        guard controller == nil else { return }
        switch UpdaterConfiguration.gate(environment) {
        case .disabled(let reason):
            statusNote = reason
            NSLog("Vibe Kit: updates off: \(reason)")
        case .enabled:
            let delegate = SparkleDelegate(owner: self)
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
            // Never send a system profile, whatever a stray user default says.
            controller.updater.sendsSystemProfile = false
            self.delegate = delegate
            self.controller = controller
            observe(controller.updater)
            do {
                try controller.updater.start()
                isAvailable = true
                statusNote = nil
            } catch {
                statusNote = "Updates couldn't start: \(error.localizedDescription)"
                NSLog("Vibe Kit: Sparkle failed to start: \(error)")
            }
            refresh()
        }
    }

    func checkForUpdates() {
        guard let controller, canCheckForUpdates else { return }
        prepareToShowUI()
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        refresh()
    }

    func setAutomaticallyDownloadsUpdates(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
        refresh()
    }

    fileprivate func refresh() {
        guard let updater = controller?.updater else { return }
        if canCheckForUpdates != updater.canCheckForUpdates { canCheckForUpdates = updater.canCheckForUpdates }
        if lastUpdateCheckDate != updater.lastUpdateCheckDate { lastUpdateCheckDate = updater.lastUpdateCheckDate }
        if automaticallyChecksForUpdates != updater.automaticallyChecksForUpdates {
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        }
        if automaticallyDownloadsUpdates != updater.automaticallyDownloadsUpdates {
            automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        }
    }

    /// An accessory app's windows open behind the app in front unless it activates first.
    fileprivate func prepareToShowUI() {
        willShowUpdateUI?()
        NSApp.activate()
    }

    private func observe(_ updater: SPUUpdater) {
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        observations = [
            updater.observe(\.canCheckForUpdates) { _, _ in changed() },
            updater.observe(\.lastUpdateCheckDate) { _, _ in changed() },
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in changed() },
            updater.observe(\.automaticallyDownloadsUpdates) { _, _ in changed() },
        ]
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info["CFBundleVersion"] as? String, !UpdaterConfiguration.isPlaceholder(build) else { return version }
        return "\(version) (\(build))"
    }
}

extension UpdaterConfiguration.Environment {
    @MainActor static var current: Self {
        let bundle = Bundle.main
        let info = (bundle.infoDictionary ?? [:]).compactMapValues { $0 as? String }
        let process = ProcessInfo.processInfo.environment
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return .init(
            info: info,
            bundlePath: bundle.bundlePath,
            isDebugBuild: debug,
            isRunningTests: process["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil,
            teamIdentifier: signingTeamIdentifier(),
            allowUnsigned: process["VIBEKIT_UPDATER_ALLOW_UNSIGNED"] == "1")
    }

    /// The team in the running app's code signature, or nil when it is ad hoc or unsigned.
    static func signingTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Sparkle's delegate callbacks, forwarded to `Updater`. Sparkle calls them on the main thread.
@MainActor
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    weak var owner: Updater?

    init(owner: Updater) { self.owner = owner }

    // MARK: SPUUpdaterDelegate

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        owner?.refresh()
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A menu bar app has no Dock icon to badge, so Sparkle shows scheduled updates itself and
    /// `standardUserDriverWillHandleShowingUpdate` brings them to the front.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { owner?.prepareToShowUI() }
    }

    func standardUserDriverWillShowModalAlert() {
        owner?.prepareToShowUI()
    }
}
