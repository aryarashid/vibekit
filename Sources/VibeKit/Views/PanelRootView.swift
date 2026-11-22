import SwiftUI
import VibeKitCore

enum Route: Equatable {
    case list
    case settings
    case logs(subtitle: String, url: URL)
    /// The prompt editor. `nil` writes a new prompt.
    case prompt(UUID?)
}

struct PanelRootView: View {
    let store: ServerStore
    let prompts: PromptStore
    let onHeightChange: (CGFloat) -> Void
    let onUsePrompt: (Prompt) -> Void
    let close: () -> Void
    /// Starting state: the tab to show, and for `--snapshot` specific screens.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let initial: InitialState

    @State private var route: Route
    @State private var tab: PanelTab

    init(store: ServerStore, prompts: PromptStore, onHeightChange: @escaping (CGFloat) -> Void,
         onUsePrompt: @escaping (Prompt) -> Void, close: @escaping () -> Void, initial: InitialState = InitialState()) {
        self.store = store
        self.prompts = prompts
        self.onHeightChange = onHeightChange
        self.onUsePrompt = onUsePrompt
        self.close = close
        self.initial = initial
        // Start on the right page, so opening on Prompts does not build the server list first.
        _route = State(initialValue: initial.route)
        _tab = State(initialValue: initial.tab)
    }

    struct InitialState {
        var tab: PanelTab = .servers
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
            case .list where tab == .prompts:
                PromptListPage(store: store, prompts: prompts, tab: $tab, route: $route, onHeightChange: onHeightChange,
                               onUse: onUsePrompt, close: close, initialQuery: initial.query,
                               selectFirst: initial.selectFirst)
            case .list:
                ServerListPage(store: store, tab: $tab, route: $route, onHeightChange: onHeightChange, close: close, initial: initial)
            case .settings:
                SettingsPage(store: store, prompts: prompts, back: { route = .list }, onHeightChange: onHeightChange)
            case .logs(let subtitle, let url):
                LogPage(subtitle: subtitle, url: url, back: { route = .list }, onHeightChange: onHeightChange)
            case .prompt(let id):
                PromptEditor(prompts: prompts, id: id, back: { route = .list }, onHeightChange: onHeightChange)
            }
        }
        .frame(maxWidth: PanelMetrics.width)
        // Pinned to the top: if the panel is ever shorter than its content, the bottom gives way, never the header.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .onChange(of: tab) { _, tab in store.settings.lastTab = tab }
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
        // The last few points ease clipped rows into the fixed footer. Content has its own bottom inset.
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 5)
            }
        }
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
    @Binding var tab: PanelTab
    @Binding var route: Route
    let onHeightChange: (CGFloat) -> Void
    let close: () -> Void
    var initial = PanelRootView.InitialState()

    @State private var query = ""
    @State private var selection: String?
    @State private var expanded: String?
    @State private var confirmStopAll = false
    @State private var stopAllResetTask: Task<Void, Never>?
    /// Where the pointer was when the keyboard last moved the selection or changed the search. Rows that scroll,
    /// expand or filter under a still pointer must not take the selection, or a shortcut would act on a server
    /// you did not pick.
    @State private var hoverLock: NSPoint?
    /// Whether the port typed in the search is free. Worked out when the query changes, not on every redraw.
    @State private var portCheck: (port: UInt16, free: Bool)?
    @FocusState private var searchFocused: Bool

    private static let headerHeight: CGFloat = 46
    private static let footerHeight: CGFloat = 38

    var body: some View {
        let sections = makeSections()
        let items = sections.flatMap(\.items)
        let active = activeID(in: items)

        VStack(spacing: 0) {
            header(items: items)
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                MeasuredScroll(onHeight: { onHeightChange($0 + Self.headerHeight + (store.hasScanned ? Self.footerHeight : 0) + 1) }) {
                    content(sections, active: active)
                }
                .onChange(of: selection) { _, id in
                    guard let id, keyboardMoved else { return }
                    keyboardMoved = false
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) }
                }
            }
            if store.hasScanned { footer }
        }
        .onAppear {
            // The first layout happens before the nonactivating panel becomes key.
            // Asking for focus in that layout can be silently ignored by AppKit.
            DispatchQueue.main.async { searchFocused = true }
            query = initial.query
            if let first = store.servers.first(where: { $0.category == .dev }) {
                if initial.selectFirst { selection = first.id }
                if initial.expandFirst { expanded = first.id }
            }
            if let port = initial.selectPort { selection = store.servers.first { $0.primaryPort == port }?.id }
            if let port = initial.expandPort { expanded = store.servers.first { $0.primaryPort == port }?.id }
        }
        .background(shortcuts)
    }

    @State private var keyboardMoved = false

    // MARK: Header

    private func header(items: [Item]) -> some View {
        HStack(spacing: 9) {
            BrandMark(state: store.overallLight)
                .help(store.overallLightHelp)
            PanelSearchField(title: "Search servers, ports, projects", text: $query)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                .onKeyPress(.return) { activate(items); return .handled }
                .onKeyPress(.rightArrow) {
                    guard query.isEmpty, let id = selection, !id.hasPrefix("recent:") else { return .ignored }
                    hoverLock = NSEvent.mouseLocation
                    toggleDetails(id)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    guard query.isEmpty, expanded != nil else { return .ignored }
                    hoverLock = NSEvent.mouseLocation
                    withAnimation(.snappy(duration: 0.22)) { expanded = nil }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !query.isEmpty { query = "" } else if expanded != nil { expanded = nil } else { close() }
                    return .handled
                }
                .onKeyPress(.tab) { tab = .prompts; return .handled }
                .onChange(of: query) { _, _ in
                    selection = nil
                    hoverLock = NSEvent.mouseLocation
                    expanded = nil
                    portCheck = queriedPort.map { ($0, Network.isPortFree($0)) }
                }
            if !query.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: "Clear search", size: 22) { query = "" }
            }
            TabSwitch(tab: $tab)
            IconButton(symbol: "gearshape", help: "Settings") { route = .settings }
        }
        .padding(.leading, 15)
        .padding(.trailing, 8)
        .frame(height: Self.headerHeight)
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
    private func content(_ sections: [Section], active: String?) -> some View {
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
                    sectionView(section, active: active)
                }
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func sectionView(_ section: Section, active: String?) -> some View {
        if section.collapsible {
            let count = store.servers(in: .other).filter(matches).count
            Button {
                guard query.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.18)) { store.settings.showOtherListeners.toggle() }
            } label: {
                SectionHeader(title: section.title, count: count, collapsed: section.items.isEmpty)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!query.isEmpty)
            .help(section.items.isEmpty ? "Show apps and system services that listen on a port" : "Hide")
        } else if section.id == "recents" {
            SectionHeader(title: section.title, count: section.items.count, trailing: AnyView(
                Button { store.clearRecents() } label: {
                    Text("Clear")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                }
                .buttonStyle(PanelButtonStyle(hoverInk: Theme.danger, tint: Theme.danger))
                .help("Clear recently stopped servers")
            ))
        } else {
            SectionHeader(title: section.title, count: section.items.count)
        }
        ForEach(section.items) { item in
            row(item, isSelected: active == item.id).id(item.id)
        }
    }

    @ViewBuilder
    private func row(_ item: Item, isSelected: Bool) -> some View {
        switch item {
        case .server(let server):
            ServerRow(server: server, store: store, isSelected: isSelected, isExpanded: expanded == item.id,
                      onHover: { hover(item.id) },
                      onActivate: { activate(.server(server)) },
                      onToggleDetails: { toggleDetails(item.id) },
                      onShowLogs: { server in
                          if let url = store.logURL(for: server) {
                              route = .logs(subtitle: "\(server.title) · \(server.primaryPort)", url: url)
                          }
                      },
                      onClose: close)
        case .recent(let recent):
            RecentRow(recent: recent, store: store, isSelected: isSelected, onHover: { hover(item.id) },
                      onShowLogs: { url in route = .logs(subtitle: "\(recent.title) · \(recent.port)", url: url) })
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
            if let portCheck, portCheck.port == queriedPort {
                let port = portCheck.port, free = portCheck.free
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
        // Checked again each time this shows, so a port freed after you typed it reads as free.
        .onAppear { portCheck = queriedPort.map { ($0, Network.isPortFree($0)) } }
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
                    .foregroundStyle(Theme.heat(cpu).map(AnyShapeStyle.init) ?? AnyShapeStyle(Theme.readout))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
    }

    private func stopAllButton(count: Int) -> some View {
        Button {
            stopAllResetTask?.cancel()
            stopAllResetTask = nil
            if confirmStopAll {
                store.stopAll()
                confirmStopAll = false
            } else {
                confirmStopAll = true
                stopAllResetTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { confirmStopAll = false }
                }
            }
        } label: {
            Text(confirmStopAll ? "Stop \(count)?" : "Stop All")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .monospacedDigit()
        }
        .buttonStyle(PanelButtonStyle(ink: confirmStopAll ? Theme.danger : Theme.readout,
                                     hoverInk: Theme.danger, tint: confirmStopAll ? Theme.danger : .primary,
                                     restingFill: confirmStopAll ? 0.14 : 0.06))
        .animation(.easeOut(duration: 0.15), value: confirmStopAll)
        .help("Stop every dev server")
    }

    // MARK: Keyboard

    // SwiftUI can dispatch the previous layout's shortcut just after filtering.
    // Resolve its target from the current query and selection when the key is pressed.
    private var visibleItems: [Item] { makeSections().flatMap(\.items) }

    private func shortcutServer(explicitSelection: Bool = false) -> Server? {
        let items = visibleItems
        let id = explicitSelection ? selection : activeID(in: items)
        guard let id, case .server(let server)? = items.first(where: { $0.id == id }) else { return nil }
        return server
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { if let server = shortcutServer() { store.restart(server) } }.keyboardShortcut("r", modifiers: .command)
            // While you type, ⌘⌫ deletes to the start of the line, as in any text field. It stops only a row you
            // picked, never the fallback, so pressing it once more after the search clears stops nothing.
            Button("") { if query.isEmpty, let picked = shortcutServer(explicitSelection: true) { store.stop(picked) } }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(!query.isEmpty)
            Button("") { if let server = shortcutServer() { store.copyURL(server) } }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { if let server = shortcutServer() { store.openInEditor(server); close() } }.keyboardShortcut("o", modifiers: .command)
            Button("") { if let server = shortcutServer() { store.openInTerminal(server); close() } }.keyboardShortcut("t", modifiers: .command)
            Button("") { route = .settings }.keyboardShortcut(",", modifiers: .command)
            // ⌘1 to ⌘9 open the servers in list order.
            ForEach(1..<10) { number in
                Button("") { openNumbered(number, in: visibleItems) }
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
        hoverLock = NSEvent.mouseLocation
        guard let current = activeID(in: items), let index = items.firstIndex(where: { $0.id == current }) else {
            selection = delta > 0 ? items.first?.id : items.last?.id
            return
        }
        selection = items[(index + delta + items.count) % items.count].id
    }

    private func activate(_ items: [Item]) {
        let active = activeID(in: items)
        activate(items.first { $0.id == active })
    }

    /// The row keys act on: the one you picked, or while you type, the top match.
    private func activeID(in items: [Item]) -> String? {
        if let selection, items.contains(where: { $0.id == selection }) { return selection }
        // While you type, the top match. Otherwise a lone row, so ↩ opens it without a click.
        return query.trimmingCharacters(in: .whitespaces).isEmpty && items.count > 1 ? nil : items.first?.id
    }

    private func hover(_ id: String) {
        if let hoverLock, hoverLock == NSEvent.mouseLocation { return }
        hoverLock = nil
        selection = id
    }

    /// A port number typed in the search, such as `3000` or `:3000`.
    private var queriedPort: UInt16? {
        UInt16(query.trimmingCharacters(in: CharacterSet(charactersIn: ": "))).flatMap { $0 > 0 ? $0 : nil }
    }

    private func activate(_ target: Item?) {
        switch target {
        case .server(let server):
            if server.category == .dev && server.framework.speaksHTTP {
                store.open(server)
                close()
            } else if server.framework.urlScheme != nil || (server.category == .database && server.localURL != nil) {
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
        hoverLock = NSEvent.mouseLocation
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
                        store.pages[server.id]?.title ?? "", server.ports.map { String($0.port) }.joined(separator: " ")]
            .joined(separator: "\n").lowercased()
        // Every word must match somewhere, so "storefront next" finds the Next.js server of storefront.
        return q.split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    private func matches(_ recent: RecentServer) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let port = q.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if !port.isEmpty, port.allSatisfy(\.isNumber) { return String(recent.port).hasPrefix(port) }
        let haystack = [recent.title, recent.frameworkName, recent.launch.displayCommand, recent.branch ?? "", String(recent.port)]
            .joined(separator: "\n").lowercased()
        return q.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}
