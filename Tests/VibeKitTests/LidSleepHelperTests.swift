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

    private func runHelper(_ arguments: [String] = ["--tick", "state"]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = directory
        process.arguments = [script.path] + arguments
        process.environment = [
            "VIBEKIT_LID_FAKE_DIR": directory.path,
            "VIBEKIT_LID_CONFIG": directory.appendingPathComponent("config").path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func lines(_ name: String = "actions") throws -> [String] {
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
        try write("lid", "Yes")
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
        try write("lid", "Yes")
        try write("state", "closed_at=$(touch pwned)\nfired=1x\nflag=10\n")
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
}
