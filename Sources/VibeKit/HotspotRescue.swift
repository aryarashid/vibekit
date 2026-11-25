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
///
/// After a join it keeps `Settings.hotspotJoinedAt` set while the Mac stays on that hotspot, so
/// the panel can say so. macOS then prefers the hotspot over your usual Wi-Fi until the phone
/// stops sharing, and turning Wi-Fi off and on goes straight back to it, so Settings points you
/// to the Wi-Fi settings to pick your network.
@MainActor
final class HotspotRescue {
    static let checkInterval: TimeInterval = 10
    /// Asking the phone and joining takes up to a minute or so, so it is not worth starting with
    /// less than this left before the Mac sleeps.
    static let minimumSecondsLeft = 120

    private let settings: Settings
    private var policy = HotspotRescuePolicy()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    /// Set while an attempt runs. Raising it tells the attempt to stop before it turns the
    /// hotspot on or joins it.
    private var inFlight: StopFlag?
    /// The Wi-Fi channel of the hotspot Vibe Kit joined, and a timer that notices when the Mac
    /// is no longer on it.
    private var joinedChannel: Int?
    private var joinedWatch: Timer?
    private var notifyPort: IONotificationPortRef?
    private var notification: io_object_t = 0
    /// The attempt blocks for up to a couple of minutes, so it gets its own thread rather than
    /// one of Swift's shared task threads.
    private static let queue = DispatchQueue(label: "dev.vibekit.hotspot-rescue", qos: .utility)

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
        let active = settings.hotspotRescue && settings.lidStayAwake && Self.lidClosed()
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
        guard policy.shouldAttempt(Self.readInputs(minimumSecondsLeft: Self.minimumSecondsLeft)) else { return }
        let stop = StopFlag()
        inFlight = stop
        let attempt = policy.attempts
        NSLog("Vibe Kit: Wi-Fi is down with the lid closed, asking your iPhone for its hotspot (try \(attempt))")
        Self.queue.async {
            // The setting going off is caught by `stop`; everything else is read fresh.
            let outcome = PersonalHotspot.connect(stillNeeded: {
                !stop.isSet && HotspotRescuePolicy.isNeeded(Self.readInputs(minimumSecondsLeft: 1))
            })
            let channel = outcome == .joined ? CWWiFiClient.shared().interface()?.wlanChannel()?.channelNumber : nil
            Task { @MainActor [weak self] in
                NSLog("Vibe Kit: hotspot try \(attempt): \(outcome)")
                guard let self, self.inFlight === stop else { return }
                self.inFlight = nil
                self.policy.attemptEnded(at: Date())
                switch outcome {
                case .joined: self.joined(channel: channel)
                // Wi-Fi came back or the lid opened, so a later drop is a new outage and should
                // not wait out this one's backoff.
                case .stopped: self.policy = HotspotRescuePolicy()
                default: break
                }
            }
        }
    }

    // MARK: After a join

    private func joined(channel: Int?) {
        settings.hotspotJoinedAt = Date()
        joinedChannel = channel
        guard joinedWatch == nil else { return }
        let watch = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStillJoined() }
        }
        watch.tolerance = 5
        RunLoop.main.add(watch, forMode: .common)
        joinedWatch = watch
    }

    /// The network name is hidden without Location access, so leaving shows up as Wi-Fi
    /// dropping or moving to another channel.
    private func checkStillJoined() {
        let wifi = CWWiFiClient.shared().interface()
        let channel = wifi?.wlanChannel()?.channelNumber
        if !Self.wifiAssociated(wifi) || (joinedChannel != nil && channel != joinedChannel) { forgetJoin() }
    }

    private func forgetJoin() {
        settings.hotspotJoinedAt = nil
        joinedChannel = nil
        joinedWatch?.invalidate()
        joinedWatch = nil
    }

    // MARK: System readings

    /// `minimumSecondsLeft` is how much of the lid helper's countdown must be left. At zero the
    /// helper has let go of the Mac, even if its sleep request failed and it still says it is
    /// counting.
    nonisolated static func readInputs(minimumSecondsLeft: Int) -> HotspotRescuePolicy.Inputs {
        let wifi = CWWiFiClient.shared().interface()
        let now = Date()
        let left = LidSleep.readStatus()?.remaining(at: Int64(now.timeIntervalSince1970)) ?? 0
        return HotspotRescuePolicy.Inputs(
            lidClosedAndAwake: lidClosed() && left >= minimumSecondsLeft,
            wifiOn: wifi?.powerOn() ?? false,
            wifiAssociated: wifiAssociated(wifi),
            wiredPrimary: wiredOnline(wifiName: wifi?.interfaceName),
            now: now)
    }

    /// Signal strength reads 0 both when not joined and when the read fails, so a channel also
    /// has to be missing before Wi-Fi counts as down.
    nonisolated static func wifiAssociated(_ wifi: CWInterface?) -> Bool {
        guard let wifi else { return false }
        return wifi.rssiValue() != 0 || wifi.wlanChannel() != nil
    }

    nonisolated static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Whether a wired network other than Wi-Fi is up, so there is nothing to fix. The primary
    /// interface is read for IPv4 and IPv6, and every network service too, since a VPN over
    /// Ethernet makes the tunnel primary with the cable underneath.
    nonisolated static func wiredOnline(wifiName: String?) -> Bool {
        let primaries = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].compactMap { key in
            (SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any])?["PrimaryInterface"] as? String
        }
        if primaries.contains(where: { isWired(primary: $0, wifiName: wifiName) }) { return true }
        let keys = (SCDynamicStoreCopyKeyList(nil, "State:/Network/Service/.*/IPv[46]" as CFString) as? [String]) ?? []
        return keys.contains { key in
            guard let service = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
                  let name = service["InterfaceName"] as? String, service["Router"] != nil else { return false }
            return isWired(primary: name, wifiName: wifiName)
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
