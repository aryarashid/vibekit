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
                // Everything already running at launch counts as old, so the first two minutes stay cheap.
                entry = Known(info: info, firstSeen: known[pid]?.firstSeen ?? (firstScan ? 0 : now), ports: known[pid]?.ports ?? [])
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
        for (pid, ports) in listeners {
            guard let process = inspect(pid) else { continue }
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
            var server = builtServer(unit, now: now)
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

    private func builtServer(_ unit: Unit, now: UInt64) -> Server {
        let listeners = unit.listeners.sorted { $0.0.pid < $1.0.pid }
        let key = BuildKey(start: unit.root.start, chain: unit.chain.map(\.pid),
                           listeners: listeners.map(\.0.pid), ports: listeners.flatMap(\.1))
        if let hit = built[unit.root.pid], hit.key == key, now &- hit.at < Self.rebuildInterval { return hit.server }
        let server = makeServer(unit)
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
        "dotnet", "gradle", "mvn", "foreman", "overmind",
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
            for arg in p.facts.argv.dropFirst().prefix(3) {
                let name = ((arg as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                if Self.jsRunnerScripts.contains(name) { return true }
                if arg.contains("/node_modules/") && arg.contains("/bin/") { return true }
            }
            return false
        }
        // Python autoreloaders (Django, Flask, uvicorn --reload) run the server as a python child.
        if isPython(p) {
            return isPython(child) && !p.facts.argv.contains("-c")
        }
        return false
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

    private func makeServer(_ unit: Unit) -> Server {
        let primary = unit.listeners.min { $0.0.pid < $1.0.pid }!.0
        let framework = unit.listeners.map { classify($0.0) }.first { $0.category != .other } ?? unit.framework
        let launch = framework.category == .other ? nil : launchSpec(for: unit.chain)
        let ports = orderedPorts(unit.listeners.flatMap(\.1), hints: unit.chain.flatMap(\.facts.argv))
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
            launch: launch
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

    /// Drops variables that only make sense inside the old process tree.
    static func cleaned(_ env: [String]) -> [String] {
        let drop: Set<String> = ["RUN_MAIN", "WERKZEUG_RUN_MAIN", "WERKZEUG_SERVER_FD", "NODE_CHANNEL_FD",
                                 "NODE_UNIQUE_ID", "TERM_SESSION_ID", "ITERM_SESSION_ID", "SHLVL", "_"]
        return env.filter { entry in
            guard let eq = entry.firstIndex(of: "=") else { return false }
            return !drop.contains(String(entry[..<eq]))
        }
    }

    /// One entry per port, the one named in argv first, then ascending.
    /// When a port is bound on several addresses, all interfaces wins, then localhost, so the URL reaches it.
    func orderedPorts(_ bindings: [PortBinding], hints: [String]) -> [PortBinding] {
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
        return byPort.values.sorted { a, b in
            if a.port == hinted { return true }
            if b.port == hinted { return false }
            return a.port < b.port
        }
    }
}
