import SwiftUI
import VibeKitCore

struct ServerRow: View {
    let server: Server
    let store: ServerStore
    let isSelected: Bool
    let isExpanded: Bool
    let onHover: () -> Void
    let onActivate: () -> Void
    let onToggleDetails: () -> Void
    let onShowLogs: (Server) -> Void
    let onClose: () -> Void

    private var pending: Pending? { store.pending[server.id] }
    private var page: PageInfo? { store.pages[server.id] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                port.padding(.trailing, Theme.rowGap)
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    metaLine
                }
                Spacer(minLength: 6)
                trailing.fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture(perform: onActivate)

            if isExpanded {
                ServerDetail(server: server, store: store, page: page, onShowLogs: { onShowLogs(server) }, onClose: onClose)
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
        .contextMenu { ServerMenu(server: server, store: store, onShowLogs: onShowLogs, onClose: onClose) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.title), \(server.framework.name), port \(server.primaryPort)")
        .accessibilityValue(accessibilityState)
        .accessibilityAction(named: primaryActionTitle, onActivate)
        .modifier(ServerAccessibilityActions(server: server, store: store, isExpanded: isExpanded, onToggleDetails: onToggleDetails))
    }

    private var primaryActionTitle: String {
        if server.opensInBrowser { return "Open in browser" }
        if server.framework.urlScheme != nil || (server.category == .database && server.localURL != nil) { return "Copy URL" }
        return isExpanded ? "Hide details" : "Show details"
    }

    private var isDirectoryDeleted: Bool {
        guard !store.isDemo, server.category == .dev, let dir = server.directory else { return false }
        return !FileManager.default.fileExists(atPath: dir)
    }

    private var worktreeTagText: String? {
        guard let project = server.project, project.worktree != nil else { return nil }
        let sameProjectCount = store.devServers.count { $0.project?.name == project.name }
        if sameProjectCount >= 2, let slug = project.worktreeSlug {
            return "wt: \(slug)"
        }
        return "worktree"
    }

    /// What the light and tags say, for VoiceOver.
    private var accessibilityState: String {
        if let pending { return pending == .restarting ? "Restarting" : pending == .starting ? "Starting" : "Stopping" }
        var parts = [lightHelp.isEmpty ? "Running" : lightHelp]
        if let wt = worktreeTagText { parts.append(wt) }
        if isDirectoryDeleted { parts.append("deleted directory") }
        if let shared = server.ports.first(where: { store.sharedPorts.contains($0.port) }) {
            parts.append(store.sharedPortLabel(for: server, binding: shared))
        }
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
        ViewThatFits(in: .horizontal) {
            title(compact: false)
            title(compact: true)
        }
        .help(server.title)
    }

    private func title(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Text(server.title)
                .font(Theme.titleFont)
                .lineLimit(1)
                .truncationMode(.tail)
            if let worktree = server.project?.worktree, let label = worktreeTagText {
                Tag(text: label, help: "Linked worktree \(worktree)", tint: Theme.violet, symbol: compact ? "arrow.triangle.branch" : nil)
            }
            if isDirectoryDeleted {
                Tag(text: "deleted dir",
                    help: "Working directory no longer exists on disk (\(Format.path(server.directory ?? ""))). This server is still running from a deleted folder or worktree.",
                    tint: Theme.warning, symbol: compact ? "folder.badge.questionmark" : nil)
            }
            if let shared = server.ports.first(where: { store.sharedPorts.contains($0.port) }) {
                let label = store.sharedPortLabel(for: server, binding: shared)
                let address = store.host(for: server, binding: shared)
                Tag(text: label, help: "Another server also listens on port \(shared.port). Opening uses \(address):\(shared.port) to reach this one.",
                    tint: Theme.warning, symbol: compact ? "square.on.square" : nil)
            }
            if server.isExposed && server.category == .dev {
                Tag(text: "LAN", help: "Reachable from other devices on your network", tint: Theme.cyan, symbol: compact ? "wifi" : nil)
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
                .monospacedDigit()
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
                        .foregroundStyle(Theme.heat(server.cpu).map(AnyShapeStyle.init) ?? AnyShapeStyle(Theme.readout))
                    if server.memory > 0 {
                        Text(" · \(Format.memory(server.memory))")
                            .foregroundStyle(Theme.readout)
                    }
                }
                .font(Theme.monoSmall)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            }
            .help(usageHelp)
        }
    }

    private var light: LightState { store.light(for: server) }

    private var lightHelp: String {
        switch light {
        case .up:
            store.settings.skippedHTTPChecks.contains(server.httpCheckKey) ? "Running (HTTP check skipped)" : "Running"
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
        var text = "CPU \(Format.cpu(server.cpu)) now, peak \(Format.cpu(peak)) recently"
        if server.memory > 0 { text += ". \(Format.memory(server.memory))" }
        if server.processCount > 1 { text += " across \(server.processCount) processes" }
        return text + "."
    }
}

private struct ServerAccessibilityActions: ViewModifier {
    let server: Server
    let store: ServerStore
    let isExpanded: Bool
    let onToggleDetails: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "Stop") { store.stop(server) }
            .accessibilityAction(named: isExpanded ? "Hide details" : "Show details", onToggleDetails)
            .modifier(OptionalAction(enabled: server.localURL != nil,
                                     name: server.framework.urlScheme == nil ? "Copy URL" : "Copy connection URL") {
                store.copyURL(server)
            })
            .modifier(OptionalAction(enabled: server.launch != nil, name: "Restart") {
                store.restart(server)
            })
    }
}

private struct OptionalAction: ViewModifier {
    let enabled: Bool
    let name: String
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

struct Tag: View {
    let text: String
    var help: String?
    var tint: Color = .secondary
    var symbol: String?

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).accessibilityLabel(text) }
            else { Text(text) }
        }
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
    let onClose: () -> Void

    var body: some View {
        if server.opensInBrowser {
            Button("Open in Browser") { store.open(server); onClose() }
        }
        if let url = store.url(for: server) {
            Button(server.framework.urlScheme == nil ? "Copy URL" : "Copy Connection URL") { store.copy(url.absoluteString) }
        }
        if let network = store.networkURL(for: server) {
            Button("Copy Network URL") { store.copy(network.absoluteString) }
        }
        if server.category == .dev && server.framework.speaksHTTP {
            let skipped = store.settings.skippedHTTPChecks.contains(server.httpCheckKey)
            Divider()
            Button("Re-check Status") { store.reprobe(server) }
            Button(skipped ? "Check HTTP Status" : "Skip HTTP Check") { store.toggleSkipHTTP(server) }
        }
        Divider()
        if server.directory != nil || server.project != nil {
            if let editor = ExternalApp.resolve(store.settings.editorID, in: ExternalApp.editors) {
                Button("Open in \(editor.name)") { store.openInEditor(server); onClose() }
            }
            if let terminal = ExternalApp.resolve(store.settings.terminalID, in: ExternalApp.terminals) {
                Button("Open in \(terminal.name)") { store.openInTerminal(server); onClose() }
            }
            Button("Reveal in Finder") { store.reveal(server); onClose() }
        }
        if store.logURL(for: server) != nil {
            Button("Show Logs") { onShowLogs(server) }
        }
        Divider()
        if server.launch != nil {
            Button("Restart") { store.restart(server) }
        }
        Button("Stop") { store.stop(server) }
        if let shared = server.ports.first(where: { store.sharedPorts.contains($0.port) }) {
            let others = store.otherServers(sharingPort: shared.port, with: server)
            if !others.isEmpty {
                Button("Stop Other on :\(shared.port)") {
                    for other in others { store.stop(other) }
                }
            }
        }
        Button("Force Quit") { store.forceQuit(server) }
        Divider()
        Button("Copy Command") { store.copy(server.copyableCommand, label: "command") }
        Button("Copy PID \(server.pid)") { store.copy("\(server.pid)") }
    }
}
