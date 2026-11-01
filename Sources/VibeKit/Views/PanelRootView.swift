import SwiftUI
import VibeKitCore

enum Route: Equatable {
    case list
    case settings
    case logs(Server)
}

struct PanelRootView: View {
    let store: ServerStore
    let onHeightChange: (CGFloat) -> Void
    let close: () -> Void
    /// Starting state, used by `--snapshot` to render specific screens.
    var initial = InitialState()

    @State private var route: Route = .list

    struct InitialState {
        var route: Route = .list
        var selectFirst = false
        var expandFirst = false
        var selectPort: UInt16?
        var expandPort: UInt16?
        var query = ""
    }

    var body: some View {
        Group {
            switch route {
            case .list:
                ServerListPage(store: store, route: $route, onHeightChange: onHeightChange, close: close, initial: initial)
            case .settings:
                SettingsPage(store: store, back: { route = .list }, onHeightChange: onHeightChange)
            case .logs(let server):
                LogPage(server: server, store: store, back: { route = .list }, onHeightChange: onHeightChange)
            }
        }
        .frame(width: PanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { route = initial.route }
    }
}

/// Scroll content that reports its natural height, so the panel can grow to fit and only scroll when it must.
struct MeasuredScroll<Content: View>: View {
    let onHeight: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            content()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
                })
        }
        .scrollIndicators(.automatic)
        .onPreferenceChange(HeightKey.self) { height in
            MainActor.assumeIsolated { onHeight(height) }
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A header with a back button, shared by the settings and log pages.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let back: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: "Back", action: back)
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(Theme.metaFont).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
    }
}

// MARK: - List

private enum Item: Identifiable {
    case server(Server)
    case recent(RecentServer)

    var id: String {
        switch self {
        case .server(let server): server.id
        case .recent(let recent): "recent:" + recent.id
        }
    }
}

struct ServerListPage: View {
    let store: ServerStore
    @Binding var route: Route
    let onHeightChange: (CGFloat) -> Void
    let close: () -> Void
    var initial = PanelRootView.InitialState()

    @State private var query = ""
    @State private var selection: String?
    @State private var expanded: String?
    @State private var confirmStopAll = false
    @FocusState private var searchFocused: Bool

    private static let headerHeight: CGFloat = 46
    private static let footerHeight: CGFloat = 38

    var body: some View {
        let sections = makeSections()
        let items = sections.flatMap(\.items)

        VStack(spacing: 0) {
            header(items: items)
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                MeasuredScroll(onHeight: { onHeightChange($0 + Self.headerHeight + Self.footerHeight + 1) }) {
                    content(sections)
                }
                .onChange(of: selection) { _, id in
                    guard let id, keyboardMoved else { return }
                    keyboardMoved = false
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) }
                }
            }
            footer
        }
        .onAppear {
            searchFocused = true
            query = initial.query
            if let first = store.servers.first(where: { $0.category == .dev }) {
                if initial.selectFirst { selection = first.id }
                if initial.expandFirst { expanded = first.id }
            }
            if let port = initial.selectPort { selection = store.servers.first { $0.primaryPort == port }?.id }
            if let port = initial.expandPort { expanded = store.servers.first { $0.primaryPort == port }?.id }
        }
        .background(shortcuts(items: items))
    }

    @State private var keyboardMoved = false

    // MARK: Header

    private func header(items: [Item]) -> some View {
        HStack(spacing: 9) {
            BrandMark(state: store.overallLight)
                .help(overallHelp)
            TextField("Search servers, ports, projects", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                .onKeyPress(.return) { activate(items); return .handled }
                .onKeyPress(.rightArrow) {
                    guard query.isEmpty, let id = selection, !id.hasPrefix("recent:") else { return .ignored }
                    toggleDetails(id)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !query.isEmpty { query = "" } else if expanded != nil { expanded = nil } else { close() }
                    return .handled
                }
                .onChange(of: query) { _, _ in
                    selection = nil
                    expanded = nil
                }
            if !query.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: "Clear search", size: 22) { query = "" }
            }
            IconButton(symbol: "gearshape", help: "Settings") { route = .settings }
        }
        .padding(.leading, 15)
        .padding(.trailing, 8)
        .frame(height: Self.headerHeight)
    }

    private var overallHelp: String {
        switch store.overallLight {
        case .failing: "A dev server is answering with errors"
        case .waiting: "A dev server is not answering yet"
        case .stopped: "No dev servers running"
        default: "All dev servers are up"
        }
    }

    // MARK: Content

    private struct Section: Identifiable {
        let id: String
        let title: String
        let items: [Item]
        var collapsible = false
    }

    private func makeSections() -> [Section] {
        let filtered = store.servers.filter(matches)
        var sections: [Section] = []
        for category in [ServerCategory.dev, .database, .service] {
            let servers = filtered.filter { $0.category == category }
            if !servers.isEmpty {
                sections.append(Section(id: category.rawValue, title: category.title, items: servers.map(Item.server)))
            }
        }
        let recents = store.recents.filter(matches)
        if !recents.isEmpty {
            sections.append(Section(id: "recents", title: "Recently Stopped", items: recents.map(Item.recent)))
        }
        let others = filtered.filter { $0.category == .other }
        if !others.isEmpty {
            let open = store.settings.showOtherListeners || !query.isEmpty
            sections.append(Section(id: "other", title: ServerCategory.other.title, items: open ? others.map(Item.server) : [],
                                    collapsible: true))
        }
        return sections
    }

    @ViewBuilder
    private func content(_ sections: [Section]) -> some View {
        VStack(spacing: 0) {
            if !store.hasScanned {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for servers").font(Theme.metaFont).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if !query.isEmpty && sections.allSatisfy({ $0.items.isEmpty }) {
                noMatches
            } else {
                if query.isEmpty && !sections.contains(where: { $0.id == ServerCategory.dev.rawValue }) {
                    emptyState
                }
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        if section.collapsible {
            let count = store.servers(in: .other).filter(matches).count
            SectionHeader(title: section.title, count: count, collapsed: section.items.isEmpty)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard query.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.18)) { store.settings.showOtherListeners.toggle() }
                }
                .help(section.items.isEmpty ? "Show apps and system services that listen on a port" : "Hide")
        } else if section.id == "recents" {
            SectionHeader(title: section.title, count: section.items.count, trailing: AnyView(
                Button("Clear") { store.clearRecents() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            ))
        } else {
            SectionHeader(title: section.title, count: section.items.count)
        }
        ForEach(section.items) { item in
            row(item).id(item.id)
        }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .server(let server):
            ServerRow(server: server, store: store, isSelected: selection == item.id, isExpanded: expanded == item.id,
                      onHover: { selection = item.id },
                      onToggleDetails: { toggleDetails(item.id) },
                      onShowLogs: { route = .logs($0) })
        case .recent(let recent):
            RecentRow(recent: recent, store: store, isSelected: selection == item.id, onHover: { selection = item.id })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            VibeMark(size: 34)
                .padding(.bottom, 4)
            Text("No dev servers running")
                .font(.system(size: 13, weight: .semibold))
            Text("Start one in your terminal and it appears here within a few seconds.")
                .font(Theme.metaFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    private var noMatches: some View {
        VStack(spacing: 6) {
            if let port = UInt16(query.trimmingCharacters(in: CharacterSet(charactersIn: ": "))), port > 0 {
                let free = Network.isPortFree(port)
                Text(free ? "Port \(String(port)) is free" : "Port \(String(port)) is taken")
                    .font(.system(size: 13, weight: .semibold))
                Text(free ? "Nothing is listening on it." : "Another user or a system service holds it, so Vibe Kit can't show or stop it.")
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            } else {
                Text("No matches for “\(query)”")
                    .font(.system(size: 13, weight: .semibold))
                Text("Search by project, port, framework, branch or command.")
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: Footer

    private var footer: some View {
        let dev = store.devServers
        return VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                if let toast = store.toast {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Theme.warning : Theme.live)
                        .font(.system(size: 11.5))
                    Text(toast.message)
                        .font(Theme.metaFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .transition(.opacity)
                } else {
                    summary(dev)
                }
                Spacer(minLength: 6)
                if !dev.isEmpty && store.toast == nil {
                    stopAllButton(count: dev.count)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.footerHeight - 1)
            .animation(.easeOut(duration: 0.15), value: store.toast)
        }
    }

    /// How many servers run, then anything that needs a look, else their combined CPU and memory.
    private func summary(_ dev: [Server]) -> some View {
        let lights = dev.map(store.light(for:))
        let starting = lights.filter { $0 == .waiting }.count
        let silent = lights.filter { $0 == .silent }.count
        let failing = lights.filter { $0 == .failing }.count
        let cpu = dev.reduce(0) { $0 + $1.cpu }
        let memory = dev.reduce(UInt64(0)) { $0 + $1.memory }
        return HStack(spacing: 6) {
            Text(dev.count == 1 ? "1 running" : "\(dev.count) running")
                .foregroundStyle(.secondary)
            if failing > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(failing) failing").foregroundStyle(Theme.danger)
            }
            if silent > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(silent) not answering").foregroundStyle(Theme.warning)
            }
            if starting > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(starting) starting").foregroundStyle(Theme.warning)
            }
            if !dev.isEmpty && failing + silent + starting == 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(Format.cpu(cpu)) CPU · \(Format.memory(memory))")
                    .foregroundStyle(Theme.heat(cpu).map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
    }

    private func stopAllButton(count: Int) -> some View {
        Button {
            if confirmStopAll {
                store.stopAll()
                confirmStopAll = false
            } else {
                confirmStopAll = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    confirmStopAll = false
                }
            }
        } label: {
            Text(confirmStopAll ? "Stop \(count)?" : "Stop All")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(confirmStopAll ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(confirmStopAll ? Theme.danger : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: confirmStopAll)
        .help("Stop every dev server")
    }

    // MARK: Keyboard

    private func shortcuts(items: [Item]) -> some View {
        let server: Server? = {
            guard let selection, case .server(let s)? = items.first(where: { $0.id == selection }) else { return nil }
            return s
        }()
        return ZStack {
            Button("") { if let server { store.restart(server) } }.keyboardShortcut("r", modifiers: .command)
            Button("") { if let server { store.stop(server) } }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { if let server { store.copyURL(server) } }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { if let server { store.openInEditor(server); close() } }.keyboardShortcut("o", modifiers: .command)
            Button("") { if let server { store.openInTerminal(server); close() } }.keyboardShortcut("t", modifiers: .command)
            Button("") { route = .settings }.keyboardShortcut(",", modifiers: .command)
            // ⌘1 to ⌘9 open the servers in list order.
            ForEach(1..<10) { number in
                Button("") { openNumbered(number, in: items) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func move(_ delta: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        keyboardMoved = true
        guard let current = selection, let index = items.firstIndex(where: { $0.id == current }) else {
            selection = delta > 0 ? items.first?.id : items.last?.id
            return
        }
        selection = items[(index + delta + items.count) % items.count].id
    }

    private func activate(_ items: [Item]) {
        activate(items.first { $0.id == selection } ?? (items.count == 1 ? items.first : nil))
    }

    private func activate(_ target: Item?) {
        switch target {
        case .server(let server):
            if server.category == .dev && server.framework.speaksHTTP {
                store.open(server)
                close()
            } else if server.framework.urlScheme != nil {
                store.copyURL(server)
            } else {
                toggleDetails(server.id)
            }
        case .recent(let recent):
            store.start(recent)
        case nil:
            break
        }
    }

    private func openNumbered(_ number: Int, in items: [Item]) {
        let servers = items.filter { if case .server = $0 { true } else { false } }
        guard number <= servers.count else { return }
        selection = servers[number - 1].id
        activate(servers[number - 1])
    }

    private func toggleDetails(_ id: String) {
        withAnimation(.snappy(duration: 0.22)) { expanded = expanded == id ? nil : id }
    }

    // MARK: Search

    private func matches(_ server: Server) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let port = q.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if !port.isEmpty, port.allSatisfy(\.isNumber) {
            // Numbers match ports by prefix, and PIDs exactly.
            return server.ports.contains { String($0.port).hasPrefix(port) }
                || [server.pid, server.rootPid].contains { String($0) == port } || server.listenerPids.contains { String($0) == port }
        }
        let haystack = [server.title, server.framework.name, server.processName, server.command,
                        server.project?.branch ?? "", server.project?.subpath ?? "", server.project?.worktree ?? "",
                        store.pages[server.id]?.title ?? ""]
        return haystack.contains { $0.lowercased().contains(q) }
    }

    private func matches(_ recent: RecentServer) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let port = q.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if !port.isEmpty, port.allSatisfy(\.isNumber) { return String(recent.port).hasPrefix(port) }
        return [recent.title, recent.frameworkName, recent.launch.displayCommand, recent.branch ?? ""]
            .contains { $0.lowercased().contains(q) }
    }
}
