import SwiftUI
import VibeKitCore

struct ServerRow: View {
    let server: Server
    let store: ServerStore
    let isSelected: Bool
    let isExpanded: Bool
    let onHover: () -> Void
    let onToggleDetails: () -> Void
    let onShowLogs: (Server) -> Void

    private var pending: Pending? { store.pending[server.id] }
    private var page: PageInfo? { store.pages[server.id] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                port
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    metaLine
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture { primaryAction() }

            if isExpanded {
                ServerDetail(server: server, store: store, page: page, onShowLogs: { onShowLogs(server) })
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.06 : (isSelected ? 0.075 : 0)))
        )
        // The open row gets a thin bar in its framework's color, tying the details to their server.
        .overlay(alignment: .leading) {
            if isExpanded {
                Capsule().fill(server.framework.tint.opacity(0.7)).frame(width: 2.5).padding(.vertical, 14).padding(.leading, 1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .opacity(pending == .stopping ? 0.4 : 1)
        .animation(.easeOut(duration: 0.15), value: pending)
        .onHover { if $0 { onHover() } }
        .contextMenu { ServerMenu(server: server, store: store, onShowLogs: onShowLogs) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.title), \(server.framework.name), port \(server.primaryPort)")
        .accessibilityValue(accessibilityState)
        .accessibilityAction(named: "Open") { primaryAction() }
        .accessibilityAction(named: "Copy URL") { store.copyURL(server) }
        .accessibilityAction(named: "Restart") { store.restart(server) }
        .accessibilityAction(named: "Stop") { store.stop(server) }
        .accessibilityAction(named: isExpanded ? "Hide details" : "Show details") { onToggleDetails() }
    }

    /// What the light and tags say, for VoiceOver.
    private var accessibilityState: String {
        if let pending { return pending == .restarting ? "Restarting" : pending == .starting ? "Starting" : "Stopping" }
        var parts = [lightHelp.isEmpty ? "Running" : lightHelp]
        if server.project?.worktree != nil { parts.append("worktree") }
        if server.ports.contains(where: { store.sharedPorts.contains($0.port) }) { parts.append("shared port") }
        if server.isExposed && server.category == .dev { parts.append("on the local network") }
        return parts.joined(separator: ", ")
    }

    // MARK: Parts

    private var port: some View {
        HStack(spacing: 6) {
            StatusLight(state: light, diameter: 7, announcesReady: isYoung).sized()
            Text(verbatim: "\(server.primaryPort)")
                .font(Theme.portFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: Theme.portColumn, alignment: .leading)
        // The light is too small to hover, so the whole column explains it.
        .contentShape(Rectangle())
        .help(lightHelp)
    }

    private var titleLine: some View {
        HStack(spacing: 5) {
            Text(server.title)
                .font(Theme.titleFont)
                .lineLimit(1)
                .truncationMode(.tail)
            if let worktree = server.project?.worktree {
                Tag(text: "worktree", help: "Linked worktree \(worktree)", tint: Theme.violet)
            }
            if let shared = server.ports.first(where: { store.sharedPorts.contains($0.port) }) {
                Tag(text: "shared port", help: "Another server also listens on port \(shared.port). localhost:\(shared.port) may reach either one, depending on IPv4 or IPv6.",
                    tint: Theme.warning)
            }
            if server.isExposed && server.category == .dev {
                Tag(text: "LAN", help: "Reachable from other devices on your network", tint: Theme.cyan)
            }
        }
    }

    /// Framework, then where it runs, then uptime. When space is short the place drops to the branch, then the
    /// subfolder. After that a selected row, whose action buttons take the room, leaves the place out rather than
    /// show a fragment like "j…in"; other rows truncate it in the middle.
    @ViewBuilder
    private var metaLine: some View {
        let places = placeOptions
        if places.isEmpty {
            meta(place: nil)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(places, id: \.self) { meta(place: $0) }
                meta(place: isSelected || isExpanded ? nil : places[0])
            }
        }
    }

    private func meta(place: String?) -> some View {
        HStack(spacing: 4) {
            if server.title != server.framework.name {
                Text(server.framework.name)
                    .foregroundStyle(server.framework.tint)
                    .fontWeight(.medium)
                    .layoutPriority(2)
                Text("·").foregroundStyle(.tertiary).layoutPriority(2)
            }
            if let place {
                Text(place).foregroundStyle(.secondary).truncationMode(.middle)
                Text("·").foregroundStyle(.tertiary).layoutPriority(2)
            }
            Text(Format.uptime(since: server.startDate))
                .foregroundStyle(.secondary)
                .layoutPriority(2)
                .help("Started \(server.startDate.formatted(date: .abbreviated, time: .shortened))")
        }
        .font(Theme.metaFont)
        .lineLimit(1)
    }

    /// Ways to say where the server runs, longest first.
    private var placeOptions: [String] {
        switch server.category {
        case .dev:
            let subpath = server.project?.subpath, branch = server.project?.branch
            if let subpath, let branch { return ["\(subpath) · \(branch)", branch, subpath] }
            return [subpath ?? branch].compactMap { $0 }
        case .database, .service:
            return [server.detail.map { $0.hasPrefix("~") || $0.hasPrefix("/") ? Format.path(($0 as NSString).deletingLastPathComponent) : $0 }]
                .compactMap { $0 }
        case .other:
            return server.processName == server.title ? [] : [server.processName]
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let pending {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(pending == .restarting ? "Restarting" : "Stopping")
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)
            }
        } else if isSelected || isExpanded {
            HStack(spacing: 2) {
                if server.localURL != nil {
                    IconButton(symbol: "doc.on.doc", help: server.framework.urlScheme == nil ? "Copy URL" : "Copy connection URL") {
                        store.copyURL(server)
                    }
                }
                if server.launch != nil {
                    IconButton(symbol: "arrow.clockwise", help: "Restart") { store.restart(server) }
                }
                IconButton(symbol: "stop.fill", help: "Stop", role: .destructive) { store.stop(server) }
                IconButton(symbol: "chevron.down", help: isExpanded ? "Hide details" : "Show details") { onToggleDetails() }
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .transition(.opacity)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Sparkline(values: store.history[server.id] ?? [], tint: server.framework.tint)
                    .frame(width: 52, height: 15)
                HStack(spacing: 0) {
                    // CPU turns amber, then red, when a server runs hot.
                    Text(Format.cpu(server.cpu))
                        .foregroundStyle(Theme.heat(server.cpu).map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                    Text(" · \(Format.memory(server.memory))")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 9.5, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
            }
            .help(usageHelp)
        }
    }

    private var light: LightState { store.light(for: server) }

    private var lightHelp: String {
        switch light {
        case .up: "Running"
        case .busy: "Busy: using \(Format.cpu(server.cpu)) CPU"
        case .waiting: "Listening, waiting for its first response"
        case .silent: "Listening, but not answering HTTP requests"
        case .failing: "Answering with server errors (\(page?.status ?? 500))"
        case .neutral: "Not a dev server"
        case .stopped, .crashed: ""
        }
    }

    /// Servers that started in the last few minutes flash once when they become ready.
    private var isYoung: Bool { Date().timeIntervalSince(server.startDate) < 180 }

    private var usageHelp: String {
        let peak = (store.history[server.id] ?? []).max() ?? server.cpu
        var text = "CPU \(Format.cpu(server.cpu)) now, peak \(Format.cpu(peak)) recently. \(Format.memory(server.memory))"
        if server.processCount > 1 { text += " across \(server.processCount) processes" }
        return text + "."
    }

    private func primaryAction() {
        switch server.category {
        case .dev where server.framework.speaksHTTP:
            store.open(server)
        case .database where server.localURL != nil:
            store.copyURL(server)
        default:
            onToggleDetails()
        }
    }
}

struct Tag: View {
    let text: String
    var help: String?
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.08)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.75))
            .help(help ?? text)
            .fixedSize()
    }
}

/// The right-click menu for a server. Every action in the panel is also here.
struct ServerMenu: View {
    let server: Server
    let store: ServerStore
    let onShowLogs: (Server) -> Void

    var body: some View {
        if server.category == .dev && server.framework.speaksHTTP {
            Button("Open in Browser") { store.open(server) }
        }
        if let url = store.url(for: server) {
            Button(server.framework.urlScheme == nil ? "Copy URL" : "Copy Connection URL") { store.copy(url.absoluteString) }
        }
        if let network = store.networkURL(for: server) {
            Button("Copy Network URL") { store.copy(network.absoluteString) }
        }
        Divider()
        if server.directory != nil || server.project != nil {
            if let editor = ExternalApp.resolve(store.settings.editorID, in: ExternalApp.editors) {
                Button("Open in \(editor.name)") { store.openInEditor(server) }
            }
            if let terminal = ExternalApp.resolve(store.settings.terminalID, in: ExternalApp.terminals) {
                Button("Open in \(terminal.name)") { store.openInTerminal(server) }
            }
            Button("Reveal in Finder") { store.reveal(server) }
        }
        if store.logURL(for: server) != nil {
            Button("Show Logs") { onShowLogs(server) }
        }
        Divider()
        if server.launch != nil {
            Button("Restart") { store.restart(server) }
        }
        Button("Stop") { store.stop(server) }
        Button("Force Quit") { store.forceQuit(server) }
        Divider()
        Button("Copy Command") { store.copy(server.copyableCommand, label: "command") }
        Button("Copy PID \(server.pid)") { store.copy("\(server.pid)") }
    }
}
