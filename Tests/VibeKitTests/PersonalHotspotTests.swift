import CoreWLAN
import XCTest
@testable import VibeKit

final class PersonalHotspotTests: XCTestCase {
    /// Without Location access scan results have no name, and joining them fails. The name the
    /// phone sent goes back in, on a copy.
    func testPutsTheNetworkNameBackIntoAScanResult() throws {
        let found = CWNetwork()
        XCTAssertNil(found.ssid)
        let joinable = try XCTUnwrap(PersonalHotspot.withName(found, "Hotspot"))
        XCTAssertEqual(joinable.ssid, "Hotspot")
        XCTAssertEqual(joinable.ssidData, Data("Hotspot".utf8))
        XCTAssertNil(found.ssid, "the scan result itself is left alone")
    }
}

/// Turns on the real iPhone's hotspot and joins it. Skipped unless VIBEKIT_LIVE_HOTSPOT=1,
/// since it needs your iPhone nearby and changes the Mac's Wi-Fi.
final class PersonalHotspotLiveTests: XCTestCase {
    func testJoinsYourOwnPhonesHotspot() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBEKIT_LIVE_HOTSPOT"] == "1", "needs a real iPhone")
        XCTAssertTrue(PersonalHotspot.isAvailable)
        // Run with Wi-Fi dropped: a channel must be missing too before it counts as down.
        XCTAssertFalse(HotspotRescue.wifiAssociated(CWWiFiClient.shared().interface()), "Wi-Fi reads as joined while dropped")
        XCTAssertEqual(PersonalHotspot.connect(), .joined)
    }
}
