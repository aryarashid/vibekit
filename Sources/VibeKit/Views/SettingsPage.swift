import SwiftUI
import VibeKitCore

struct SettingsPage: View {
    let store: ServerStore
    let prompts: PromptStore
    let back: () -> Void
    let onHeightChange: (CGFloat) -> Void

    private var settings: Settings { store.settings }
    @State private var pasteAccess = PromptStore.canPaste

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            PageHeader(title: "Settings", back: back) { EmptyView() }
            Divider().opacity(0.6)
            MeasuredScroll(onHeight: { onHeightChange($0 + 47) }) {
                VStack(alignment: .leading, spacing: 0) {
                    group("General") {
                        toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                        toggle("Show server count in the menu bar", isOn: $settings.showCountInMenuBar)
                        toggle("Show other listeners (apps and system services)", isOn: $settings.showOtherListeners)
                        toggle("Open with ⌃⌥⌘V from anywhere", isOn: $settings.hotKeyEnabled)
                        toggle("Open Prompts with ⌃⌥⌘P from anywhere", isOn: $settings.promptsHotKeyEnabled)
                    }
                    group("Prompts") {
                        toggle("Paste into the app in front when you pick a prompt", isOn: Binding(
                            get: { settings.pasteOnUse },
                            set: { on in
                                settings.pasteOnUse = on
                                if on && !PromptStore.canPaste { PromptStore.requestPasteAccess() }
                                pasteAccess = PromptStore.canPaste
                            }))
                        if settings.pasteOnUse && !pasteAccess {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                Text("Allow Vibe Kit under Privacy & Security › Accessibility. Until then, picking a prompt copies it.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button("Open") { openAccessibilitySettings() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.violet)
                                    .fontWeight(.semibold)
                            }
                            .font(Theme.metaFont)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                        HStack {
                            Text("Prompts file").font(.system(size: 12.5))
                            Text("prompts.json").font(Theme.monoSmall).foregroundStyle(.tertiary)
                            Spacer()
                            Button("Show in Finder") { prompts.revealFile() }
                                .controlSize(.small)
                                .help("A readable JSON file. Edit it by hand or keep it in your dotfiles; Vibe Kit picks up changes.")
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                    }
                    group("Open projects with") {
                        picker("Editor", selection: $settings.editorID, apps: ExternalApp.editors)
                        picker("Terminal", selection: $settings.terminalID, apps: ExternalApp.terminals)
                    }
                    group("Keyboard") {
                        shortcut("↑ ↓", "Move between servers")
                        shortcut("↩", "Open in browser, or start a stopped server")
                        shortcut("→", "Show details")
                        shortcut("⌘1–⌘9", "Open server 1 to 9 in the list")
                        shortcut("⌘R", "Restart")
                        shortcut("⌘⌫", "Stop")
                        shortcut("⇧⌘C", "Copy URL")
                        shortcut("⌘O  ⌘T", "Open in editor or terminal")
                        shortcut("Tab", "Switch between servers and prompts")
                        shortcut("↩  ⌘1–⌘9", "Use a prompt")
                        shortcut("⌘N  ⌘E", "New or edit prompt")
                        shortcut("⌘P", "Pin or unpin a prompt")
                    }
                    HStack(spacing: 10) {
                        VibeMark(live: true, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Vibe Kit \(version)").font(.system(size: 12, weight: .semibold))
                            Text("Open source under the MIT license.").font(Theme.metaFont).foregroundStyle(.secondary)
                        }
                        Spacer()
                        PillButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(Theme.sectionFont)
                .kerning(0.7)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
            content()
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        // Switches line up in one column on the right, like System Settings.
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
    }

    private func picker(_ title: String, selection: Binding<String?>, apps: [ExternalApp]) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            if apps.isEmpty {
                Text("None found").font(Theme.metaFont).foregroundStyle(.secondary)
            } else {
                Picker(title, selection: Binding(get: { selection.wrappedValue ?? apps.first?.id }, set: { selection.wrappedValue = $0 })) {
                    ForEach(apps) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private func shortcut(_ keys: String, _ description: String) -> some View {
        HStack {
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(keys).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 22)
    }
}
