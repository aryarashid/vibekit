import XCTest
@testable import VibeKit

final class SettingsTests: XCTestCase {
    func testLaunchAtLoginWaitsUntilTheAppIsInstalled() {
        XCTAssertTrue(Settings.isInstalled(at: "/Applications/Vibe Kit.app"))
        XCTAssertTrue(Settings.isInstalled(at: "/Users/me/Applications/Vibe Kit.app"))
        // Opened from the mounted disk image.
        XCTAssertFalse(Settings.isInstalled(at: "/Volumes/Vibe Kit/Vibe Kit.app"))
        // Opened from Downloads without moving it, so Gatekeeper runs it from a random path.
        XCTAssertFalse(Settings.isInstalled(at: "/private/var/folders/x/T/AppTranslocation/0A1B/d/Vibe Kit.app"))
        // `swift run` and the test runner.
        XCTAssertFalse(Settings.isInstalled(at: "/Users/me/vibekit/.build/debug"))
    }
}
