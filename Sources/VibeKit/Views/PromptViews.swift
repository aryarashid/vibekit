import SwiftUI
import VibeKitCore

/// Switches the panel between servers and prompts. Tab switches from the keyboard.
struct TabSwitch: View {
    @Binding var tab: PanelTab

    var body: some View {
        HStack(spacing: 1) {
            segment(.servers, symbol: "server.rack", help: "Servers")
            segment(.prompts, symbol: "text.bubble", help: "Prompts")
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
    }

    private func segment(_ value: PanelTab, symbol: String, help: String) -> some View {
        let selected = tab == value
        return Button { tab = value } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(selected && value == .prompts ? Theme.violet : Color.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 20)
                .background(Capsule().fill(Color.primary.opacity(selected ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(help)  (Tab switches)")
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - List

struct PromptListPage: View {
    let store: ServerStore
    let prompts: PromptStore
    @Binding var tab: PanelTab
    @Binding var route: Route
    let onHeightChange: (CGFloat) -> Void
    let onUse: (Prompt) -> Void
    let close: () -> Void
    var initialQuery = ""
    var selectFirst = false

    @State private var query = ""
    @State private var selection: UUID?
    @State private var used: UUID?
    @State private var keyboardMoved = false
    @State private var clipboardText: String?
    @State private var pendingUse: Task<Void, Never>?
    /// See `ServerListPage.hoverLock`.
    @State private var hoverLock: NSPoint?
    @FocusState private var searchFocused: Bool

    private static let headerHeight: CGFloat = 46
    private static let footerHeight: CGFloat = 38

    var body: some View {
        let list = PromptLibrary.search(prompts.prompts, query: query)
        VStack(spacing: 0) {
            header(list)
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                MeasuredScroll(onHeight: { onHeightChange($0 + Self.headerHeight + Self.footerHeight + 1) }) {
                    content(list)
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
            DispatchQueue.main.async { searchFocused = true }
            query = initialQuery
            prompts.reloadIfChanged()
            if selectFirst { selection = PromptLibrary.search(prompts.prompts, query: initialQuery).first?.id }
            clipboardText = NSPasteboard.general.string(forType: .string).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        .onDisappear { pendingUse?.cancel() }
        .background(shortcuts(list))
    }

    // MARK: Header

    private func header(_ list: [Prompt]) -> some View {
        HStack(spacing: 9) {
            BrandMark(state: store.overallLight)
            TextField("Search prompts", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
                .onKeyPress(.return) { use(active(in: list)); return .handled }
                .onKeyPress(.tab) { tab = .servers; return .handled }
                .onKeyPress(.escape) {
                    if !query.isEmpty { query = "" } else { close() }
                    return .handled
                }
                .onChange(of: query) { _, _ in selection = nil }
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

    @ViewBuilder
    private func content(_ list: [Prompt]) -> some View {
        VStack(spacing: 0) {
            if prompts.prompts.isEmpty {
                emptyState
            } else if list.isEmpty {
                VStack(spacing: 6) {
                    Text("No prompts match “\(query)”").font(.system(size: 13, weight: .semibold))
                    Text("Search looks in titles and text.").font(Theme.metaFont).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                let maxScore = list.map { $0.score() }.max() ?? 0
                let active = active(in: list)?.id
                let pinned = list.filter(\.pinned)
                let rest = list.filter { !$0.pinned }
                if !pinned.isEmpty && query.isEmpty {
                    SectionHeader(title: "Pinned", count: pinned.count)
                    rows(pinned, maxScore: maxScore, offset: 0, active: active)
                    SectionHeader(title: "Most Used", count: rest.count)
                    rows(rest, maxScore: maxScore, offset: pinned.count, active: active)
                } else {
                    SectionHeader(title: query.isEmpty ? "Most Used" : "Results", count: list.count)
                    rows(list, maxScore: maxScore, offset: 0, active: active)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func rows(_ items: [Prompt], maxScore: Double, offset: Int, active: UUID?) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, prompt in
            PromptRow(prompt: prompt, number: offset + index + 1, heat: maxScore > 0 ? prompt.score() / maxScore : 0,
                      isSelected: active == prompt.id, wasUsed: used == prompt.id,
                      onHover: { hover(prompt.id) },
                      onUse: { use(prompt) },
                      onCopy: { copyOnly(prompt) },
                      onEdit: { route = .prompt(prompt.id) },
                      onPin: { withAnimation(.snappy(duration: 0.2)) { prompts.togglePin(prompt) } },
                      onDelete: { withAnimation(.easeOut(duration: 0.15)) { prompts.delete(prompt) } })
                .id(prompt.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.violet)
                .padding(.bottom, 2)
            Text("Keep your best prompts one key away")
                .font(.system(size: 13, weight: .semibold))
            Text("Pick a prompt to copy it, or paste it straight into the app you are in. To save text from any app, select it, right-click and choose Services › Add to Vibe Kit.")
                .font(Theme.metaFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
            HStack(spacing: 6) {
                PillButton(title: "New Prompt", symbol: "plus") { route = .prompt(nil) }
                if clipboardText != nil {
                    PillButton(title: "From Clipboard", symbol: "doc.on.clipboard") { addFromClipboard() }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                if let deleted = prompts.deleted {
                    Text("Deleted “\(deleted.displayTitle)”")
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button("Undo") { withAnimation(.easeOut(duration: 0.15)) { prompts.undoDelete() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                        .keyboardShortcut("z", modifiers: .command)
                } else if let problem = prompts.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.system(size: 11.5))
                    Text(problem).font(Theme.metaFont).lineLimit(1).truncationMode(.tail).help(problem)
                    Spacer(minLength: 6)
                    Button("Show") { prompts.revealFile() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                } else if let toast = store.toast {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Theme.warning : Theme.live)
                        .font(.system(size: 11.5))
                    Text(toast.message).font(Theme.metaFont).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                } else {
                    summary
                    Spacer(minLength: 6)
                    if clipboardText != nil && !prompts.prompts.isEmpty {
                        IconButton(symbol: "doc.on.clipboard", help: "New prompt from the clipboard", size: 24) { addFromClipboard() }
                    }
                    if !prompts.prompts.isEmpty {
                        PillButton(title: "New", symbol: "plus") { route = .prompt(nil) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.footerHeight - 1)
            .animation(.easeOut(duration: 0.15), value: store.toast)
        }
    }

    private var summary: some View {
        let count = prompts.prompts.count
        let pinned = prompts.pinnedCount
        return HStack(spacing: 6) {
            Text(count == 1 ? "1 prompt" : "\(count) prompts").foregroundStyle(.secondary)
            if pinned > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(pinned) pinned").foregroundStyle(.tertiary)
            }
            if store.settings.pasteOnUse {
                Text("·").foregroundStyle(.tertiary)
                Text(PromptStore.canPaste ? "↩ pastes" : "↩ copies")
                    .foregroundStyle(.tertiary)
                    .help(PromptStore.canPaste ? "Picking a prompt pastes it into the app in front" : "Allow Vibe Kit in Accessibility settings to paste")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
    }

    // MARK: Actions

    /// Copies, or pastes when that is on. The copy happens at once; the row flashes before the panel goes,
    /// so you see it worked, and closing the panel meanwhile cannot lose it.
    private func use(_ prompt: Prompt?) {
        guard let prompt else { return }
        prompts.copy(prompt)
        if store.settings.pasteOnUse && PromptStore.canPaste {
            onUse(prompt)
            return
        }
        used = prompt.id
        pendingUse?.cancel()
        pendingUse = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            onUse(prompt)
        }
    }

    private func copyOnly(_ prompt: Prompt) {
        prompts.copy(prompt)
        store.show(Toast(message: "Copied “\(prompt.displayTitle)”"))
    }

    private func addFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = prompts.add(text: text)
        route = .prompt(prompt.id)
    }

    private func move(_ delta: Int, in list: [Prompt]) {
        guard !list.isEmpty else { return }
        keyboardMoved = true
        hoverLock = NSEvent.mouseLocation
        guard let current = active(in: list)?.id, let index = list.firstIndex(where: { $0.id == current }) else {
            selection = delta > 0 ? list.first?.id : list.last?.id
            return
        }
        selection = list[(index + delta + list.count) % list.count].id
    }

    /// The prompt keys act on: the one you picked, or while you type, the top match.
    private func active(in list: [Prompt]) -> Prompt? {
        if let selection, let picked = list.first(where: { $0.id == selection }) { return picked }
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : list.first
    }

    private func hover(_ id: UUID) {
        if let hoverLock, hoverLock == NSEvent.mouseLocation { return }
        hoverLock = nil
        selection = id
    }

    private func shortcuts(_ list: [Prompt]) -> some View {
        let selected = active(in: list)
        return ZStack {
            Button("") { route = .prompt(nil) }.keyboardShortcut("n", modifiers: .command)
            Button("") { if let selected { route = .prompt(selected.id) } }.keyboardShortcut("e", modifiers: .command)
            Button("") { if let selected { prompts.togglePin(selected) } }.keyboardShortcut("p", modifiers: .command)
            Button("") { if let selected { copyOnly(selected) } }.keyboardShortcut("c", modifiers: [.command, .shift])
            // While you type, ⌘⌫ deletes to the start of the line, as in any text field.
            Button("") { if let selected { prompts.delete(selected) } }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(!query.isEmpty)
            Button("") { route = .settings }.keyboardShortcut(",", modifiers: .command)
            ForEach(1..<10) { number in
                Button("") { if number <= list.count { selection = list[number - 1].id; use(list[number - 1]) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Row

struct PromptRow: View {
    let prompt: Prompt
    let number: Int
    /// This prompt's use score as a share of the most used one, for the meter.
    let heat: Double
    let isSelected: Bool
    let wasUsed: Bool
    let onHover: () -> Void
    let onUse: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            gauge
            VStack(alignment: .leading, spacing: 2) {
                // A one-line prompt has nothing to preview, so its title may take both lines.
                let preview = prompt.preview
                Text(prompt.displayTitle)
                    .font(Theme.titleFont)
                    .lineLimit(preview.isEmpty ? 2 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if !preview.isEmpty {
                    Text(preview)
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 46)
        .contentShape(Rectangle())
        .onTapGesture(perform: onUse)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(wasUsed ? Theme.violet.opacity(0.16) : Color.primary.opacity(isSelected ? 0.075 : 0))
        )
        .animation(.easeOut(duration: 0.12), value: wasUsed)
        .padding(.horizontal, 6)
        .onHover { if $0 { onHover() } }
        .help(usageHelp)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Edit", action: onEdit)
            Button(prompt.pinned ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(prompt.displayTitle)
        .accessibilityValue(prompt.pinned ? "Pinned, \(usageHelp)" : usageHelp)
        .accessibilityAction(named: "Use", onUse)
        .accessibilityAction(named: "Copy", onCopy)
        .accessibilityAction(named: prompt.pinned ? "Unpin" : "Pin", onPin)
        .accessibilityAction(named: "Edit", onEdit)
    }

    /// A pin for pinned prompts. Otherwise a small level meter: how much you use this prompt next to your favorite.
    @ViewBuilder
    private var gauge: some View {
        if prompt.pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.violet)
                .rotationEffect(.degrees(35))
                .frame(width: 10, height: 26)
        } else {
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Theme.violet.opacity(0.35 + 0.65 * heat))
                    .frame(height: heat > 0 ? max(4, 26 * heat) : 0)
            }
            .frame(width: 3, height: 26)
            .frame(width: 10)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if wasUsed {
            Label("Copied", systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.violet)
                .transition(.opacity)
        } else if isSelected {
            HStack(spacing: 2) {
                IconButton(symbol: "doc.on.doc", help: "Copy without closing", action: onCopy)
                IconButton(symbol: prompt.pinned ? "pin.slash" : "pin", help: prompt.pinned ? "Unpin" : "Pin to the top", action: onPin)
                IconButton(symbol: "pencil", help: "Edit", action: onEdit)
            }
            .transition(.opacity)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                if number <= 9 {
                    Text("⌘\(number)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
                Text(usage)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var usage: String {
        guard prompt.uses > 0, let last = prompt.lastUsed else { return "new" }
        return "\(prompt.uses)× · \(Format.short(since: last))"
    }

    private var usageHelp: String {
        let tokens = Format.tokens(prompt.text)
        guard prompt.uses > 0, let last = prompt.lastUsed else { return "Never used. \(tokens)." }
        return "Used \(prompt.uses == 1 ? "once" : "\(prompt.uses) times"), last \(Format.ago(last)). \(tokens)."
    }
}

// MARK: - Editor

struct PromptEditor: View {
    let prompts: PromptStore
    let id: UUID?
    let back: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @State private var title = ""
    @State private var text = ""
    @State private var savedID: UUID?
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field { case title, text }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: id == nil ? "New Prompt" : "Edit Prompt",
                       subtitle: prompts.problem == nil ? "Saved as you type" : "Not saved", back: done) {
                PillButton(title: "Done", symbol: "checkmark") { done() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .text }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write or paste the prompt…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .text)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(focus == .text ? 0.14 : 0.06)))
            }
            .padding(14)
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                if let problem = prompts.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.system(size: 11))
                    Text(problem).font(Theme.metaFont).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(problem)
                } else {
                    Text("\(text.count.formatted()) characters · \(Format.tokens(text))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let current = savedID.flatMap(prompts.prompt) {
                    Button("Delete") {
                        pendingSave?.cancel()
                        pendingSave = nil
                        prompts.delete(current)
                        savedID = nil
                        text = ""
                        back()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 37)
        }
        .onAppear {
            savedID = id
            var naming = false
            if let id, let prompt = prompts.prompt(id) {
                title = prompt.title
                text = prompt.text
                // Just saved from Services or the clipboard: it needs a name more than an edit.
                naming = prompt.title.isEmpty && Date().timeIntervalSince(prompt.created) < 10
            }
            onHeightChange(440)
            // Like the search fields: focus asked for before the panel is key can be ignored.
            DispatchQueue.main.async { focus = naming ? .title : .text }
        }
        .onDisappear {
            flush()
            removeIfEmptied()
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
    }

    /// Saves shortly after you stop typing, not on every key, so a large library or a synced file stays quick.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            pendingSave = nil
            commit()
        }
    }

    private func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        commit()
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Saves as you type. A new prompt is created on its first character, and never saved while empty.
    private func commit() {
        guard !isEmpty else { return }
        if let savedID, prompts.edit(savedID, { $0.title = title; $0.text = text }) { return }
        // New, or deleted from the file while open: save it as a prompt of its own.
        savedID = prompts.add(text: text, title: title).id
    }

    /// A prompt emptied and left is deleted, with Undo in the list, rather than keeping its old text.
    private func removeIfEmptied() {
        guard isEmpty, let id = savedID, let prompt = prompts.prompt(id) else { return }
        savedID = nil
        prompts.delete(prompt)
    }

    private func done() {
        pendingSave?.cancel()
        pendingSave = nil
        commit()
        removeIfEmptied()
        back()
    }
}
