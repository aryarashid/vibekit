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
    private var connecting = false
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
        }
    }

    private func check() {
        guard !connecting else { return }
        let wifi = CWWiFiClient.shared().interface()
        let inputs = HotspotRescuePolicy.Inputs(
            lidClosedAndAwake: Self.lidClosed() && LidSleep.readStatus()?.state == .counting,
            wifiOn: wifi?.powerOn() ?? false,
            wifiAssociated: (wifi?.rssiValue() ?? 0) != 0,
            wiredPrimary: Self.wiredPrimary(wifiName: wifi?.interfaceName),
            now: Date())
        guard policy.shouldAttempt(inputs) else { return }
        connecting = true
        let attempt = policy.attempts
        NSLog("Vibe Kit: Wi-Fi is down with the lid closed, asking your iPhone for its hotspot (try \(attempt))")
        Task.detached(priority: .utility) {
            let outcome = PersonalHotspot.connect()
            await MainActor.run { [weak self] in
                NSLog("Vibe Kit: hotspot try \(attempt): \(outcome)")
                self?.connecting = false
            }
        }
    }

    // MARK: System readings

    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Whether a wired network other than Wi-Fi is the way out, so there is nothing to fix.
    static func wiredPrimary(wifiName: String?) -> Bool {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return false }
        return isWired(primary: primary, wifiName: wifiName)
    }

    /// VPN tunnels can stay primary with nothing under them, so only `en` interfaces count.
    nonisolated static func isWired(primary: String, wifiName: String?) -> Bool {
        primary.hasPrefix("en") && primary != (wifiName ?? "en0")
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
