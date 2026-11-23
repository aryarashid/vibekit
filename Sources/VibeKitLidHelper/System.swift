import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import VibeKitLidCore
import os

/// Everything the helper reads from the Mac and does to it. With `VIBEKIT_LID_FAKE_DIR` set, the
/// readings come from files in that folder and the actions are written to one, so tests can run
/// this same program without root and without putting the Mac to sleep.
struct HelperSystem: Sendable {
    let config: String
    let appFile: String
    let statePath: String
    let statusPath: String
    let fake: String?

    /// nil when the fake folder is named but empty, which would otherwise fall through to the real Mac.
    init?(environment: [String: String]) {
        if let fake = environment["VIBEKIT_LID_FAKE_DIR"] {
            guard !fake.isEmpty else { return nil }
            self.fake = fake
        } else {
            fake = nil
        }
        config = environment["VIBEKIT_LID_CONFIG"] ?? "/Library/Application Support/Vibe Kit/lid-sleep-minutes"
        // Written by the installer, root's like this program: the app this helper belongs to.
        appFile = environment["VIBEKIT_LID_APP_FILE"] ?? "/Library/Application Support/Vibe Kit/app-path"
        // /var/run is emptied at boot, so a timer never carries over a restart of the Mac.
        statePath = environment["VIBEKIT_LID_STATE"] ?? "/var/run/dev.vibekit.lid-sleep.state"
        statusPath = environment["VIBEKIT_LID_STATUS"] ?? fake.map { $0 + "/status" } ?? "/var/run/dev.vibekit.lid-sleep.status"
    }

    // MARK: Reading

    func readInputs() -> LidSleepEngine.Inputs {
        // The folder is root's, so the user can change this file's text but cannot swap it for a
        // link or a pipe. Still refuse anything but a plain file, and read at most 17 bytes so a
        // file that grows meanwhile cannot make root read more.
        let minutes = Self.readPlainFile(config, limit: LidSleepEngine.maxConfigBytes + 1)
            .flatMap(LidSleepEngine.parseMinutes) ?? 0
        if let fake {
            func word(_ name: String) -> String { Self.readWord(fake + "/" + name) }
            func yesNo(_ name: String) -> Bool? {
                switch word(name) {
                case "Yes": return true
                case "No": return false
                default: return nil
                }
            }
            return LidSleepEngine.Inputs(
                minutes: minutes, appPresent: appPresent(),
                lidClosed: yesNo("lid"), clamshellCausesSleep: yesNo("causes"), sleepDisabled: yesNo("sleepdisabled"),
                now: Self.digits(word("now"), upTo: 12),
                onBattery: word("power") == "Battery", batteryPercent: Self.digits(word("percent"), upTo: 3).map(Int.init),
                idleSleepDue: yesNo("idle") == true)
        }
        let lid = Self.readLid()
        let battery = Self.readBattery()
        // Only an open lid needs to know, and only while a delay is set.
        let idle = minutes > 0 && lid.closed == false && Self.idleSleepDue(onBattery: battery.onBattery)
        return LidSleepEngine.Inputs(
            minutes: minutes, appPresent: appPresent(),
            lidClosed: lid.closed, clamshellCausesSleep: lid.causesSleep, sleepDisabled: lid.sleepDisabled,
            now: Int64(time(nil)), onBattery: battery.onBattery, batteryPercent: battery.percent, idleSleepDue: idle)
    }

    /// Whether macOS would sleep now if `disablesleep` were off. The cheap readings come first, so
    /// `pmset -g custom` only runs once the user is away and nothing holds the Mac awake.
    private static func idleSleepDue(onBattery: Bool) -> Bool {
        guard let idle = hidIdleSeconds(), idle >= 60 else { return false }
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let assertions = status?.takeRetainedValue() as? [String: Int],
              LidSleepEngine.idleSleepDue(idleSeconds: idle, sleepTimerMinutes: 1, assertions: assertions, onBattery: onBattery),
              let output = capture("/usr/bin/pmset", ["-g", "custom"]) else { return false }
        let timer = LidSleepEngine.sleepTimerMinutes(pmsetCustom: output, onBattery: onBattery)
        return LidSleepEngine.idleSleepDue(idleSeconds: idle, sleepTimerMinutes: timer, assertions: assertions, onBattery: onBattery)
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    private static func hidIdleSeconds() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return Int(value.uint64Value / 1_000_000_000)
    }

    /// The path in the app file, if it names one. Used to watch the app for being moved away.
    func appPath() -> [UInt8]? {
        guard var bytes = Self.readPlainFile(appFile, limit: 1024) else { return nil }
        bytes.removeAll { $0 == 0 }
        while bytes.last == 0x0a { bytes.removeLast() }
        return bytes.isEmpty ? nil : bytes
    }

    /// True unless the app file names a folder that is no longer there.
    private func appPresent() -> Bool {
        guard let path = appPath() else { return true }
        var info = stat()
        return (path + [0]).withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { stat($0.baseAddress, &info) == 0 }
        } && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func readLid() -> (closed: Bool?, causesSleep: Bool?, sleepDisabled: Bool?) {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(root) }
        func flag(_ key: String) -> Bool? {
            guard let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return (value as? NSNumber)?.boolValue
        }
        return (flag("AppleClamshellState"), flag("AppleClamshellCausesSleep"), flag("SleepDisabled"))
    }

    /// Whether the Mac is running on its battery, and how full that is.
    private static func readBattery() -> (onBattery: Bool, percent: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue(),
              providing as String == kIOPMBatteryPowerKey else { return (false, nil) }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (true, nil) }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int, let full = info[kIOPSMaxCapacityKey] as? Int,
                  (0...1_000_000).contains(current), (1...1_000_000).contains(full) else { continue }
            return (true, current * 100 / full)
        }
        return (true, nil)
    }

    // MARK: Acting

    func perform(_ action: LidSleepEngine.Action) -> Bool {
        if let fake {
            return Self.appendLine(action.arguments.joined(separator: " "), to: fake + "/actions")
        }
        if case .disableSleep = action {
            return Self.run("/usr/bin/pmset", ["-a"] + action.arguments)
        }
        return Self.run("/usr/bin/pmset", action.arguments)
    }

    func log(_ message: String) {
        if let fake {
            _ = Self.appendLine(message, to: fake + "/log")
        } else {
            Self.logger.notice("\(message, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: "dev.vibekit.lid-sleep", category: "helper")

    /// Runs a system tool and waits for it. True only if it exited with 0.
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        spawn(path, arguments, output: nil)
    }

    /// Runs a system tool and returns what it printed, if it exited with 0. Only for tools that
    /// print a little: the pipe is read after the tool exits, and a tool that fills the pipe
    /// gets an error instead of waiting forever.
    private static func capture(_ path: String, _ arguments: [String]) -> String? {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return nil }
        let reader = ends[0], writer = ends[1]
        defer { close(reader) }
        _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
        _ = fcntl(reader, F_SETFL, O_NONBLOCK)
        _ = fcntl(writer, F_SETFL, O_NONBLOCK)
        let ok = spawn(path, arguments, output: writer)
        close(writer)
        guard ok else { return nil }
        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while output.count < 65_536 {
            let count = read(reader, &buffer, buffer.count)
            if count > 0 { output += buffer[0..<count] } else if count < 0 && errno == EINTR { continue } else { break }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func spawn(_ path: String, _ arguments: [String], output: Int32?) -> Bool {
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), strdup("LC_ALL=C"), nil]
        defer { (argv + envp).forEach { free($0) } }

        // This process ignores the signals it handles itself. The tool must not inherit that.
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in handledSignals { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let output {
            posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)
            posix_spawn_file_actions_addclose(&actions, output)
        }

        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else { return false }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return false }
        }
        // Exited, not killed, and with 0.
        return status & 0x7f == 0 && (status >> 8) & 0xff == 0
    }

    // MARK: Files

    static let handledSignals = [SIGTERM, SIGINT, SIGHUP]

    /// The first bytes of a plain file, never read through a link. nil if it is not one.
    static func readPlainFile(_ path: String, limit: Int) -> [UInt8]? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: limit)
        var count: Int
        repeat {
            count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, limit) }
        } while count < 0 && errno == EINTR
        guard count >= 0 else { return nil }
        return Array(buffer.prefix(count))
    }

    /// A short file's text without the line ends, for the fake readings.
    private static func readWord(_ path: String) -> String {
        guard var bytes = readPlainFile(path, limit: 64) else { return "" }
        while bytes.last == 0x0a { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func digits(_ text: String, upTo length: Int) -> Int64? {
        let bytes = text.utf8
        guard (1...length).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int64(text)
    }

    private static func appendLine(_ line: String, to path: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array((line + "\n").utf8)
        return bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count
    }

    /// Writes beside the target and renames over it, so a reader never sees half a file and a
    /// link planted at the target is replaced, not followed.
    @discardableResult
    static func writeAtomically(_ bytes: [UInt8], to path: String, mode: mode_t) -> Bool {
        var template = Array((path + ".XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return false }
        var done = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count
        done = fchmod(descriptor, mode) == 0 && done
        close(descriptor)
        if done { done = rename(template, path) == 0 }
        if !done { unlink(template) }
        return done
    }

    func loadState() -> LidSleepEngine.State {
        Self.loadState(statePath)
    }

    static func loadState(_ path: String) -> LidSleepEngine.State {
        guard let bytes = readPlainFile(path, limit: 4096) else { return LidSleepEngine.State() }
        return LidSleepEngine.State(serialized: String(decoding: bytes, as: UTF8.self))
    }

    /// Readable by everyone: the app runs as the user and shows this in Settings.
    @discardableResult
    func writeStatus(_ status: LidSleepStatus) -> Bool {
        Self.writeAtomically(Array(status.encoded), to: statusPath, mode: 0o644)
    }
}
