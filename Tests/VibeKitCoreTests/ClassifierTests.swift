import Foundation
import Testing
@testable import VibeKitCore

private let home = "/Users/dev"
private let classifier = Classifier(home: home, isProject: { _ in false })

private func facts(_ executable: String, _ argv: [String], cwd: String? = "/Users/dev/code/app") -> ProcessFacts {
    ProcessFacts(comm: (executable as NSString).lastPathComponent, executable: executable, argv: argv, cwd: cwd)
}

@Suite("Classifier")
struct ClassifierTests {
    @Test func viteFromNodeModules() {
        let f = facts("/opt/homebrew/bin/node", ["node", "/Users/dev/code/app/node_modules/.bin/vite", "--port", "5173"])
        #expect(classifier.classify(f) == .vite)
    }

    @Test func nextFromRewrittenTitle() {
        // Node rewrites argv into a single title string when it sets process.title.
        let f = facts("/opt/homebrew/bin/node", ["next-server (v15.1.0)", "", ""])
        #expect(classifier.classify(f) == .next)
    }

    @Test func npmTitleCountsAsJavaScript() {
        let f = facts("/opt/homebrew/bin/node", ["npm run dev", "", ""])
        #expect(classifier.classify(f) == .node)
    }

    @Test func djangoRunserver() {
        let f = facts("/usr/bin/python3", ["python3", "manage.py", "runserver", "8000"])
        #expect(classifier.classify(f) == .django)
    }

    @Test func pythonHTTPServer() {
        let f = facts("/usr/bin/python3", ["python3", "-m", "http.server", "8080"])
        #expect(classifier.classify(f) == .pythonHTTP)
    }

    @Test func pythonDashCIsATool() {
        let f = facts("/usr/bin/python3", ["python3", "-c", "import http.server"])
        #expect(classifier.classify(f) == .tool)
    }

    @Test func dashCAfterTheModuleBelongsToTheServer() {
        let f = facts("/usr/bin/python3", ["python3", "-m", "gunicorn", "-c", "gunicorn.conf.py", "app:app"])
        #expect(classifier.classify(f) == .gunicorn)
        #expect(Classifier.runsInlinePython(["python3", "-u", "-W", "ignore", "-c", "print(1)"]))
    }

    @Test func postgresIsADatabase() {
        let f = facts("/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres", "-D", "/Users/dev/pgdata"], cwd: "/")
        let framework = classifier.classify(f)
        #expect(framework == .postgres)
        #expect(framework.category == .database)
        #expect(classifier.detail(f, framework: framework) == "~/pgdata")
    }

    @Test func redisFromHomebrew() {
        let f = facts("/opt/homebrew/opt/redis/bin/redis-server", ["redis-server *:6379"], cwd: "/")
        let framework = classifier.classify(f)
        #expect(framework == .redis)
        #expect(classifier.detail(f, framework: framework) == "Homebrew")
    }

    @Test func electronHelperIsAnApp() {
        let f = facts("/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper",
                      ["Cursor Helper", "--type=utility"], cwd: "/")
        #expect(classifier.classify(f) == .app)
        #expect(classifier.displayName(f) == "Cursor")
    }

    @Test func pythonFrameworkIsNotAnApp() {
        let exe = "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
        let f = facts(exe, [exe, "-m", "uvicorn", "main:app"])
        #expect(classifier.classify(f) == .uvicorn)
    }

    @Test func plainNodeOutsideAProjectIsATool() {
        let f = facts("/opt/homebrew/bin/node", ["node", "server.js"], cwd: "/Users/dev/Library/Application Support/Thing")
        #expect(classifier.classify(f) == .tool)
    }

    @Test func plainNodeInAProjectIsADevServer() {
        let f = facts("/opt/homebrew/bin/node", ["node", "server.js"], cwd: "/Users/dev/code/api")
        #expect(classifier.classify(f) == .node)
    }

    @Test func rustAndSwiftBuildOutputs() {
        #expect(classifier.classify(facts("/Users/dev/code/api/target/debug/api", ["api"])) == .rust)
        #expect(classifier.classify(facts("/Users/dev/code/kit/.build/debug/Server", ["Server"])) == .swift)
        #expect(classifier.classify(facts("/Users/dev/code/kit/.build/x86_64-apple-macosx/debug/Server", ["Server"])) == .swift)
        #expect(classifier.classify(facts("/Users/dev/code/WebApi/bin/Debug/net8.0/WebApi", ["WebApi"])) == .dotnet)
    }

    @Test func httpServerDirectoryFlag() {
        let f = facts("/usr/bin/python3", ["python3", "-m", "http.server", "--directory", "dist"], cwd: "/Users/dev/code/site")
        #expect(classifier.projectDirectory(f, framework: .pythonHTTP) == "/Users/dev/code/site/dist")
        let sibling = facts("/usr/bin/python3", ["python3", "-m", "http.server", "-d", "../assets"], cwd: "/Users/dev/code/site")
        #expect(classifier.projectDirectory(sibling, framework: .pythonHTTP) == "/Users/dev/code/assets")
    }

    @Test func homeIsNotAProjectDirectory() {
        let f = facts("/opt/homebrew/bin/node", ["node", "vite"], cwd: home)
        #expect(classifier.projectDirectory(f, framework: .vite) == nil)
    }

    @Test func workspaces() {
        #expect(classifier.isUserWorkspace("/Users/dev/code/app"))
        #expect(!classifier.isUserWorkspace("/Users/dev"))
        #expect(!classifier.isUserWorkspace("/Users/dev/Library/Caches/x"))
        #expect(!classifier.isUserWorkspace("/usr/local/lib"))
        #expect(!classifier.isUserWorkspace("/Users/dev/.cache/tool"))
    }
}

@Suite("Command lines")
struct CommandLineTests {
    @Test func quotesArgumentsWithSpaces() {
        #expect(CommandLine.display(["echo", "hello world", "it's", ""]) == "echo 'hello world' 'it'\\''s' ''")
    }

    @Test func quotesShellCharacters() {
        #expect(CommandLine.display(["serve", "--directory", "site&docs", "$HOME", "*.md"]) == "serve --directory 'site&docs' '$HOME' '*.md'")
        #expect(CommandLine.display(["vite", "--port=3000", "--host", "0.0.0.0"]) == "vite --port=3000 --host 0.0.0.0")
    }

    @Test func friendlyShortensPaths() {
        let argv = ["/opt/homebrew/bin/node", "/Users/dev/code/app/node_modules/.bin/vite", "--port", "3000"]
        #expect(CommandLine.friendly(argv, home: home) == "vite --port 3000")
    }

    @Test func friendlyKeepsScriptsAndAbbreviatesHome() {
        let argv = ["/opt/homebrew/bin/node", "/Users/dev/code/app/server.js"]
        #expect(CommandLine.friendly(argv, home: home) == "node ~/code/app/server.js")
    }
}

@Suite("Process arguments")
struct ProcArgsTests {
    private func buffer(argc: Int32, _ parts: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(parts[0].utf8) + [UInt8](repeating: 0, count: padding)
        for part in parts.dropFirst() { bytes += Array(part.utf8) + [0] }
        return bytes + [0]
    }

    @Test func parsesExecutableArgvAndEnvironment() throws {
        let bytes = buffer(argc: 2, ["/bin/node", "node", "server.js", "PORT=3000", "HOME=/Users/dev"])
        let parsed = try #require(LibProc.parseProcArgs(bytes))
        #expect(parsed.executable == "/bin/node")
        #expect(parsed.argv == ["node", "server.js"])
        #expect(parsed.environment == ["PORT=3000", "HOME=/Users/dev"])
    }

    @Test func rejectsTruncatedBuffers() {
        #expect(LibProc.parseProcArgs([1, 0]) == nil)
    }
}

@Suite("Page titles")
struct ProbeTests {
    @Test func readsAndDecodesTitle() {
        let html = Data("<html><head><title data-x>\n  Tom &amp; Jerry&#39;s   App </title></head>".utf8)
        #expect(Probe.title(in: html) == "Tom & Jerry's App")
    }

    @Test func missingTitle() {
        #expect(Probe.title(in: Data("<html><body>hi</body></html>".utf8)) == nil)
        #expect(Probe.title(in: Data("<title></title>".utf8)) == nil)
    }
}

@Suite("Projects")
struct ProjectResolverTests {
    private func makeTemp() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("vibekit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).resolvingSymlinksInPath
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func repositoryWithSubpathAndBranch() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/shop"
        try write("ref: refs/heads/feature/cart\n", to: repo + "/.git/HEAD")
        try FileManager.default.createDirectory(atPath: repo + "/apps/web", withIntermediateDirectories: true)

        let project = ProjectResolver.resolve(repo + "/apps/web", home: "/nonexistent")
        #expect(project.name == "shop")
        #expect(project.subpath == "apps/web")
        #expect(project.branch == "feature/cart")
        #expect(project.worktree == nil)
    }

    @Test func linkedWorktreeUsesMainRepositoryName() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("ref: refs/heads/main\n", to: root + "/shop/.git/HEAD")
        try write("ref: refs/heads/fix-login\n", to: root + "/shop/.git/worktrees/shop-fix/HEAD")
        try write("gitdir: \(root)/shop/.git/worktrees/shop-fix\n", to: root + "/shop-fix/.git")

        let project = ProjectResolver.resolve(root + "/shop-fix", home: "/nonexistent")
        #expect(project.name == "shop")
        #expect(project.worktree == "shop-fix")
        #expect(project.branch == "fix-login")
    }

    @Test func detachedHeadShowsShortHash() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39\n", to: root + "/.git/HEAD")
        #expect(ProjectResolver.branch(gitDir: root + "/.git") == "3f2a9c1")
    }
}

@Suite("Exit codes")
struct ExitCodeTests {
    @Test func normalExitKeepsItsCode() {
        #expect(ProcessControl.exitCode(0) == 0)
        #expect(ProcessControl.exitCode(1 << 8) == 1)
        #expect(ProcessControl.exitCode(127 << 8) == 127)
    }

    @Test func signalsReadLikeAShell() {
        #expect(ProcessControl.exitCode(SIGINT) == 130)
        #expect(ProcessControl.exitCode(SIGKILL) == 137)
        #expect(ProcessControl.exitCode(SIGSEGV | 0x80) == 139)  // core dumped
    }
}

@Suite("Restart commands")
struct ReplayTests {
    @Test func plainRunnerTitlesReplay() {
        #expect(PortScanner.isReplayableTitle("npm run dev"))
        #expect(PortScanner.isReplayableTitle("pnpm --filter @acme/web dev -- --port=3000"))
    }

    @Test func titlesThatAreNotCommandsDoNot() {
        #expect(!PortScanner.isReplayableTitle("next-server (v15.1.0)"))
        #expect(!PortScanner.isReplayableTitle("npm run dev $(touch x)"))
        #expect(!PortScanner.isReplayableTitle("npm run dev; rm -rf ~"))
    }
}

@Suite("Addresses")
struct AddressTests {
    private func server(_ bindings: [PortBinding]) -> Server {
        Server(id: "s", pid: 1, rootPid: 1, listenerPids: [1], startDate: Date(), ports: bindings, framework: .vite,
               project: nil, processName: "vite", executable: "/bin/node", command: "vite", directory: nil, launch: nil)
    }

    @Test func holdsAPortOnlyForTheSameProjectFolder() {
        func server(root: String, subpath: String?, port: UInt16) -> Server {
            Server(id: "s", pid: 1, rootPid: 1, listenerPids: [1], startDate: Date(),
                   ports: [PortBinding(port: port, address: "::1", isIPv6: true)], framework: .vite,
                   project: Project(name: "web", root: root, subpath: subpath, branch: nil, worktree: nil),
                   processName: "vite", executable: "/bin/node", command: "vite", directory: nil, launch: nil)
        }
        let a = server(root: "/clients/a/web", subpath: nil, port: 3000)
        #expect(a.holds(port: 3000, inFolder: "/clients/a/web"))
        // Same name, other checkout: not the same server coming back.
        #expect(!server(root: "/clients/b/web", subpath: nil, port: 3000).holds(port: 3000, inFolder: "/clients/a/web"))
        #expect(!a.holds(port: 3001, inFolder: "/clients/a/web"))
        #expect(server(root: "/repo", subpath: "apps/web", port: 3000).holds(port: 3000, inFolder: "/repo/apps/web"))
        #expect(!server(root: "/repo", subpath: "apps/api", port: 3000).holds(port: 3000, inFolder: "/repo/apps/web"))
    }

    @Test func loopbackAndWildcardUseLocalhost() {
        #expect(server([PortBinding(port: 5173, address: "::1", isIPv6: true)]).localURL?.absoluteString == "http://localhost:5173")
        #expect(server([PortBinding(port: 5173, address: "0.0.0.0", isIPv6: false)]).localURL?.absoluteString == "http://localhost:5173")
    }

    @Test func specificAddressIsUsedAsIs() {
        #expect(server([PortBinding(port: 5173, address: "192.168.1.20", isIPv6: false)]).localURL?.absoluteString == "http://192.168.1.20:5173")
        #expect(server([PortBinding(port: 5173, address: "fd00::5", isIPv6: true)]).localURL?.absoluteString == "http://[fd00::5]:5173")
        // `localhost` does not reach a loopback alias.
        #expect(server([PortBinding(port: 5173, address: "127.0.0.2", isIPv6: false)]).localURL?.absoluteString == "http://127.0.0.2:5173")
    }

    @Test func ipv6OnlyListenerGetsNoIPv4NetworkURL() {
        let v6only = server([PortBinding(port: 3000, address: "::", isIPv6: true, acceptsIPv4: false)])
        #expect(v6only.networkURL(host: "192.168.1.24") == nil)
        let dual = server([PortBinding(port: 3000, address: "::", isIPv6: true, acceptsIPv4: true)])
        #expect(dual.networkURL(host: "192.168.1.24")?.absoluteString == "http://192.168.1.24:3000")
    }

    @Test func socketListerSeesDualStack() throws {
        func makeListener(v6only: Int32) throws -> (fd: Int32, port: UInt16) {
            let fd = socket(AF_INET6, SOCK_STREAM, 0)
            try #require(fd >= 0)
            var only = v6only
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_any
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let ok = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            try #require(ok)
            return (fd, UInt16(bigEndian: addr.sin6_port))
        }
        let dual = try makeListener(v6only: 0), only = try makeListener(v6only: 1)
        defer { close(dual.fd); close(only.fd) }
        let bindings = LibProc.SocketLister().listeningSockets(getpid())
        #expect(bindings.first { $0.port == dual.port }?.acceptsIPv4 == true)
        #expect(bindings.first { $0.port == only.port }?.acceptsIPv4 == false)
    }

    @Test func networkURLUsesTheExposedPort() {
        let s = server([PortBinding(port: 3000, address: "127.0.0.1", isIPv6: false), PortBinding(port: 3001, address: "0.0.0.0", isIPv6: false)])
        #expect(s.networkURL(host: "192.168.1.24")?.absoluteString == "http://192.168.1.24:3001")
        #expect(server([PortBinding(port: 3000, address: "127.0.0.1", isIPv6: false)]).networkURL(host: "192.168.1.24") == nil)
    }

    @Test func reachableBindingWinsForAPort() {
        let ports = PortScanner().orderedPorts([
            PortBinding(port: 3000, address: "192.168.1.20", isIPv6: false),
            PortBinding(port: 3000, address: "127.0.0.1", isIPv6: false),
        ], hints: [])
        #expect(ports == [PortBinding(port: 3000, address: "127.0.0.1", isIPv6: false)])
    }

    @Test func portHeldOnlyOnIPv6IsNotFree() throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        #expect(!Network.isPortFree(UInt16(bigEndian: addr.sin6_port)))
    }
}

@Suite("Process control", .timeLimit(.minutes(1)))
struct ProcessControlTests {
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func doesNotSignalAReusedPid() async throws {
        let process = try sleeper()
        defer { process.terminate() }
        let result = await ProcessControl.stop(root: process.processIdentifier, started: Date(timeIntervalSince1970: 0), grace: 0.2)
        #expect(result == .stopped)
        #expect(ProcessControl.isAlive(process.processIdentifier))
    }

    @Test func stopsTheProcessThatStartedThen() async throws {
        let process = try sleeper()
        let started = try #require(LibProc.startDate(process.processIdentifier))
        let result = await ProcessControl.stop(root: process.processIdentifier, started: started, grace: 2)
        #expect(result == .stopped)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
    }

    @Test func reportsTheExitCodeOfASpawnedServer() async throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vibekit-exit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let spec = LaunchSpec(executable: "/bin/sh", arguments: ["sh", "-c", "echo boom; exit 3"], directory: NSTemporaryDirectory(),
                              viaShell: false, environment: nil)
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            do {
                let spawned = try ProcessControl.spawn(spec, environment: ["PATH=/usr/bin:/bin"], log: log) { _, code in
                    continuation.resume(returning: code)
                }
                close(spawned.stdinWriter)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(code == 3)
        #expect(try String(contentsOf: log, encoding: .utf8) == "boom\n")
    }
}
