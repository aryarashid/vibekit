import Foundation
import Testing
@testable import VibeKitCore

private typealias A = PortScanner.Ancestor

private func shell(_ pid: pid_t, _ name: String = "zsh") -> A { A(pid: pid, executable: "/bin/\(name)", argv: ["-\(name)"]) }
private func app(_ pid: pid_t, _ bundle: String, _ binary: String) -> A {
    A(pid: pid, executable: "/Applications/\(bundle).app/Contents/MacOS/\(binary)", argv: [binary])
}
private let own: pid_t = 999
private func launcher(_ ancestors: [A]) -> String? { PortScanner.identifyLauncher(ancestors: ancestors, ownPid: own) }

@Suite("Launchers")
struct LauncherTests {
    @Test func claudeCodeBehindAShell() {
        // The native installer's binary is named after its version; argv[0] still says claude.
        let claude = A(pid: 20, executable: "/Users/dev/.local/share/claude/versions/2.1.3", argv: ["/Users/dev/.local/bin/claude", "--model", "x"])
        #expect(launcher([shell(10), claude, app(30, "Ghostty", "ghostty"), A(pid: 1, executable: "/sbin/launchd", argv: [])]) == "Claude Code")
    }

    @Test func claudeCodeFromNpm() {
        let claude = A(pid: 20, executable: "/opt/homebrew/bin/node",
                       argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"])
        #expect(launcher([shell(10), claude]) == "Claude Code")
    }

    @Test func codexAsNodeScriptAndNativeBinary() {
        let script = A(pid: 20, executable: "/Users/dev/.nvm/versions/node/v22/bin/node",
                       argv: ["node", "/Users/dev/.nvm/versions/node/v22/bin/codex"])
        #expect(launcher([shell(10), script]) == "Codex")
        let native = A(pid: 21, executable: "/Users/dev/.nvm/versions/node/v22/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex",
                       argv: ["codex", "exec"])
        #expect(launcher([shell(10), native, script]) == "Codex")
    }

    @Test func terminalsAndEditors() {
        let login = A(pid: 11, executable: "/usr/bin/login", argv: ["login", "-pfl", "dev"])
        #expect(launcher([shell(10), login, app(30, "Ghostty", "ghostty")]) == "Ghostty")
        #expect(launcher([shell(10), login, app(30, "Utilities/Terminal", "Terminal")]) == "Terminal")
        #expect(launcher([shell(10), login, app(30, "iTerm", "iTerm2")]) == "iTerm")
        #expect(launcher([shell(10), app(30, "Warp", "stable")]) == "Warp")
        #expect(launcher([shell(10), app(30, "kitty", "kitty")]) == "kitty")
        #expect(launcher([shell(10), app(30, "WezTerm", "wezterm-gui")]) == "WezTerm")
        #expect(launcher([shell(10), app(30, "Alacritty", "alacritty")]) == "Alacritty")
        #expect(launcher([shell(10), app(30, "Zed", "zed")]) == "Zed")
        let codeHelper = A(pid: 30, executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                           argv: ["Code Helper (Plugin)"])
        #expect(launcher([shell(10), codeHelper]) == "VS Code")
        let cursorHelper = A(pid: 30, executable: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
                             argv: ["Cursor Helper (Plugin)"])
        #expect(launcher([shell(10), cursorHelper]) == "Cursor")
        #expect(launcher([shell(10), app(30, "Antigravity", "Electron")]) == "Antigravity")
    }

    @Test func tmuxServer() {
        let tmux = A(pid: 40, executable: "/opt/homebrew/bin/tmux", argv: ["tmux"])
        #expect(launcher([shell(10), tmux, A(pid: 1, executable: "/sbin/launchd", argv: [])]) == "tmux")
    }

    @Test func nearestRecognisedLauncherWins() {
        // Claude Code running inside VS Code's terminal is Claude Code.
        let claude = A(pid: 20, executable: "/Users/dev/.local/bin/claude", argv: ["claude"])
        let codeHelper = A(pid: 30, executable: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", argv: ["Electron"])
        #expect(launcher([shell(10), claude, shell(25), codeHelper]) == "Claude Code")
    }

    @Test func vibeKitAndLaunchd() {
        #expect(launcher([A(pid: own, executable: "", argv: [])]) == "Vibe Kit")
        #expect(launcher([shell(10), A(pid: own, executable: "", argv: [])]) == "Vibe Kit")
        #expect(launcher([A(pid: 1, executable: "/sbin/launchd", argv: ["launchd"])]) == "launchd")
        // launchd far above an unknown supervisor did not start the server itself.
        let supervisor = A(pid: 50, executable: "/usr/bin/python3", argv: ["python3", "supervisor.py"])
        #expect(launcher([supervisor, A(pid: 1, executable: "/sbin/launchd", argv: [])]) == nil)
    }

    @Test func unknownAppFallsBackToItsBundleName() {
        let t3 = A(pid: 30, executable: "/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)", argv: ["T3 Code (Beta)"])
        #expect(launcher([shell(10), t3, A(pid: 1, executable: "/sbin/launchd", argv: [])]) == "T3 Code (Beta)")
        #expect(launcher([]) == nil)
    }
}

@Suite("Runner detection")
struct RunnerTests {
    @Test func nodeAndBunWatchModeAreRunners() {
        #expect(PortScanner.isWatchMode(["node", "--watch", "server.js"]))
        #expect(PortScanner.isWatchMode(["node", "--watch-path=src", "server.js"]))
        #expect(PortScanner.isWatchMode(["node", "--watch-path", "src", "server.js"]))
        #expect(PortScanner.isWatchMode(["bun", "--watch", "run", "dev"]))
        #expect(PortScanner.isWatchMode(["bun", "run", "--watch", "src/index.ts"]))
    }

    @Test func watchFlagForTheScriptDoesNotCount() {
        #expect(!PortScanner.isWatchMode(["node", "server.js", "--watch"]))
        #expect(!PortScanner.isWatchMode(["node", "server.js"]))
        #expect(!PortScanner.isWatchMode(["node", "--watch-preserve-output-only-is-not-a-flag", "x.js"]))
    }
}
