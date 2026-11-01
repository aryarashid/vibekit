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
    public var cpu: Double = 0
    public var memory: UInt64 = 0
    public var processCount: Int = 1

    public init(
        id: String, pid: pid_t, rootPid: pid_t, listenerPids: [pid_t], startDate: Date,
        ports: [PortBinding], framework: Framework, project: Project?, processName: String,
        executable: String, command: String, directory: String?, launch: LaunchSpec?
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
    }

    public var category: ServerCategory { framework.category }

    /// The port people mean when they talk about this server.
    public var primaryPort: UInt16 { ports.first?.port ?? 0 }

    public var isExposed: Bool { ports.contains { $0.isWildcard } }

    /// Dev servers are named by project, databases by their data folder, apps by their app name.
    public var title: String {
        switch category {
        case .dev: project?.name ?? framework.name
        case .database, .service:
            if let detail, detail.hasPrefix("/") || detail.hasPrefix("~") { (detail as NSString).lastPathComponent } else { framework.name }
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

    /// How this Mac reaches the primary port: `localhost`, unless the server listens on one other address only.
    public var host: String {
        guard let binding = ports.first, !binding.isWildcard, !binding.isLocalhost else { return "localhost" }
        let address = binding.address.replacingOccurrences(of: "%", with: "%25")
        return binding.isIPv6 ? "[\(address)]" : address
    }

    public var localURL: URL? {
        if let scheme = framework.urlScheme {
            return URL(string: "\(scheme)://\(host):\(primaryPort)")
        }
        guard framework.speaksHTTP else { return nil }
        return URL(string: "http://\(host):\(primaryPort)")
    }

    /// The URL for another device: the primary port if it is open to the network, else the first port that is.
    /// `host` is an IPv4 address, so an IPv6-only listener gets none.
    public func networkURL(host: String?) -> URL? {
        guard framework.speaksHTTP, let host, let exposed = ports.first(where: { $0.isWildcard && $0.acceptsIPv4 }) else { return nil }
        return URL(string: "http://\(host):\(exposed.port)")
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
