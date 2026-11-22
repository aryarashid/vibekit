import Foundation
import Testing
@testable import VibeKitCore

private let home = "/Users/dev"

private func facts(_ executable: String, _ argv: [String], cwd: String? = "/Users/dev/code/app") -> ProcessFacts {
    ProcessFacts(comm: (executable as NSString).lastPathComponent, executable: executable, argv: argv, cwd: cwd)
}

/// A classifier that sees only `files` on disk.
private func classifier(files: Set<String> = []) -> Classifier {
    Classifier(home: home, isProject: { _ in false }, fileExists: { files.contains($0) })
}

@Suite("Modern stack")
struct ModernStackTests {
    @Test func aiRunners() {
        let c = classifier()
        #expect(c.classify(facts("/opt/homebrew/bin/llama-server", ["llama-server", "-m", "model.gguf"], cwd: "/")) == .llamaCpp)
        #expect(c.classify(facts("/Users/dev/venv/bin/python3", ["python3", "/Users/dev/venv/bin/vllm", "serve", "Qwen/Qwen3"])) == .vllm)
        #expect(c.classify(facts("/usr/bin/python3", ["python3", "-m", "vllm.entrypoints.openai.api_server"])) == .vllm)
        #expect(c.classify(facts("/usr/bin/python3", ["python3", "-m", "mlx_lm.server", "--model", "x"])) == .mlxLM)
        #expect(c.classify(facts("/usr/bin/python3", ["python3", "-m", "mlx_lm", "server"])) == .mlxLM)
        #expect(c.classify(facts("/Users/dev/venv/bin/python3", ["python3", "/Users/dev/venv/bin/litellm", "--model", "gpt"])) == .litellm)
        #expect(Framework.llamaCpp.category == .service && Framework.vllm.category == .service)
    }

    @Test func workflowEnginesProxiesAndCLIs() {
        let c = classifier()
        #expect(c.classify(facts("/opt/homebrew/bin/inngest", ["inngest", "dev"])) == .inngest)
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["node", "/Users/dev/code/app/node_modules/.bin/inngest-cli", "dev"])) == .inngest)
        #expect(c.classify(facts("/opt/homebrew/bin/temporal", ["temporal", "server", "start-dev"])) == .temporal)
        #expect(c.classify(facts("/opt/homebrew/bin/caddy", ["caddy", "run"])) == .caddy)
        let stripe = c.classify(facts("/opt/homebrew/bin/stripe", ["stripe", "listen", "--forward-to", "localhost:3000"]))
        #expect(stripe == .stripe)
        #expect(!stripe.speaksHTTP)
    }

    @Test func granianAndHypercornExecutables() {
        let c = classifier()
        #expect(c.classify(facts("/Users/dev/code/app/.venv/bin/granian", ["granian", "--interface", "asgi", "main:app"])) == .uvicorn)
        #expect(c.classify(facts("/Users/dev/code/app/.venv/bin/hypercorn", ["hypercorn", "main:app"])) == .uvicorn)
        // `-c` is a config file for these servers, not inline code.
        #expect(c.classify(facts("/Users/dev/code/app/.venv/bin/hypercorn", ["hypercorn", "-c", "hypercorn.toml", "main:app"])) == .uvicorn)
        #expect(c.classify(facts("/Users/dev/code/app/.venv/bin/gunicorn", ["gunicorn", "-c", "gunicorn.conf.py", "app:app"])) == .gunicorn)
        #expect(c.classify(facts("/usr/bin/python3", ["python3", "-c", "import x"])) == .tool)
    }

    @Test func serveCountsOnlyAsTheProgram() {
        let c = classifier()
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["node", "/Users/dev/.npm/_npx/abc/node_modules/.bin/serve", "dist"])) == .staticServer)
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["node", "/Users/dev/.npm/_npx/abc/node_modules/serve/build/main.js"])) == .staticServer)
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["npx serve -l 4000", "", ""])) == .staticServer)
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["pnpm dlx serve", "", ""])) == .staticServer)
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["node", "/Users/dev/code/app/node_modules/.bin/http-server"])) == .staticServer)
        // A subcommand named serve belongs to the script.
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["node", "mytool.js", "serve"])) == .node)
        #expect(c.classify(facts("/opt/homebrew/bin/node", ["node", "dist/cli.js", "serve", "--port", "3000"])) == .node)
        #expect(!Classifier.runsServe(["node", "server.js", "serve"]))
        #expect(Classifier.runsServe(["npx", "-y", "serve", "out"]))
    }

    @Test func compiledBinaryInAWorkspace() {
        let c = classifier(files: ["/Users/dev/code/api/go.mod", "/Users/dev/code/engine/Cargo.toml", "/Users/dev/code/kit/Package.swift"])
        #expect(c.classify(facts("/Users/dev/code/api/bin/api", ["./bin/api"], cwd: "/Users/dev/code/api")) == .go)
        // go.mod at the repository root, run from a subfolder.
        #expect(c.classify(facts("/Users/dev/code/api/bin/api", ["api"], cwd: "/Users/dev/code/api/cmd/api")) == .go)
        #expect(c.classify(facts("/Users/dev/code/engine/out/engine", ["engine"], cwd: "/Users/dev/code/engine")) == .rust)
        #expect(c.classify(facts("/Users/dev/code/kit/dist/Server", ["Server"], cwd: "/Users/dev/code/kit")) == .swift)
        // No marker: still a tool.
        #expect(c.classify(facts("/Users/dev/code/misc/bin/thing", ["thing"], cwd: "/Users/dev/code/misc")) == .tool)
    }

    @Test func installedToolsRunFromAWorkspaceStayTools() {
        let c = classifier(files: ["/Users/dev/code/api/go.mod"])
        #expect(c.classify(facts("/usr/bin/ssh", ["ssh", "-L", "5432:db:5432", "bastion"], cwd: "/Users/dev/code/api")) == .tool)
        #expect(c.classify(facts("/opt/homebrew/bin/kubectl", ["kubectl", "port-forward", "svc/api", "8080"], cwd: "/Users/dev/code/api")) == .tool)
        #expect(c.classify(facts("/Users/dev/go/bin/dlv", ["dlv", "debug"], cwd: "/Users/dev/code/api")) == .tool)
        #expect(c.classify(facts("/Users/dev/.cargo/bin/some-tool", ["some-tool"], cwd: "/Users/dev/code/api")) == .tool)
        // Native helpers that a package manager installed, in a workers-rs or Go repository that also has package.json.
        #expect(c.classify(facts("/Users/dev/code/api/node_modules/@esbuild/darwin-arm64/bin/esbuild", ["esbuild", "--service"],
                                 cwd: "/Users/dev/code/api")) == .tool)
        // Outside a workspace nothing is checked.
        #expect(c.classify(facts("/Users/dev/code/api/bin/api", ["api"], cwd: "/")) == .tool)
    }

    @Test func buildFolderFastPathsStillWin() {
        let c = classifier()
        #expect(c.classify(facts("/private/var/folders/x/T/go-build123/b001/exe/main", ["main"])) == .go)
        #expect(c.classify(facts("/Users/dev/code/api/target/debug/api", ["api"])) == .rust)
        #expect(c.classify(facts("/Users/dev/code/kit/.build/debug/Server", ["Server"])) == .swift)
    }
}

@Suite("Local hosts")
struct LocalHostTests {
    private let mine = { ["192.168.1.24", "10.0.0.5"] }

    @Test func loopbackIsLocal() {
        #expect(Probe.isLocal("localhost", ownAddresses: mine))
        #expect(Probe.isLocal("127.0.0.1", ownAddresses: mine))
        #expect(Probe.isLocal("[::1]", ownAddresses: mine))
    }

    @Test func thisMacsOwnAddressesAreLocal() {
        #expect(Probe.isLocal("192.168.1.24", ownAddresses: mine))
        #expect(Probe.isLocal("10.0.0.5", ownAddresses: mine))
    }

    @Test func otherHostsAreNot() {
        #expect(!Probe.isLocal("192.168.1.25", ownAddresses: mine))  // Another machine on the same network.
        #expect(!Probe.isLocal("8.8.8.8", ownAddresses: mine))
        #expect(!Probe.isLocal("example.com", ownAddresses: mine))
        #expect(!Probe.isLocal("192.168.1.24.evil.test", ownAddresses: mine))
    }

    @Test func realInterfacesIncludeTheLANAddress() {
        if let lan = Network.lanAddress() {
            #expect(Network.localAddresses().contains(lan))
            #expect(Probe.isLocal(lan))
        }
    }
}
