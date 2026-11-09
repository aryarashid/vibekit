import AppKit
import XCTest
@testable import VibeKit
import VibeKitCore

/// Runs a real throwaway server through restart, force quit and start again, with storage and logs in a temp folder.
/// Only the server this test starts is ever signalled.
@MainActor
final class ProcessFlowTests: XCTestCase {
    private var directory: URL!
    private var server: Process?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vk-flow-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("site"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server?.terminate()
        try? FileManager.default.removeItem(at: directory)
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testRestartForceQuitAndStartAgain() throws {
        var port: UInt16 = 0
        repeat { port = UInt16.random(in: 41_000...48_000) } while !Network.isPortFree(port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.currentDirectoryURL = directory.appendingPathComponent("site")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process

        let suite = "VibeKitTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(settings: Settings(defaults: defaults), persistenceDirectory: directory.appendingPathComponent("support"),
                                logsDirectory: directory.appendingPathComponent("logs"))
        store.isPanelOpen = true
        store.start()
        func running() -> Server? { store.servers.first { $0.ports.contains { $0.port == port } } }
        XCTAssertTrue(pump { running() != nil }, "The scan finds the server")
        let original = try XCTUnwrap(running())
        XCTAssertEqual(original.rootPid, process.processIdentifier)
        XCTAssertTrue(pump { store.pages[original.id] != nil }, "The panel reads its page")

        // Restart: the same command comes back under Vibe Kit, with a log.
        store.restart(original)
        XCTAssertTrue(pump { running().map { $0.rootPid != original.rootPid } ?? false }, "Restart brings it back")
        let restarted = try XCTUnwrap(running())
        XCTAssertTrue(pump { store.pending[original.id] == nil })
        XCTAssertNotNil(store.logURL(for: restarted), "A server Vibe Kit started has a log")

        // Force quit: gone, nothing pending, and remembered so it can be started again.
        store.forceQuit(restarted)
        XCTAssertTrue(pump { running() == nil && store.pending.isEmpty }, "Force quit leaves nothing running or pending")
        let recent = try XCTUnwrap(store.recents.first { $0.port == port })
        XCTAssertEqual(recent.reason, .stopped)

        // Start again from Recently Stopped.
        store.start(recent)
        XCTAssertTrue(pump { running() != nil }, "Start brings it back")
        XCTAssertTrue(pump { !store.recents.contains { $0.port == port } }, "Running again, it leaves Recently Stopped")
        let again = try XCTUnwrap(running())
        store.stop(again)
        XCTAssertTrue(pump { running() == nil && store.pending.isEmpty }, "Stop leaves nothing running or pending")
        XCTAssertFalse(ProcessControl.isAlive(again.rootPid))
    }
}
