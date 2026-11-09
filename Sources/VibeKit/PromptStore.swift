import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import VibeKitCore

/// Saved prompts, kept in a readable JSON file you can edit by hand or sync.
@MainActor @Observable
final class PromptStore {
    private(set) var prompts: [Prompt] = []
    /// The last deleted prompt, so the footer can offer Undo for a few seconds.
    private(set) var deleted: Prompt?
    /// Why changes are not reaching the file right now, shown in the panel. Nil when all is saved.
    private(set) var problem: String?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private let persists: Bool
    /// The file exists but could not be read. Saving now would replace it, so nothing is saved until it reads again.
    @ObservationIgnored private var unreadable = false

    static let defaultFile = ServerStore.supportDirectory.appendingPathComponent("prompts.json")

    init(file: URL = PromptStore.defaultFile, persists: Bool = true) {
        self.file = file
        self.persists = persists
        if persists { reloadIfChanged() }
    }

    var pinnedCount: Int { prompts.count { $0.pinned } }

    func prompt(_ id: UUID) -> Prompt? { prompts.first { $0.id == id } }

    /// Picks up edits made to the file outside Vibe Kit. Cheap: one stat call when nothing changed.
    /// Every change calls it first, so a change never writes over an edit made elsewhere.
    func reloadIfChanged() {
        guard persists else { return }
        let modified = modificationDate()
        // A file that failed to read is tried again every time: fixing its permissions does not change its date.
        guard unreadable || modified == nil || modified != loadedAt else { return }
        loadedAt = modified
        do {
            prompts = try PromptLibrary.load(from: file)
            unreadable = false
            problem = nil
            // A hand-written entry with no id gets a new one on every read. Save once, so the ids stay put.
            if PromptLibrary.hasMissingIDs(at: file) { save() }
        } catch {
            // Keep what was last read, and leave the file alone until it reads again.
            unreadable = true
            problem = "prompts.json has an error, so nothing is saved"
        }
    }

    @discardableResult
    func add(text: String, title: String = "") -> Prompt {
        reloadIfChanged()
        let prompt = Prompt(title: title, text: text)
        prompts.append(prompt)
        save()
        return prompt
    }

    /// Changes the stored prompt with this ID. Returns false when there is none, for example after it was
    /// deleted in the file.
    @discardableResult
    func edit(_ id: UUID, _ change: (inout Prompt) -> Void) -> Bool {
        reloadIfChanged()
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return false }
        var prompt = prompts[index]
        change(&prompt)
        guard prompts[index] != prompt else { return true }
        prompts[index] = prompt
        save()
        return true
    }

    func delete(_ prompt: Prompt) {
        reloadIfChanged()
        // Undo brings back the prompt as stored, which may have changed in the file since the list showed it.
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        deleted = prompts.remove(at: index)
        save()
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { deleted = nil }
        }
    }

    func undoDelete() {
        guard let deleted else { return }
        self.deleted = nil
        reloadIfChanged()
        // It may be back already, restored in the file.
        guard prompt(deleted.id) == nil else { return }
        prompts.append(deleted)
        save()
    }

    func togglePin(_ prompt: Prompt) {
        edit(prompt.id) { $0.pinned.toggle() }
    }

    /// Puts the prompt on the clipboard and counts the use.
    func copy(_ prompt: Prompt) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.text, forType: .string)
        edit(prompt.id) {
            $0.uses += 1
            $0.lastUsed = Date()
        }
    }

    func revealFile() {
        if !FileManager.default.fileExists(atPath: file.path) { reloadIfChanged(); save() }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func save() {
        guard persists, !unreadable else { return }
        do {
            try PromptLibrary.save(prompts, to: file)
            loadedAt = modificationDate()
            problem = nil
        } catch {
            problem = "Could not save prompts: \(error.localizedDescription)"
        }
    }

    /// Read fresh every time. `URL.resourceValues` caches on the URL, which hid edits made outside Vibe Kit
    /// and then let the next save write over them.
    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
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
        let v = CGKeyCode(KeyLayout.keyCode(for: "v", fallback: kVK_ANSI_V))
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
