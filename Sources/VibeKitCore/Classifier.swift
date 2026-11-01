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
/// Pure apart from the `isProject` probe, so it is easy to test.
public struct Classifier: Sendable {
    public var home: String
    public var isProject: @Sendable (String) -> Bool

    public init(home: String = NSHomeDirectory(), isProject: @escaping @Sendable (String) -> Bool = Classifier.looksLikeProject) {
        self.home = home
        self.isProject = isProject
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
            if process.args.contains("-c") { return .tool }
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

        return .tool
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
            return dir.hasPrefix("/") ? dir : facts.cwd.map { ($0 as NSString).appendingPathComponent(dir) }
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
                // Prefer the outermost app for helpers nested inside another app.
                if let outer = facts.executable.range(of: ".app/"), outer.lowerBound != range.lowerBound {
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
        if dir.hasPrefix(home + "/Library") { return false }
        if dir.hasPrefix(home + "/.") {
            // Hidden folders hold tool state; count them only when they contain a real project.
            return isProject(dir)
        }
        return true
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
        if n.contains("serve") || n.contains("http-server") || n.contains("live-server")
            || n.contains("json-server") || n.contains("browser-sync") { return .staticServer }
        return nil
    }

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
        exe.hasPrefix("python") || exe == "uvicorn" || exe == "gunicorn" || path.contains("/Python.framework/")
    }

    func isRuntime(_ names: Set<String>) -> Bool { names.contains(exe) }
}
