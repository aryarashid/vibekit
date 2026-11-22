import SwiftUI
import VibeKitCore

struct SettingsPage: View {
    let store: ServerStore
    let prompts: PromptStore
    let back: () -> Void
    let onHeightChange: (CGFloat) -> Void

    private var settings: Settings { store.settings }
    private var updater: Updater { Updater.shared }
    @State private var pasteAccess = PromptStore.canPaste
    @State private var cliStatus: CLIInstaller.Status = .notInstalled
    @State private var cliError: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            PageHeader(title: "Settings", back: back) { EmptyView() }
            Divider().opacity(0.6)
            MeasuredScroll(onHeight: { onHeightChange($0 + 47) }) {
                VStack(alignment: .leading, spacing: 12) {
                    group("General") {
                        toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                        toggle("Show server count in the menu bar", isOn: $settings.showCountInMenuBar)
                        toggle("Show other listeners (apps and system services)", isOn: $settings.showOtherListeners)
                        toggle("Open Servers from anywhere", keys: "⌃⌥⌘V", isOn: $settings.hotKeyEnabled)
                        toggle("Open Prompts from anywhere", keys: "⌃⌥⌘P", isOn: $settings.promptsHotKeyEnabled)
                        if !settings.takenShortcuts.isEmpty {
                            let keys = settings.takenShortcuts.sorted().reversed().joined(separator: " and ")
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                Text("Another app already uses \(keys), so it does nothing here. The menu bar icon still works.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(Theme.metaFont)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }
                    if LidSleep.isSupported {
                        group("Lid sleep") { lidSleepRows }
                    }
                    group("Prompts") {
                        toggle("Paste into the front app when picking a prompt", isOn: Binding(
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
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                        if settings.pasteOnUse {
                            toggle("Restore clipboard after pasting", isOn: $settings.restoreClipboardAfterPaste)
                        }
                        HStack {
                            Text("Prompts file").font(.system(size: 12.5))
                            Text("prompts.json").font(Theme.monoSmall).foregroundStyle(Theme.readout)
                            Spacer()
                            Button("Show in Finder") { prompts.revealFile() }
                                .controlSize(.small)
                                .help("A readable JSON file. Edit it by hand or keep it in your dotfiles; Vibe Kit picks up changes.")
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                    }
                    group("Open projects with") {
                        picker("Editor", selection: $settings.editorID, apps: ExternalApp.editors)
                        picker("Terminal", selection: $settings.terminalID, apps: ExternalApp.terminals)
                    }
                    group("Command line") { cliRows }
                    group("Updates") { updateRows }
                    group("Keyboard shortcuts") {
                        shortcut("↑  ↓", "Move between servers")
                        shortcut("↩", "Open in browser, or start a stopped server")
                        shortcut("→", "Show details")
                        shortcut("⌘1–⌘9", "Open server 1 to 9 in the list")
                        shortcut("⌘R", "Restart")
                        shortcut("⌘⌫", "Stop")
                        shortcut("⇧⌘C", "Copy URL")
                        shortcut("⌘O  ⌘T", "Open in editor or terminal")
                        Divider().padding(.horizontal, 10).padding(.vertical, 4)
                        shortcut("Tab", "Switch between servers and prompts")
                        shortcut("↩  ⌘1–⌘9", "Use a prompt")
                        shortcut("⌘N  ⌘E", "New or edit prompt")
                        shortcut("⌘P", "Pin or unpin a prompt")
                    }
                    HStack(spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 30, height: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Vibe Kit \(version)").font(.system(size: 12, weight: .semibold))
                            Text("Open source under the MIT license.").font(Theme.metaFont).foregroundStyle(.secondary)
                        }
                        Spacer()
                        PillButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
        .onAppear {
            if !store.isDemo {
                settings.refreshLaunchAtLogin()
                settings.refreshLidStayAwake()
                cliStatus = CLIInstaller().status()
            }
            pasteAccess = PromptStore.canPaste
        }
    }

    @ViewBuilder private var lidSleepRows: some View {
        toggle("Stay awake after closing the lid", isOn: Binding(
            get: { settings.lidStayAwake },
            set: { on in Task { await settings.setLidStayAwake(on) } }))
            .disabled(settings.lidHelperBusy)
        HStack {
            Text("Then sleep after").font(.system(size: 12.5))
            Spacer()
            Picker("Then sleep after", selection: Binding(get: { settings.lidSleepMinutes }, set: { settings.setLidSleepMinutes($0) })) {
                ForEach(LidSleep.choices, id: \.self) { minutes in
                    Text(minutes == 60 ? "1 hour" : "\(minutes) minutes").tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .disabled(settings.lidHelperBusy)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        Group {
            if let error = settings.lidHelperError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    lidNotice(error, warning: true)
                    Spacer(minLength: 0)
                    // The way out of a helper that cannot be switched off.
                    if settings.lidHelperInstalled { removeButton }
                }
            } else if settings.lidHelperBusy {
                lidNotice("Installing the helper…")
            } else if settings.lidHelperPaused {
                lidNotice("Paused. The helper is not running, or the copy of Vibe Kit it was set up for is gone. Switch this on to set it up again.", warning: true)
            } else if settings.lidHelperOutdatedActive {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    lidNotice("On, using the helper from an earlier version of Vibe Kit.", warning: true)
                    Spacer(minLength: 0)
                    Button("Update") { Task { await settings.updateLidHelper() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.violet)
                        .fontWeight(.semibold)
                        .disabled(settings.lidHelperBusy)
                }
            } else if settings.lidStayAwake {
                lidNotice("The screen turns off when the lid closes, and work keeps running until the time is up. It sleeps right away at 15% battery or less (open or closed), and stays awake while docked to a display.")
            } else if settings.lidHelperInstalled {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Off. The helper is installed but does nothing.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    removeButton
                }
            } else {
                lidNotice("Turning this on installs a small helper and asks for your password once.")
            }
        }
        .font(Theme.metaFont)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var cliRows: some View {
        let installer = CLIInstaller()
        let displayPath = store.isDemo ? "~/.local/bin/vibekit" : Format.path(installer.directory.appendingPathComponent("vibekit").path)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("vibekit CLI").font(.system(size: 12.5))
                    Text(displayPath)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.readout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let cliError {
                    Text(cliError)
                        .font(Theme.metaFont)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    switch cliStatus {
                    case .installed:
                        Text("Installed. Supports --list --json, port, stop, restart, logs, and --mcp.")
                            .font(Theme.metaFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .notInstalled:
                        Text("Adds a symlink so scripts and coding agents can run vibekit --list --json or vibekit --mcp.")
                            .font(Theme.metaFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .conflict(let url):
                        Text("\(Format.path(url.path)) already exists and belongs to another tool.")
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            switch cliStatus {
            case .notInstalled:
                Button("Install") {
                    guard !store.isDemo else { return }
                    cliError = nil
                    do { cliStatus = try installer.install() }
                    catch { cliError = error.localizedDescription }
                }
                .controlSize(.small)
            case .installed:
                Button("Remove") {
                    guard !store.isDemo else { return }
                    cliError = nil
                    do { cliStatus = try installer.uninstall() }
                    catch { cliError = error.localizedDescription }
                }
                .controlSize(.small)
            case .conflict:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var updateRows: some View {
        toggle("Check for updates automatically", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }))
            .disabled(!updater.isAvailable)
        toggle("Download and install automatically", isOn: Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.setAutomaticallyDownloadsUpdates($0) }))
            .disabled(!updater.isAvailable || !updater.automaticallyChecksForUpdates)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Version \(updater.versionDescription)").font(.system(size: 12.5))
                Text(updateStatus)
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Check Now") { updater.checkForUpdates() }
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var updateStatus: String {
        if let note = updater.statusNote { return note }
        guard let date = updater.lastUpdateCheckDate else { return "Not checked yet." }
        return "Last checked \(date.formatted(.relative(presentation: .named)))."
    }

    private var removeButton: some View {
        Button("Remove") { Task { await settings.removeLidHelper() } }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.violet)
            .fontWeight(.semibold)
            .disabled(settings.lidHelperBusy)
    }

    private func lidNotice(_ text: String, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.readout)
                .padding(.leading, 9)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false))
        }
    }

    private func toggle(_ title: String, keys: String? = nil, isOn: Binding<Bool>) -> some View {
        SettingsToggleRow(title: title, keys: keys, isOn: isOn)
    }

    private func picker(_ title: String, selection: Binding<String?>, apps: [ExternalApp]) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            if apps.isEmpty {
                Text("None found").font(Theme.metaFont).foregroundStyle(.secondary)
            } else {
                Picker(title, selection: Binding(get: { ExternalApp.resolve(selection.wrappedValue, in: apps)?.id }, set: { selection.wrappedValue = $0 })) {
                    ForEach(apps) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
    }

    /// `keys` holds one or more key combinations, two spaces apart. Each one is drawn as a key cap.
    private func shortcut(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 4) {
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ForEach(Array(keys.components(separatedBy: "  ").enumerated()), id: \.offset) { _, key in
                KeyCap(key)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 25)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let keys: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // Switches line up in one column on the right, like System Settings.
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            if let keys { KeyCap(keys).accessibilityHidden(true) }
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(PanelSwitch())
                .accessibilityLabel([title, keys].compactMap { $0 }.joined(separator: ", "))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 31)
    }
}
