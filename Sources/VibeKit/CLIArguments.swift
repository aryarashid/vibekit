import Foundation

struct CLIError: LocalizedError {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
    var errorDescription: String? { message }
}

/// The same operations back the command line and MCP. Formatting and exit codes belong to the caller.
enum ServerAction: Equatable {
    case list(all: Bool, cpu: Bool)
    case port(UInt16, next: Bool)
    case stop(String), restart(String), logs(String, tail: Int), prompts(String), probe(UInt16, host: String)
}

enum CLIArguments: Equatable {
    case app, help, version, mcp(allowControl: Bool)
    case toggle(tab: String?, query: String?), bench(seconds: Int, open: Bool), snapshot(String)
    case action(ServerAction, json: Bool)

    static let usage = """
    Usage: VibeKit [command]
      --list [--all] [--cpu] [--json]     List servers. --cpu samples for 300 ms.
      port <N> [--json]                  Check a port (exit 0 free, 1 taken). Alias: --port
      port --next <N> [--json]           Find a free port starting at N.
      stop|restart <target> [--json]     Match a port, PID, or project/title (exit 2 if ambiguous).
      logs <target> [--tail N]           Print the last N log lines (default 50).
      prompt [query] [--json]            List prompts, or print the best match's text.
      --toggle [servers|prompts] [--query <text>]
      --mcp [--allow-control]            Serve MCP on stdio. Control tools require the flag.
      --bench [seconds] [--open]         Benchmark the scanner.
      --snapshot <path> [options]        Render the panel to a PNG.
      --help, -h, --version
    """

    static func enclosingAppBundleURL(executableURL: URL? = nil) -> URL? {
        let raw = executableURL
            ?? Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let resolved = raw.standardizedFileURL.resolvingSymlinksInPath()
        let macOS = resolved.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    static func versionString(executableURL: URL? = nil) -> String {
        if executableURL == nil,
           let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        // Invoking via ~/.local/bin/vibekit symlink points Bundle.main at the symlink directory;
        // follow the symlink back to the enclosing .app bundle to read its Info.plist version.
        if let app = enclosingAppBundleURL(executableURL: executableURL),
           let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        // SwiftPM executables have no bundle Info.plist. Use the release file in this source checkout.
        let source = URL(fileURLWithPath: #filePath)
        let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "dev"
    }

    static var versionString: String { versionString(executableURL: nil) }

    static func parse(_ arguments: [String]) throws -> Self {
        guard let command = arguments.first else { return .app }
        var args = Array(arguments.dropFirst())
        func flag(_ name: String) -> Bool {
            guard let index = args.firstIndex(of: name) else { return false }
            args.remove(at: index)
            return true
        }
        func value(_ name: String) throws -> String? {
            guard let index = args.firstIndex(of: name) else { return nil }
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw CLIError("Missing value for \(name).", code: 2)
            }
            let result = args[index + 1]
            args.removeSubrange(index...index + 1)
            return result
        }
        func positional(_ label: String) throws -> String {
            guard let first = args.first, !first.hasPrefix("--"),
                  !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError("Expected \(label). See --help.", code: 2)
            }
            return args.removeFirst()
        }

        let parsed: Self
        switch command {
        case "--help", "-h": parsed = .help
        case "--version": parsed = .version
        case "--mcp": parsed = .mcp(allowControl: flag("--allow-control"))
        case "--toggle":
            let query = try value("--query")
            let tab = args.isEmpty ? nil : try positional("servers or prompts")
            guard tab == nil || tab == "servers" || tab == "prompts" else { throw CLIError("Expected servers or prompts.", code: 2) }
            parsed = .toggle(tab: tab, query: query)
        case "--bench":
            let open = flag("--open")
            let seconds = args.isEmpty ? 40 : Int(try positional("seconds"))
            parsed = .bench(seconds: seconds ?? 40, open: open)
        case "--snapshot": return .snapshot(try positional("an output path")) // Snapshot reads its own flags.
        case "--list":
            parsed = .action(.list(all: flag("--all"), cpu: flag("--cpu")), json: flag("--json"))
        case "port", "--port":
            let json = flag("--json"), next = flag("--next")
            guard let port = UInt16(try positional("a port")), port > 0 else { throw CLIError("Expected port 1–65535.", code: 2) }
            parsed = .action(.port(port, next: next), json: json)
        case "stop", "restart":
            let json = flag("--json"), target = try positional("a server target")
            parsed = .action(command == "stop" ? .stop(target) : .restart(target), json: json)
        case "logs":
            let count = try value("--tail") ?? "50"
            guard let tail = Int(count), tail >= 0 else { throw CLIError("Expected a nonnegative line count.", code: 2) }
            parsed = .action(.logs(try positional("a log target"), tail: tail), json: false)
        case "prompt":
            let json = flag("--json")
            var words: [String] = []
            while !args.isEmpty { words.append(try positional("a prompt query")) }
            parsed = .action(.prompts(words.joined(separator: " ")), json: json)
        default:
            // Finder and Xcode can supply Cocoa defaults when launching the GUI.
            if command.hasPrefix("-psn_") || command.hasPrefix("-NS") || command.hasPrefix("-Apple") { return .app }
            throw CLIError("Unknown command \(command). See --help.", code: 2)
        }
        guard args.isEmpty else { throw CLIError("Unexpected argument \(args[0]). See --help.", code: 2) }
        return parsed
    }
}
