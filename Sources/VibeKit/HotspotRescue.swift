import CoreWLAN
import Foundation
import IOKit
import SystemConfiguration
import VibeKitCore

/// Gets a Mac that is awake with the lid closed back online when its Wi-Fi drops, by turning on
/// your iPhone's hotspot and joining it. See `HotspotRescuePolicy` for why macOS does not.
///
/// It only runs while the lid is closed and the lid helper is keeping the Mac awake. While the
/// lid is closed it also stops App Nap from stretching its timer, since the app has no window
/// open then and macOS would otherwise let it check only now and then.
@MainActor
final class HotspotRescue {
    static let checkInterval: TimeInterval = 10

    private let settings: Settings
    private var policy = HotspotRescuePolicy()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    /// Set while an attempt runs. Raising it tells the attempt to stop before it turns the
    /// hotspot on or joins it.
    private var inFlight: StopFlag?
    private var notifyPort: IONotificationPortRef?
    private var notification: io_object_t = 0

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        guard LidSleep.isSupported else { return }
        watchLid()
        update()
    }

    /// Call when the setting changes.
    func update() {
        let active = settings.hotspotRescue && Self.lidClosed() && LidSleep.readStatus()?.enabled == true
        if active, timer == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Reconnecting to your iPhone's hotspot with the lid closed")
            let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            check()
        } else if !active, timer != nil {
            timer?.invalidate()
            timer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            policy = HotspotRescuePolicy()
            inFlight?.set()
        }
    }

    private func check() {
        guard inFlight == nil else { return }
        guard policy.shouldAttempt(Self.readInputs()) else { return }
        let stop = StopFlag()
        inFlight = stop
        let attempt = policy.attempts
        NSLog("Vibe Kit: Wi-Fi is down with the lid closed, asking your iPhone for its hotspot (try \(attempt))")
        Task.detached(priority: .utility) {
            // The setting going off is caught by `stop`; everything else is read fresh.
            let outcome = PersonalHotspot.connect(stillNeeded: {
                !stop.isSet && HotspotRescuePolicy.isNeeded(Self.readInputs())
            })
            await MainActor.run { [weak self] in
                NSLog("Vibe Kit: hotspot try \(attempt): \(outcome)")
                guard let self, self.inFlight === stop else { return }
                self.inFlight = nil
                // Wi-Fi came back or the lid opened, so a later drop is a new outage and should
                // not wait out this one's backoff.
                if outcome == .stopped { self.policy = HotspotRescuePolicy() }
            }
        }
    }

    // MARK: System readings

    nonisolated static func readInputs() -> HotspotRescuePolicy.Inputs {
        let wifi = CWWiFiClient.shared().interface()
        let now = Date()
        // Time must be left on the countdown: at zero the helper has let go of the Mac, even if
        // its sleep request failed and it still says it is counting.
        let left = LidSleep.readStatus()?.remaining(at: Int64(now.timeIntervalSince1970)) ?? 0
        return HotspotRescuePolicy.Inputs(
            lidClosedAndAwake: lidClosed() && left > 0,
            wifiOn: wifi?.powerOn() ?? false,
            wifiAssociated: (wifi?.rssiValue() ?? 0) != 0,
            wiredPrimary: wiredPrimary(wifiName: wifi?.interfaceName),
            now: now)
    }

    nonisolated static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Whether a wired network other than Wi-Fi is the way out, so there is nothing to fix. An
    /// IPv6-only network has no IPv4 primary, so both are read.
    nonisolated static func wiredPrimary(wifiName: String?) -> Bool {
        ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].contains { key in
            guard let global = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
                  let primary = global["PrimaryInterface"] as? String else { return false }
            return isWired(primary: primary, wifiName: wifiName)
        }
    }

    /// VPN tunnels can stay primary with nothing under them, so only Ethernet-style `en`
    /// interfaces and Thunderbolt Bridge (`bridge`) count.
    nonisolated static func isWired(primary: String, wifiName: String?) -> Bool {
        (primary.hasPrefix("en") || primary.hasPrefix("bridge")) && primary != (wifiName ?? "en0")
    }

    /// The power manager sends a message when the lid opens or closes, among others, and each
    /// one just triggers a fresh look. The app lives as long as this object, so the unretained
    /// pointer stays good.
    private func watchLid() {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceInterestCallback = { context, _, _, _ in
            guard let context else { return }
            let rescue = Unmanaged<HotspotRescue>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { rescue.update() }
        }
        if IOServiceAddInterestNotification(port, root, kIOGeneralInterest, callback,
                                            Unmanaged.passUnretained(self).toOpaque(), &notification) == KERN_SUCCESS {
            notifyPort = port
        } else {
            IONotificationPortDestroy(port)
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
