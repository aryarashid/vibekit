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

    func testLidSleepInstallerCarriesTheHelperAndQuotesPaths() throws {
        let helper = Data([0xcf, 0xfa, 0xed, 0xfe] + Array("not really a program".utf8))
        let command = LidSleep.installCommand(helper: helper, minutes: 99, uid: 501, appPath: "/Applications/Vibe Kit's.app")
        // The helper is inside the command, and root checks it wrote exactly those bytes. It is
        // never read from the bundle by path.
        XCTAssertTrue(command.contains(helper.base64EncodedString()))
        XCTAssertTrue(command.contains("= \(LidSleep.sha256(helper)) ] || { /bin/rm -f \"$tmp\"; exit 1; }"))
        XCTAssertFalse(command.contains("Contents/Helpers"))
        XCTAssertFalse(command.contains(".build"))
        // An unknown delay falls back to the default rather than reaching the shell.
        XCTAssertTrue(command.contains("printf '%s\\n' 45 >"))
        XCTAssertTrue(command.contains("chown 501 '/Library/Application Support/Vibe Kit/lid-sleep-minutes'"))
        XCTAssertTrue(command.contains("printf '%s' '/Applications/Vibe Kit'\\''s.app' > '/Library/Application Support/Vibe Kit/app-path'"))
        XCTAssertTrue(command.contains("if [ -L \"$p\" ]"))
        XCTAssertTrue(command.hasSuffix("/bin/launchctl enable system/dev.vibekit.lid-sleep\n/bin/launchctl bootstrap system '/Library/LaunchDaemons/dev.vibekit.lid-sleep.plist'"))
        XCTAssertFalse(LidSleep.launchdPlist.contains("'"), "The plist is passed in single quotes")
        // No team to compare with, so no signature check.
        XCTAssertFalse(command.contains("codesign"))
    }

    func testLidSleepInstallerChecksADifferentHashForDifferentBytes() {
        let one = LidSleep.installCommand(helper: Data("one".utf8), minutes: 45, uid: 501, appPath: "/Applications/Vibe Kit.app")
        let two = LidSleep.installCommand(helper: Data("two".utf8), minutes: 45, uid: 501, appPath: "/Applications/Vibe Kit.app")
        XCTAssertTrue(one.contains(LidSleep.sha256(Data("one".utf8))))
        XCTAssertFalse(one.contains(LidSleep.sha256(Data("two".utf8))))
        XCTAssertTrue(two.contains(LidSleep.sha256(Data("two".utf8))))
    }

    func testLidSleepInstallerMakesRootCheckTheSignature() throws {
        let requirement = try XCTUnwrap(LidSleep.helperRequirement(teamID: "ABCDE12345"))
        XCTAssertEqual(requirement, #"identifier "dev.vibekit.lid-sleep" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        let command = LidSleep.installCommand(helper: Data("x".utf8), requirement: requirement, minutes: 45, uid: 501,
                                              appPath: "/Applications/Vibe Kit.app")
        let lines = command.components(separatedBy: "\n")
        let check = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("/usr/bin/codesign --verify --strict --all-architectures --test-requirement '=identifier") })
        XCTAssertTrue(lines[check].hasSuffix(#" "$tmp" || { /bin/rm -f "$tmp"; exit 1; }"#))
        // Root checks the file it wrote, after the hash and before it becomes the helper.
        let hash = try XCTUnwrap(lines.firstIndex { $0.contains("shasum -a 256") })
        let move = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("/bin/mv -f \"$tmp\"") })
        XCTAssertLessThan(hash, check)
        XCTAssertLessThan(check, move)
    }

    func testLidSleepRequirementRefusesAnythingButATeamID() {
        for bad in ["", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE1234'", "ABCDE\"2345", "ABCDE 2345", "ABCDE1234;", "ÀBCDE12345"] {
            XCTAssertNil(LidSleep.helperRequirement(teamID: bad), bad)
        }
    }

    func testLidSleepSignatureCheckRefusesAHelperFromNobody() throws {
        // The test bundle's own binary is signed ad hoc at best, never by this made-up team.
        let binary = try XCTUnwrap(Bundle(for: PanelTests.self).executableURL)
        let requirement = try XCTUnwrap(LidSleep.helperRequirement(teamID: "ABCDE12345"))
        XCTAssertFalse(LidSleep.helperIsSigned(at: binary, by: "ABCDE12345", requirement: requirement))
        XCTAssertFalse(LidSleep.helperIsSigned(at: URL(fileURLWithPath: "/nonexistent"), by: "ABCDE12345", requirement: requirement))
    }

    func testLidSleepDaemonRunsTheHelperDirectly() throws {
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(LidSleep.launchdPlist.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Library/PrivilegedHelperTools/dev.vibekit.lid-sleep"])
        XCTAssertEqual(plist["Label"] as? String, "dev.vibekit.lid-sleep")
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    }

    func testLidSleepHelperIsOutdatedUnlessItIsThisCopysByteForByte() {
        let ours = Data("native helper".utf8), old = Data("#!/bin/bash\n# version 1\n".utf8)
        let app = "/Applications/Vibe Kit.app"
        XCTAssertEqual(LidSleep.helperState(installed: ours, bundled: ours, installedFor: app, appPath: app), .current)
        // The shell helper from before, or any other build.
        XCTAssertEqual(LidSleep.helperState(installed: old, bundled: ours, installedFor: app, appPath: app), .outdated)
        // Ours, but set up for another copy of the app.
        XCTAssertEqual(LidSleep.helperState(installed: ours, bundled: ours, installedFor: "/Users/me/Vibe Kit.app", appPath: app), .outdated)
        XCTAssertEqual(LidSleep.helperState(installed: ours, bundled: ours, installedFor: nil, appPath: app), .outdated)
        // Nothing bundled to compare with.
        XCTAssertEqual(LidSleep.helperState(installed: ours, bundled: nil, installedFor: app, appPath: app), .outdated)
    }

    func testAnOutdatedHelperThatIsStillRunningCountsAsOn() {
        // Upgrading from the shell helper: it is loaded with a delay, so the Mac stays awake.
        var flags = Settings.lidFlags(state: .outdated, loaded: true, minutes: 45, appExists: true)
        XCTAssertTrue(flags.on)
        XCTAssertTrue(flags.outdatedActive)
        XCTAssertFalse(flags.paused)

        // Really stopped: not loaded, or the app it was set up for is gone.
        flags = Settings.lidFlags(state: .outdated, loaded: false, minutes: 45, appExists: true)
        XCTAssertEqual([flags.on, flags.paused, flags.outdatedActive], [false, true, false])
        flags = Settings.lidFlags(state: .outdated, loaded: true, minutes: 45, appExists: false)
        XCTAssertEqual([flags.on, flags.paused, flags.outdatedActive], [false, true, false])
        flags = Settings.lidFlags(state: .current, loaded: false, minutes: 30, appExists: true)
        XCTAssertEqual([flags.on, flags.paused, flags.outdatedActive], [false, true, false])

        // Switched off: neither on nor paused, whichever helper it is.
        flags = Settings.lidFlags(state: .outdated, loaded: true, minutes: 0, appExists: true)
        XCTAssertEqual([flags.on, flags.paused, flags.outdatedActive], [false, false, false])

        // This copy's helper, running.
        flags = Settings.lidFlags(state: .current, loaded: true, minutes: 15, appExists: true)
        XCTAssertEqual([flags.on, flags.paused, flags.outdatedActive], [true, false, false])
        flags = Settings.lidFlags(state: .missing, loaded: false, minutes: 0, appExists: true)
        XCTAssertEqual([flags.on, flags.paused, flags.outdatedActive], [false, false, false])
    }

    func testTheBuiltHelperFitsInTheInstallCommand() throws {
        let helper = Bundle(for: PanelTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent(LidSleep.helperName)
        let data = try Data(contentsOf: helper)
        XCTAssertLessThanOrEqual(data.count, LidSleep.maxHelperBytes)
        // One command line can hold about a megabyte, and this one is passed on twice.
        let command = LidSleep.installCommand(helper: data, requirement: LidSleep.helperRequirement(teamID: "ABCDE12345"),
                                              minutes: 45, uid: 501, appPath: "/Applications/Vibe Kit.app")
        XCTAssertLessThan(LidSleep.appleScriptString(command).utf8.count, 1_000_000)
    }

    // MARK: The part of the installer that carries the helper, run for real in a scratch folder

    private var builtHelper: URL {
        Bundle(for: PanelTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent(LidSleep.helperName)
    }

    /// Runs the installer's own lines that write the helper and check it, with root's folder
    /// swapped for a scratch one. Returns the exit status and the files left behind.
    private func runCarryingLines(of command: String, in folder: URL) throws -> (status: Int32, files: [String]) {
        let lines = command.components(separatedBy: "\n")
        let first = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("tmp=$(/usr/bin/mktemp ") })
        let last = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("/usr/sbin/chown root:wheel \"$tmp\"") })
        let script = (["set -e"] + lines[first..<last]).joined(separator: "\n")
            .replacingOccurrences(of: "/Library/PrivilegedHelperTools/", with: folder.path + "/")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // One argument, as `do shell script` passes it, so this also proves the helper fits.
        process.arguments = ["-c", script]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibekit-install-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testRootWritesExactlyTheHelperItWasHanded() throws {
        let helper = try Data(contentsOf: builtHelper)
        let folder = try scratchFolder()
        let command = LidSleep.installCommand(helper: helper, minutes: 45, uid: 501, appPath: "/Applications/Vibe Kit.app")
        let result = try runCarryingLines(of: command, in: folder)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.files.count, 1)
        let written = try Data(contentsOf: folder.appendingPathComponent(try XCTUnwrap(result.files.first)))
        XCTAssertEqual(written, helper, "The program must arrive byte for byte")
    }

    func testRootRefusesAHelperThatChangedOnTheWay() throws {
        let helper = try Data(contentsOf: builtHelper)
        let folder = try scratchFolder()
        let command = LidSleep.installCommand(helper: helper, minutes: 45, uid: 501, appPath: "/Applications/Vibe Kit.app")
        // Swap the bytes inside the command for other ones, leaving the hash the app worked out.
        var other = helper
        other[other.count / 2] ^= 0xff
        let options: Data.Base64EncodingOptions = [.lineLength64Characters, .endLineWithLineFeed]
        let tampered = command.replacingOccurrences(of: helper.base64EncodedString(options: options),
                                                    with: other.base64EncodedString(options: options))
        XCTAssertNotEqual(tampered, command)
        let result = try runCarryingLines(of: tampered, in: folder)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.files, [], "Nothing may be left for a later step to install")
    }

    func testRootRefusesAHelperNotSignedByTheAppsTeam() throws {
        // The app is signed by a team, and the helper it found is not: the hash matches, because
        // the app hashed what it read, but the signature root looks for is missing.
        let helper = try Data(contentsOf: builtHelper)
        let folder = try scratchFolder()
        let command = LidSleep.installCommand(helper: helper, requirement: LidSleep.helperRequirement(teamID: "ABCDE12345"),
                                              minutes: 45, uid: 501, appPath: "/Applications/Vibe Kit.app")
        let result = try runCarryingLines(of: command, in: folder)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.files, [])
    }

    @MainActor
    func testRestoreClipboardAndSkippedHTTPChecksPersist() {
        let suite = "VibeKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = Settings(defaults: defaults)
        XCTAssertTrue(first.restoreClipboardAfterPaste, "restoreClipboardAfterPaste defaults to true")
        XCTAssertTrue(first.skippedHTTPChecks.isEmpty)

        first.restoreClipboardAfterPaste = false
        first.skippedHTTPChecks.insert("/tmp/app\u{0}npm run dev")
        first.skippedHTTPChecks.insert("worker:9000")

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.restoreClipboardAfterPaste)
        XCTAssertEqual(reloaded.skippedHTTPChecks, ["/tmp/app\u{0}npm run dev", "worker:9000"])
    }
}
