import Foundation
import VibeKitCore

struct CommandOutput {
    var text: String
    var exitCode: Int32 = 0

    static func json(_ value: Any, exitCode: Int32 = 0) throws -> Self {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return Self(text: String(decoding: data, as: UTF8.self) + "\n", exitCode: exitCode)
    }
}

struct ListCommand {
    enum Format { case text, json, mcp }
    var support = ServerStore.supportDirectory
    var logs = ServerStore.logsDirectory
    var scan: @Sendable (Bool, Bool) -> [Server] = Self.scanServers
    var isFree: @Sendable (UInt16) -> Bool = Network.isPortFree

    private static func scanServers(all: Bool, cpu: Bool) -> [Server] {
        let scanner = PortScanner()
        var categories = Set(ServerCategory.allCases)
        if !all { categories.remove(.other) }
        if cpu {
            _ = scanner.scan(usageFor: categories)
            Thread.sleep(forTimeInterval: 0.3)
        }
        return scanner.scan(usageFor: categories, fullSweep: true)
            .filter { categories.contains($0.category) }
            .sorted { ($0.category.sortOrder, $0.primaryPort, $0.rootPid) < ($1.category.sortOrder, $1.primaryPort, $1.rootPid) }
    }

    func run(_ action: ServerAction, format: Format) async throws -> CommandOutput {
        switch action {
        case .list(let all, let cpu):
            let servers = scan(all, cpu)
            if format == .text { return CommandOutput(text: Self.table(servers, cpu: cpu)) }
            let managed = try ManagedRegistry(directory: support).load()
            let host = Network.lanAddress()
            return try .json(servers.map { Self.record($0, host: host, log: managed[$0.id]?.log, cpu: cpu) })
        case .port(let port, let next):
            if next {
                let found = try nextPort(from: port)
                return format == .text ? CommandOutput(text: "\(found)\n") : try .json(["startPort": port, "port": found])
            }
            let free = isFree(port)
            var record: [String: Any] = ["port": port, "free": free]
            var message = "Port \(port) is " + (free ? "free." : "taken.")
            if !free, let owner = scan(true, false).first(where: { $0.ports.contains { $0.port == port } }) {
                message += " " + Self.label(owner)
                record["owner"] = Self.record(owner, host: Network.lanAddress(), log: try ManagedRegistry(directory: support).load()[owner.id]?.log, cpu: false)
            }
            return format == .text ? CommandOutput(text: message + "\n", exitCode: free ? 0 : 1)
                : try .json(record, exitCode: free ? 0 : 1)
        case .prompts(let query):
            let file = support.appendingPathComponent("prompts.json")
            let now = Date()
            let prompts = PromptLibrary.search(try PromptLibrary.load(from: file), query: query, now: now)
            func record(_ prompt: Prompt) -> [String: Any] {
                ["id": prompt.id.uuidString, "title": prompt.displayTitle, "text": prompt.text,
                 "pinned": prompt.pinned, "score": prompt.score(now: now)]
            }
            if !query.isEmpty, format != .mcp {
                guard let first = prompts.first else { throw CLIError("No matching prompt.") }
                if format == .json { return try .json(record(first)) }
                return CommandOutput(text: first.text)
            }
            if format != .text { return try .json(prompts.map(record)) }
            return CommandOutput(text: prompts.map { "\($0.displayTitle)\t\(String(format: "%.2f", $0.score(now: now)))\n" }.joined())
        case .logs(let target, let tail):
            return CommandOutput(text: try logTail(target: target, lines: tail))
        case .probe(let port, let host):
            guard let page = await Probe.page(host: host, port: port) else { throw CLIError("No HTTP response from \(host) on port \(port).") }
            return try .json(["status": page.status, "title": page.title as Any, "isSecure": page.isSecure])
        case .stop(let target), .restart(let target):
            let server = try Self.resolve(target, servers: scan(true, false))
            let restart = action == .restart(target)
            if restart && server.launch == nil { throw CLIError("No launch command for \(server.title).") }
            if restart, let spec = server.launch {
                let record = try await HeadlessLaunch.restart(spec, server: server, support: support, logs: logs)
                if format != .text {
                    return try .json(["status": "restarted", "id": server.id, "pid": record.pid, "logPath": record.log.path])
                }
                return CommandOutput(text: "Restarted \(server.title) (PID \(record.pid)). Log: \(record.log.path)\n")
            }
            try await HeadlessLaunch.stop(server, support: support)
            if format != .text { return try .json(["status": "stopped", "id": server.id, "rootPid": server.rootPid]) }
            return CommandOutput(text: "Stopped \(Self.label(server)).\n")
        }
    }

    static func record(_ server: Server, host: String?, log: URL?, cpu: Bool) -> [String: Any] {
        ["id": server.id, "primaryPort": server.primaryPort,
         "ports": server.ports.map { ["port": $0.port, "address": $0.address, "isIPv6": $0.isIPv6, "acceptsIPv4": $0.acceptsIPv4] as [String: Any] },
         "title": server.title, "framework": server.framework.name, "category": server.category.rawValue,
         "url": server.localURL?.absoluteString as Any, "networkURL": server.networkURL(host: host)?.absoluteString as Any,
         "branch": server.project?.branch as Any, "subpath": server.project?.subpath as Any,
         "worktree": server.project?.worktree as Any, "projectRoot": server.project?.root as Any,
         "directory": server.directory as Any, "pid": server.pid, "rootPid": server.rootPid, "command": server.command,
         "uptimeSeconds": max(0, Int(Date().timeIntervalSince(server.startDate))),
         "cpu": cpu ? server.cpu as Any : NSNull(), "memoryBytes": server.memory, "processCount": server.processCount,
         "logPath": log?.path as Any]
    }

    private static func table(_ servers: [Server], cpu: Bool) -> String {
        guard !servers.isEmpty else { return "No dev servers running.\n" }
        let header = ["PORT", "NAME", "KIND", "BRANCH", "PID", "CPU", "MEM"]
        let rows = [header] + servers.map { server in
            [String(server.primaryPort), server.title, server.framework.name, server.project?.branch ?? "",
             String(server.rootPid), cpu ? String(format: "%.1f%%", server.cpu) : "—", "\(server.memory / 1_048_576) MB"]
        }
        let widths = header.indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
                .joined(separator: "  ") + "\n"
        }.joined()
    }

    func nextPort(from start: UInt16) throws -> UInt16 {
        for candidate in Int(start)...min(65_535, Int(start) + 1000) where isFree(UInt16(candidate)) {
            return UInt16(candidate)
        }
        throw CLIError("No free port within the search range starting at \(start).")
    }

    private static func label(_ server: Server) -> String { "\(server.title) (port \(server.primaryPort), PID \(server.rootPid))" }

    private static func matching(_ target: String, servers: [Server]) -> [Server] {
        if let number = Int(target) {
            return servers.filter { server in
                server.rootPid == number || server.pid == number || server.listenerPids.contains { $0 == number }
                    || server.ports.contains { $0.port == number }
            }
        }
        guard !target.isEmpty else { return [] }
        return servers.filter { server in
            [server.title, server.project?.name, server.project?.folder, server.directory].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(target) }
        }
    }

    static func resolve(_ target: String, servers: [Server]) throws -> Server {
        let matches = matching(target, servers: servers)
        guard let first = matches.first else { throw CLIError("No running server matches '\(target)'.") }
        guard matches.count == 1 else {
            throw CLIError("Ambiguous target '\(target)':\n" + matches.map(label).joined(separator: "\n"), code: 2)
        }
        return first
    }

    private func logTail(target: String, lines: Int) throws -> String {
        let live = Self.matching(target, servers: scan(true, false))
        let managed = try ManagedRegistry(directory: support).load()
        if !live.isEmpty {
            let server = try Self.resolve(target, servers: live)
            if let log = managed[server.id]?.log {
                return try Self.tail(log, lines: lines)
            }
        }
        let recents: [RecentServer]
        do {
            recents = try JSONDecoder().decode([RecentServer].self, from: Data(contentsOf: support.appendingPathComponent("recents.json")))
        } catch CocoaError.fileReadNoSuchFile { recents = [] }
        let matches = recents.filter { entry in
            guard entry.log != nil else { return false }
            // Never return an unrelated stopped server's output just because its old port was reused.
            if let server = live.first { return server.launch?.signature == entry.id }
            if let number = Int(target) { return entry.port == number }
            return [entry.title, entry.projectFolder, entry.launch.directory].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(target) }
        }
        var candidates: [URL: String] = [:]
        for entry in matches {
            if let log = entry.log { candidates[log] = "\(entry.title) (port \(entry.port))" }
        }
        if live.isEmpty {
            for entry in managed.values {
                let owner = entry.owner
                let matches: Bool
                if let number = Int(target) {
                    matches = number == entry.pid || owner?.ports.contains { $0 == number } == true
                } else {
                    matches = [owner?.title, owner?.directory].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(target) }
                }
                if matches { candidates[entry.log] = "\(owner?.title ?? "Server") (PID \(entry.pid))" }
            }
        }
        guard let log = candidates.keys.first else { throw CLIError("No recorded log for '\(target)'.") }
        guard candidates.count == 1 else {
            throw CLIError("Ambiguous log target '\(target)':\n" + candidates.values.sorted().joined(separator: "\n"), code: 2)
        }
        return try Self.tail(log, lines: lines)
    }

    /// Work backwards in blocks until the requested suffix is complete, even for a very large log.
    static func tail(_ url: URL, lines: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard lines > 0 else { return "" }
        var offset = try handle.seekToEnd()
        var blocks: [Data] = []
        var breaks = 0
        while offset > 0, breaks <= lines {
            let length = Int(min(offset, 16 * 1024))
            offset -= UInt64(length)
            try handle.seek(toOffset: offset)
            let block = try handle.read(upToCount: length) ?? Data()
            breaks += block.filter { $0 == 10 }.count
            blocks.append(block)
        }
        var data = Data()
        for block in blocks.reversed() { data.append(block) }
        guard !data.isEmpty else { return "" }
        let endsInNewline = data.last == 10
        if endsInNewline { data.removeLast() }
        let suffix = data.split(separator: 10, omittingEmptySubsequences: false).suffix(lines).joined(separator: [10])
        let raw = String(decoding: Data(suffix), as: UTF8.self) + (endsInNewline ? "\n" : "")
        var plain = ANSI.parse(raw).map(\.text).joined()
        if !endsInNewline, plain.hasSuffix("\n") { plain.removeLast() }
        return plain
    }
}
