import VibeKitCore
import XCTest

/// Runs the real compiled helper against a folder of made-up readings. Every rule the helper
/// keeps has a test here, so a change that breaks one fails before it can reach a Mac.
final class LidSleepHelperTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibekit-lid-\(UUID())", isDirectory: true)
    /// SwiftPM builds the helper next to the test bundle, because the tests depend on it.
    private let helper = Bundle(for: LidSleepHelperTests.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("VibeKitLidHelper")

    override func setUpWithError() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), "The helper was not built at \(helper.path)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("config", "45")
        try write("lid", "No")
        try write("causes", "Yes")
        try write("now", "1000")
        try write("power", "AC")
        try write("percent", "100")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ value: String) throws {
        try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func runHelper(_ arguments: [String] = ["--tick", "state"], environment: [String: String] = [:],
                           expecting status: Int32 = 0) throws {
        let process = Process()
        process.executableURL = helper
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.environment = [
            "VIBEKIT_LID_FAKE_DIR": directory.path,
            "VIBEKIT_LID_CONFIG": directory.appendingPathComponent("config").path,
        ].merging(environment) { $1 }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, status)
    }

    /// Throws, without recording a failure, while there is no status yet, so it can be polled.
    private func status() throws -> LidSleepStatus {
        let data = try Data(contentsOf: directory.appendingPathComponent("status"))
        guard let status = LidSleepStatus.decode(data) else { throw CocoaError(.fileReadCorruptFile) }
        return status
    }

    /// The actions file without `displaysleepnow`, which has its own test.
    private func lines(_ name: String = "actions") throws -> [String] {
        try allLines(name).filter { $0 != "displaysleepnow" }
    }

    private func allLines(_ name: String = "actions") throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testDelayAndDarkWake() throws {
        try runHelper()
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])

        try write("lid", "Yes")
        try runHelper()
        try write("now", String(1000 + 44 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])

        let slept = ["disablesleep 1", "disablesleep 0", "sleepnow"]
        try write("now", String(1000 + 45 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), slept)
        try write("now", "9000")
        try runHelper()
        XCTAssertEqual(try lines(), slept)

        try write("lid", "No")
        try runHelper()
        try write("lid", "Yes")
        try runHelper()
        XCTAssertEqual(try lines(), slept + ["disablesleep 1"])
        XCTAssertTrue(try lines("state").contains("closed_at=9000"))
    }

    func testDockedUntilDisplayDisconnects() throws {
        try write("lid", "Yes")
        try write("causes", "No")
        try write("power", "Battery")
        try write("percent", "15")
        try runHelper()
        try write("now", String(1000 + 2 * 3600))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        XCTAssertEqual(try lines("log").count, 2)

        try write("power", "AC")
        try write("causes", "Yes")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        try write("now", String(1000 + 2 * 3600 + 45 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
    }

    func testLowBatteryThreshold() throws {
        try runHelper()
        try write("lid", "Yes")
        try write("percent", "15")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])

        try write("power", "Battery")
        try write("percent", "16")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])

        try write("percent", "15")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
    }

    func testDisabledAndInvalidConfigs() throws {
        // Lid open and on mains, so a config read as valid would show up as `disablesleep 1`.
        try write("lid", "No")
        let configs: [String?] = [nil, "0", "abc", "20", "45; rm -rf /", "$(touch pwned)",
                                  "4\u{0}5", "45" + String(repeating: " ", count: 14) + "x"]
        for (index, config) in configs.enumerated() {
            if let config { try write("config", config) }
            else { try FileManager.default.removeItem(at: directory.appendingPathComponent("config")) }
            try runHelper(["--tick", "state-\(index)"])
        }
        XCTAssertEqual(try lines(), Array(repeating: "disablesleep 0", count: configs.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
    }

    func testWhitespaceAndStrictStateParsing() throws {
        try write("config", "  30\n")
        try write("state", "closed_at=$(touch pwned)\nfired=1x\nflag=10\n")
        try runHelper()
        try write("lid", "Yes")
        try runHelper()
        try write("now", "2799")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        try write("now", "2800")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
    }

    func testConfigSymlinkIsOff() throws {
        let config = directory.appendingPathComponent("config")
        let target = directory.appendingPathComponent("target")
        try write("target", "45")
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 0"])
    }

    func testOff() throws {
        try runHelper(["--off"])
        XCTAssertEqual(try lines(), ["disablesleep 0"])
    }

    func testStartingWithTheLidClosedStillSleepsWithinTheDelay() throws {
        // A first start, or a restart without saved state, while the Mac is in a bag. Clearing
        // the flag alone would not make it sleep, so count down from now and then sleep.
        try write("lid", "Yes")
        try runHelper()
        try write("now", String(1000 + 44 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        try write("now", String(1000 + 45 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
    }

    func testTheDaemonKeepsItsTimerAcrossARestart() throws {
        // Run the real loop twice against the same state file, as launchd would after an update.
        try runHelper()
        try write("lid", "Yes")
        try write("now", "1000")
        try runDaemon(until: "The helper should save when the lid closed") {
            (try? lines("daemon-state"))?.contains("closed_at=1000") == true
        }
        try write("now", String(1000 + 45 * 60))
        try runDaemon(until: "The restarted helper should keep counting from 1000") {
            (try? lines())?.contains("sleepnow") == true
        }
    }

    private func startDaemon(environment: [String: String] = [:]) throws -> Process {
        let process = Process()
        process.executableURL = helper
        process.environment = [
            "VIBEKIT_LID_FAKE_DIR": directory.path,
            "VIBEKIT_LID_CONFIG": directory.appendingPathComponent("config").path,
            "VIBEKIT_LID_STATE": directory.appendingPathComponent("daemon-state").path,
        ].merging(environment) { $1 }
        try process.run()
        return process
    }

    /// Runs the daemon until it has done what is expected, then stops it as launchd would.
    private func runDaemon(until what: String, _ condition: () -> Bool) throws {
        let process = try startDaemon()
        waitFor(what, condition)
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// Polls for something the daemon should do by itself, without a fixed wait.
    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(condition(), what)
    }

    func testDockingAfterSleepStartsAFreshTimerOnUndock() throws {
        try runHelper()
        try write("lid", "Yes")
        try write("now", "1000")
        try runHelper()
        try write("now", String(1000 + 45 * 60))
        try runHelper()
        let slept = ["disablesleep 1", "disablesleep 0", "sleepnow"]
        XCTAssertEqual(try lines(), slept)

        try write("causes", "No")
        try write("now", "10000")
        try runHelper()
        XCTAssertEqual(try lines(), slept + ["disablesleep 1"])
        try write("causes", "Yes")
        try write("now", "10010")
        try runHelper()
        try write("now", String(10010 + 45 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), slept + ["disablesleep 1", "disablesleep 0", "sleepnow"])
    }

    func testAsksAgainIfTheMacDidNotSleep() throws {
        try runHelper()
        try write("lid", "Yes")
        try write("percent", "10")
        try write("power", "Battery")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
        // Still awake and polling every few seconds: ask again after a minute.
        for now in stride(from: 1010, through: 1060, by: 10) {
            try write("now", String(now))
            try runHelper()
        }
        XCTAssertEqual(try lines().filter { $0 == "sleepnow" }.count, 2)
        // It slept (a long gap between polls), then woke with the lid still closed: leave it be.
        for now in [5000, 5010, 5080, 5150] {
            try write("now", String(now))
            try runHelper()
        }
        XCTAssertEqual(try lines().filter { $0 == "sleepnow" }.count, 2)
    }

    func testAClockSetBackwardsDoesNotStretchTheDelay() throws {
        try runHelper()
        try write("lid", "Yes")
        try write("now", "5000")
        try runHelper()
        try write("now", "1000")
        try runHelper()
        try write("now", String(1000 + 45 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
    }

    func testStopsWhenTheAppIsGone() throws {
        let appFile = directory.appendingPathComponent("app-path")
        try write("app-path", directory.path)
        try runHelper(environment: ["VIBEKIT_LID_APP_FILE": appFile.path])
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        try write("app-path", directory.appendingPathComponent("Trashed.app").path)
        try runHelper(environment: ["VIBEKIT_LID_APP_FILE": appFile.path])
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0"])
    }

    func testASmallBackwardsClockStepStillSleepsOnTime() throws {
        try runHelper()
        try write("lid", "Yes")
        try runHelper()
        for minute in stride(from: 1, through: 44, by: 1) {
            try write("now", String(1000 + minute * 60))
            try runHelper()
        }
        // The clock is corrected back ten minutes, then one more minute passes.
        try write("now", String(1000 + 34 * 60))
        try runHelper()
        try write("now", String(1000 + 35 * 60))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
    }

    func testTheScreenSleepsWhenTheLidClosesButNotWhenDocked() throws {
        try runHelper()
        try write("lid", "Yes")
        try runHelper()
        try write("now", "1060")
        try runHelper()
        // The display sleeps once, as the timer starts, while the system stays awake.
        XCTAssertEqual(try allLines(), ["disablesleep 1", "displaysleepnow"])

        try write("lid", "No")
        try runHelper()
        try write("lid", "Yes")
        try write("causes", "No")
        try runHelper()
        XCTAssertEqual(try allLines().filter { $0 == "displaysleepnow" }.count, 1)
    }

    // MARK: Rules the shell helper did not have

    func testLowBatteryWithTheLidOpenNeverHoldsTheFlag() throws {
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        XCTAssertEqual(try status().state, .armed)

        // On battery but not low yet: still held.
        try write("power", "Battery")
        try write("percent", "16")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])

        // 15% with the lid open: let the Mac sleep by itself, and at once if the lid closes.
        try write("percent", "15")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(try status().state, .lowBattery)
        XCTAssertTrue(try status().enabled)
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0"])

        // Closing the lid now sleeps straight away, with no timer and the flag already clear.
        try write("lid", "Yes")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
        XCTAssertEqual(try status().state, .slept)

        // Plugged in and opened again: back to holding it.
        try write("lid", "No")
        try write("power", "AC")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow", "disablesleep 1"])
        XCTAssertEqual(try status().state, .armed)
    }

    func testLowBatteryOnMainsWithTheLidOpenStillHoldsTheFlag() throws {
        try write("percent", "5")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        XCTAssertEqual(try status().state, .armed)
    }

    func testAnIdleMacWithTheLidOpenIsLetGo() throws {
        try runHelper()
        try write("idle", "Yes")
        try write("now", "1020")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(try status().state, .idle)
        try write("idle", "No")
        try write("now", "1040")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "disablesleep 1"])
        XCTAssertEqual(try status().state, .armed)
    }

    func testStatusFileSaysWhatTheHelperIsDoing() throws {
        try runHelper()
        XCTAssertEqual(try status(), LidSleepStatus(enabled: true, minutes: 45, state: .armed, updatedAt: 1000))

        try write("lid", "Yes")
        try write("now", "1600")
        try runHelper()
        try write("now", "1900")
        try runHelper()
        let counting = try status()
        XCTAssertEqual(counting, LidSleepStatus(enabled: true, minutes: 45, state: .counting, remainingSeconds: 40 * 60, updatedAt: 1900))
        // The app counts on from the last write, so the helper need not write every second.
        XCTAssertEqual(counting.remaining(at: 1960), 39 * 60)
        XCTAssertEqual(counting.remaining(at: 99_999), 0)

        try write("causes", "No")
        try runHelper()
        XCTAssertEqual(try status().state, .docked)
        XCTAssertNil(try status().remainingSeconds)

        try write("causes", "Yes")
        try write("now", String(1900 + 45 * 60))
        try runHelper()
        try write("now", String(1900 + 90 * 60))
        try runHelper()
        XCTAssertEqual(try status().state, .slept)

        try write("config", "0")
        try runHelper()
        XCTAssertEqual(try status(), LidSleepStatus(enabled: false, minutes: 0, state: .off, updatedAt: Int64(1900 + 90 * 60)))

        // The lid sensor cannot be read: nothing is held, though a delay is set.
        try write("config", "30")
        try write("lid", "Maybe")
        try runHelper()
        XCTAssertEqual(try status().state, .off)
        XCTAssertTrue(try status().enabled)
        // The flag was cleared before the sleep and has not been set since.
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0", "sleepnow"])
    }

    func testStatusFileIsReadableByEveryoneAndTheStateIsNot() throws {
        try runHelper()
        func mode(_ name: String) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return try XCTUnwrap(attributes[.posixPermissions] as? Int)
        }
        // The app reads the status as the user. Nobody but root needs the timer.
        XCTAssertEqual(try mode("status"), 0o644)
        XCTAssertEqual(try mode("state"), 0o600)
        // Written whole and renamed into place, so nothing is left beside them.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("status.") || $0.hasPrefix("state.") }
        XCTAssertEqual(leftovers, [])
    }

    func testStatusSaysWhenTheAppIsGone() throws {
        let appFile = directory.appendingPathComponent("app-path")
        try write("app-path", directory.appendingPathComponent("Trashed.app").path)
        try runHelper(environment: ["VIBEKIT_LID_APP_FILE": appFile.path])
        XCTAssertEqual(try lines(), ["disablesleep 0"])
        XCTAssertEqual(try status(), LidSleepStatus(enabled: false, minutes: 45, state: .appMissing, updatedAt: 1000))
    }

    func testAStatusOrStateLinkIsReplacedNotFollowed() throws {
        // Someone plants links where root is about to write.
        try write("victim", "untouched")
        let victim = directory.appendingPathComponent("victim")
        for name in ["status", "state"] {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: victim)
        }
        try runHelper()
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "untouched")
        XCTAssertEqual(try status().state, .armed)
        // A linked state file is not read either, so the planted text sets nothing.
        try write("victim", "closed_at=1\nfired=1\n")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("state"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("state"), withDestinationURL: victim)
        try write("lid", "Yes")
        try runHelper()
        XCTAssertEqual(try status().state, .counting)
        XCTAssertEqual(try status().remainingSeconds, 45 * 60)
    }

    func testTheSystemFlagWinsOverTheRememberedOne() throws {
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        // Something else cleared it. The helper remembers 1, but sets it again.
        try write("sleepdisabled", "No")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 1"])
        // And when the system already has it, there is nothing to do.
        try write("sleepdisabled", "Yes")
        try write("state", "flag=0\n")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 1"])
        // Switched off while the system still has it set: clear it, whatever was remembered.
        try write("config", "0")
        try write("state", "flag=0\n")
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 1", "disablesleep 0"])
    }

    func testConfigOverSixteenBytesIsOff() throws {
        try write("config", "45" + String(repeating: "\n", count: 14))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1"], "Sixteen bytes is allowed")
        try write("config", "45" + String(repeating: "\n", count: 15))
        try runHelper()
        XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0"])
    }

    func testUnknownArgumentsAndAnEmptyFakeFolderAreRefused() throws {
        try runHelper(["--nonsense"], expecting: 2)
        try runHelper(["--tick"], expecting: 2)
        try runHelper(["--tick", "state", "extra"], expecting: 2)
        // An empty fake folder must not fall through to the real Mac.
        try runHelper(["--off"], environment: ["VIBEKIT_LID_FAKE_DIR": ""], expecting: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("actions").path))
    }

    // MARK: The daemon, driven by events

    func testTheDaemonAppliesAConfigChangeAtOnce() throws {
        let daemon = try startDaemon()
        defer { daemon.terminate(); daemon.waitUntilExit() }
        waitFor("The daemon should hold the flag on start") { (try? lines()) == ["disablesleep 1"] }

        // What Vibe Kit does when the switch goes off: rewrite the file in place.
        let started = Date()
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("config"))
        try handle.write(contentsOf: Data("0\n".utf8))
        try handle.truncate(atOffset: 2)
        try handle.close()
        waitFor("Switching off should clear the flag without waiting for a poll") {
            (try? lines()) == ["disablesleep 1", "disablesleep 0"]
        }
        // The old helper looked every 10 seconds. This one is told.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        waitFor("The status should follow") { (try? status().state) == .off }
    }

    func testTheDaemonNoticesAConfigTheInstallerReplaced() throws {
        try write("config", "0")
        let daemon = try startDaemon()
        defer { daemon.terminate(); daemon.waitUntilExit() }
        waitFor("Off to begin with") { (try? lines()) == ["disablesleep 0"] }

        // The installer removes the file and writes a new one, so the watched file is gone.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config"))
        try write("config", "30")
        waitFor("A replaced config should apply") { (try? lines()) == ["disablesleep 0", "disablesleep 1"] }
        // The new file is watched in turn.
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("config"))
        try handle.write(contentsOf: Data("0\n".utf8))
        try handle.truncate(atOffset: 2)
        try handle.close()
        waitFor("And so should a later change to it") {
            (try? lines()) == ["disablesleep 0", "disablesleep 1", "disablesleep 0"]
        }
    }

    func testTheDaemonCountsDownToSleepByItself() throws {
        // One second of the delay is left, and no event will arrive. Only the countdown timer can
        // act, and only if the fake clock is moved on by the time it fires.
        try write("lid", "Yes")
        try write("now", "5000")
        try write("daemon-state", "closed_at=\(5000 - 45 * 60 + 1)\nlast_tick=5000\nflag=1\n")
        let daemon = try startDaemon()
        defer { daemon.terminate(); daemon.waitUntilExit() }
        waitFor("It should be counting") { (try? status().state) == .counting }
        XCTAssertEqual(try status().remainingSeconds, 1)
        XCTAssertEqual(try allLines("log").filter { $0.hasPrefix("Requested sleep") }, [])
        try write("now", "5001")
        waitFor("The timer should end the countdown") { (try? lines())?.contains("sleepnow") == true }
        XCTAssertEqual(try lines(), ["disablesleep 0", "sleepnow"])
        waitFor("And report slept") { (try? status().state) == .slept }
    }

    func testTheDaemonStopsSoonAfterTheAppIsMovedAway() throws {
        // The app lives outside the watched config folder, as it does on a real Mac.
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent("vibekit-apps-\(UUID())", isDirectory: true)
        let app = apps.appendingPathComponent("Vibe Kit.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: apps) }
        try write("app-path", app.path)
        let daemon = try startDaemon(environment: ["VIBEKIT_LID_APP_FILE": directory.appendingPathComponent("app-path").path])
        defer { daemon.terminate(); daemon.waitUntilExit() }
        waitFor("The daemon should hold the flag on start") { (try? lines()) == ["disablesleep 1"] }

        // Into the Trash. No config change and no lid event tells the helper; the watch on the app does.
        try FileManager.default.moveItem(at: app, to: apps.appendingPathComponent("Trashed.app"))
        waitFor("It should stop keeping the Mac awake well within the heartbeat", timeout: 15) {
            (try? lines()) == ["disablesleep 1", "disablesleep 0"]
        }
        waitFor("And report appMissing") { (try? status().state) == .appMissing }
    }

    func testEverySignalClearsTheFlagAndSaysSo() throws {
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("actions"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("daemon-state"))
            let daemon = try startDaemon()
            waitFor("The daemon should hold the flag on start") { (try? lines()) == ["disablesleep 1"] }
            waitFor("And say so") { (try? status().state) == .armed }
            kill(daemon.processIdentifier, signal)
            daemon.waitUntilExit()
            XCTAssertEqual(daemon.terminationStatus, 0, "signal \(signal)")
            XCTAssertEqual(daemon.terminationReason, .exit, "signal \(signal)")
            XCTAssertEqual(try lines(), ["disablesleep 1", "disablesleep 0"], "signal \(signal)")
            XCTAssertEqual(try status().state, .off)
            XCTAssertFalse(try status().enabled)
            XCTAssertTrue(try lines("daemon-state").contains("flag=0"))
        }
    }

    func testTheDaemonStaysQuietWhenNothingChanges() throws {
        let daemon = try startDaemon()
        defer { daemon.terminate(); daemon.waitUntilExit() }
        waitFor("The daemon should hold the flag on start") { (try? lines()) == ["disablesleep 1"] }
        let status = directory.appendingPathComponent("status")
        waitFor("And write its status") { FileManager.default.fileExists(atPath: status.path) }
        let written = try FileManager.default.attributesOfItem(atPath: status.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.5)
        // No polling: nothing was run and nothing rewritten while nothing changed.
        XCTAssertEqual(try lines(), ["disablesleep 1"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: status.path)[.modificationDate] as? Date, written)
    }
}
