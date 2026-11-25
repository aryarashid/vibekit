import VibeKitCore
import XCTest

final class HotspotRescueTests: XCTestCase {
    private var policy = HotspotRescuePolicy()
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func ask(at seconds: TimeInterval, lid: Bool = true, wifiOn: Bool = true, associated: Bool = false,
                     wired: Bool = false) -> Bool {
        policy.shouldAttempt(.init(lidClosedAndAwake: lid, wifiOn: wifiOn, wifiAssociated: associated,
                                   wiredPrimary: wired, now: start.addingTimeInterval(seconds)))
    }

    func testAsksOnceWiFiHasBeenDownForTheGracePeriod() {
        XCTAssertFalse(ask(at: 0), "macOS gets a chance to rejoin a network it can see")
        XCTAssertFalse(ask(at: 10))
        XCTAssertTrue(ask(at: 20))
        XCTAssertEqual(policy.attempts, 1)
    }

    func testBacksOffSoAPhoneOutOfReachIsNotAskedOverAndOver() {
        XCTAssertFalse(ask(at: 0))
        XCTAssertTrue(ask(at: 20))
        XCTAssertFalse(ask(at: 70))
        XCTAssertTrue(ask(at: 80))
        XCTAssertFalse(ask(at: 190))
        XCTAssertTrue(ask(at: 200))
        XCTAssertTrue(ask(at: 440))
        XCTAssertFalse(ask(at: 700))
        XCTAssertTrue(ask(at: 740), "capped at five minutes")
        XCTAssertEqual(HotspotRescuePolicy.retryDelay(afterAttempts: 9), 300)
    }

    func testNeverAsksWithTheLidOpenOrWiFiSwitchedOffOrAWiredNetwork() {
        for (lid, wifiOn, associated, wired) in [(false, true, false, false), (true, false, false, false),
                                                 (true, true, true, false), (true, true, false, true)] {
            policy = HotspotRescuePolicy()
            XCTAssertFalse(ask(at: 0, lid: lid, wifiOn: wifiOn, associated: associated, wired: wired))
            XCTAssertFalse(ask(at: 60, lid: lid, wifiOn: wifiOn, associated: associated, wired: wired))
            XCTAssertNil(policy.downSince)
        }
    }

    func testGettingBackOnlineStartsOver() {
        XCTAssertFalse(ask(at: 0))
        XCTAssertTrue(ask(at: 20))
        XCTAssertFalse(ask(at: 30, associated: true))
        XCTAssertEqual(policy, HotspotRescuePolicy())
        XCTAssertFalse(ask(at: 40), "a new drop waits the grace period again")
        XCTAssertTrue(ask(at: 60))
    }

    func testOnlyYourOwnPhoneIsAskedNeverAFamilyMembers() {
        // Asking a family member's phone puts a prompt on their screen.
        XCTAssertNil(HotspotDevice.pick([.init(group: 2, signal: 4)]))
        XCTAssertNil(HotspotDevice.pick([]))
        XCTAssertEqual(HotspotDevice.pick([.init(group: 2, signal: 4), .init(group: 1, signal: 1)]), 1)
        XCTAssertEqual(HotspotDevice.pick([.init(group: 1, signal: 2), .init(group: 2, signal: 4), .init(group: 1, signal: 3)]), 2)
        XCTAssertEqual(HotspotDevice.pick([.init(group: 1, signal: nil), .init(group: 1, signal: nil)]), 0, "ties keep the first")
    }
}
