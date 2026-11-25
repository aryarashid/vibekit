import CoreWLAN
import Foundation
import VibeKitCore

/// Turns on your iPhone's Personal Hotspot from the Mac and joins it, the way the Wi-Fi menu
/// does when you pick a phone under Personal Hotspot.
///
/// This uses `SFRemoteHotspotSession` from Apple's private Sharing framework, since there is no
/// public way to do it. Every class and selector is checked first, so if a macOS update changes
/// them this does nothing instead of crashing. All calls block, so run them off the main thread.
/// Nothing here logs the phone's name, the network name or the password.
enum PersonalHotspot {
    private static let sessionClass = "SFRemoteHotspotSession"
    private static let enableSelector = NSSelectorFromString("enableHotspotForDevice:withCompletionHandler:")

    enum Outcome: Equatable {
        case unavailable, noPhone, enableFailed, notJoined, joined
        /// `stillNeeded` said no partway through, for example because the lid opened.
        case stopped
    }

    /// The enable call's argument types (a device object and a block), as checked on a real Mac.
    /// If a macOS update changes them, the call is skipped, since calling it would crash.
    private static let enableTypes = "v32@0:8@16@?24"

    /// Whether this macOS still has the private calls this needs.
    static var isAvailable: Bool {
        guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
              let cls = NSClassFromString(sessionClass) as? NSObject.Type,
              let method = class_getInstanceMethod(cls, enableSelector),
              let types = method_getTypeEncoding(method), String(cString: types) == enableTypes else { return false }
        return ["startBrowsing", "stopBrowsing", "setDelegate:"]
            .allSatisfy { cls.instancesRespond(to: NSSelectorFromString($0)) }
    }

    /// Finds your own iPhone, asks it to turn on its hotspot and joins it. `stillNeeded` is asked
    /// again before turning the hotspot on and before each join, since this takes a while and
    /// the lid may open or Wi-Fi come back meanwhile.
    static func connect(browseSeconds: TimeInterval = 8, enableTimeout: TimeInterval = 45,
                        stillNeeded: () -> Bool = { true }) -> Outcome {
        guard isAvailable, let cls = NSClassFromString(sessionClass) as? NSObject.Type else { return .unavailable }
        let session = cls.init()
        let browser = Browser()
        session.setValue(browser, forKey: "delegate")
        session.perform(NSSelectorFromString("startBrowsing"))
        defer { session.perform(NSSelectorFromString("stopBrowsing")) }

        // The list arrives in pieces as phones answer over Bluetooth, so wait the whole time.
        Thread.sleep(forTimeInterval: browseSeconds)
        let devices = browser.devices
        let summaries = devices.map { device in
            HotspotDevice(group: number(device, "group") ?? 0, signal: number(device, "signalStrength"))
        }
        guard let index = HotspotDevice.pick(summaries) else { return .noPhone }
        guard stillNeeded() else { return .stopped }

        guard let credentials = enable(devices[index], on: session, timeout: enableTimeout) else { return .enableFailed }
        return join(network: credentials.network, password: credentials.password, stillNeeded: stillNeeded)
    }

    /// Reads a property only if the object has it, since asking for a missing key throws.
    private static func number(_ object: NSObject, _ key: String) -> Int? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.intValue
    }

    /// The completion hands back the hotspot's network name and password, or nils on failure.
    private static func enable(_ device: NSObject, on session: NSObject, timeout: TimeInterval) -> (network: String, password: String?)? {
        typealias Completion = @convention(block) (AnyObject?, AnyObject?) -> Void
        typealias Enable = @convention(c) (AnyObject, Selector, AnyObject, Completion) -> Void
        guard session.responds(to: enableSelector) else { return nil }
        let result = Box<(String, String?)>()
        let done = DispatchSemaphore(value: 0)
        let completion: Completion = { network, password in
            if let network = network as? String, !network.isEmpty {
                result.set((network, password as? String))
            }
            done.signal()
        }
        let call = unsafeBitCast(session.method(for: enableSelector), to: Enable.self)
        call(session, enableSelector, device, completion)
        guard done.wait(timeout: .now() + timeout) == .success, let value = result.get() else { return nil }
        return (value.0, value.1)
    }

    /// The phone needs a few seconds to start broadcasting after it says yes. Scanning by name
    /// works without Location access; the results just hide the name.
    private static func join(network: String, password: String?, stillNeeded: () -> Bool) -> Outcome {
        guard let wifi = CWWiFiClient.shared().interface() else { return .notJoined }
        for attempt in 1...6 {
            Thread.sleep(forTimeInterval: attempt == 1 ? 2 : 4)
            do {
                guard let found = try wifi.scanForNetworks(withName: network).first,
                      let target = withName(found, network) else { continue }
                guard stillNeeded() else { return .stopped }
                try wifi.associate(to: target, password: password)
                return .joined
            } catch {
                NSLog("Vibe Kit: joining the hotspot failed on try \(attempt): \((error as NSError).domain) \((error as NSError).code)")
            }
        }
        return .notJoined
    }

    /// Without Location access, macOS strips the network name out of scan results, and joining
    /// such a result fails with an invalid parameter error. Putting the name back into a copy's
    /// scan record makes it joinable. We already know the name, since the phone sent it.
    static func withName(_ network: CWNetwork, _ name: String) -> CWNetwork? {
        if network.ssid != nil { return network }
        let setRecord = NSSelectorFromString("setScanRecord:")
        guard network.responds(to: NSSelectorFromString("scanRecord")), network.responds(to: setRecord),
              let copy = network.copy() as? CWNetwork else { return nil }
        var record = (network.value(forKey: "scanRecord") as? [String: Any]) ?? [:]
        record["SSID_STR"] = name
        record["SSID"] = Data(name.utf8)
        copy.perform(setRecord, with: record as NSDictionary)
        return copy.ssid == name ? copy : nil
    }

    /// Receives the list of phones. Sharing calls it on its own queue.
    private final class Browser: NSObject, @unchecked Sendable {
        private let lock = NSLock()
        private var found: [NSObject] = []
        var devices: [NSObject] { lock.withLock { found } }

        @objc(session:updatedFoundDevices:)
        func updated(_ session: AnyObject?, devices: AnyObject?) {
            let list = (devices as? [NSObject]) ?? []
            lock.withLock { found = list }
        }
    }

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        func set(_ newValue: Value) { lock.withLock { value = newValue } }
        func get() -> Value? { lock.withLock { value } }
    }
}
