import XCTest

final class LidSleepHelperTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibekit-lid-\(UUID())", isDirectory: true)
    private let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/lid-sleep-helper.sh")

    override func setUpWithError() throws {
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

    private func runHelper(_ arguments: [String] = ["--tick", "state"], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = directory
        process.arguments = [script.path] + arguments
        process.environment = [
            "VIBEKIT_LID_FAKE_DIR": directory.path,
            "VIBEKIT_LID_CONFIG": directory.appendingPathComponent("config").path,
        ].merging(environment) { $1 }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
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
        // Lid open, so a config read as valid would show up as `disablesleep 1`.
        try write("lid", "No")
        try write("power", "Battery")
        try write("percent", "1")
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
        try runDaemonBriefly()
        try write("now", String(1000 + 45 * 60))
        try runDaemonBriefly()
        XCTAssertTrue(try lines().contains("sleepnow"), "The restarted helper should keep counting from 1000")
    }

    private func runDaemonBriefly() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = [
            "VIBEKIT_LID_FAKE_DIR": directory.path,
            "VIBEKIT_LID_CONFIG": directory.appendingPathComponent("config").path,
            "VIBEKIT_LID_STATE": directory.appendingPathComponent("daemon-state").path,
            "VIBEKIT_LID_INTERVAL": "5",
        ]
        try process.run()
        Thread.sleep(forTimeInterval: 0.5)
        process.terminate()
        process.waitUntilExit()
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
}
