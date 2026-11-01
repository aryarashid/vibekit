import SwiftUI
import VibeKitCore

/// The expanded view of a row: where it lives, how it was started, and what you can open it in.
struct ServerDetail: View {
    let server: Server
    let store: ServerStore
    let page: PageInfo?
    let onShowLogs: () -> Void

    @State private var showQR = false

    private var editor: ExternalApp? { ExternalApp.resolve(store.settings.editorID, in: ExternalApp.editors) }
    private var terminal: ExternalApp? { ExternalApp.resolve(store.settings.terminalID, in: ExternalApp.terminals) }
    private var folder: String? { server.project?.root ?? server.directory }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let page {
                HStack(spacing: 6) {
                    Text(page.title ?? "No page title")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(page.title == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StatusChip(status: page.status)
                }
            }

            if let url = server.localURL {
                line("globe", url.absoluteString, mono: true) {
                    IconButton(symbol: "doc.on.doc", help: "Copy", size: 22) { store.copy(url.absoluteString) }
                }
            }
            if let network = server.networkURL(host: store.lanAddress) {
                line("wifi", network.absoluteString, mono: true) {
                    IconButton(symbol: "qrcode", help: showQR ? "Hide QR code" : "Show QR code to open on a phone", size: 22) {
                        withAnimation(.easeOut(duration: 0.18)) { showQR.toggle() }
                    }
                    IconButton(symbol: "doc.on.doc", help: "Copy", size: 22) { store.copy(network.absoluteString) }
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
                line("folder", Format.path(folder) + (server.project?.branch.map { "  ⎇ \($0)" } ?? "")) {
                    IconButton(symbol: "arrow.up.right", help: "Reveal in Finder", size: 22) { store.reveal(server) }
                }
            }
            line("terminal", server.command, mono: true, lines: 3) {
                IconButton(symbol: "doc.on.doc", help: "Copy command", size: 22) { store.copy(server.command, label: "command") }
            }
            line("cpu", processSummary) { EmptyView() }

            HStack(spacing: 6) {
                if folder != nil {
                    if let editor {
                        PillButton(title: editor.name, image: editor.icon) { store.openInEditor(server) }
                    }
                    if let terminal {
                        PillButton(title: terminal.name, image: terminal.icon) { store.openInTerminal(server) }
                    }
                }
                if store.logURL(for: server) != nil {
                    PillButton(title: "Logs", symbol: "text.alignleft", action: onShowLogs)
                }
                Spacer(minLength: 0)
                PillButton(title: "Force Quit", role: .destructive) { store.forceQuit(server) }
            }
            .padding(.top, 3)
        }
        .padding(.leading, 10 + Theme.portColumn + 10)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
    }

    private var processSummary: String {
        var parts = ["PID \(server.pid)"]
        if server.processCount > 1 { parts.append("\(server.processCount) processes") }
        if server.memory > 0 { parts.append(Format.memory(server.memory)) }
        if server.ports.count > 1 { parts.append("ports " + server.ports.map { "\($0.port)" }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func line<Trailing: View>(_ symbol: String, _ text: String, mono: Bool = false, lines: Int = 1,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(text)
                .font(mono ? Theme.monoSmall : Theme.metaFont)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            HStack(spacing: 0, content: trailing)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
        }
        .frame(minHeight: 22)
    }
}

struct StatusChip: View {
    let status: Int

    var body: some View {
        let ok = status < 400
        let color = status >= 500 ? Theme.danger : (ok ? Theme.live : Theme.warning)
        Text(verbatim: "\(status)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
            .help(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)
    }
}
