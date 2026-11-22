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

    func testLidSleepHelperHashMatchesTheScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/lid-sleep-helper.sh")
        // Changed the helper? Put its new `shasum -a 256` in LidSleep.helperSHA256.
        XCTAssertEqual(LidSleep.sha256(try Data(contentsOf: script)), LidSleep.helperSHA256)
    }

    func testLidSleepInstallerCarriesTheHelperAndQuotesPaths() throws {
        let helper = Data("#!/bin/bash\necho hi\n".utf8)
        let command = LidSleep.installCommand(helper: helper, minutes: 99, uid: 501, appPath: "/Applications/Vibe Kit's.app")
        // The script is inside the command and checked again by root, never read from the bundle.
        XCTAssertTrue(command.contains(helper.base64EncodedString()))
        XCTAssertTrue(command.contains("= \(LidSleep.helperSHA256) ] ||"))
        XCTAssertFalse(command.contains("Resources/lid-sleep-helper.sh"))
        // An unknown delay falls back to the default rather than reaching the shell.
        XCTAssertTrue(command.contains("printf '%s\\n' 45 >"))
        XCTAssertTrue(command.contains("chown 501 '/Library/Application Support/Vibe Kit/lid-sleep-minutes'"))
        XCTAssertTrue(command.contains("printf '%s' '/Applications/Vibe Kit'\\''s.app' > '/Library/Application Support/Vibe Kit/app-path'"))
        XCTAssertTrue(command.contains("if [ -L \"$p\" ]"))
        XCTAssertTrue(command.hasSuffix("/bin/launchctl enable system/dev.vibekit.lid-sleep\n/bin/launchctl bootstrap system '/Library/LaunchDaemons/dev.vibekit.lid-sleep.plist'"))
        XCTAssertFalse(LidSleep.launchdPlist.contains("'"), "The plist is passed in single quotes")
    }
}
