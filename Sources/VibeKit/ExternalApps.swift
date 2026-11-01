import AppKit

/// Editors and terminals that can open a project folder.
struct ExternalApp: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    static let editorIDs: [(String, String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "VS Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("dev.zed.Zed", "Zed"),
        ("dev.zed.Zed-Preview", "Zed Preview"),
        ("com.exafunction.windsurf", "Windsurf"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.panic.Nova", "Nova"),
        ("com.jetbrains.WebStorm", "WebStorm"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.pycharm", "PyCharm"),
        ("com.jetbrains.goland", "GoLand"),
        ("com.jetbrains.rubymine", "RubyMine"),
        ("com.apple.dt.Xcode", "Xcode"),
    ]

    static let terminalIDs: [(String, String)] = [
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.googlecode.iterm2", "iTerm"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("com.apple.Terminal", "Terminal"),
    ]

    static func installed(_ ids: [(String, String)]) -> [ExternalApp] {
        ids.compactMap { id, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { ExternalApp(id: id, name: name, url: $0) }
        }
    }

    /// Looked up once per launch; Launch Services queries are not free and apps rarely appear mid-session.
    @MainActor static let editors: [ExternalApp] = installed(editorIDs)
    @MainActor static let terminals: [ExternalApp] = installed(terminalIDs)

    /// The chosen app if it is still installed, otherwise the first one found.
    static func resolve(_ preferred: String?, in apps: [ExternalApp]) -> ExternalApp? {
        apps.first { $0.id == preferred } ?? apps.first
    }

    func open(_ folder: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: url, configuration: config)
    }
}
