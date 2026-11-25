import Foundation

/// When Vibe Kit should ask your iPhone to turn on its hotspot, so a Mac kept awake with the lid
/// closed gets back online after Wi-Fi drops.
///
/// macOS has its own fallback to a nearby iPhone's hotspot, but with the screen off it only
/// reads a cache of nearby phones, which is empty, so it never finds one until the lid opens.
/// These are the rules for stepping in; `HotspotRescue` in the app does the asking.
public struct HotspotRescuePolicy: Sendable, Equatable {
    /// How long Wi-Fi must stay down before asking, so macOS can rejoin a network it can see.
    public static let downGrace: TimeInterval = 20

    public struct Inputs: Sendable {
        /// The lid is closed and the lid helper is keeping the Mac awake.
        public var lidClosedAndAwake: Bool
        /// The Wi-Fi radio is on. Off means someone switched it off on purpose.
        public var wifiOn: Bool
        /// Joined to a Wi-Fi network.
        public var wifiAssociated: Bool
        /// Another wired network (Ethernet, Thunderbolt) is carrying traffic.
        public var wiredPrimary: Bool
        public var now: Date

        public init(lidClosedAndAwake: Bool, wifiOn: Bool, wifiAssociated: Bool, wiredPrimary: Bool, now: Date) {
            self.lidClosedAndAwake = lidClosedAndAwake
            self.wifiOn = wifiOn
            self.wifiAssociated = wifiAssociated
            self.wiredPrimary = wiredPrimary
            self.now = now
        }
    }

    public private(set) var downSince: Date?
    public private(set) var lastAttempt: Date?
    public private(set) var attempts = 0

    public init() {}

    /// Whether to ask the iPhone now. Counts the attempt when it says yes.
    public mutating func shouldAttempt(_ inputs: Inputs) -> Bool {
        guard Self.isNeeded(inputs) else {
            self = Self()
            return false
        }
        let since = downSince ?? inputs.now
        downSince = since
        guard inputs.now.timeIntervalSince(since) >= Self.downGrace else { return false }
        if let lastAttempt, inputs.now.timeIntervalSince(lastAttempt) < Self.retryDelay(afterAttempts: attempts) { return false }
        lastAttempt = inputs.now
        attempts += 1
        return true
    }

    /// Whether the Mac is in the state the hotspot is for: lid closed and held awake, Wi-Fi on
    /// but not joined, and no wired network. An attempt in progress asks this again before it
    /// turns the hotspot on and before each join.
    public static func isNeeded(_ inputs: Inputs) -> Bool {
        inputs.lidClosedAndAwake && inputs.wifiOn && !inputs.wifiAssociated && !inputs.wiredPrimary
    }

    /// One minute after the first try, then two, four, and every five after that. Each try turns
    /// the phone's hotspot on, which costs its battery, so a phone that is out of signal or out
    /// of reach is not asked over and over.
    public static func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        return min(60 * pow(2, Double(attempts - 1)), 300)
    }
}

/// A phone that offered its hotspot, as the system lists it.
public struct HotspotDevice: Sendable, Equatable {
    /// 1 for devices signed in to your own Apple Account, 2 for Family Sharing members' devices.
    public var group: Int
    /// Bars of signal, higher is better, or nil if not known.
    public var signal: Int?

    public init(group: Int, signal: Int?) {
        self.group = group
        self.signal = signal
    }

    public static let ownGroup = 1

    /// The index of the device to ask: your own, never a family member's. Asking a family
    /// member's phone puts a prompt on their screen. The strongest signal wins.
    public static func pick(_ devices: [HotspotDevice]) -> Int? {
        devices.indices
            .filter { devices[$0].group == ownGroup }
            .max { (devices[$0].signal ?? 0, $1) < (devices[$1].signal ?? 0, $0) }
    }
}
