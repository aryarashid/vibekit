import SwiftUI
import VibeKitCore

/// The expanded view of a row: where it lives, how it was started, and what you can open it in.
struct ServerDetail: View {
    let server: Server
    let store: ServerStore
    let page: PageInfo?
    let onShowLogs: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showQR = false

    private var editor: ExternalApp? { ExternalApp.resolve(store.settings.editorID, in: ExternalApp.editors) }
    private var terminal: ExternalApp? { ExternalApp.resolve(store.settings.terminalID, in: ExternalApp.terminals) }
    private var folder: String? { server.project?.folder ?? server.directory }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.bottom, 3)
            if let page {
                HStack(spacing: 6) {
                    Text(page.title ?? "No page title")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(page.title == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StatusChip(status: page.status, onRecheck: { store.reprobe(server) })
                }
            }

            if let url = store.url(for: server) {
                line("globe", url.absoluteString, mono: true) {
                    IconButton(symbol: "doc.on.doc", help: "Copy URL", size: 22) { store.copy(url.absoluteString) }
                }
            }
            if server.ports.count > 1 {
                portsRow
            }
            if let network = store.networkURL(for: server) {
                line("wifi", network.absoluteString, mono: true) {
                    IconButton(symbol: "qrcode", help: showQR ? "Hide QR code" : "Show QR code to open on a phone", size: 22) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showQR.toggle() }
                    }
                    IconButton(symbol: "doc.on.doc", help: "Copy network URL", size: 22) { store.copy(network.absoluteString) }
                }
                if showQR {
                    HStack {
                        QRCodeView(text: network.absoluteString)
                        Text("Scan with your phone's camera. It must be on the same network.")
                            .font(Theme.metaFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }
            }
            if let folder {
                line("folder", Format.path(folder), branch: server.project?.branch) {
                    IconButton(symbol: "arrow.up.right", help: "Reveal in Finder", size: 22) { store.reveal(server); onClose() }
                }
            }
            line("terminal", server.command, mono: true, lines: 3) {
                IconButton(symbol: "doc.on.doc", help: "Copy command", size: 22) { store.copy(server.copyableCommand, label: "command") }
            }
            if let container = server.containerName {
                let label = server.launcher.map { "\(container) · \($0)" } ?? container
                line("shippingbox", label) { EmptyView() }
            } else if let launcher = server.launcher {
                line("arrow.turn.down.right", "Started by \(launcher)") { EmptyView() }
            }
            line("cpu", processSummary) { EmptyView() }

            if hasBottomActions {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        projectActions
                        Spacer(minLength: 6)
                        if !server.isContainerControlled { forceQuit }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) { projectActions }
                        if !server.isContainerControlled { forceQuit }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var hasBottomActions: Bool {
        !server.isContainerControlled
            || (folder != nil && (editor != nil || terminal != nil))
            || store.logURL(for: server) != nil
    }

    private var forceQuit: some View {
        PillButton(title: "Force Quit", role: .destructive) { store.forceQuit(server) }
    }

    @ViewBuilder private var projectActions: some View {
        if folder != nil {
            if let editor {
                PillButton(title: editor.name, image: editor.icon) { store.openInEditor(server); onClose() }
            }
            if let terminal {
                PillButton(title: terminal.name, image: terminal.icon) { store.openInTerminal(server); onClose() }
            }
        }
        if store.logURL(for: server) != nil {
            PillButton(title: "Logs", symbol: "text.alignleft", action: onShowLogs)
        }
    }

    private var portsRow: some View {
        let bindings = uniquePorts
        return HStack(alignment: .center, spacing: 7) {
            Image(systemName: "network")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.readout)
                .frame(width: 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(bindings, id: \.port) { binding in
                        portChip(binding)
                    }
                }
            }
        }
        .frame(minHeight: 22)
    }

    private var uniquePorts: [PortBinding] {
        var seen: Set<UInt16> = []
        return server.ports.filter { seen.insert($0.port).inserted }
    }

    @ViewBuilder
    private func portChip(_ binding: PortBinding) -> some View {
        let targetURL = store.url(for: server, binding: binding)
        let opens = server.category != .other && (targetURL?.scheme == "http" || targetURL?.scheme == "https")
        let helpText: String = if opens, let targetURL {
            "Open \(targetURL.absoluteString)"
        } else if let targetURL {
            "Copy \(targetURL.absoluteString)"
        } else {
            "Copy port \(binding.port)"
        }
        Button {
            if opens {
                store.open(server, binding: binding)
                onClose()
            } else if let targetURL {
                store.copy(targetURL.absoluteString)
            } else {
                store.copy("\(binding.port)")
            }
        } label: {
            Text(verbatim: ":\(binding.port)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .frame(height: 20)
        }
        .buttonStyle(PanelButtonStyle(ink: .primary, hoverInk: .primary, tint: server.framework.tint, restingFill: 0.08))
        .help(helpText)
    }

    private var processSummary: String {
        var parts = [server.containerName != nil ? "Runtime PID \(server.pid)" : "PID \(server.pid)"]
        if server.processCount > 1 { parts.append("\(server.processCount) processes") }
        if server.memory > 0 { parts.append(Format.memory(server.memory)) }
        return parts.joined(separator: " · ")
    }

    private func line<Trailing: View>(_ symbol: String, _ text: String, mono: Bool = false, lines: Int = 1, branch: String? = nil,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.readout)
                .frame(width: 14)
            Text(text)
                .font(mono ? Theme.monoSmall : Theme.metaFont)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .truncationMode(.middle)
                .monospacedDigit()
                .textSelection(.enabled)
                .help(text)
            if let branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.readout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Git branch: \(branch)")
            }
            Spacer(minLength: 4)
            HStack(spacing: 0, content: trailing)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
        }
        .frame(minHeight: 22)
    }
}

struct StatusChip: View {
    let status: Int
    var onRecheck: (() -> Void)? = nil

    var body: some View {
        let ok = status < 400
        let color = status >= 500 ? Theme.danger : (ok ? Theme.live : Theme.warning)
        let chip = Text(verbatim: "\(status)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
        if let onRecheck {
            Button(action: onRecheck) { chip }
                .buttonStyle(.plain)
                .help("HTTP \(status) — Click to re-check")
                .accessibilityLabel("HTTP \(status), re-check status")
        } else {
            chip
                .help(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)
        }
    }
}
