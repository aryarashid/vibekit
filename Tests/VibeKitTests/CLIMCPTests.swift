import Foundation
import XCTest
@testable import VibeKit
import VibeKitCore

final class CLIMCPTests: XCTestCase {
    typealias Object = [String: Any]

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vk-cli-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func server(_ name: String = "Project", pid: Int32 = 40, port: UInt16 = 5000) -> Server {
        Server(id: "\(pid)-0", pid: pid + 1, rootPid: pid, listenerPids: [pid + 1, pid + 2],
               startDate: Date(timeIntervalSince1970: 0), ports: [
                PortBinding(port: port, address: "0.0.0.0", isIPv6: false),
                PortBinding(port: port + 1, address: "::1", isIPv6: true)
               ], framework: .vite, project: Project(name: name, root: "/tmp/\(name)", subpath: nil, branch: "main", worktree: nil),
               processName: "node", executable: "/bin/node", command: "vite", directory: "/tmp/\(name)", launch: nil)
    }

    func testArguments() throws {
        XCTAssertEqual(try CLIArguments.parse([]), .app)
        XCTAssertEqual(try CLIArguments.parse(["--list", "--all"]), .action(.list(all: true, cpu: false), json: false))
        XCTAssertEqual(try CLIArguments.parse(["--list", "--json", "--cpu"]), .action(.list(all: false, cpu: true), json: true))
        XCTAssertEqual(try CLIArguments.parse(["--port", "80"]), .action(.port(80, next: false), json: false))
        XCTAssertEqual(try CLIArguments.parse(["port", "--next", "65535", "--json"]), .action(.port(65535, next: true), json: true))
        XCTAssertEqual(try CLIArguments.parse(["--toggle", "prompts", "--query", "a b"]), .toggle(tab: "prompts", query: "a b"))
        XCTAssertEqual(try CLIArguments.parse(["--toggle", "--query", "vite"]), .toggle(tab: nil, query: "vite"))
        XCTAssertEqual(try CLIArguments.parse(["--mcp", "--allow-control"]), .mcp(allowControl: true))
        XCTAssertEqual(try CLIArguments.parse(["--bench", "2", "--open"]), .bench(seconds: 2, open: true))
        XCTAssertEqual(try CLIArguments.parse(["--snapshot", "out.png", "--demo", "--query", "vite"]), .snapshot("out.png"))
        XCTAssertEqual(try CLIArguments.parse(["logs", "target"]), .action(.logs("target", tail: 50), json: false))
        XCTAssertEqual(try CLIArguments.parse(["prompt", "two", "words", "--json"]), .action(.prompts("two words"), json: true))
        for args in [["port", "0"], ["port", "65536"], ["port", "--next"], ["stop", ""], ["restart"],
                     ["--toggle", "--query"], ["logs", "name", "--tail", "-1"], ["--mcp", "--allow-controll"]] {
            XCTAssertThrowsError(try CLIArguments.parse(args)) { XCTAssertEqual(($0 as? CLIError)?.code, 2) }
        }
    }

    func testResolutionAndPortPIDCollision() throws {
        let first = server(), second = server("Project Two", pid: 5000, port: 8000)
        let both = [first, second]
        for target in ["41", "42", "40"] { XCTAssertEqual(try ListCommand.resolve(target, servers: both), first) }
        XCTAssertEqual(try ListCommand.resolve("two", servers: both), second)
        for target in ["project", "5000", "5001"] {
            XCTAssertThrowsError(try ListCommand.resolve(target, servers: both)) {
                XCTAssertEqual(($0 as? CLIError)?.code, 2)
                XCTAssertTrue($0.localizedDescription.contains("PID 40"))
                XCTAssertTrue($0.localizedDescription.contains("PID 5000"))
            }
        }
        XCTAssertThrowsError(try ListCommand.resolve("missing", servers: both))
    }

    func testJSONFieldsAndManagedLogTail() async throws {
        let dir = try temporaryDirectory(), fixture = server(), file = dir.appendingPathComponent("output.log")
        let text = String(repeating: "old line\n", count: 9000) + "old\rfinal\r\n\u{1b}[32mgreen\u{1b}[0m\n\n"
        try Data(text.utf8).write(to: file)
        try ManagedRegistry(directory: dir).update {
            $0[fixture.id] = ManagedProcess(pid: fixture.rootPid, started: fixture.startDate, log: file)
        }
        let service = ListCommand(support: dir, scan: { _, _ in [fixture] })
        let result = try await service.run(.list(all: true, cpu: false), format: .json)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [Object])
        let row = try XCTUnwrap(array.first)
        XCTAssertEqual(Set(row.keys), Set("id primaryPort ports title framework category url networkURL branch subpath worktree projectRoot directory pid rootPid command uptimeSeconds cpu memoryBytes processCount logPath".split(separator: " ").map(String.init)))
        XCTAssertTrue(row["cpu"] is NSNull)
        XCTAssertTrue(row["worktree"] is NSNull)
        XCTAssertEqual(row["logPath"] as? String, file.path)
        XCTAssertEqual((row["ports"] as? [Object])?.last?["isIPv6"] as? Bool, true)
        let output = try await service.run(.logs("5001", tail: 3), format: .text)
        XCTAssertEqual(output.text, "final\ngreen\n\n")
        XCTAssertEqual(try ListCommand.tail(file, lines: 0), "")
        try Data("before\n🦊 tail".utf8).write(to: file)
        XCTAssertEqual(try ListCommand.tail(file, lines: 1), "🦊 tail")
        let entry = RecentServer(title: "Past project", frameworkName: "Vite", frameworkColor: nil, port: 7000, branch: nil,
                                 launch: LaunchSpec(executable: "vite", arguments: ["vite"], directory: "/tmp/past", viaShell: false,
                                                    environment: nil), stoppedAt: Date(), log: file)
        try JSONEncoder().encode([entry]).write(to: dir.appendingPathComponent("recents.json"))
        let recent = try await service.run(.logs("past", tail: 1), format: .text)
        XCTAssertEqual(recent.text, "🦊 tail")
    }

    func testPortRangeAndOwner() async throws {
        let dir = try temporaryDirectory(), fixture = server()
        let service = ListCommand(support: dir, scan: { _, _ in [fixture] }, isFree: { $0 == 65535 })
        XCTAssertEqual(try service.nextPort(from: 65534), 65535)
        XCTAssertEqual(try service.nextPort(from: 65535), 65535)
        XCTAssertThrowsError(try service.nextPort(from: 64534))
        XCTAssertEqual(try service.nextPort(from: 64535), 65535)
        let taken = try await service.run(.port(5001, next: false), format: .json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(taken.text.utf8)) as? Object)
        XCTAssertEqual(taken.exitCode, 1)
        XCTAssertEqual(object["free"] as? Bool, false)
        XCTAssertEqual((object["owner"] as? Object)?["id"] as? String, fixture.id)
    }

    private func rpc(_ server: MCPServer, _ method: String, params: Object = [:]) async throws -> Object {
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "test", "method": method, "params": params])
        let reply = await server.handleRequest(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reply)) as? Object)
        XCTAssertEqual(obj["id"] as? String, "test")
        return obj
    }

    private func content(_ result: Object) throws -> String {
        try XCTUnwrap(((result["result"] as? Object)?["content"] as? [Object])?.first?["text"] as? String)
    }

    func testMCPHandshakeToolsAndPermissions() async throws {
        let readOnly = MCPServer { _ in XCTFail("Unexpected tool invocation"); return CommandOutput(text: "") }
        let rw = MCPServer(allowControl: true) { action in
            XCTAssertEqual(action, .restart("demo"))
            return CommandOutput(text: "started")
        }
        let initReply = try await rpc(readOnly, "initialize", params: ["protocolVersion": "2025-03-26"])
        XCTAssertEqual((initReply["result"] as? Object)?["protocolVersion"] as? String, "2025-03-26")
        let initialized = await readOnly.handleRequest(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(initialized)
        let ping = try await rpc(readOnly, "ping")
        XCTAssertTrue(ping["result"] is Object)
        let names: Set<String> = ["list_servers", "check_port", "probe_server", "read_server_logs", "list_prompts"]
        for server in [readOnly, rw] {
            let result = try await rpc(server, "tools/list")
            let tools = try XCTUnwrap((result["result"] as? Object)?["tools"] as? [Object])
            XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), server.allowControl ? names.union(["stop_server", "restart_server"]) : names)
        }
        for name in ["stop_server", "restart_server"] {
            let result = try await rpc(readOnly, "tools/call", params: ["name": name, "arguments": ["target": "demo"]])
            XCTAssertTrue(((result["error"] as? Object)?["message"] as? String)?.contains("--allow-control") == true)
        }
        let restart = try await rpc(rw, "tools/call", params: ["name": "restart_server", "arguments": ["target": "demo"]])
        XCTAssertEqual(try content(restart), "started")
    }

    func testMCPPortAndPromptTools() async throws {
        let dir = try temporaryDirectory()
        let prompts = [Prompt(title: "Write review", text: "the exact\nbody", pinned: true), Prompt(title: "Greeting", text: "hello")]
        try PromptLibrary.save(prompts, to: dir.appendingPathComponent("prompts.json"))
        let service = ListCommand(support: dir, isFree: { $0 >= 59003 })
        let mcp = MCPServer { try await service.run($0, format: .mcp) }
        let result = try await rpc(mcp, "tools/call", params: ["name": "check_port", "arguments": ["port": 59000, "next_free": true]])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(content(result).utf8)) as? [String: Int], ["startPort": 59000, "port": 59003])
        let match = try await rpc(mcp, "tools/call", params: ["name": "list_prompts", "arguments": ["query": "review"]])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content(match).utf8)) as? [Object])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["text"] as? String, prompts[0].text)
        let raw = try await service.run(.prompts("review"), format: .text)
        XCTAssertEqual(raw.text, prompts[0].text)
    }

    func testMCPRejectsMalformedRequestsAndTypes() async throws {
        let server = MCPServer { _ in XCTFail("Invalid call ran a tool"); return CommandOutput(text: "") }
        let invalid = await server.handleRequest(Data("{".utf8))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(invalid)) as? Object)
        XCTAssertEqual((reply["error"] as? Object)?["code"] as? Int, -32700)
        let missing = try await rpc(server, "no/method")
        XCTAssertEqual((missing["error"] as? Object)?["code"] as? Int, -32601)
        for args: Object in [["port": true], ["port": 0], ["port": "80"], ["port": 80.5], ["port": 80, "next_free": 1], ["port": 80, "extra": true]] {
            let result = try await rpc(server, "tools/call", params: ["name": "check_port", "arguments": args])
            XCTAssertEqual((result["error"] as? Object)?["code"] as? Int, -32602)
        }
        let unknown = MCPServer { _ in throw CLIError("No recorded log") }
        let result = try await rpc(unknown, "tools/call", params: ["name": "read_server_logs", "arguments": ["target": "demo"]])
        XCTAssertEqual((result["result"] as? Object)?["isError"] as? Bool, true)
    }

    func testInstallerOwnsOnlyItsOwnLink() throws {
        let dir = try temporaryDirectory(), binary = dir.appendingPathComponent("VibeKit")
        try Data("binary".utf8).write(to: binary)
        let bin = dir.appendingPathComponent("bin"), link = bin.appendingPathComponent("vibekit")
        let installer = CLIInstaller(executable: binary, directory: bin)
        XCTAssertEqual(installer.status(), .notInstalled)
        XCTAssertEqual(try installer.install(), .installed(link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), binary.path)
        XCTAssertEqual(try installer.install(), .installed(link))
        XCTAssertEqual(try installer.uninstall(), .notInstalled)
        try Data("preserve".utf8).write(to: link)
        XCTAssertEqual(try installer.install(), .conflict(link))
        XCTAssertEqual(try installer.uninstall(), .conflict(link))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "preserve")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../missing")
        XCTAssertEqual(try installer.install(), .conflict(link))
        XCTAssertEqual(try installer.uninstall(), .conflict(link))
    }
}

extension CLIMCPTests {
    func testHeadlessRestartKeepsStdinOpenAndPublishesItsLog() async throws {
        let dir = try temporaryDirectory()
        // A recognized server script remains restartable even under the system temporary directory.
        let script = dir.appendingPathComponent("http.server")
        let body = """
        import socket, sys
        s = socket.socket()
        s.bind(('127.0.0.1', int(sys.argv[1])))
        s.listen(1)
        print('ready', flush=True)
        # A server that exits when stdin closes must survive the CLI returning.
        sys.stdin.read()
        """
        try Data(body.utf8).write(to: script)
        let port = try ListCommand().nextPort(from: UInt16.random(in: 40000...59000))
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, String(port)]
        process.currentDirectoryURL = dir
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let service = ListCommand(support: dir, logs: dir)
        func findServer(pid: Int32) async throws -> Server {
            for _ in 0..<80 {
                if let found = service.scan(true, false).first(where: { $0.rootPid == pid && $0.primaryPort == port }) { return found }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CLIError("Fixture did not listen.")
        }
        let original = try await findServer(pid: process.processIdentifier)
        let spec = try XCTUnwrap(original.launch)
        // Only the known fixture identity may be controlled, even if other users of this machine bind similar ports.
        let isolated = ListCommand(support: dir, logs: dir, scan: { _, _ in [original] })
        let changed = try await isolated.run(.restart(String(original.rootPid)), format: .json)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(changed.text.utf8)) as? Object)
        let pid = try XCTUnwrap(result["pid"] as? Int32)
        let records = try ManagedRegistry(directory: dir).load()
        let record = try XCTUnwrap(records.values.first { $0.pid == pid })
        defer { ProcessControl.forceKill(root: pid, started: record.started) }
        let replacement = try await findServer(pid: pid)
        XCTAssertEqual(replacement.launch?.directory, spec.directory)
        XCTAssertEqual(records[replacement.id]?.log, record.log)
        let running = ListCommand(support: dir, logs: dir, scan: { _, _ in [replacement] })
        let log = try await running.run(.logs(String(pid), tail: 1), format: .text)
        XCTAssertEqual(log.text, "ready\n")
        _ = try await running.run(.stop(String(pid)), format: .json)
        XCTAssertFalse(ProcessControl.isAlive(pid))
        let offline = ListCommand(support: dir, logs: dir, scan: { _, _ in [] })
        for target in [String(pid), String(port), original.title] {
            let saved = try await offline.run(.logs(target, tail: 1), format: .text)
            XCTAssertEqual(saved.text, "ready\n")
        }
    }
}
