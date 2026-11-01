import Foundation
import VibeKitCore

/// Sample servers for `--snapshot --demo`, so README screenshots show no one's real projects.
@MainActor
enum DemoData {
    static func load(into store: ServerStore) {
        let home = NSHomeDirectory()
        let now = Date()
        var servers: [Server] = []
        var pages: [String: PageInfo] = [:]
        var history: [String: [Double]] = [:]

        func add(_ id: String, port: UInt16, address: String = "127.0.0.1", framework: Framework, project: String?,
                 subpath: String? = nil, branch: String? = "main", worktree: String? = nil, name: String? = nil,
                 command: String, age: TimeInterval, cpu: Double, memoryMB: UInt64, processes: Int = 2,
                 page: PageInfo? = nil, trace: [Double]) {
            let root = project.map { "\(home)/code/\($0)" }
            let directory = root.map { root in subpath.map { "\(root)/\($0)" } ?? root }
            let launch = directory.map {
                LaunchSpec(executable: "/opt/homebrew/bin/npm", arguments: ["npm", "run", "dev"], directory: $0,
                           viaShell: false, environment: nil)
            }
            var server = Server(
                id: id, pid: Int32(40000 + Int(port) % 9000), rootPid: Int32(39000 + Int(port) % 9000),
                listenerPids: [Int32(40000 + Int(port) % 9000)], startDate: now.addingTimeInterval(-age),
                ports: [PortBinding(port: port, address: address, isIPv6: address.contains(":"))],
                framework: framework,
                project: project.map { Project(name: $0, root: root!, subpath: subpath, branch: branch, worktree: worktree) },
                processName: name ?? framework.name, executable: "/opt/homebrew/bin/node", command: command,
                directory: directory, launch: framework.category == .dev ? launch : nil)
            server.cpu = cpu
            server.memory = memoryMB * 1_048_576
            server.processCount = processes
            servers.append(server)
            if let page { pages[id] = page }
            history[id] = trace
        }

        add("api", port: 8000, address: "0.0.0.0", framework: .fastAPI, project: "api", command: "uvicorn app.main:app --reload --host 0.0.0.0",
            age: 5 * 3600 + 120, cpu: 1.6, memoryMB: 96, page: PageInfo(status: 404, title: nil),
            trace: wave(base: 1.2, amplitude: 0.8, seed: 1))
        add("ds-vite", port: 5173, framework: .vite, project: "design-system", subpath: "packages/ui", branch: "feat/tokens",
            worktree: "design-system-tokens", command: "vite --port 5173", age: 38 * 60, cpu: 0.6, memoryMB: 182,
            page: PageInfo(status: 200, title: "Design System"), trace: wave(base: 0.5, amplitude: 0.5, seed: 2))
        add("ds-storybook", port: 6006, framework: .storybook, project: "design-system", branch: "feat/tokens",
            command: "storybook dev -p 6006", age: 38 * 60, cpu: 0.3, memoryMB: 241, processes: 3,
            page: PageInfo(status: 200, title: "Storybook"), trace: wave(base: 0.3, amplitude: 0.3, seed: 3))
        add("docs", port: 4321, framework: .astro, project: "docs", command: "astro dev", age: 7, cpu: 24, memoryMB: 133,
            trace: [0, 3, 18, 31, 24])
        add("storefront", port: 3000, framework: .next, project: "storefront", command: "next dev --turbopack",
            age: 2 * 3600 + 14 * 60, cpu: 46, memoryMB: 1240, processes: 5, page: PageInfo(status: 200, title: "Storefront"),
            trace: Array(wave(base: 2, amplitude: 1.5, seed: 4).dropLast(8)) + [6, 14, 28, 39, 52, 61, 49, 46])
        add("postgres", port: 5432, framework: .postgres, project: nil, branch: nil, name: "Homebrew",
            command: "postgres -D /opt/homebrew/var/postgresql@17", age: 3 * 86400 + 4 * 3600, cpu: 0.2, memoryMB: 48,
            processes: 7, trace: wave(base: 0.2, amplitude: 0.2, seed: 5))
        add("redis", port: 6379, framework: .redis, project: nil, branch: nil, name: "Homebrew",
            command: "redis-server 127.0.0.1:6379", age: 3 * 86400 + 4 * 3600, cpu: 0.4, memoryMB: 9, processes: 1,
            trace: wave(base: 0.4, amplitude: 0.3, seed: 6))
        add("ollama", port: 11434, framework: .ollama, project: nil, branch: nil, command: "ollama serve",
            age: 26 * 3600, cpu: 0.1, memoryMB: 312, processes: 1, trace: wave(base: 0.1, amplitude: 0.1, seed: 7))

        let recents = [
            RecentServer(title: "worker", frameworkName: "Node.js", frameworkColor: Framework.node.color, port: 9000,
                         branch: "main", launch: LaunchSpec(executable: "/opt/homebrew/bin/node", arguments: ["node", "worker.js"],
                                                            directory: "\(home)/code/worker", viaShell: false, environment: nil),
                         stoppedAt: now.addingTimeInterval(-180), reason: .crashed(code: 1)),
            RecentServer(title: "marketing-site", frameworkName: "Remix", frameworkColor: Framework.remix.color, port: 3001,
                         branch: "main", launch: LaunchSpec(executable: "/opt/homebrew/bin/npm", arguments: ["npm", "run", "dev"],
                                                            directory: "\(home)/code/marketing-site", viaShell: false, environment: nil),
                         stoppedAt: now.addingTimeInterval(-12 * 60), reason: .stopped),
        ]
        store.showDemo(servers: servers, pages: pages, history: history, recents: recents)
    }

    /// A calm, slightly uneven trace, the same every run.
    private static func wave(base: Double, amplitude: Double, seed: Double) -> [Double] {
        (0..<36).map { i in
            let x = Double(i)
            return max(0, base + amplitude * (0.6 * sin(x * 0.55 + seed) + 0.4 * sin(x * 1.7 + seed * 2.3)))
        }
    }
}
