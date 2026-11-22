import Darwin
import Foundation

public struct PortBinding: Hashable, Sendable, Codable {
    public let port: UInt16
    public let address: String
    public let isIPv6: Bool
    /// False for an IPv6 socket with `IPV6_V6ONLY`. A dual-stack `::` listener also takes IPv4.
    public let acceptsIPv4: Bool

    public init(port: UInt16, address: String, isIPv6: Bool, acceptsIPv4: Bool? = nil) {
        self.port = port
        self.address = address
        self.isIPv6 = isIPv6
        self.acceptsIPv4 = acceptsIPv4 ?? !isIPv6
    }

    /// Bound to every interface, so other devices on the network can reach it.
    public var isWildcard: Bool { address == "0.0.0.0" || address == "::" || address == "*" }
    public var isLoopback: Bool { address.hasPrefix("127.") || address == "::1" }
    /// Reached by `localhost`. A loopback alias such as 127.0.0.2 is not.
    public var isLocalhost: Bool { address == "127.0.0.1" || address == "::1" }
}

public enum ServerCategory: String, Sendable, Codable, CaseIterable {
    case dev, database, service, other

    public var title: String {
        switch self {
        case .dev: "Dev Servers"
        case .database: "Databases"
        case .service: "Services"
        case .other: "Other Listeners"
        }
    }

    /// Display order in both the menu panel and `--list`.
    public var sortOrder: Int {
        switch self {
        case .dev: 0
        case .database: 1
        case .service: 2
        case .other: 3
        }
    }
}

public struct Project: Hashable, Sendable {
    /// Repository name (the main checkout's name for linked worktrees), or the folder name.
    public let name: String
    /// Repository root, or the folder itself when there is no repository.
    public let root: String
    /// Path from the repository root to the working directory, such as `apps/web`.
    public let subpath: String?
    public let branch: String?
    /// Linked worktree folder name, when the server runs from one.
    public let worktree: String?

    /// The folder the server runs from: the root plus the subpath. Two checkouts with the same name differ here.
    public var folder: String { subpath.map { (root as NSString).appendingPathComponent($0) } ?? root }

    /// Concise name for a linked worktree, stripping `<project>-` (or `_` / `.`) when present.
    public var worktreeSlug: String? {
        guard let worktree, !worktree.isEmpty else { return nil }
        let lower = worktree.lowercased()
        let prefix = name.lowercased()
        for separator in ["-", "_", "."] {
            let full = prefix + separator
            if lower.hasPrefix(full), worktree.count > full.count {
                return String(worktree.dropFirst(full.count))
            }
        }
        return worktree
    }

    public init(name: String, root: String, subpath: String?, branch: String?, worktree: String?) {
        self.name = name
        self.root = root
        self.subpath = subpath
        self.branch = branch
        self.worktree = worktree
    }
}

/// Everything needed to run a server again.
/// The environment lives in memory only and is never written to disk.
public struct LaunchSpec: Hashable, Sendable, Codable {
    public let executable: String
    public let arguments: [String]
    public let directory: String
    /// Run as `sh -c "exec <command>"` because the original argv was overwritten by a process title.
    public let viaShell: Bool
    public var environment: [String]?

    public init(executable: String, arguments: [String], directory: String, viaShell: Bool, environment: [String]?) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.viaShell = viaShell
        self.environment = environment
    }

    enum CodingKeys: String, CodingKey { case executable, arguments, directory, viaShell }

    /// The command as a person would type it.
    public var displayCommand: String {
        if viaShell { return arguments.joined(separator: " ") }
        return CommandLine.display(arguments)
    }

    /// Identity used to match a stopped server with a running one.
    public var signature: String { directory + "\u{0}" + displayCommand }
}

/// One running server: a launch unit (for example `npm run dev` plus its node child)
/// with every port its processes listen on.
public struct Server: Identifiable, Hashable, Sendable {
    public let id: String
    /// The process that holds the listening socket (the lowest PID if several do).
    public let pid: pid_t
    /// Top of the launch unit. Stopping kills this process and everything under it.
    public let rootPid: pid_t
    public let listenerPids: [pid_t]
    public let startDate: Date
    public let ports: [PortBinding]
    public let framework: Framework
    public let project: Project?
    public let processName: String
    public let executable: String
    public let command: String
    public let directory: String?
    public let launch: LaunchSpec?
    /// The app or agent that started this server, such as `Claude Code`, `Ghostty` or `launchd`, when one is known.
    public let launcher: String?
    /// Set for a published port of a Docker or OrbStack container. `pid` and `rootPid` then belong to the
    /// container runtime on this Mac, so stopping them would stop every container: the app must not offer Stop.
    public let containerName: String?
    /// Host ports mapped to a container's web UI ports (such as RabbitMQ 15672 published as 25672).
    public let webUIPorts: Set<UInt16>
    public var cpu: Double = 0
    public var memory: UInt64 = 0
    public var processCount: Int = 1

    public init(
        id: String, pid: pid_t, rootPid: pid_t, listenerPids: [pid_t], startDate: Date,
        ports: [PortBinding], framework: Framework, project: Project?, processName: String,
        executable: String, command: String, directory: String?, launch: LaunchSpec?,
        launcher: String? = nil, containerName: String? = nil, webUIPorts: Set<UInt16> = []
    ) {
        self.id = id
        self.pid = pid
        self.rootPid = rootPid
        self.listenerPids = listenerPids
        self.startDate = startDate
        self.ports = ports
        self.framework = framework
        self.project = project
        self.processName = processName
        self.executable = executable
        self.command = command
        self.directory = directory
        self.launch = launch
        self.launcher = launcher
        self.containerName = containerName
        self.webUIPorts = webUIPorts
    }

    /// The same server with other ports, keeping its usage figures.
    public func replacingPorts(_ ports: [PortBinding]) -> Server {
        var copy = Server(id: id, pid: pid, rootPid: rootPid, listenerPids: listenerPids, startDate: startDate, ports: ports,
                          framework: framework, project: project, processName: processName, executable: executable,
                          command: command, directory: directory, launch: launch, launcher: launcher,
                          containerName: containerName, webUIPorts: webUIPorts)
        copy.cpu = cpu
        copy.memory = memory
        copy.processCount = processCount
        return copy
    }

    /// True for unpacked containers and raw Docker/OrbStack runtime listeners, where stopping or restarting
    /// `rootPid` would take down every running container.
    public var isContainerControlled: Bool {
        containerName != nil || framework.id == Framework.docker.id || framework.id == Framework.orbstack.id
    }

    /// Ports where `localhost` could reach more than one server (for example IPv4 and IPv6 listeners on the same port).
    public static func sharedPorts(in servers: [Server]) -> Set<UInt16> {
        var owners: [UInt16: Set<String>] = [:]
        for server in servers {
            for binding in server.ports where binding.isWildcard || binding.isLocalhost {
                owners[binding.port, default: []].insert(server.id)
            }
        }
        return Set(owners.filter { $0.value.count > 1 }.keys)
    }

    public var category: ServerCategory { framework.category }

    /// Whether this server runs from the project folder `folder` and listens on `port`.
    public func holds(port: UInt16, inFolder folder: String) -> Bool {
        project?.folder == folder && ports.contains { $0.port == port }
    }

    /// The port people mean when they talk about this server.
    public var primaryPort: UInt16 { ports.first?.port ?? 0 }

    public var isExposed: Bool { ports.contains { $0.isWildcard } }

    /// Dev servers are named by project, databases by their data folder, apps by their app name.
    public var title: String {
        switch category {
        case .dev: project?.name ?? framework.name
        case .database, .service:
            if let detail, detail.hasPrefix("/") || detail.hasPrefix("~") {
                (detail as NSString).lastPathComponent
            } else if let containerName, framework.id == Framework.docker.id || framework.id == Framework.orbstack.id {
                // A container with no recognised image, such as Supabase Studio, reads better by its own name than as "Docker".
                containerName
            } else {
                framework.name
            }
        case .other: processName
        }
    }

    /// Where a database or service lives: its data folder, or how it was installed.
    public var detail: String? {
        guard category == .database || category == .service, processName != framework.name else { return nil }
        let raw = (executable as NSString).lastPathComponent
        return processName == raw ? nil : processName
    }

    /// The exact command to paste into a terminal. `command` is shortened for reading, such as `vite` for
    /// `node node_modules/.bin/vite`, which may not be on PATH.
    public var copyableCommand: String { launch?.displayCommand ?? command }

    /// Stable key for per-server HTTP check preferences.
    public var httpCheckKey: String { launch?.signature ?? "\(directory ?? processName):\(primaryPort)" }

    /// How this Mac reaches `binding`. `localhost` covers loopback and all-interfaces listeners. With
    /// `explicitLoopback`, those name the address family instead (`127.0.0.1` or `[::1]`), for when two processes
    /// hold the same port on IPv4 and IPv6 and `localhost` would reach whichever the system tries first.
    public func host(for binding: PortBinding, explicitLoopback: Bool = false) -> String {
        if binding.isWildcard || binding.isLocalhost {
            guard explicitLoopback else { return "localhost" }
            return binding.isIPv6 && !(binding.isWildcard && binding.acceptsIPv4) ? "[::1]" : "127.0.0.1"
        }
        let address = binding.address.replacingOccurrences(of: "%", with: "%25")
        return binding.isIPv6 ? "[\(address)]" : address
    }

    /// How this Mac reaches the primary port: `localhost`, unless the server listens on one other address only.
    public var host: String {
        guard let binding = ports.first else { return "localhost" }
        return host(for: binding)
    }

    public var localURL: URL? { localURL(secure: false) }

    /// `secure` when the server answered over HTTPS only, such as Vite with a local certificate.
    public func localURL(secure: Bool) -> URL? {
        if let binding = ports.first {
            return localURL(for: binding, secure: secure)
        }
        return localURL(for: primaryPort, secure: secure)
    }

    private func isWebUIPort(_ port: UInt16) -> Bool {
        containerName != nil ? webUIPorts.contains(port) : framework.preferredPorts.contains(port)
    }

    /// Local URL for a specific port binding on this server. A port in `framework.preferredPorts` (or its remapped
    /// host port on a container) is a web UI and gets `http://`, even on a tool whose other ports take a connection string.
    public func localURL(for binding: PortBinding, secure: Bool = false, explicitLoopback: Bool = false) -> URL? {
        let host = host(for: binding, explicitLoopback: explicitLoopback)
        let webUI = isWebUIPort(binding.port)
        if let scheme = framework.urlScheme, !webUI {
            return URL(string: "\(scheme)://\(host):\(binding.port)")
        }
        guard framework.speaksHTTP || webUI else { return nil }
        return URL(string: "\(secure ? "https" : "http")://\(host):\(binding.port)")
    }

    /// The URL for one of this server's ports, for a clickable pill per port.
    public func localURL(for port: UInt16, secure: Bool = false, explicitLoopback: Bool = false) -> URL? {
        if let binding = ports.first(where: { $0.port == port }) {
            return localURL(for: binding, secure: secure, explicitLoopback: explicitLoopback)
        }
        let webUI = isWebUIPort(port)
        if let scheme = framework.urlScheme, !webUI {
            return URL(string: "\(scheme)://localhost:\(port)")
        }
        guard framework.speaksHTTP || webUI else { return nil }
        return URL(string: "\(secure ? "https" : "http")://localhost:\(port)")
    }

    /// A dev server, admin UI or app page worth opening in a browser. Connection strings and plain listeners are not.
    public var canOpenInBrowser: Bool {
        guard category != .other else { return false }
        if isWebUIPort(primaryPort) { return true }
        return framework.speaksHTTP && framework.urlScheme == nil
    }

    /// Whether clicking this server opens a web browser (dev servers and HTTP services/databases without a custom scheme).
    public var opensInBrowser: Bool { canOpenInBrowser }

    /// False once the folder the server ran from was deleted, such as a removed worktree. True when there is none.
    public var directoryExists: Bool { directory.map { FileManager.default.fileExists(atPath: $0) } ?? true }
    /// The URL for another device: the primary port if it is open to the network, else the first port that is.
    /// `host` is an IPv4 address, so an IPv6-only listener gets none.
    public func networkURL(host: String?, secure: Bool = false) -> URL? {
        guard framework.speaksHTTP, let host, let exposed = ports.first(where: { $0.isWildcard && $0.acceptsIPv4 }) else { return nil }
        return URL(string: "\(secure ? "https" : "http")://\(host):\(exposed.port)")
    }
}

public enum CommandLine {
    /// Joins argv for display, quoting arguments the shell would change, so a copied command runs the same argv.
    public static func display(_ argv: [String]) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,~"))
        return argv.map { arg in
            if arg.isEmpty { return "''" }
            if arg.unicodeScalars.contains(where: { !plain.contains($0) }) {
                return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return arg
        }.joined(separator: " ")
    }

    /// argv with absolute paths shortened to what a person would type (`node_modules/.bin/vite` becomes `vite`).
    public static func friendly(_ argv: [String], home: String = NSHomeDirectory()) -> String {
        var args = argv
        if let first = args.first {
            args[0] = (first as NSString).lastPathComponent
        }
        for i in args.indices.dropFirst() {
            let arg = args[i]
            if arg.contains("/node_modules/.bin/") || arg.hasSuffix("/bin/npm") || arg.hasSuffix("/bin/npx")
                || arg.hasSuffix("/bin/pnpm") || arg.hasSuffix("/bin/yarn") {
                args[i] = (arg as NSString).lastPathComponent
            } else if arg.hasPrefix(home + "/") {
                args[i] = "~" + arg.dropFirst(home.count)
            }
        }
        // `node vite --port 3000` reads better as `vite --port 3000`.
        if args.count > 1, ["node", "bun", "deno"].contains(args[0]), !args[1].hasPrefix("-"),
           !args[1].contains("/"), !args[1].hasSuffix(".js"), !args[1].hasSuffix(".mjs"), !args[1].hasSuffix(".ts") {
            args.removeFirst()
        }
        return display(args)
    }
}
