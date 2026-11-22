import Darwin
import Foundation

/// Finds every TCP listener owned by the current user and groups them into servers.
/// Not thread safe: call it from one serial queue.
public final class PortScanner: @unchecked Sendable {
    public let classifier: Classifier
    private let ownPid = getpid()
    private var cache: [pid_t: Inspected] = [:]
    private var classified: [pid_t: (start: Date, framework: Framework)] = [:]
    private var cpuSamples: [pid_t: (cpu: UInt64, wall: UInt64)] = [:]
    private let sockets = LibProc.SocketLister()

    public init(classifier: Classifier = Classifier()) {
        self.classifier = classifier
    }

    private struct Known {
        var info: LibProc.ShortInfo
        let firstSeen: UInt64
        var ports: [PortBinding]
        /// Apps and tools are hidden by default, so their sockets only get rechecked on a sweep.
        var isOther = false
    }

    private var known: [pid_t: Known] = [:]
    /// Counters for `--bench`.
    public private(set) var stats = (pids: 0, socketChecks: 0, newPids: 0)
    private var lastSweep: UInt64 = 0
    /// New processes have their sockets checked on every scan for this long. Dev servers bind within seconds.
    private static let youngWindow: UInt64 = 120 * NSEC_PER_SEC
    /// Older processes are only rechecked on a periodic full sweep, which is what keeps idle scans cheap.
    private static let sweepInterval: UInt64 = 30 * NSEC_PER_SEC

    /// When a process already running at the first scan counts as first seen: its real start if that was within
    /// the young window, else long ago.
    private static func launchAge(_ pid: pid_t, now: UInt64) -> UInt64 {
        guard let start = LibProc.startDate(pid) else { return 0 }
        let age = Date().timeIntervalSince(start)
        guard age >= 0, age < Double(youngWindow) / Double(NSEC_PER_SEC) else { return 0 }
        return now &- UInt64(age * Double(NSEC_PER_SEC))
    }

    /// One pass over the process table.
    /// - Parameters:
    ///   - usageFor: categories whose process trees get CPU and memory totals.
    ///   - fullSweep: check every process's sockets now instead of only new ones and known listeners.
    public func scan(usageFor categories: Set<ServerCategory>, fullSweep: Bool = false) -> [Server] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let firstScan = known.isEmpty
        let sweep = fullSweep || firstScan || now &- lastSweep >= Self.sweepInterval
        if sweep { lastSweep = now }

        var next: [pid_t: Known] = [:]
        stats = (0, 0, 0)
        for pid in LibProc.userPids() where pid != ownPid {
            stats.pids += 1
            var entry: Known
            if let old = known[pid], !sweep {
                entry = old
            } else if let info = LibProc.shortInfo(pid) {
                if known[pid] == nil { stats.newPids += 1 }
                // Everything already running at launch counts as old, so the first two minutes stay cheap, except
                // processes started just before, such as a server still compiling when Vibe Kit opens at login.
                let firstSeen = known[pid]?.firstSeen ?? (firstScan ? Self.launchAge(pid, now: now) : now)
                entry = Known(info: info, firstSeen: firstSeen, ports: known[pid]?.ports ?? [])
            } else {
                continue
            }
            if sweep || now &- entry.firstSeen < Self.youngWindow || (!entry.ports.isEmpty && !entry.isOther) {
                entry.ports = sockets.listeningSockets(pid)
                stats.socketChecks += 1
            }
            next[pid] = entry
        }
        known = next

        let table = known.mapValues(\.info)
        var listeners: [pid_t: [PortBinding]] = [:]
        for (pid, entry) in known where !entry.ports.isEmpty { listeners[pid] = entry.ports }

        var children: [pid_t: [pid_t]] = [:]
        for info in table.values { children[info.ppid, default: []].append(info.pid) }

        // Forget processes that have exited.
        cache = cache.filter { table[$0.key] != nil }
        classified = classified.filter { table[$0.key] != nil }

        var units: [pid_t: Unit] = [:]
        // Deterministic order: a launch unit with several listeners keeps the same root chain and framework across scans.
        for pid in listeners.keys.sorted() {
            guard let ports = listeners[pid], let process = inspect(pid) else { continue }
            let framework = classify(process)
            known[pid]?.isOther = framework.category == .other
            let chain = framework.category == .other
                ? [process]
                : launchChain(from: process, table: table, children: children, listeners: listeners)
            let root = chain[0]
            if var unit = units[root.pid] {
                unit.listeners.append((process, ports))
                units[root.pid] = unit
            } else {
                units[root.pid] = Unit(root: root, chain: chain, framework: framework, listeners: [(process, ports)])
            }
        }

        let wallNow = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var seenForUsage = Set<pid_t>()
        var servers: [Server] = []
        for unit in units.values {
            var server = builtServer(unit, now: now, table: table)
            if categories.contains(server.category) {
                // An app's process tree can hold hundreds of helpers and terminals, so other listeners count only themselves.
                let tree = server.category == .other ? server.listenerPids : descendants(of: unit.root.pid, children: children)
                var cpu = 0.0
                var memory: UInt64 = 0
                for pid in tree {
                    seenForUsage.insert(pid)
                    guard let usage = LibProc.usage(pid) else { continue }
                    memory += usage.footprint
                    if let previous = cpuSamples[pid], wallNow > previous.wall, usage.cpuNanos >= previous.cpu {
                        cpu += Double(usage.cpuNanos - previous.cpu) / Double(wallNow - previous.wall) * 100
                    }
                    cpuSamples[pid] = (usage.cpuNanos, wallNow)
                }
                server.cpu = cpu
                server.memory = memory
                server.processCount = tree.count
            }
            servers.append(server)
        }
        if !categories.isEmpty {
            cpuSamples = cpuSamples.filter { seenForUsage.contains($0.key) }
        }
        built = built.filter { units[$0.key] != nil }
        return servers
    }

    private struct BuildKey: Equatable {
        let start: Date
        let chain: [pid_t]
        let listeners: [pid_t]
        let ports: [PortBinding]
    }

    /// Servers built on earlier scans. Building one formats command lines and reads git state, so it is reused
    /// while the unit's processes and ports stay the same. The age limit lets branch switches show up.
    private var built: [pid_t: (key: BuildKey, server: Server, at: UInt64)] = [:]
    private static let rebuildInterval: UInt64 = 12 * NSEC_PER_SEC

    private func builtServer(_ unit: Unit, now: UInt64, table: [pid_t: LibProc.ShortInfo]) -> Server {
        let listeners = unit.listeners.sorted { $0.0.pid < $1.0.pid }
        let key = BuildKey(start: unit.root.start, chain: unit.chain.map(\.pid),
                           listeners: listeners.map(\.0.pid), ports: listeners.flatMap(\.1))
        if let hit = built[unit.root.pid], hit.key == key, now &- hit.at < Self.rebuildInterval { return hit.server }
        let server = makeServer(unit, table: table)
        built[unit.root.pid] = (key, server, now)
        return server
    }

    /// PIDs of `root` and every process under it.
    public static func processTree(of root: pid_t) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for pid in LibProc.userPids() {
            if let info = LibProc.shortInfo(pid) { children[info.ppid, default: []].append(pid) }
        }
        return PortScanner().descendants(of: root, children: children)
    }

    private func descendants(of root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var result = [root]
        var index = 0
        while index < result.count {
            result.append(contentsOf: children[result[index]] ?? [])
            index += 1
        }
        return result
    }

    // MARK: Inspection

    struct Inspected {
        let pid: pid_t
        let ppid: pid_t
        let start: Date
        let facts: ProcessFacts
        let environment: [String]

        /// False when node or another runtime overwrote argv with a process title like "npm run dev".
        var argvIntact: Bool {
            guard let first = facts.argv.first else { return false }
            if facts.argv.count == 1 { return !first.contains(" ") }
            return !(first.contains(" ") && facts.argv.dropFirst().allSatisfy(\.isEmpty))
        }

        var title: String { facts.argv.filter { !$0.isEmpty }.joined(separator: " ") }
        var exeName: String { (facts.executable as NSString).lastPathComponent }
    }

    private func inspect(_ pid: pid_t) -> Inspected? {
        guard let start = LibProc.startDate(pid) else { return nil }
        if let cached = cache[pid], cached.start == start { return cached }
        guard let info = LibProc.shortInfo(pid) else { return nil }
        let args = LibProc.arguments(pid)
        let executable = LibProc.executablePath(pid) ?? args?.executable ?? info.comm
        let facts = ProcessFacts(pid: pid, comm: info.comm, executable: executable,
                                 argv: args?.argv ?? [info.comm], cwd: LibProc.currentDirectory(pid))
        let inspected = Inspected(pid: pid, ppid: info.ppid, start: start, facts: facts, environment: args?.environment ?? [])
        cache[pid] = inspected
        return inspected
    }

    private func classify(_ process: Inspected) -> Framework {
        if let hit = classified[process.pid], hit.start == process.start { return hit.framework }
        let framework = classifier.classify(process.facts)
        classified[process.pid] = (process.start, framework)
        return framework
    }

    // MARK: Launch units

    /// Walks up from a listener through the wrappers that launched it (`npm run dev`, `pnpm --filter`,
    /// a Django autoreloader) and stops at a shell, terminal, agent or anything that also runs another server.
    /// Returns the chain from the topmost wrapper down to the listener.
    private func launchChain(from listener: Inspected, table: [pid_t: LibProc.ShortInfo],
                             children: [pid_t: [pid_t]], listeners: [pid_t: [PortBinding]]) -> [Inspected] {
        var chain = [listener]
        var current = listener
        let listenerDir = listener.facts.cwd ?? ""
        let sockets = Set(listeners[listener.pid] ?? [])

        func runsAnotherServer(_ parent: pid_t, besides child: pid_t) -> Bool {
            for sibling in children[parent] ?? [] where sibling != child {
                for pid in descendants(of: sibling, children: children) {
                    // Workers that inherited the same listening socket (gunicorn, uvicorn --workers) are one server,
                    // even if one of them also opens a port of its own, such as metrics.
                    if let ports = listeners[pid], sockets.isDisjoint(with: ports) { return true }
                }
            }
            return false
        }

        while current.ppid > 1, table[current.ppid] != nil, chain.count < 8, let parent = inspect(current.ppid) {
            // Something that runs several servers (turbo, concurrently) is not part of this one.
            if runsAnotherServer(parent.pid, besides: current.pid) { break }
            // Vibe Kit started this process, so it is the top of the unit even if it is a shell.
            if parent.ppid == ownPid {
                chain.insert(parent, at: 0)
                break
            }
            // A prefork master holds the socket its workers inherited, so it is the top of the same server.
            if let ports = listeners[parent.pid], !sockets.isDisjoint(with: ports) {
                chain.insert(parent, at: 0)
                current = parent
                continue
            }
            let parentDir = parent.facts.cwd ?? "/"
            guard parentDir != "/", listenerDir == parentDir || listenerDir.hasPrefix(parentDir + "/") else { break }

            if isRunner(parent, child: current) {
                chain.insert(parent, at: 0)
                current = parent
                continue
            }
            // `sh -c "vite"` spawned by npm is transparent; a shell started by a person or an agent is not.
            if isScriptShell(parent), parent.ppid > 1, let grandparent = inspect(parent.ppid),
               isRunner(grandparent, child: parent), !runsAnotherServer(grandparent.pid, besides: parent.pid) {
                chain.insert(parent, at: 0)
                current = parent
                continue
            }
            break
        }
        // Never end the chain on a bare shell, unless Vibe Kit started it.
        while chain.count > 1, isScriptShell(chain[0]), chain[0].ppid != ownPid { chain.removeFirst() }
        return chain
    }

    private static let runnerNames: Set<String> = [
        "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx", "deno", "uv", "uvx", "poetry", "pipenv", "hatch",
        "bundle", "rake", "mix", "cargo", "cargo-watch", "go", "air", "make", "just", "nodemon", "watchexec",
        "dotnet", "gradle", "mvn",
    ]
    private static let jsRunnerScripts: Set<String> = [
        "npm", "npm-cli", "npx", "npx-cli", "pnpm", "pnpx", "yarn", "nodemon", "tsx", "ts-node-dev", "next",
        "nuxi", "nuxt", "astro", "wrangler", "vercel", "netlify", "expo", "react-scripts", "remix", "react-router",
        "nest", "storybook", "vite-node", "dotenv", "cross-env", "env-cmd",
    ]

    private func isRunner(_ p: Inspected, child: Inspected) -> Bool {
        let exe = p.exeName.lowercased()
        if Self.runnerNames.contains(exe) { return true }
        if exe == "node" || exe == "bun" {
            if !p.argvIntact {
                let first = p.facts.argv.first?.split(separator: " ").first.map(String.init) ?? ""
                return ["npm", "npx", "pnpm", "yarn", "next-server", "node"].contains(first)
            }
            // `node --watch server.js` restarts its child on every change, so Stop must take the watcher too.
            if Self.isWatchMode(p.facts.argv) { return true }
            for arg in p.facts.argv.dropFirst().prefix(3) {
                let name = ((arg as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                if Self.jsRunnerScripts.contains(name) { return true }
                if arg.contains("/node_modules/") && arg.contains("/bin/") { return true }
            }
            return false
        }
        // Python autoreloaders (Django, Flask, uvicorn --reload) run the server as a python child.
        // Any other Python parent, such as a supervisor script, is its own program: stopping the server must not stop it.
        if isPython(p) {
            guard isPython(child), !Classifier.runsInlinePython(p.facts.argv) else { return false }
            return Self.isPythonReloader(parent: p.facts.argv, child: child.facts.argv)
        }
        return false
    }

    /// True for `node --watch app.js`, `node --watch-path=src app.js` and `bun --watch run dev`. Only options
    /// before the script count: in `node app.js --watch` the flag belongs to the script.
    static func isWatchMode(_ argv: [String]) -> Bool {
        for arg in argv.dropFirst() {
            if arg == "--watch" || arg.hasPrefix("--watch=") || arg == "--watch-path" || arg.hasPrefix("--watch-path=") { return true }
            if arg == "run" { continue }  // `bun run --watch dev`
            if !arg.hasPrefix("-") { return false }
        }
        return false
    }

    /// Django and Flask reloaders run the same command again as a child. uvicorn and hypercorn `--reload` start the
    /// server through multiprocessing. Watchers such as watchfiles and hupper name themselves.
    static func isPythonReloader(parent: [String], child: [String]) -> Bool {
        let parentArgs = parent.dropFirst().filter { !$0.hasPrefix("-W") && !$0.hasPrefix("-X") }
        let childArgs = child.dropFirst().filter { !$0.hasPrefix("-W") && !$0.hasPrefix("-X") }
        if !parentArgs.isEmpty, parentArgs.elementsEqual(childArgs) { return true }
        // The spawn worker: `python -c "from multiprocessing.spawn import spawn_main; ..." --multiprocessing-fork`.
        if child.contains("--multiprocessing-fork") || child.contains(where: { $0.hasPrefix("from multiprocessing") }) { return true }
        let names = parent.dropFirst().map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
        return names.contains { ["--reload", "runserver", "watchfiles", "watchmedo", "hupper"].contains($0) }
    }

    private func isPython(_ p: Inspected) -> Bool {
        p.exeName.lowercased().hasPrefix("python") || p.facts.executable.contains("/Python.framework/")
    }

    private func isScriptShell(_ p: Inspected) -> Bool {
        ["sh", "bash", "zsh", "dash", "fish"].contains(p.exeName) && p.facts.argv.contains("-c")
    }

    // MARK: Server assembly

    private struct Unit {
        let root: Inspected
        let chain: [Inspected]
        let framework: Framework
        var listeners: [(Inspected, [PortBinding])]
    }

    private static let genericRuntimes: Set<String> = ["node", "bun", "deno", "python", "ruby", "php", "java", "dotnet"]

    private func makeServer(_ unit: Unit, table: [pid_t: LibProc.ShortInfo]) -> Server {
        let sortedListeners = unit.listeners.sorted { $0.0.pid < $1.0.pid }
        let primary = sortedListeners[0].0
        let frameworks = sortedListeners.map { classify($0.0) }
        // Prefer a named framework (Vite, Next.js) over a generic runtime (Node.js) when one unit holds several listeners.
        let framework = frameworks.first { $0.category != .other && !Self.genericRuntimes.contains($0.id) }
            ?? frameworks.first { $0.category != .other }
            ?? unit.framework
        // launchd brings back a database or service it manages (`brew services`) as soon as it stops, so starting
        // another copy on Restart would collide with it on the same port and data folder.
        let launchdManaged = Self.isLaunchdManaged(ppid: unit.root.ppid, environment: unit.root.environment)
            && (framework.category == .database || framework.category == .service)
        let launch = framework.category == .other || launchdManaged ? nil : launchSpec(for: unit.chain)
        let ports = Self.orderedPorts(sortedListeners.flatMap(\.1), hints: unit.chain.flatMap(\.facts.argv),
                                      preferred: framework.preferredPorts)
        let launcher = framework.category == .other ? nil : launcher(above: unit.root, table: table)
        let projectDir = classifier.projectDirectory(primary.facts, framework: framework)
        let project = projectDir.map(resolveProject)

        let command: String
        if let launch {
            command = launch.viaShell ? launch.displayCommand : CommandLine.friendly(launch.arguments, home: classifier.home)
        } else {
            command = primary.argvIntact ? CommandLine.friendly(primary.facts.argv, home: classifier.home) : primary.title
        }

        var name = classifier.displayName(primary.facts)
        if framework.category != .other, let detail = classifier.detail(primary.facts, framework: framework) {
            name = detail
        }

        return Server(
            id: "\(unit.root.pid)-\(Int(unit.root.start.timeIntervalSince1970))",
            pid: primary.pid,
            rootPid: unit.root.pid,
            listenerPids: unit.listeners.map(\.0.pid).sorted(),
            startDate: unit.root.start,
            ports: ports,
            framework: framework,
            project: project,
            processName: name,
            executable: primary.facts.executable,
            command: command,
            directory: projectDir ?? primary.facts.cwd,
            launch: launch,
            launcher: launcher
        )
    }

    private var projects: [String: (project: Project, at: UInt64)] = [:]
    private static let projectLifetime: UInt64 = 5 * NSEC_PER_SEC

    /// Git branches change, so cached projects expire after a few seconds.
    private func resolveProject(_ directory: String) -> Project {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let hit = projects[directory], now &- hit.at < Self.projectLifetime { return hit.project }
        let project = ProjectResolver.resolve(directory, home: classifier.home)
        projects[directory] = (project, now)
        if projects.count > 64 { projects = projects.filter { now &- $0.value.at < Self.projectLifetime } }
        return project
    }

    /// The process to run again on restart: the topmost one in the chain whose argv is still exact.
    private func launchSpec(for chain: [Inspected]) -> LaunchSpec? {
        if let exact = chain.first(where: \.argvIntact), let dir = exact.facts.cwd {
            return LaunchSpec(executable: exact.facts.executable, arguments: exact.facts.argv, directory: dir,
                              viaShell: false, environment: Self.cleaned(exact.environment))
        }
        // Node rewrote argv into a title such as "npm run dev". Replay it through a shell only when it reads as a command.
        guard let root = chain.first, let dir = root.facts.cwd, Self.isReplayableTitle(root.title) else { return nil }
        return LaunchSpec(executable: "/bin/sh", arguments: [root.title], directory: dir,
                          viaShell: true, environment: Self.cleaned(root.environment))
    }

    /// A title such as "pnpm run dev" can be run again through `sh -c`. One such as "next-server (v15.1.0)"
    /// is not a command, and nothing with characters the shell treats specially is run.
    static func isReplayableTitle(_ title: String) -> Bool {
        let runners: Set<String> = ["npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx", "node", "deno"]
        guard let first = title.split(separator: " ").first, runners.contains(String(first)) else { return false }
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-./:=@%+,"))
        return title.unicodeScalars.allSatisfy(plain.contains)
    }

    /// Drops variables that only make sense inside the old process tree. An environment without PATH was not
    /// readable (macOS hides some), so the restart falls back to the login shell's instead of running with none.
    static func cleaned(_ env: [String]) -> [String]? {
        guard env.contains(where: { $0.hasPrefix("PATH=") }) else { return nil }
        let drop: Set<String> = ["RUN_MAIN", "WERKZEUG_RUN_MAIN", "WERKZEUG_SERVER_FD", "NODE_CHANNEL_FD",
                                 "NODE_UNIQUE_ID", "TERM_SESSION_ID", "ITERM_SESSION_ID", "SHLVL", "_",
                                 "VIBEKIT_MANAGED"]
        return env.filter { entry in
            guard let eq = entry.firstIndex(of: "=") else { return false }
            return !drop.contains(String(entry[..<eq]))
        }
    }

    /// One entry per port: the one named in argv first, then the framework's web UI ports in its order, then ascending.
    /// When a port is bound on several addresses, all interfaces wins, then localhost, so the URL reaches it.
    static func orderedPorts(_ bindings: [PortBinding], hints: [String], preferred: [UInt16] = []) -> [PortBinding] {
        func reach(_ binding: PortBinding) -> Int {
            binding.isWildcard ? (binding.acceptsIPv4 ? 4 : 3) : binding.isLocalhost ? 2 : binding.isLoopback ? 1 : 0
        }
        var byPort: [UInt16: PortBinding] = [:]
        for binding in bindings {
            if let existing = byPort[binding.port], reach(existing) >= reach(binding) { continue }
            byPort[binding.port] = binding
        }
        var hinted: UInt16?
        for (i, arg) in hints.enumerated() {
            var value: String?
            if ["--port", "-p", "--http-port", "--listen"].contains(arg), i + 1 < hints.count { value = hints[i + 1] }
            else if arg.hasPrefix("--port=") { value = String(arg.dropFirst(7)) }
            if let value, let port = UInt16(value.split(separator: ":").last ?? ""), byPort[port] != nil {
                hinted = port
                break
            }
        }
        func rank(_ port: UInt16) -> (Int, Int, UInt16) {
            (port == hinted ? 0 : 1, preferred.firstIndex(of: port) ?? preferred.count, port)
        }
        return byPort.values.sorted { rank($0.port) < rank($1.port) }
    }

    func orderedPorts(_ bindings: [PortBinding], hints: [String], preferred: [UInt16] = []) -> [PortBinding] {
        Self.orderedPorts(bindings, hints: hints, preferred: preferred)
    }

    // MARK: Launcher

    /// One process above a launch unit, as `identifyLauncher` sees it.
    public struct Ancestor: Sendable, Hashable {
        public let pid: pid_t
        public let executable: String
        public let argv: [String]

        public init(pid: pid_t, executable: String, argv: [String]) {
            self.pid = pid
            self.executable = executable
            self.argv = argv
        }
    }

    /// Up to this many processes above the unit are checked, not counting shells and `login`.
    private static let launcherHops = 4

    /// True when `launchd` itself supervises this process (such as a `brew services` LaunchAgent), rather than an
    /// orphaned process reparented to PID 1 (such as a detached `vibekit restart` or closed terminal tab).
    static func isLaunchdManaged(ppid: pid_t, environment: [String]) -> Bool {
        guard ppid == 1 else { return false }
        if environment.contains("VIBEKIT_MANAGED=1") { return false }
        guard !environment.isEmpty else { return true }
        if let xpc = environment.first(where: { $0.hasPrefix("XPC_SERVICE_NAME=") }) {
            let value = xpc.dropFirst("XPC_SERVICE_NAME=".count)
            // LaunchServices tags GUI apps with `application.<bundle-id>.*`, which their detached children inherit.
            return !value.isEmpty && value != "0" && !value.hasPrefix("application.")
        }
        return !environment.contains { $0.hasPrefix("TERM_PROGRAM=") || $0.hasPrefix("SSH_TTY=") || $0.hasPrefix("SHELL=") }
    }

    /// The processes above `root`, nearest first, ending at Vibe Kit, launchd or the hop limit.
    private func launcher(above root: Inspected, table: [pid_t: LibProc.ShortInfo]) -> String? {
        if root.environment.contains("VIBEKIT_MANAGED=1") { return "Vibe Kit" }
        var ancestors: [Ancestor] = []
        var pid = root.ppid
        var hops = 0
        // The table holds only this user's processes and leaves out Vibe Kit, so a root-owned `login` between a
        // terminal and its shell is read directly.
        while ancestors.count < 12 {
            if pid <= 1 {
                if ancestors.isEmpty && !Self.isLaunchdManaged(ppid: 1, environment: root.environment) { break }
                ancestors.append(Ancestor(pid: 1, executable: "/sbin/launchd", argv: ["launchd"]))
                break
            }
            if pid == ownPid {
                ancestors.append(Ancestor(pid: pid, executable: "", argv: []))
                break
            }
            let next: pid_t
            if let process = inspect(pid) {
                ancestors.append(Ancestor(pid: pid, executable: process.facts.executable, argv: process.facts.argv))
                next = process.ppid
            } else if let info = table[pid] ?? LibProc.shortInfo(pid) {
                ancestors.append(Ancestor(pid: pid, executable: LibProc.executablePath(pid) ?? info.comm, argv: [info.comm]))
                next = info.ppid
            } else {
                break
            }
            if !Self.isPassThrough(ancestors[ancestors.count - 1]) {
                hops += 1
                if hops >= Self.launcherHops { break }
            }
            pid = next
        }
        return Self.identifyLauncher(ancestors: ancestors, ownPid: ownPid)
    }

    private static let passThroughNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "login", "env", "sudo", "nohup"]

    /// Shells and `login` sit between every terminal and the command typed into it, so they never name a launcher.
    private static func isPassThrough(_ ancestor: Ancestor) -> Bool {
        let name = ((ancestor.executable as NSString).lastPathComponent).lowercased()
        let arg0 = ((ancestor.argv.first ?? "") as NSString).lastPathComponent.lowercased()
        return passThroughNames.contains(name) || passThroughNames.contains(arg0.trimmingCharacters(in: CharacterSet(charactersIn: "-")))
    }

    /// Names the agent, editor or terminal behind a server from the processes above it, nearest first.
    /// The nearest one that is recognised wins, so `claude` inside Ghostty is Claude Code. Shells are skipped.
    /// launchd counts only when it started the server directly. Failing all of these, the nearest app bundle's name.
    public static func identifyLauncher(ancestors: [Ancestor], ownPid: pid_t = getpid()) -> String? {
        var fallback: String?
        var sawProcess = false
        for (index, ancestor) in ancestors.enumerated() where index < 12 {
            if ancestor.pid == ownPid { return "Vibe Kit" }
            if ancestor.pid == 1 { return sawProcess ? fallback : "launchd" }
            if isPassThrough(ancestor) { continue }
            if let name = knownLauncher(ancestor) { return name }
            sawProcess = true
            if fallback == nil { fallback = appBundleName(ancestor.executable) }
        }
        return fallback
    }

    private static func knownLauncher(_ ancestor: Ancestor) -> String? {
        let path = ancestor.executable
        let exe = (path as NSString).lastPathComponent.lowercased()
        let arg0 = ((ancestor.argv.first ?? "") as NSString).lastPathComponent.lowercased()
        // A node CLI such as Codex runs as `node …/bin/codex.js`; its script is the second argument.
        let script = ancestor.argv.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? ""
        let scriptName = ((script as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let names: Set<String> = [exe, arg0, scriptName]

        // The native installer links `claude` to a binary named after its version, such as `versions/2.1.3`.
        if names.contains("claude") || path.contains("/claude/versions/") || path.contains("/@anthropic-ai/claude-code/")
            || script.contains("/@anthropic-ai/claude-code/") { return "Claude Code" }
        if names.contains("codex") || path.contains("/@openai/codex/") || script.contains("/@openai/codex/") { return "Codex" }
        if path.contains("/Cursor.app/") || names.contains("cursor-agent") { return "Cursor" }
        if path.contains("/Antigravity.app/") || names.contains("antigravity") { return "Antigravity" }
        if path.contains("/Visual Studio Code.app/") || path.contains("/Visual Studio Code - Insiders.app/") { return "VS Code" }
        if path.contains("/Zed.app/") || path.contains("/Zed Preview.app/") { return "Zed" }
        if path.contains("/Ghostty.app/") || names.contains("ghostty") { return "Ghostty" }
        if path.contains("/Warp.app/") || path.contains("/WarpPreview.app/") { return "Warp" }
        if path.contains("/iTerm.app/") || path.contains("/iTerm2.app/") { return "iTerm" }
        if path.contains("/Terminal.app/") { return "Terminal" }
        if path.contains("/kitty.app/") || names.contains("kitty") { return "kitty" }
        if path.contains("/WezTerm.app/") || names.contains("wezterm-gui") || names.contains("wezterm") { return "WezTerm" }
        if path.contains("/Alacritty.app/") || names.contains("alacritty") { return "Alacritty" }
        if names.contains("tmux") || arg0.hasPrefix("tmux") { return "tmux" }
        return nil
    }

    /// The outermost app bundle's name, such as `T3 Code` for a helper inside it.
    private static func appBundleName(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = path[..<range.lowerBound]
        guard let slash = bundle.lastIndex(of: "/") else { return nil }
        let name = String(bundle[bundle.index(after: slash)...])
        return name.isEmpty ? nil : name
    }
}
