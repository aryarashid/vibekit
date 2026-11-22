import Darwin
import Foundation
import VibeKitCore

enum HeadlessLaunch {
    /// Unlike the GUI, the launching CLI can exit immediately. Give the server a private read/write FIFO for
    /// stdin so it can keep waiting for input without a parent process kept alive just to hold a pipe writer.
    static func restart(_ spec: LaunchSpec, server: Server, support: URL, logs: URL) async throws -> ManagedProcess {
        let registry = ManagedRegistry(directory: support)
        _ = try registry.load()
        let fm = FileManager.default
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        var environment = spec.environment
        if environment == nil { environment = await ShellEnvironment.load() }
        let entries = environment ?? ShellEnvironment.fallback()
        let process = Process()
        if spec.viaShell {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec " + spec.arguments.joined(separator: " ")]
        } else {
            let name = ((spec.arguments.first ?? spec.executable) as NSString).lastPathComponent
            let executable = fm.isExecutableFile(atPath: spec.executable) ? spec.executable : ProcessControl.which(name, environment: entries)
            guard let executable else { throw ProcessControl.SpawnError.executableNotFound(name) }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(spec.arguments.dropFirst())
        }
        var env: [String: String] = [:]
        for entry in entries {
            if let equals = entry.firstIndex(of: "=") { env[String(entry[..<equals])] = String(entry[entry.index(after: equals)...]) }
        }
        env["PWD"] = spec.directory
        env["VIBEKIT_MANAGED"] = "1"
        env["XPC_SERVICE_NAME"] = "0"
        if env["FORCE_COLOR"] == nil { env["FORCE_COLOR"] = "1" }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: spec.directory, isDirectory: true)
        let fifo = logs.appendingPathComponent(".stdin-\(UUID())")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let inputFD = open(fifo.path, O_RDWR | O_CLOEXEC)
        let inputError = errno
        unlink(fifo.path)
        guard inputFD >= 0 else { throw POSIXError(.init(rawValue: inputError) ?? .EIO) }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        process.standardInput = input

        let log = logs.appendingPathComponent("server-\(server.primaryPort)-\(UUID()).log")
        let fd = open(log.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output

        var launched = false
        defer { if !launched { try? fm.removeItem(at: log) } }
        try await stop(server, support: support) {
            try process.run()
            launched = true
        }
        let pid = process.processIdentifier
        guard let started = LibProc.startDate(pid) else { throw CLIError("Restart exited before registration. Log: \(log.path)") }
        let owner = ManagedProcess.LogOwner(title: server.title, ports: server.ports.map(\.port),
                                           directory: server.project?.folder ?? spec.directory)
        let record = ManagedProcess(pid: pid, started: started, log: log, owner: owner)
        do {
            try registry.update { entries in
                entries.removeValue(forKey: server.id)
                entries["\(pid)-\(Int(started.timeIntervalSince1970))"] = record
            }
        } catch { throw CLIError("Started PID \(pid), but could not save its log path: \(log.path). \(error.localizedDescription)") }
        return record
    }

    /// A second CLI that resolved the same old PID must not launch another copy after the first stopped it.
    static func stop(_ server: Server, support: URL, afterStop: () throws -> Void = {}) async throws {
        if server.isContainerControlled {
            let detail = server.containerName.map { "runs inside container '\($0)'" } ?? "is a container runtime"
            throw CLIError("\(server.title) \(detail). Stop or restart containers with docker or orb instead.")
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lockFile = support.appendingPathComponent(".control-\(server.id).lock")
        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CLIError("Another operation is controlling \(server.title).") }
        defer { unlink(lockFile.path) }
        guard LibProc.startDate(server.rootPid) == server.startDate else { throw CLIError("The selected process has already exited.") }
        guard await ProcessControl.stop(root: server.rootPid, started: server.startDate) != .failed else {
            throw CLIError("Could not stop \(server.title) (PID \(server.rootPid)).")
        }
        try afterStop()
    }
}
