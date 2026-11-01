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

    init(title: String, frameworkName: String, frameworkColor: UInt32?, port: UInt16, branch: String?, launch: LaunchSpec,
         stoppedAt: Date, reason: StopReason? = nil, log: URL? = nil) {
        self.title = title
        self.frameworkName = frameworkName
        self.frameworkColor = frameworkColor
        self.port = port
        self.branch = branch
        self.launch = launch
        self.stoppedAt = stoppedAt
        self.reason = reason
        self.log = log
    }

    init(_ server: Server, launch: LaunchSpec, reason: StopReason, log: URL?) {
        self.init(title: server.title, frameworkName: server.framework.name, frameworkColor: server.framework.color,
                  port: server.primaryPort, branch: server.project?.branch, launch: launch, stoppedAt: Date(), reason: reason, log: log)
    }

    /// The same server, stopped just now.
    func stopped(_ reason: StopReason, log: URL?) -> RecentServer {
        RecentServer(title: title, frameworkName: frameworkName, frameworkColor: frameworkColor, port: port, branch: branch,
                     launch: launch, stoppedAt: Date(), reason: reason, log: log)
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

    let settings: Settings
    /// Called when the number of running dev servers changes, for the menu bar count.
    var onCountChange: ((Int) -> Void)?

    var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            if isPanelOpen {
                lanAddress = Network.lanAddress()
                // Ask again, once, about servers that were failing or silent last time.
                staleProbes = Set(pages.filter { $0.value.status >= 500 }.keys).union(unanswered)
                retryAt.removeAll()
                scanNow(fullSweep: true)
            }
            schedule()
        }
    }

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.vibekit.scan", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var probing = Set<String>()
    @ObservationIgnored private var staleProbes = Set<String>()
    @ObservationIgnored private var probeAttempts: [String: Int] = [:]
    @ObservationIgnored private var retryAt: [String: Date] = [:]
    /// Exit codes of servers Vibe Kit started, by PID, kept until the scan notices they are gone.
    @ObservationIgnored private var exitCodes: [Int32: Int32] = [:]
    @ObservationIgnored private var managed: [String: ManagedProcess] = [:]
    @ObservationIgnored private var stdinWriters: [Int32: Int32] = [:]
    /// Environments of servers stopped this session. Memory only, never written to disk.
    @ObservationIgnored private var recentEnvironments: [String: [String]] = [:]
    @ObservationIgnored private var expectedSignatures: [String: String] = [:]
    @ObservationIgnored private var shellEnvironment: [String]?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastCount = -1
    /// Recently stopped servers that Vibe Kit started, by PID, until their exit code arrives.
    @ObservationIgnored private var recentPids: [Int32: String] = [:]
    /// Servers Vibe Kit started this session, by PID, until they exit.
    @ObservationIgnored private var launches: [Int32: (pendingID: String, entry: RecentServer, log: URL)] = [:]

    private static let historyLength = 36

    init(settings: Settings) {
        self.settings = settings
        recents = Self.load([RecentServer].self, from: "recents.json") ?? []
        managed = (Self.load([String: ManagedProcess].self, from: "managed.json") ?? [:]).filter { _, process in
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
    }

    private var scanCategories: Set<ServerCategory> {
        var categories: Set<ServerCategory> = [.dev, .database, .service]
        if isPanelOpen && settings.showOtherListeners { categories.insert(.other) }
        return categories
    }

    /// 1.5 s while the panel is open, 4 s with generous leeway while it is closed, so the system can batch wakeups.
    private func schedule() {
        timer?.cancel()
        let open = isPanelOpen || !pending.isEmpty
        let interval: DispatchTimeInterval = open ? .milliseconds(1500) : .seconds(4)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: open ? .milliseconds(150) : .seconds(1))
        timer.setEventHandler(handler: Self.scanJob(scanner, categories: scanCategories, fullSweep: false, store: self))
        timer.resume()
        self.timer = timer
    }

    func scanNow(fullSweep: Bool = false) {
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
        let sorted = scanned.sorted { a, b in
            let order: [ServerCategory] = [.dev, .database, .service, .other]
            if a.category != b.category { return order.firstIndex(of: a.category)! < order.firstIndex(of: b.category)! }
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
        let running = Set(sorted.compactMap { $0.launch?.signature })
        if recents.contains(where: { running.contains($0.id) }) {
            recents.removeAll { running.contains($0.id) }
            saveRecents()
        }

        // Clear pending work that has finished.
        let hadPending = !pending.isEmpty
        for (id, state) in pending {
            switch state {
            case .stopping:
                if !ids.contains(id) { pending[id] = nil }
            case .restarting, .starting:
                if let signature = expectedSignatures[id], running.contains(signature) {
                    pending[id] = nil
                    expectedSignatures[id] = nil
                }
            }
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

        // Ports where `localhost` could reach more than one server. Other listeners count: AirPlay holds 5000 and 7000.
        var owners: [UInt16: Set<String>] = [:]
        for server in sorted {
            for binding in server.ports where binding.isWildcard || binding.isLoopback {
                owners[binding.port, default: []].insert(server.id)
            }
        }
        let shared = Set(owners.filter { $0.value.count > 1 }.keys)
        if shared != sharedPorts { sharedPorts = shared }
        for (pid, fd) in stdinWriters where !sorted.contains(where: { $0.rootPid == pid }) && !ProcessControl.isAlive(pid) {
            close(fd)
            stdinWriters[pid] = nil
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
            && (pages[server.id] == nil || staleProbes.contains(server.id)) && !probing.contains(server.id)
            && (retryAt[server.id].map { $0 <= now } ?? true) {
            probing.insert(server.id)
            staleProbes.remove(server.id)
            let id = server.id
            let host = server.host
            let port = server.primaryPort
            Task {
                let page = await Probe.page(host: host, port: port)
                self.probing.remove(id)
                guard self.servers.contains(where: { $0.id == id }) else { return }
                if let page {
                    self.pages[id] = page
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
    }

    // MARK: Actions

    func open(_ server: Server) {
        guard let url = server.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String, label: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(Toast(message: "Copied \(label ?? text)"))
    }

    func copyURL(_ server: Server) {
        guard let url = server.localURL else { return }
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
            }
            scanNow()
        }
    }

    func forceQuit(_ server: Server) {
        pending[server.id] = .stopping
        ProcessControl.forceKill(root: server.rootPid, started: server.startDate)
        scanNow()
    }

    func stopAll() {
        for server in devServers { stop(server) }
    }

    func restart(_ server: Server) {
        guard let launch = server.launch, pending[server.id] == nil else { return }
        pending[server.id] = .restarting
        expectedSignatures[server.id] = launch.signature
        schedule()
        Task {
            let result = await ProcessControl.stop(root: server.rootPid, started: server.startDate)
            guard result != .failed else {
                pending[server.id] = nil
                show(Toast(message: "Could not stop \(server.title)", isError: true))
                return
            }
            // Give the kernel a moment to release the port.
            try? await Task.sleep(for: .milliseconds(250))
            launchServer(launch, environment: launch.environment, entry: RecentServer(server, launch: launch, reason: .stopped, log: nil),
                         pendingID: server.id)
        }
    }

    func start(_ recent: RecentServer) {
        guard pending[recent.id] == nil else { return }
        pending[recent.id] = .starting
        expectedSignatures[recent.id] = recent.launch.signature
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
        Task {
            var env = environment
            if env == nil {
                if shellEnvironment == nil { shellEnvironment = await ShellEnvironment.load() }
                env = shellEnvironment
            }
            let log = Self.logURL(name: name, port: entry.port, directory: spec.directory)
            do {
                let spawned = try ProcessControl.spawn(spec, environment: env ?? ShellEnvironment.fallback(), log: log) { pid, code in
                    Task { @MainActor in self.processExited(pid: pid, code: code) }
                }
                launches[spawned.pid] = (pendingID, entry, log)
                stdinWriters[spawned.pid] = spawned.stdinWriter
                if let started = LibProc.startDate(spawned.pid) {
                    managed["\(spawned.pid)-\(Int(started.timeIntervalSince1970))"] = ManagedProcess(pid: spawned.pid, started: started, log: log)
                    saveManaged()
                }
                scanNow()
                // Clear the spinner if the server never binds its port, and say so.
                try? await Task.sleep(for: .seconds(45))
                // Still running but not listening. A launch that already exited has said why.
                if pending[pendingID] != nil, launches[spawned.pid] != nil {
                    pending[pendingID] = nil
                    expectedSignatures[pendingID] = nil
                    show(Toast(message: "\(name) did not open a port. Check its log.", isError: true))
                    schedule()
                }
            } catch {
                pending[pendingID] = nil
                show(Toast(message: error.localizedDescription, isError: true))
                schedule()
            }
        }
    }

    /// One log per project folder and port, so two projects with the same name do not share a file.
    private static func logURL(name: String, port: UInt16, directory: String) -> URL {
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
        }
        let recent = RecentServer(server, launch: launch, reason: reason, log: log)
        if log != nil, reason == .exited {
            recentPids[server.rootPid] = recent.id
            if recentPids.count > 32 { recentPids.removeAll() }
        }
        add(recent)
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
        let launch = launches.removeValue(forKey: pid)
        let recentID = recentPids.removeValue(forKey: pid)
        guard Self.isCrash(code) else { return }
        // It failed before its server came up, such as a syntax error on restart. Say so now, not after a timeout.
        if let launch, let state = pending[launch.pendingID], state != .stopping {
            pending[launch.pendingID] = nil
            expectedSignatures[launch.pendingID] = nil
            add(launch.entry.stopped(.crashed(code: code), log: launch.log))
            show(Toast(message: "\(launch.entry.title) exited with code \(code). Check its log.", isError: true))
            schedule()
            return
        }
        if let recentID, let index = recents.firstIndex(where: { $0.id == recentID }), recents[index].reason == .exited {
            recents[index].reason = .crashed(code: code)
            saveRecents()
        } else if recentID == nil {
            exitCodes[pid] = code
            if exitCodes.count > 32 { exitCodes.removeAll() }
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
        timer?.cancel()
        self.servers = servers
        self.pages = pages
        self.history = history
        self.recents = recents
        lanAddress = "192.168.1.24"
        hasScanned = true
    }

    // MARK: Persistence

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VibeKit", isDirectory: true)
    }()

    static let logsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VibeKit", isDirectory: true)

    private static func load<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to file: String) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: supportDirectory.appendingPathComponent(file), options: .atomic)
    }

    private func saveRecents() { Self.save(recents, to: "recents.json") }
    private func saveManaged() { Self.save(managed, to: "managed.json") }
}
