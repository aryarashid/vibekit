import AppKit
import ApplicationServices
import Observation
import VibeKitCore

/// Saved prompts, kept in a readable JSON file you can edit by hand or sync.
@MainActor @Observable
final class PromptStore {
    private(set) var prompts: [Prompt] = []
    /// The last deleted prompt, so the footer can offer Undo for a few seconds.
    private(set) var deleted: Prompt?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private let persists: Bool

    static let defaultFile = ServerStore.supportDirectory.appendingPathComponent("prompts.json")

    init(file: URL = PromptStore.defaultFile, persists: Bool = true) {
        self.file = file
        self.persists = persists
        if persists { reloadIfChanged() }
    }

    var pinnedCount: Int { prompts.count { $0.pinned } }

    func prompt(_ id: UUID) -> Prompt? { prompts.first { $0.id == id } }

    /// Picks up edits made to the file outside Vibe Kit. Cheap: one stat call when nothing changed.
    func reloadIfChanged() {
        guard persists else { return }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified == nil || modified != loadedAt else { return }
        loadedAt = modified
        prompts = PromptLibrary.load(from: file) ?? []
    }

    @discardableResult
    func add(text: String, title: String = "") -> Prompt {
        let prompt = Prompt(title: title, text: text)
        prompts.append(prompt)
        save()
        return prompt
    }

    func update(_ prompt: Prompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        guard prompts[index] != prompt else { return }
        prompts[index] = prompt
        save()
    }

    func delete(_ prompt: Prompt) {
        prompts.removeAll { $0.id == prompt.id }
        save()
        deleted = prompt
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { deleted = nil }
        }
    }

    func undoDelete() {
        guard let deleted else { return }
        prompts.append(deleted)
        self.deleted = nil
        save()
    }

    func togglePin(_ prompt: Prompt) {
        guard var current = self.prompt(prompt.id) else { return }
        current.pinned.toggle()
        update(current)
    }

    /// Puts the prompt on the clipboard and counts the use.
    func copy(_ prompt: Prompt) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.text, forType: .string)
        guard var current = self.prompt(prompt.id) else { return }
        current.uses += 1
        current.lastUsed = Date()
        update(current)
    }

    func revealFile() {
        if !FileManager.default.fileExists(atPath: file.path) { save() }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func save() {
        guard persists else { return }
        do {
            try PromptLibrary.save(prompts, to: file)
            loadedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        } catch {
            NSLog("Vibe Kit: could not save prompts: \(error.localizedDescription)")
        }
    }

    /// Sample prompts for `--snapshot --demo`. Nothing is saved.
    func showDemo(_ prompts: [Prompt]) { self.prompts = prompts }

    // MARK: Pasting

    /// Pasting into another app sends a ⌘V keystroke, which macOS allows only with Accessibility access.
    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    static func requestPasteAccess() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Sends ⌘V to the app in front. Call after the panel is gone, so the keystroke reaches that app.
    static func pasteIntoFrontApp() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(9) // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
