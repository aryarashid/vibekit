import Darwin
import Foundation

/// What we know about one process, gathered from libproc.
public struct ProcessFacts: Sendable {
    public var pid: pid_t
    public var comm: String
    public var executable: String
    public var argv: [String]
    public var cwd: String?

    public init(pid: pid_t = 0, comm: String, executable: String, argv: [String], cwd: String?) {
        self.pid = pid
        self.comm = comm
        self.executable = executable
        self.argv = argv
        self.cwd = cwd
    }
}

/// Decides what a listening process is from its executable, argv and working directory.
/// Pure apart from the `isProject` and `fileExists` probes, so it is easy to test.
public struct Classifier: Sendable {
    public var home: String
    public var isProject: @Sendable (String) -> Bool
    /// Whether a file exists, used to tell what language a compiled binary's workspace is written in.
    public var fileExists: @Sendable (String) -> Bool

    public init(home: String = NSHomeDirectory(), isProject: @escaping @Sendable (String) -> Bool = Classifier.looksLikeProject,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.home = home
        self.isProject = isProject
        self.fileExists = fileExists
    }

    public func classify(_ facts: ProcessFacts) -> Framework {
        let process = Tokens(facts)

        if let match = Self.databaseOrService(process) { return match }

        if process.isRuntime(["node", "bun", "deno"]) || process.hasJSTitle {
            if process.insideAppBundle { return .app }
            if let match = Self.javaScript(process) { return match }
            if process.exe == "bun" { return devOrTool(.bun, facts) }
            if process.exe == "deno" { return devOrTool(.deno, facts) }
            return devOrTool(.node, facts)
        }
        if process.isPython {
            // `gunicorn -c conf.py` and `hypercorn -c conf.toml` pass a config file, not code.
            if process.isPythonInterpreter, Self.runsInlinePython(facts.argv) { return .tool }
            if let match = Self.python(process) { return match }
            return devOrTool(.python, facts)
        }
        if process.isRuntime(["ruby"]) || process.names.contains("rails") || process.names.contains("puma") {
            if process.names.contains("jekyll") { return .jekyll }
            if process.names.contains("rails") || process.names.contains("puma") { return .rails }
            return devOrTool(.ruby, facts)
        }
        if process.isRuntime(["php"]) {
            return process.names.contains("artisan") ? .laravel : devOrTool(.php, facts)
        }
        if process.exe == "hugo" { return .hugo }
        if process.exe == "trunk" { return .trunk }
        if process.exe == "beam.smp" {
            return process.joined.contains("phx") || process.joined.contains("phoenix") ? .phoenix : devOrTool(.elixir, facts)
        }
        if process.exe == "java" {
            if process.joined.contains("kotlin") && process.joined.contains("daemon") { return .tool }
            if process.joined.contains("gradledaemon") || process.joined.contains("gradle-launcher") { return .tool }
            if process.joined.contains("spring-boot") || process.joined.contains("springframework") { return .spring }
            if process.joined.contains("firebase") || process.joined.contains("cloud-firestore-emulator") { return .firebase }
            return devOrTool(.java, facts)
        }
        if process.exe == "dotnet" { return devOrTool(.dotnet, facts) }

        if process.insideAppBundle { return .app }

        // Compiled binaries run from a project build folder.
        let exePath = facts.executable
        if exePath.contains("/go-build") || process.exe == "air" { return .go }
        if exePath.contains("/target/debug/") || exePath.contains("/target/release/") { return .rust }
        if exePath.contains("/.build/debug/") || exePath.contains("/.build/release/")
            || exePath.contains("/.build/arm64-apple-macosx/") || exePath.contains("/.build/x86_64-apple-macosx/") { return .swift }
        // `dotnet run` with an apphost runs the project's own binary from bin/<configuration>/net<version>/.
        if exePath.contains("/bin/Debug/net") || exePath.contains("/bin/Release/net") { return .dotnet }
        // A binary built to a folder of its own choosing, such as `go build -o bin/api`, run from its workspace.
        if let language = workspaceLanguage(facts) { return language }

        return .tool
    }

    /// The language of the workspace a compiled binary runs from, read from `go.mod`, `Cargo.toml` or `Package.swift`
    /// in its working directory or up to two folders above it. Installed tools such as `ssh` or `kubectl` started from
    /// a Go repository stay tools.
    private func workspaceLanguage(_ facts: ProcessFacts) -> Framework? {
        guard var dir = facts.cwd, isUserWorkspace(dir), !isInstalledTool(facts.executable) else { return nil }
        for _ in 0..<3 {
            if fileExists((dir as NSString).appendingPathComponent("go.mod")) { return .go }
            if fileExists((dir as NSString).appendingPathComponent("Cargo.toml")) { return .rust }
            if fileExists((dir as NSString).appendingPathComponent("Package.swift")) { return .swift }
            let parent = (dir as NSString).deletingLastPathComponent
            guard parent != dir, isUserWorkspace(parent) else { break }
            dir = parent
        }
        return nil
    }

    /// Executables installed system-wide, by Homebrew, or into a toolchain's bin folder, rather than built in a workspace.
    private func isInstalledTool(_ executable: String) -> Bool {
        guard executable.hasPrefix("/") else { return true }
        for prefix in ["/usr/", "/bin/", "/sbin/", "/System/", "/Library/", "/opt/", "/Applications/", "/nix/", "/private/", "/var/"]
            where executable.hasPrefix(prefix) {
            return true
        }
        return executable.hasPrefix(home + "/.") || executable.hasPrefix(home + "/go/bin/") || executable.hasPrefix(home + "/Library/")
    }

    /// A runtime with no recognised framework counts as a dev server only when it runs from a project.
    private func devOrTool(_ framework: Framework, _ facts: ProcessFacts) -> Framework {
        guard let dir = facts.cwd, isUserWorkspace(dir) else { return .tool }
        return framework
    }

    /// The folder a server serves, which is usually its working directory.
    public func projectDirectory(_ facts: ProcessFacts, framework: Framework) -> String? {
        guard framework.category == .dev else { return nil }
        if framework == .pythonHTTP, let dir = value(after: ["--directory", "-d"], in: facts.argv) {
            let path = dir.hasPrefix("/") ? dir : facts.cwd.map { ($0 as NSString).appendingPathComponent(dir) }
            // `../assets` must not resolve to the repository the server was started from.
            return path.map { URL(fileURLWithPath: $0).standardized.path }
        }
        guard let cwd = facts.cwd, cwd != "/", cwd != home else { return nil }
        return cwd
    }

    /// A short note on where a database or service lives, such as its data folder.
    public func detail(_ facts: ProcessFacts, framework: Framework) -> String? {
        switch framework.category {
        case .database:
            if let dir = value(after: ["-D", "--datadir", "--dbpath", "--dir"], in: facts.argv) {
                return abbreviate(dir)
            }
            if facts.executable.contains("/Postgres.app/") { return "Postgres.app" }
            if facts.executable.hasPrefix("/opt/homebrew/") || facts.executable.hasPrefix("/usr/local/Cellar/") { return "Homebrew" }
            return facts.cwd.flatMap { $0 == "/" ? nil : abbreviate($0) }
        case .service:
            return nil
        case .other:
            return abbreviate(facts.executable)
        case .dev:
            return nil
        }
    }

    /// The name shown for apps and tools, taken from the app bundle when there is one.
    public func displayName(_ facts: ProcessFacts) -> String {
        if let range = facts.executable.range(of: ".app/", options: .backwards) {
            let bundle = facts.executable[..<range.lowerBound]
            if let slash = bundle.lastIndex(of: "/") {
                let name = String(bundle[bundle.index(after: slash)...])
                // Prefer the outermost app for helpers nested inside another app, but not for a language runtime
                // that ships inside a framework, such as the Python inside Xcode: that is Python, not Xcode.
                if !bundle.contains(".framework/"), let outer = facts.executable.range(of: ".app/"), outer.lowerBound != range.lowerBound {
                    let outerBundle = facts.executable[..<outer.lowerBound]
                    if let s = outerBundle.lastIndex(of: "/") { return String(outerBundle[outerBundle.index(after: s)...]) }
                }
                return name
            }
        }
        let name = (facts.executable as NSString).lastPathComponent
        return name.isEmpty ? facts.comm : name
    }

    public func abbreviate(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A folder a person works in, rather than system or app-support locations.
    public func isUserWorkspace(_ dir: String) -> Bool {
        if dir == "/" || dir == home || dir == home + "/" { return false }
        for prefix in ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/var", "/opt/homebrew", "/Applications"]
            where dir == prefix || dir.hasPrefix(prefix + "/") {
            return false
        }
        if dir == home + "/Library" || dir.hasPrefix(home + "/Library/") { return false }
        if dir.hasPrefix(home + "/.") {
            // Hidden folders hold tool state; count them only when they contain a real project.
            return isProject(dir)
        }
        return true
    }

    /// True for `python -c "code"`. Only options before the script or `-m` belong to Python, so
    /// `python -m gunicorn -c gunicorn.conf.py` is a server with a config file.
    static func runsInlinePython(_ argv: [String]) -> Bool {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "-c" { return true }
            if arg == "-m" || !arg.hasPrefix("-") { return false }
            if arg == "-W" || arg == "-X" { index += 1 }  // These take a value.
            index += 1
        }
        return false
    }

    @Sendable public static func looksLikeProject(_ dir: String) -> Bool {
        let markers = ["package.json", "pyproject.toml", "requirements.txt", "Gemfile", "go.mod", "Cargo.toml",
                       "composer.json", "mix.exs", "deno.json", "Package.swift", "manage.py", ".git"]
        let fm = FileManager.default
        return markers.contains { fm.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }
    }

    private func value(after flags: [String], in argv: [String]) -> String? {
        for (i, arg) in argv.enumerated() {
            for flag in flags {
                if arg == flag, i + 1 < argv.count { return argv[i + 1] }
                if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
            }
        }
        return nil
    }

    // MARK: Rules

    private static func databaseOrService(_ p: Tokens) -> Framework? {
        switch p.exe {
        case "postgres", "postmaster": return .postgres
        case "mysqld": return p.path.contains("mariadb") ? .mariadb : .mysql
        case "mariadbd": return .mariadb
        case "mongod", "mongos": return .mongo
        case "redis-server": return .redis
        case "valkey-server": return .valkey
        case "memcached": return .memcached
        case "clickhouse", "clickhouse-server": return .clickhouse
        case "meilisearch": return .meilisearch
        case "typesense-server": return .typesense
        case "qdrant": return .qdrant
        case "minio": return .minio
        case "influxd": return .influx
        case "cockroach": return .cockroach
        case "surreal": return .surreal
        case "etcd": return .etcd
        case "nats-server": return .nats
        case "ollama": return .ollama
        case "ngrok": return .ngrok
        case "cloudflared": return .cloudflared
        case "mailpit", "mailhog": return .mailpit
        case "llama-server": return .llamaCpp
        case "vllm": return .vllm
        case "mlx_lm.server": return .mlxLM
        case "litellm": return .litellm
        case "inngest", "inngest-cli": return .inngest
        case "temporal", "temporalite": return .temporal
        case "caddy": return .caddy
        case "stripe": return .stripe
        case "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "docker-proxy", "com.docker.krun":
            return .docker
        default: break
        }
        if p.path.contains("/OrbStack.app/") { return .orbstack }
        if p.path.contains("/Docker.app/") { return .docker }
        if p.path.contains("/LM Studio.app/") { return .lmStudio }
        if p.path.contains("/Ollama.app/") { return .ollama }
        if p.exe == "java" {
            if p.joined.contains("org.elasticsearch") { return .elasticsearch }
            if p.joined.contains("org.opensearch") { return .opensearch }
        }
        if p.exe == "beam.smp", p.joined.contains("rabbit") { return .rabbitmq }
        if p.isPython, p.names.contains("localstack") { return .localstack }
        // AI runners started through Python: `python …/bin/vllm serve`, `python -m mlx_lm.server`, `litellm --model`.
        if p.isPython {
            if p.names.contains("vllm") || p.names.contains(where: { $0.hasPrefix("vllm.entrypoints") }) { return .vllm }
            if p.names.contains(where: { $0 == "mlx_lm" || $0.hasPrefix("mlx_lm.") }) { return .mlxLM }
            if p.names.contains("litellm") { return .litellm }
        }
        return nil
    }

    private static func javaScript(_ p: Tokens) -> Framework? {
        let n = p.names
        if n.contains("next") || p.joined.contains("next-server") || p.joined.contains("/next/dist/") { return .next }
        if n.contains("nuxi") || n.contains("nuxt") { return .nuxt }
        if n.contains("astro") { return .astro }
        if n.contains("react-router") { return .reactRouter }
        if n.contains("remix") { return .remix }
        if n.contains("svelte-kit") { return .svelteKit }
        if n.contains("storybook") || n.contains("start-storybook") { return .storybook }
        if n.contains("expo") || p.joined.contains("@expo/cli") { return .expo }
        if n.contains("metro") || (n.contains("react-native") && n.contains("start")) { return .metro }
        if n.contains("vitepress") { return .vitepress }
        if n.contains("vite") || p.joined.contains("/vite/bin/vite") { return .vite }
        if n.contains("react-scripts") { return .createReactApp }
        if (n.contains("ng") && n.contains("serve")) || p.joined.contains("@angular/cli") { return .angular }
        if n.contains("vue-cli-service") { return .vueCLI }
        if n.contains("webpack") || n.contains("webpack-dev-server") || n.contains("webpack-cli") { return .webpack }
        if n.contains("parcel") { return .parcel }
        if n.contains("gatsby") { return .gatsby }
        if n.contains("docusaurus") { return .docusaurus }
        if n.contains("eleventy") || p.joined.contains("@11ty") { return .eleventy }
        if n.contains("wrangler") || n.contains("workerd") { return .wrangler }
        if n.contains("vercel") { return .vercel }
        if n.contains("netlify") { return .netlify }
        if n.contains("firebase") { return .firebase }
        if n.contains("convex") { return .convex }
        if n.contains("prisma") && n.contains("studio") { return .prismaStudio }
        if n.contains("drizzle-kit") { return .drizzleStudio }
        if n.contains("nest") { return .nest }
        if n.contains("inngest-cli") { return .inngest }
        if runsServe(p) || n.contains("http-server") || n.contains("live-server")
            || n.contains("json-server") || n.contains("browser-sync") { return .staticServer }
        return nil
    }

    /// True when the `serve` package is the program, as in `npx serve dist` or `node …/.bin/serve`, and false when
    /// `serve` is a subcommand of another script, as in `node mytool.js serve`.
    static func runsServe(_ argv: [String]) -> Bool {
        let words = argv.flatMap { $0.lowercased().split(separator: " ").map(String.init) }
        guard let first = words.first else { return false }
        func name(_ word: String) -> String { ((word as NSString).lastPathComponent as NSString).deletingPathExtension }
        func isServe(_ word: String) -> Bool { name(word) == "serve" || word.contains("/node_modules/serve/") }
        if name(first) == "serve" { return true }
        // The script node or bun runs.
        if ["node", "bun", "deno"].contains(name(first)), let script = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            if isServe(script) { return true }
        }
        // The package a runner fetches and runs: `npx serve`, `pnpm dlx serve`, `npm exec serve`.
        for (i, word) in words.enumerated() where ["npx", "bunx", "pnpx", "dlx", "exec"].contains(name(word)) {
            if let next = words[(i + 1)...].first(where: { !$0.hasPrefix("-") }), isServe(next) { return true }
        }
        return false
    }

    private static func runsServe(_ p: Tokens) -> Bool { runsServe(p.args) }

    private static func python(_ p: Tokens) -> Framework? {
        let n = p.names
        if (n.contains("manage.py") && n.contains("runserver")) || n.contains("django-admin") { return .django }
        if n.contains("flask") { return .flask }
        if n.contains("fastapi") { return .fastAPI }
        if n.contains("uvicorn") || n.contains("hypercorn") || n.contains("granian") { return .uvicorn }
        if n.contains("gunicorn") { return .gunicorn }
        if n.contains("streamlit") { return .streamlit }
        if n.contains("gradio") { return .gradio }
        if n.contains(where: { $0.hasPrefix("jupyter") }) { return .jupyter }
        if n.contains("mkdocs") { return .mkdocs }
        if n.contains("http.server") || n.contains("simplehttpserver") { return .pythonHTTP }
        return nil
    }
}

/// Lowercased views of a process used by the rules.
private struct Tokens {
    let exe: String
    let path: String
    let names: Set<String>
    let args: [String]
    let joined: String
    let hasJSTitle: Bool
    let insideAppBundle: Bool

    init(_ facts: ProcessFacts) {
        path = facts.executable
        let base = (facts.executable as NSString).lastPathComponent.lowercased()
        exe = base.isEmpty ? facts.comm.lowercased() : base
        args = facts.argv.map { $0.lowercased() }
        joined = args.joined(separator: " ")
        var names = Set<String>()
        // Split on spaces too: node rewrites argv into one string when it sets process.title.
        for arg in args {
            for word in arg.split(separator: " ") {
                let name = (String(word) as NSString).lastPathComponent
                names.insert(name)
                if name.hasSuffix(".js") || name.hasSuffix(".cjs") || name.hasSuffix(".mjs") {
                    names.insert((name as NSString).deletingPathExtension)
                }
            }
        }
        self.names = names
        let first = args.first.map { ($0.split(separator: " ").first.map(String.init) ?? $0) } ?? ""
        hasJSTitle = ["npm", "npx", "pnpm", "yarn", "next-server", "next-router-worker"].contains(first)
        // Python.framework ships Python.app; that is still a plain interpreter.
        insideAppBundle = facts.executable.contains(".app/Contents/") && !facts.executable.contains("/Python.framework/")
    }

    var isPython: Bool {
        isPythonInterpreter || ["uvicorn", "gunicorn", "granian", "hypercorn"].contains(exe)
    }

    /// The interpreter itself, as opposed to a server's own entry point such as `gunicorn`.
    var isPythonInterpreter: Bool { exe.hasPrefix("python") || path.contains("/Python.framework/") }

    func isRuntime(_ names: Set<String>) -> Bool { names.contains(exe) }
}
