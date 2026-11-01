import Darwin
import Foundation

public enum ProcessControl {
    public enum StopResult: Sendable {
        case stopped
        case forced
        case failed
    }

    /// Sends SIGTERM to `root` and everything under it, like Ctrl-C in the terminal that started it,
    /// then SIGKILL to whatever is still alive after `grace` seconds.
    /// `started` is the root's start time from the scan. If the PID now belongs to another process, nothing is signalled.
    public static func stop(root: pid_t, started: Date, grace: TimeInterval = 4) async -> StopResult {
        let tree = identities(of: root, started: started)
        guard !tree.isEmpty else { return .stopped }
        for process in tree where process.isAlive { kill(process.pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !tree.contains(where: \.isAlive) { return .stopped }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // `isAlive` checks the start time again, so a PID reused during the grace period is left alone.
        for process in tree where process.isAlive { kill(process.pid, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(200))
        return tree.contains(where: \.isAlive) ? .failed : .forced
    }

    /// SIGKILL the whole tree immediately.
    public static func forceKill(root: pid_t, started: Date) {
        for process in identities(of: root, started: started) where process.isAlive { kill(process.pid, SIGKILL) }
    }

    /// A PID and its start time. PIDs get reused, the pair does not.
    struct Identity {
        let pid: pid_t
        let start: Date
        var isAlive: Bool { ProcessControl.isAlive(pid) && LibProc.startDate(pid) == start }
    }

    /// The tree under `root`, or nothing if `root` is no longer the process that started at `started`.
    static func identities(of root: pid_t, started: Date) -> [Identity] {
        func isRoot() -> Bool { LibProc.startDate(root).map { abs($0.timeIntervalSince(started)) < 0.001 } ?? false }
        guard isRoot() else { return [] }
        let tree = PortScanner.processTree(of: root).compactMap { pid in LibProc.startDate(pid).map { Identity(pid: pid, start: $0) } }
        // Check again: if the root was replaced while the table was read, the tree belongs to someone else.
        return isRoot() ? tree : []
    }

    /// True for a live process. Zombies count as dead.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    public struct Spawned: Sendable {
        public let pid: pid_t
        /// Keeps the child's stdin open. Some servers (Create React App) exit when stdin closes.
        public let stdinWriter: Int32
    }

    public enum SpawnError: Error, LocalizedError {
        case executableNotFound(String)
        case failed(Int32)

        public var errorDescription: String? {
            switch self {
            case .executableNotFound(let name): "Could not find \(name) on PATH."
            case .failed(let code): "Launch failed: \(String(cString: strerror(code)))."
            }
        }
    }

    /// Starts `spec` in its own session with output going to `log`.
    /// `onExit` gets the PID and exit code when the process ends (128 + signal number when a signal ended it).
    public static func spawn(_ spec: LaunchSpec, environment: [String], log: URL,
                             onExit: @escaping @Sendable (_ pid: pid_t, _ code: Int32) -> Void = { _, _ in }) throws -> Spawned {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)

        var env = environment
        if !env.contains(where: { $0.hasPrefix("FORCE_COLOR=") }) { env.append("FORCE_COLOR=1") }
        env.removeAll { $0.hasPrefix("PWD=") }
        env.append("PWD=\(spec.directory)")

        let executable: String
        let argv: [String]
        if spec.viaShell {
            executable = "/bin/sh"
            argv = ["/bin/sh", "-c", "exec " + spec.arguments.joined(separator: " ")]
        } else if FileManager.default.isExecutableFile(atPath: spec.executable) {
            executable = spec.executable
            argv = spec.arguments
        } else {
            // The runtime moved (a Homebrew upgrade, a new nvm version): find it on PATH again.
            let name = (spec.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? (spec.executable as NSString).lastPathComponent
            guard let found = which(name, environment: env) else { throw SpawnError.executableNotFound(name) }
            executable = found
            argv = spec.arguments
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnError.failed(errno) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[0], 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, spec.directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointer in
            withCStrings(env) { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        close(fds[0])
        guard status == 0 else {
            close(fds[1])
            throw SpawnError.failed(status)
        }
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        reapWhenDone(pid, onExit: onExit)
        return Spawned(pid: pid, stdinWriter: fds[1])
    }

    /// We are the parent of spawned servers, so we must reap them or they linger as zombies.
    private static func reapWhenDone(_ pid: pid_t, onExit: @escaping @Sendable (pid_t, Int32) -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        let reap: @Sendable (_ block: Bool) -> Void = { block in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, block ? 0 : WNOHANG) } while result == -1 && errno == EINTR
            guard result == pid else { return }
            source.cancel()
            onExit(pid, exitCode(status))
        }
        // The exit event can arrive a moment before the child becomes a zombie, and it fires only once,
        // so this wait blocks until the child can be reaped. It returns at once if the check below got it first.
        source.setEventHandler { reap(true) }
        source.resume()
        // The process may have exited before the source was armed.
        reap(false)
    }

    /// Decodes a `waitpid` status: the exit code, or 128 + the signal number, like a shell's `$?`.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    public static func which(_ name: String, environment: [String]) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = environment.first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) } ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// The user's login shell environment, for starting servers whose original environment is gone.
public enum ShellEnvironment {
    public static func load(timeout: TimeInterval = 6) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: loadSync(timeout: timeout))
            }
        }
    }

    private static func loadSync(timeout: TimeInterval) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__VIBEKIT_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive login shell, so PATH changes in .zshrc (nvm, fnm, mise, asdf) are included.
        process.arguments = ["-ilc", "printf '\\n\(marker)\\n'; /usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var env = fallback()
        do {
            try process.run()
            let deadline = DispatchTime.now() + timeout
            let group = DispatchGroup()
            group.enter()
            let box = DataBox()
            DispatchQueue.global().async {
                box.data = output.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            if group.wait(timeout: deadline) == .timedOut {
                process.terminate()
                return env
            }
            let data = box.data
            if let range = data.range(of: Data((marker + "\n").utf8)) {
                let body = data[range.upperBound...]
                let entries = body.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                    .filter { $0.contains("=") && !$0.hasPrefix("\n") }
                if entries.contains(where: { $0.hasPrefix("PATH=") }) { env = entries }
            }
        } catch {}
        return env
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Our own environment plus the usual places developer tools live.
    public static func fallback() -> [String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
                     "\(home)/.cargo/bin", "\(home)/.deno/bin", "\(home)/go/bin", "\(home)/.volta/bin"]
        let current = env["PATH"]?.split(separator: ":").map(String.init) ?? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra.filter { !current.contains($0) } + current).joined(separator: ":")
        return env.map { "\($0.key)=\($0.value)" }
    }
}
