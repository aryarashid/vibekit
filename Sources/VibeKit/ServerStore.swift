import AppKit
import Observation
import VibeKitCore

/// A dev server that stopped while Vibe Kit was watching, kept so it can be started again in one click.
struct RecentServer: Codable, Identifiable, Hashable {
    var id: String { launch.signature }
    let title: String
    let frameworkName: String
    let frameworkColor: UInt32?
    let port: UInt16
    let branch: String?
    let launch: LaunchSpec
    let stoppedAt: Date
    /// Missing in lists saved by older versions.
    var reason: StopReason?
    /// Log file, for servers Vibe Kit started.
    var log: URL?
    /// The project folder it ran from. Missing in lists saved by older versions.
    var projectFolder: String?

    init(title: String, frameworkName: String, frameworkColor: UInt32?, port: UInt16, branch: String?, launch: LaunchSpec,
         stoppedAt: Date, reason: StopReason? = nil, log: URL? = nil, projectFolder: String? = nil) {
        self.title = title
        self.frameworkName = frameworkName
        self.frameworkColor = frameworkColor
        self.port = port
        self.branch = branch
        self.launch = launch
        self.stoppedAt = stoppedAt
        self.reason = reason
        self.log = log
        self.projectFolder = projectFolder
    }

    init(_ server: Server, launch: LaunchSpec, reason: StopReason, log: URL?) {
        self.init(title: server.title, frameworkName: server.framework.name, frameworkColor: server.framework.color,
                  port: server.primaryPort, branch: server.project?.branch, launch: launch, stoppedAt: Date(), reason: reason, log: log,
                  projectFolder: server.project?.folder)
    }

    /// The same server, stopped just now.
    func stopped(_ reason: StopReason, log: URL?) -> RecentServer {
        RecentServer(title: title, frameworkName: frameworkName, frameworkColor: frameworkColor, port: port, branch: branch,
                     launch: launch, stoppedAt: Date(), reason: reason, log: log, projectFolder: projectFolder)
    }
}

/// Why a server went away, so a crash does not look like a normal stop.
enum StopReason: Codable, Hashable {
    /// Stopped from Vibe Kit.
    case stopped
    /// Ended on its own or from elsewhere, such as Ctrl-C in its terminal.
    case exited
    /// A server Vibe Kit started ended with an error code.
    case crashed(code: Int32)
}

/// A server Vibe Kit started itself, so its output is in a log file.
struct ManagedProcess: Codable, Hashable {
    let pid: Int32
    let started: Date
    let log: URL
    /// Headless launches can finish while the GUI is closed, before it can create a Recently Stopped entry.
    var owner: LogOwner? = nil

    struct LogOwner: Codable, Hashable {
        let title: String
        let ports: [UInt16]
        let directory: String
    }
}

enum Pending: Equatable {
    case stopping
    case restarting
    case starting
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    var isError = false
}

@MainActor @Observable
final class ServerStore {
    private(set) var servers: [Server] = []
    private(set) var recents: [RecentServer] = []
    private(set) var pages: [String: PageInfo] = [:]
    /// Servers whose last page request got no answer.
    private(set) var unanswered: Set<String> = []
    /// Ports held by more than one server, where `localhost` can reach either.
    private(set) var sharedPorts: Set<UInt16> = []
    private(set) var history: [String: [Double]] = [:]
    private(set) var lanAddress: String?
    private(set) var pending: [String: Pending] = [:]
    private(set) var toast: Toast?
    private(set) var hasScanned = false
    /// Managed servers that crashed while the panel was closed, cleared on the next open.
    private(set) var unreadCrashes = 0

    let settings: Settings
    @ObservationIgnored private let persistenceDirectory: URL
    @ObservationIgnored private let logsDirectory: URL
    /// Called when the number of running dev servers changes, for the menu bar count.
    var onCountChange: ((Int) -> Void)?

    var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            if isPanelOpen {
                lanAddress = Network.lanAddress()
                if unreadCrashes > 0 {
                    let count = unreadCrashes
                    let last = lastCrashNotice
                    unreadCrashes = 0
                    lastCrashNotice = nil
                    let message: String
                    if count == 1, let last {
                        message = "\(last.title) crashed (exit \(last.code)). Check Recently Stopped."
                    } else {
                        message = "\(count) servers crashed while closed. Check Recently Stopped."
                    }
                    show(Toast(message: message, isError: true))
                }
                // Ask again, once, about servers that were failing or silent last time, or not asked for a while,
                // so a server that started failing since does not stay green.
                let stale = Date().addingTimeInterval(-300)
                staleProbes = Set(pages.filter { $0.value.status >= 500 }.keys).union(unanswered)
                    .union(probedAt.filter { $0.value < stale }.keys)
                retryAt.removeAll()
                scanNow(fullSweep: true)
            }
            schedule()
        }
    }

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.vibekit.scan", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private(set) var isDemo = false
    @ObservationIgnored private var probing = Set<String>()
    @ObservationIgnored private var staleProbes = Set<String>()
    @ObservationIgnored private var probeAttempts: [String: Int] = [:]
    @ObservationIgnored private var retryAt: [String: Date] = [:]
    @ObservationIgnored private var probedAt: [String: Date] = [:]
    /// Exit codes of servers Vibe Kit started, by PID, kept until the scan notices they are gone.
    @ObservationIgnored private var exitCodes: [Int32: Int32] = [:]
    @ObservationIgnored private var managed: [String: ManagedProcess] = [:]
    @ObservationIgnored private var stdinWriters: [Int32: Int32] = [:]
    /// Environments of servers stopped this session. Memory only, never written to disk.
    @ObservationIgnored private var recentEnvironments: [String: [String]] = [:]
    @ObservationIgnored private var shellEnvironment: [String]?
    @ObservationIgnored private var shellEnvironmentTask: Task<[String], Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastCount = -1
    /// Recently stopped servers that Vibe Kit started, by PID, until their exit code arrives.
    @ObservationIgnored private var recentPids: [Int32: String] = [:]
    /// Servers Vibe Kit started this session, by PID, until they exit.
    @ObservationIgnored private var launches: [Int32: Launch] = [:]
    @ObservationIgnored private var lastCrashNotice: (title: String, code: Int32)?

    private struct Launch {
        let pendingID: String
        /// What to show in Recently Stopped if it fails before it comes up.
        let entry: RecentServer
        let log: URL
        let started: Date
        /// Seen listening. Tracked apart from the spinner, which gives up after a while.
        var isUp = false
    }

    private static let historyLength = 36

    init(settings: Settings, persistenceDirectory: URL = ServerStore.supportDirectory, logsDirectory: URL = ServerStore.logsDirectory) {
        self.settings = settings
        self.persistenceDirectory = persistenceDirectory
        self.logsDirectory = logsDirectory
        recents = Self.load([RecentServer].self, from: persistenceDirectory.appendingPathComponent("recents.json")) ?? []
        managed = (Self.load([String: ManagedProcess].self, from: persistenceDirectory.appendingPathComponent("managed.json")) ?? [:]).filter { _, process in
            LibProc.startDate(process.pid).map { abs($0.timeIntervalSince(process.started)) < 1 } ?? false
        }
    }

    // MARK: Lists

    var devServers: [Server] { servers.filter { $0.category == .dev } }

    func servers(in category: ServerCategory) -> [Server] {
        servers.filter { $0.category == category }
    }

    func logURL(for server: Server) -> URL? {
        managed["\(server.rootPid)-\(Int(server.startDate.timeIntervalSince1970))"]?.log
    }

    // MARK: Scanning

    func start() {
        schedule()
        scanNow(fullSweep: true)
        guard !isDemo else { return }
        let directory = logsDirectory
        let keep = Set(managed.values.map { $0.log.standardizedFileURL } + recents.compactMap { $0.log?.standardizedFileURL })
        queue.async { Self.pruneLogs(in: directory, keep: keep) }
    }

    private var scanCategories: Set<ServerCategory> {
        var categories: Set<ServerCategory> = [.dev, .database, .service]
        if isPanelOpen && settings.showOtherListeners { categories.insert(.other) }
        return categories
    }

    /// 1.5 s while the panel is open, 4 s with generous leeway while it is closed, so the system can batch wakeups.
    private func schedule() {
        timer?.cancel()
        guard !isDemo else { return }
        let open = isPanelOpen || !pending.isEmpty
        let interval: DispatchTimeInterval = open ? .milliseconds(1500) : .seconds(4)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: open ? .milliseconds(150) : .seconds(1))
        timer.setEventHandler(handler: Self.scanJob(scanner, categories: scanCategories, fullSweep: false, store: self))
        timer.resume()
        self.timer = timer
    }

    func scanNow(fullSweep: Bool = false) {
        guard !isDemo else { return }
        queue.async(execute: Self.scanJob(scanner, categories: scanCategories, fullSweep: fullSweep, store: self))
    }

    /// Built outside the main actor because it runs on the scan queue.
    private nonisolated static func scanJob(_ scanner: PortScanner, categories: Set<ServerCategory>, fullSweep: Bool,
                                            store: ServerStore) -> @Sendable () -> Void {
        { [weak store] in
            let result = scanner.scan(usageFor: categories, fullSweep: fullSweep)
            Task { @MainActor in store?.apply(result) }
        }
    }

    func settingsChanged() {
        schedule()
        scanNow()
    }

    private func apply(_ scanned: [Server]) {
        guard !isDemo else { return }
        // Restarts from the CLI can publish logs while the panel is running.
        let registry = ManagedRegistry(directory: persistenceDirectory)
        if let external = try? registry.load() { managed.merge(external) { _, new in new } }
        let sorted = scanned.sorted { a, b in
            if a.category != b.category { return a.category.sortOrder < b.category.sortOrder }
            let byTitle = a.title.localizedStandardCompare(b.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return a.primaryPort < b.primaryPort
        }
        let previous = servers
        let ids = Set(sorted.map(\.id))

        // Dev servers that disappeared become "recently stopped", unless we are restarting them.
        let restarting = Set(pending.filter { $0.value == .restarting }.keys)
        for gone in previous where gone.category == .dev && !ids.contains(gone.id) && !restarting.contains(gone.id) {
            remember(gone, reason: pending[gone.id] == .stopping ? .stopped : .exited)
        }
        // A stopped server is back when its command runs again, or when the same project folder holds its port
        // again, for example after a restart with other flags or from another working directory.
        let running = Set(sorted.compactMap { $0.launch?.signature })
        func isBack(_ recent: RecentServer) -> Bool {
            if running.contains(recent.id) { return true }
            guard let folder = recent.projectFolder else { return false }
            return sorted.contains { $0.holds(port: recent.port, inFolder: folder) }
        }
        if recents.contains(where: isBack) {
            recents.removeAll(where: isBack)
            saveRecents()
        }

        let hadPending = !pending.isEmpty
        // A launch is up once its own process leads a server, or a server with its command started after it.
        // Another copy of the same command that was already running does not count.
        for (pid, launch) in launches where !launch.isUp {
            let signature = launch.entry.launch.signature
            guard sorted.contains(where: { $0.rootPid == pid || ($0.launch?.signature == signature && $0.startDate >= launch.started) })
            else { continue }
            launches[pid]?.isUp = true
            if pending[launch.pendingID] != .stopping { pending[launch.pendingID] = nil }
        }

        // Clear pending work that has finished.
        for (id, state) in pending where state == .stopping && !ids.contains(id) {
            pending[id] = nil
        }

        for server in sorted where scanCategories.contains(server.category) {
            var samples = history[server.id] ?? []
            samples.append(server.cpu)
            if samples.count > Self.historyLength { samples.removeFirst(samples.count - Self.historyLength) }
            history[server.id] = samples
        }
        history = history.filter { ids.contains($0.key) }
        if pages.keys.contains(where: { !ids.contains($0) }) { pages = pages.filter { ids.contains($0.key) } }
        if unanswered.contains(where: { !ids.contains($0) }) { unanswered = unanswered.filter { ids.contains($0) } }
        probeAttempts = probeAttempts.filter { ids.contains($0.key) }
        retryAt = retryAt.filter { ids.contains($0.key) }
        probedAt = probedAt.filter { ids.contains($0.key) }

        // Ports where `localhost` could reach more than one server. Other listeners count: AirPlay holds 5000 and 7000.
        var owners: [UInt16: Set<String>] = [:]
        for server in sorted {
            for binding in server.ports where binding.isWildcard || binding.isLocalhost {
                owners[binding.port, default: []].insert(server.id)
            }
        }
        let shared = Set(owners.filter { $0.value.count > 1 }.keys)
        if shared != sharedPorts { sharedPorts = shared }
        for (pid, fd) in stdinWriters where !sorted.contains(where: { $0.rootPid == pid }) && !ProcessControl.isAlive(pid) {
            close(fd)
            stdinWriters[pid] = nil
        }
        // Drop finished managed entries now that `remember` has copied any log onto Recently Stopped.
        let liveManaged = managed.filter { key, process in
            ids.contains(key) || (ProcessControl.isAlive(process.pid)
                && LibProc.startDate(process.pid).map { abs($0.timeIntervalSince(process.started)) < 1 } == true)
        }
        if liveManaged.count != managed.count {
            let stale = managed.filter { liveManaged[$0.key] == nil }
            managed = (try? registry.update { entries in
                for (key, old) in stale where entries[key] == old { entries[key] = nil }
            }) ?? liveManaged
        }

        if sorted != servers { servers = sorted }
        hasScanned = true

        let count = sorted.lazy.filter { $0.category == .dev }.count
        if count != lastCount {
            lastCount = count
            onCountChange?(count)
        }
        if isPanelOpen { probeNewServers() }
        // Drop back to the idle cadence once pending work is done.
        if hadPending && pending.isEmpty { schedule() }
    }

    /// Reads each dev server's page once. A server that does not answer is asked again after a growing pause,
    /// and only while the panel is open, so a server that never speaks HTTP costs a request a minute at most.
    private func probeNewServers() {
        let now = Date()
        for server in servers where server.category == .dev && server.framework.speaksHTTP
            && !settings.skippedHTTPChecks.contains(server.httpCheckKey)
            && (pages[server.id] == nil || staleProbes.contains(server.id)) && !probing.contains(server.id)
            && (retryAt[server.id].map { $0 <= now } ?? true) {
            staleProbes.remove(server.id)
            probe(server)
        }
    }

    private func probe(_ server: Server) {
        guard !isDemo, !probing.contains(server.id) else { return }
        probing.insert(server.id)
        let id = server.id
        let host = host(for: server)
        let port = server.primaryPort
        Task {
            let page = await Probe.page(host: host, port: port)
            self.probing.remove(id)
            guard self.servers.contains(where: { $0.id == id }) else { return }
            self.probedAt[id] = Date()
            if let page {
                if self.pages[id] != page { self.pages[id] = page }
                self.unanswered.remove(id)
                self.probeAttempts[id] = nil
            } else {
                let attempts = (self.probeAttempts[id] ?? 0) + 1
                self.probeAttempts[id] = attempts
                // A server that is still compiling gets another try within seconds.
                let delays: [TimeInterval] = [2, 4, 8, 15, 30, 60]
                self.retryAt[id] = Date().addingTimeInterval(delays[min(attempts - 1, delays.count - 1)])
                if attempts >= 2 || self.pages[id] != nil { self.unanswered.insert(id) }
                // A cached page would stop the retries, so keep the server due for another look.
                if self.pages[id] != nil { self.staleProbes.insert(id) }
            }
        }
    }

    /// Forces an immediate single HTTP status probe for `server`.
    func reprobe(_ server: Server) {
        guard server.framework.speaksHTTP else { return }
        unanswered.remove(server.id)
        retryAt[server.id] = nil
        probeAttempts[server.id] = nil
        staleProbes.remove(server.id)
        probe(server)
    }

    /// Opts a server out of (or back into) HTTP status checks.
    func toggleSkipHTTP(_ server: Server) {
        let key = server.httpCheckKey
        if settings.skippedHTTPChecks.contains(key) {
            settings.skippedHTTPChecks.remove(key)
            reprobe(server)
        } else {
            settings.skippedHTTPChecks.insert(key)
            unanswered.remove(server.id)
            pages[server.id] = nil
            staleProbes.remove(server.id)
            retryAt[server.id] = nil
            probeAttempts[server.id] = nil
        }
    }

    // MARK: Prompt Context

    /// The best active dev server to populate prompt variables: a failing dev server first,
    /// otherwise the single or most recently started dev server.
    var contextServer: Server? {
        let dev = devServers
        guard !dev.isEmpty else { return nil }
        let failing = dev.filter { light(for: $0) == .failing }
        if !failing.isEmpty {
            return failing.max { $0.startDate < $1.startDate }
        }
        if dev.count == 1 { return dev[0] }
        return dev.max { $0.startDate < $1.startDate }
    }

    func promptContext(clipboard: String?) -> PromptContext {
        let server = contextServer
        let cleanClipboard = clipboard.flatMap { $0.isEmpty ? nil : $0 }
        return PromptContext(
            clipboard: cleanClipboard,
            url: server.flatMap { url(for: $0)?.absoluteString },
            port: server.map { String($0.primaryPort) },
            branch: server?.project?.branch,
            project: server?.project?.name ?? server?.title
        )
    }

    // MARK: Shared Ports

    func otherServers(sharingPort port: UInt16, with server: Server) -> [Server] {
        servers.filter { other in
            other.id != server.id && other.ports.contains { $0.port == port && ($0.isWildcard || $0.isLocalhost) }
        }
    }

    /// Tag label for a port shared with another listener, naming the address family when it distinguishes this server.
    func sharedPortLabel(for server: Server, binding: PortBinding) -> String {
        if !binding.isIPv6 { return "shared · IPv4" }
        if !binding.acceptsIPv4 { return "shared · IPv6" }
        let others = otherServers(sharingPort: binding.port, with: server)
        let allOthersIPv4 = !others.isEmpty && others.allSatisfy { other in
            other.ports.first { $0.port == binding.port }.map { !$0.isIPv6 } ?? false
        }
        return allOthersIPv4 ? "shared · IPv6" : "shared port"
    }

    // MARK: Actions

    /// Host for reaching a server binding, using explicit `127.0.0.1` / `[::1]` when another server shares the port.
    func host(for server: Server, binding: PortBinding? = nil) -> String {
        guard let target = binding ?? server.ports.first else { return server.host }
        return server.host(for: target, explicitLoopback: sharedPorts.contains(target.port))
    }

    /// The server's address on this Mac, over HTTPS when that is all it answered.
    func url(for server: Server, binding: PortBinding? = nil) -> URL? {
        guard let target = binding ?? server.ports.first else {
            return server.localURL(secure: pages[server.id]?.isSecure ?? false)
        }
        let secure = target.port == server.primaryPort && (pages[server.id]?.isSecure ?? false)
        return server.localURL(for: target, secure: secure, explicitLoopback: sharedPorts.contains(target.port))
    }

    /// The probe only asks the primary port, so its HTTPS answer applies only when that is the port shared on the network.
    func networkURL(for server: Server) -> URL? {
        let exposed = server.ports.first { $0.isWildcard && $0.acceptsIPv4 }?.port
        let secure = exposed == server.primaryPort && (pages[server.id]?.isSecure ?? false)
        return server.networkURL(host: lanAddress, secure: secure)
    }

    func open(_ server: Server, binding: PortBinding? = nil) {
        guard let url = url(for: server, binding: binding) else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String, label: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(Toast(message: "Copied \(label ?? text)"))
    }

    func copyURL(_ server: Server) {
        guard let url = url(for: server) else { return }
        copy(url.absoluteString)
    }

    func stop(_ server: Server) {
        guard pending[server.id] == nil else { return }
        pending[server.id] = .stopping
        schedule()
        Task {
            let result = await ProcessControl.stop(root: server.rootPid, started: server.startDate)
            if result == .failed {
                pending[server.id] = nil
                show(Toast(message: "Could not stop \(server.title)", isError: true))
                schedule()
            }
            scanNow()
        }
    }

    /// Also cancels a restart in progress: the restart sees it is no longer pending and does not start it again.
    func forceQuit(_ server: Server) {
        pending[server.id] = .stopping
        schedule()
        ProcessControl.forceKill(root: server.rootPid, started: server.startDate)
        scanNow()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard pending[server.id] == .stopping, ProcessControl.isAlive(server.rootPid),
                  LibProc.startDate(server.rootPid).map({ abs($0.timeIntervalSince(server.startDate)) < 0.001 }) ?? false else { return }
            pending[server.id] = nil
            show(Toast(message: "Could not force quit \(server.title)", isError: true))
            schedule()
        }
    }

    func stopAll() {
        for server in devServers { stop(server) }
    }

    func restart(_ server: Server) {
        guard let launch = server.launch, pending[server.id] == nil else { return }
        pending[server.id] = .restarting
        schedule()
        Task {
            let result = await ProcessControl.stop(root: server.rootPid, started: server.startDate)
            guard result != .failed else {
                pending[server.id] = nil
                show(Toast(message: "Could not stop \(server.title)", isError: true))
                schedule()
                return
            }
            // Give the kernel a moment to release the port.
            try? await Task.sleep(for: .milliseconds(250))
            // Force Quit while it was stopping means you want it gone, not back.
            guard pending[server.id] == .restarting else { return }
            launchServer(launch, environment: launch.environment, entry: RecentServer(server, launch: launch, reason: .stopped, log: nil),
                         pendingID: server.id)
        }
    }

    func start(_ recent: RecentServer) {
        guard pending[recent.id] == nil else { return }
        pending[recent.id] = .starting
        schedule()
        launchServer(recent.launch, environment: recentEnvironments[recent.id], entry: recent, pendingID: recent.id)
    }

    func forget(_ recent: RecentServer) {
        recents.removeAll { $0.id == recent.id }
        recentEnvironments[recent.id] = nil
        saveRecents()
    }

    func clearRecents() {
        recents.removeAll()
        recentEnvironments.removeAll()
        saveRecents()
    }

    /// Starts `spec`. `entry` describes the server for the recent list, in case it fails before it comes up.
    private func launchServer(_ spec: LaunchSpec, environment: [String]?, entry: RecentServer, pendingID: String) {
        let name = entry.title
        let state = pending[pendingID]
        Task {
            var env = environment
            if env == nil {
                env = await loadShellEnvironment()
                // Force Quit while the shell environment loaded means you want it gone, not back.
                guard pending[pendingID] == state else { return }
            }
            let log = freeLogURL(name: name, port: entry.port, directory: spec.directory)
            let started = Date().addingTimeInterval(-1)
            do {
                let spawned = try ProcessControl.spawn(spec, environment: env ?? ShellEnvironment.fallback(), log: log) { pid, code in
                    Task { @MainActor in self.processExited(pid: pid, code: code) }
                }
                launches[spawned.pid] = Launch(pendingID: pendingID, entry: entry, log: log, started: started)
                stdinWriters[spawned.pid] = spawned.stdinWriter
                if let started = LibProc.startDate(spawned.pid) {
                    let key = "\(spawned.pid)-\(Int(started.timeIntervalSince1970))"
                    let record = ManagedProcess(pid: spawned.pid, started: started, log: log)
                    managed[key] = record
                    _ = try? ManagedRegistry(directory: persistenceDirectory).update { $0[key] = record }
                }
                scanNow()
                // Clear the spinner if the server never binds its port, and say so.
                try? await Task.sleep(for: .seconds(45))
                // Still running but not listening. A launch that already exited has said why.
                if pending[pendingID] != nil, let launch = launches[spawned.pid], !launch.isUp {
                    pending[pendingID] = nil
                    show(Toast(message: "\(name) did not open a port. Check its log.", isError: true))
                    schedule()
                }
            } catch {
                pending[pendingID] = nil
                // A restart already stopped the server. Keep it in Recently Stopped so it can be started again.
                add(entry)
                show(Toast(message: error.localizedDescription, isError: true))
                schedule()
            }
        }
    }

    private func loadShellEnvironment() async -> [String] {
        if let shellEnvironment { return shellEnvironment }
        let task = shellEnvironmentTask ?? {
            let created = Task { await ShellEnvironment.load() }
            shellEnvironmentTask = created
            return created
        }()
        let loaded = await task.value
        shellEnvironment = loaded
        shellEnvironmentTask = nil
        return loaded
    }

    /// One log per project folder and port, so two projects with the same name do not share a file.
    /// Two servers on one port (IPv4 and IPv6) must not share a file, because opening it for
    /// the second would erase the first's output.
    private func freeLogURL(name: String, port: UInt16, directory: String) -> URL {
        let base = Self.logURL(name: name, port: port, directory: directory, in: logsDirectory)
        let inUse = Set(managed.values.filter { process in
            ProcessControl.isAlive(process.pid)
                && LibProc.startDate(process.pid).map { abs($0.timeIntervalSince(process.started)) < 0.001 } == true
        }.map(\.log))
        var log = base
        var n = 2
        while inUse.contains(log) {
            log = base.deletingPathExtension().appendingPathExtension("\(n)").appendingPathExtension("log")
            n += 1
        }
        return log
    }

    private static func logURL(name: String, port: UInt16, directory: String, in logsDirectory: URL) -> URL {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        var hash: UInt32 = 2_166_136_261  // FNV-1a, stable across launches unlike `hashValue`.
        for byte in directory.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return logsDirectory.appendingPathComponent("\(slug)-\(port)-\(String(hash, radix: 16)).log")
    }

    private func remember(_ server: Server, reason: StopReason) {
        guard let launch = server.launch else { return }
        let log = logURL(for: server)
        var reason = reason
        if reason == .exited, let code = exitCodes.removeValue(forKey: server.rootPid), Self.isCrash(code) {
            reason = .crashed(code: code)
            recordCrash(title: server.title, code: code)
        }
        guard Self.isWorthRemembering(reason: reason, lifetime: Date().timeIntervalSince(server.startDate), managed: log != nil) else { return }
        let recent = RecentServer(server, launch: launch, reason: reason, log: log)
        if log != nil, reason == .exited {
            recentPids[server.rootPid] = recent.id
            if recentPids.count > 32, let old = recentPids.keys.first(where: { $0 != server.rootPid }) { recentPids[old] = nil }
        }
        add(recent)
    }

    /// A server that ended on its own within seconds of starting was a test run or a one-off script, not one to start
    /// again. Without this, a test suite that opens a server per test fills Recently Stopped with copies on random ports.
    /// A server Vibe Kit started is always kept: its exit code may still arrive and mark it as crashed.
    static func isWorthRemembering(reason: StopReason, lifetime: TimeInterval, managed: Bool) -> Bool {
        managed || reason != .exited || lifetime >= 20
    }

    private func add(_ recent: RecentServer) {
        let launch = recent.launch
        recents.removeAll { $0.id == recent.id }
        recents.insert(recent, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        if let env = launch.environment { recentEnvironments[recent.id] = env }
        saveRecents()
    }

    /// A server Vibe Kit started has ended. Mark it crashed if it failed, now or once the scan notices it is gone.
    private func processExited(pid: Int32, code: Int32) {
        if let fd = stdinWriters.removeValue(forKey: pid) { close(fd) }
        let launch = launches.removeValue(forKey: pid)
        let recentID = recentPids.removeValue(forKey: pid)
        // It ended before its server came up, such as a syntax error on restart. Say so now, not after a timeout,
        // and keep it in the list so it can be started again.
        if let launch, !launch.isUp {
            if pending[launch.pendingID] != .stopping { pending[launch.pendingID] = nil }
            let crashed = Self.isCrash(code)
            add(launch.entry.stopped(crashed ? .crashed(code: code) : .exited, log: launch.log))
            let title = launch.entry.title
            if crashed { recordCrash(title: title, code: code) }
            show(Toast(message: crashed ? "\(title) exited with code \(code). Check its log." : "\(title) exited before it opened a port.",
                       isError: true))
            schedule()
            return
        }
        guard Self.isCrash(code) else { return }
        if let recentID, let index = recents.firstIndex(where: { $0.id == recentID }), recents[index].reason == .exited {
            recents[index].reason = .crashed(code: code)
            recordCrash(title: recents[index].title, code: code)
            saveRecents()
        } else if recentID == nil {
            exitCodes[pid] = code
            if exitCodes.count > 32, let old = exitCodes.keys.first(where: { $0 != pid }) { exitCodes[old] = nil }
        }
    }

    func recordCrash(title: String, code: Int32) {
        guard !isPanelOpen else { return }
        unreadCrashes += 1
        lastCrashNotice = (title, code)
    }

    /// Keeps the newest `maxCount` logs and drops files older than `maxAge` that are not referenced by `keep`.
    nonisolated static func pruneLogs(in directory: URL, keep: Set<URL>, maxCount: Int = 50,
                                      maxAge: TimeInterval = 30 * 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        let logs: [(url: URL, modified: Date)] = urls.compactMap { url in
            guard url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }

        let protected = Set(keep.map(\.standardizedFileURL))
        for (index, entry) in logs.enumerated() {
            if protected.contains(entry.url.standardizedFileURL) { continue }
            if index >= maxCount || now.timeIntervalSince(entry.modified) > maxAge {
                try? fm.removeItem(at: entry.url)
            }
        }
    }

    /// Exit codes that mean the server failed. Ctrl-C, hang-up and terminate signals are normal ways to stop.
    private static func isCrash(_ code: Int32) -> Bool {
        code != 0 && ![128 + SIGINT, 128 + SIGTERM, 128 + SIGHUP].contains(code)
    }

    func reveal(_ server: Server) {
        guard let dir = server.project?.root ?? server.directory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }

    func openInEditor(_ server: Server) {
        guard let dir = server.project?.root ?? server.directory else { return }
        guard let editor = ExternalApp.resolve(settings.editorID, in: ExternalApp.editors) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
            return
        }
        editor.open(dir)
    }

    func openInTerminal(_ server: Server) {
        guard let dir = server.directory ?? server.project?.root,
              let terminal = ExternalApp.resolve(settings.terminalID, in: ExternalApp.terminals) else { return }
        terminal.open(dir)
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(toast.isError ? 4 : 1.8))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    /// Shows fixed sample servers instead of scanning, for `--snapshot --demo` screenshots. Nothing is saved.
    func showDemo(servers: [Server], pages: [String: PageInfo], history: [String: [Double]], recents: [RecentServer]) {
        isDemo = true
        timer?.cancel()
        self.servers = servers
        self.pages = pages
        self.history = history
        self.recents = recents
        var owners: [UInt16: Set<String>] = [:]
        for server in servers {
            for binding in server.ports where binding.isWildcard || binding.isLocalhost {
                owners[binding.port, default: []].insert(server.id)
            }
        }
        sharedPorts = Set(owners.filter { $0.value.count > 1 }.keys)
        lanAddress = "192.168.1.24"
        hasScanned = true
    }

    // MARK: Persistence

    nonisolated static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VibeKit", isDirectory: true)
    }()

    nonisolated static let logsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VibeKit", isDirectory: true)

    private static func load<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to file: String) {
        guard !isDemo else { return }
        try? FileManager.default.createDirectory(at: persistenceDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: persistenceDirectory.appendingPathComponent(file), options: .atomic)
    }

    private func saveRecents() { save(recents, to: "recents.json") }
}
