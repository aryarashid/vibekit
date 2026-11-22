import AppKit

let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
func failCLI(_ error: Error, json: Bool = false) -> Never {
    let message = error.localizedDescription
    if json, let data = try? JSONSerialization.data(withJSONObject: ["error": message]) {
        FileHandle.standardOutput.write(data + Data([10]))
    } else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    exit((error as? CLIError)?.code ?? 1)
}

do {
    switch try CLIArguments.parse(arguments) {
    case .help: print(CLIArguments.usage)
    case .version: print("VibeKit \(CLIArguments.versionString)")
    case .mcp(let allowControl):
        Task.detached { await MCPServer(allowControl: allowControl).run(); exit(0) }
        dispatchMain()
    case .action(let action, let json):
        Task.detached {
            do {
                let output = try await ListCommand().run(action, format: json ? .json : .text)
                FileHandle.standardOutput.write(Data(output.text.utf8))
                exit(output.exitCode)
            } catch { failCLI(error, json: json) }
        }
        dispatchMain()
    case .toggle(let tab, let query):
        let running = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier == "dev.vibekit.VibeKit" || $0.executableURL?.lastPathComponent == "VibeKit")
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard running else { throw CLIError("Vibe Kit is not running. Open it first.") }
        var info: [String: String] = [:]
        info["tab"] = tab
        info["query"] = query
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.toggleNotification, object: nil, userInfo: info, deliverImmediately: true)
    case .bench(let seconds, let open): Bench.run(seconds: seconds, panelOpen: open)
    case .snapshot(let path): Snapshot.render(to: path)
    case .app:
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
} catch { failCLI(error, json: arguments.contains("--json")) }
