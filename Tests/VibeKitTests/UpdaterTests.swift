import XCTest
@testable import VibeKit

final class UpdaterTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = "https://github.com/aryarashid/vibekit/releases/latest/download/appcast.xml"

    private func release(_ change: (inout UpdaterConfiguration.Environment) -> Void = { _ in }) -> UpdaterConfiguration.Environment {
        var env = UpdaterConfiguration.Environment(
            info: ["SUFeedURL": feed, "SUPublicEDKey": key],
            bundlePath: "/Applications/Vibe Kit.app",
            isDebugBuild: false, isRunningTests: false, teamIdentifier: "ABCDE12345", allowUnsigned: false)
        change(&env)
        return env
    }

    func testASignedInstalledReleaseRunsTheUpdater() {
        XCTAssertEqual(UpdaterConfiguration.gate(release()), .enabled)
    }

    func testEveryOtherKindOfRunStaysQuiet() {
        let cases: [(String, UpdaterConfiguration.Environment)] = [
            ("tests", release { $0.isRunningTests = true }),
            ("debug", release { $0.isDebugBuild = true }),
            ("swift run", release { $0.bundlePath = "/Users/me/vibekit/.build/release" }),
            ("placeholder feed", release { $0.info["SUFeedURL"] = "__SPARKLE_FEED_URL__" }),
            ("no feed", release { $0.info["SUFeedURL"] = nil }),
            ("placeholder key", release { $0.info["SUPublicEDKey"] = "__SPARKLE_PUBLIC_KEY__" }),
            ("no key", release { $0.info["SUPublicEDKey"] = nil }),
            ("ad hoc", release { $0.teamIdentifier = nil }),
            ("disk image", release { $0.bundlePath = "/Volumes/Vibe Kit/Vibe Kit.app" }),
            ("translocated", release { $0.bundlePath = "/private/var/folders/x/T/AppTranslocation/0A1B/d/Vibe Kit.app" }),
        ]
        for (name, env) in cases {
            guard case .disabled(let reason) = UpdaterConfiguration.gate(env) else {
                return XCTFail("\(name) should not start Sparkle")
            }
            XCTAssertFalse(reason.isEmpty, name)
        }
    }

    func testAnAdHocBuildCanOptIn() {
        XCTAssertEqual(UpdaterConfiguration.gate(release { $0.teamIdentifier = nil; $0.allowUnsigned = true }), .enabled)
        // Opting in never overrides the missing key.
        XCTAssertNotEqual(UpdaterConfiguration.gate(release { $0.teamIdentifier = nil; $0.allowUnsigned = true; $0.info["SUPublicEDKey"] = "" }), .enabled)
    }

    func testFeedMustBeARealHTTPSURL() {
        XCTAssertNotNil(UpdaterConfiguration.feedURL(feed))
        XCTAssertNotNil(UpdaterConfiguration.feedURL("  https://example.com/appcast.xml\n"))
        for bad in [nil, "", "__SPARKLE_FEED_URL__", "http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://", "appcast.xml"] {
            XCTAssertNil(UpdaterConfiguration.feedURL(bad), bad ?? "nil")
        }
    }

    func testPublicKeyMustBe32Bytes() {
        XCTAssertTrue(UpdaterConfiguration.isValidPublicKey(key))
        for bad in [nil, "", "__SPARKLE_PUBLIC_KEY__", "not base64!", Data(count: 31).base64EncodedString(), Data(count: 64).base64EncodedString()] {
            XCTAssertFalse(UpdaterConfiguration.isValidPublicKey(bad), bad ?? "nil")
        }
    }

    /// The test runner itself never reaches Sparkle, and a fresh updater does nothing until started.
    @MainActor func testTheTestRunnerAndUnstartedUpdaterAreInert() {
        XCTAssertTrue(UpdaterConfiguration.Environment.current.isRunningTests)
        let updater = Updater()
        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        updater.start()
        XCTAssertFalse(updater.isAvailable)
        XCTAssertEqual(updater.statusNote, "Updates are off while tests run.")
    }

    /// The shipped Info.plist keeps placeholders for the build script, and never turns on the system profile.
    func testInfoPlistCarriesSparkleSettings() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["SUFeedURL"] as? String, "__SPARKLE_FEED_URL__")
        XCTAssertEqual(plist["SUPublicEDKey"] as? String, "__SPARKLE_PUBLIC_KEY__")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUEnableSystemProfile"] as? Bool, false)
    }
}
