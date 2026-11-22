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

    func testLidSleepConfigOnlyAcceptsTheOfferedChoices() {
        XCTAssertEqual(LidSleep.parseMinutes("45\n"), 45)
        XCTAssertEqual(LidSleep.parseMinutes("  30 "), 30)
        XCTAssertEqual(LidSleep.parseMinutes("60"), 60)
        for bad in ["", "0", "20", "045", "abc", "45; rm -rf /", "$(touch x)", "999999"] {
            XCTAssertEqual(LidSleep.parseMinutes(bad), 0, bad)
        }
    }

    func testLidSleepInstallerCopiesTheHelperAndQuotesPaths() {
        let command = LidSleep.installCommand(helper: "/Applications/Vibe Kit's.app/Contents/Resources/lid-sleep-helper.sh", minutes: 99, uid: 501)
        // The helper is copied out of the user-writable bundle and owned by root.
        XCTAssertTrue(command.contains("install -o root -g wheel -m 755 '/Applications/Vibe Kit'\\''s.app/Contents/Resources/lid-sleep-helper.sh' '/Library/PrivilegedHelperTools/dev.vibekit.lid-sleep'"))
        // An unknown delay falls back to the default rather than reaching the shell.
        XCTAssertTrue(command.contains("printf '%s\\n' 45 >"))
        XCTAssertTrue(command.contains("chown 501 '/Library/Application Support/Vibe Kit/lid-sleep-minutes'"))
        XCTAssertTrue(command.hasSuffix("/bin/launchctl bootstrap system '/Library/LaunchDaemons/dev.vibekit.lid-sleep.plist'"))
        XCTAssertFalse(LidSleep.launchdPlist.contains("'"), "The plist is passed in single quotes")
    }
}
