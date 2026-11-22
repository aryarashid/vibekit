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

    private struct FileStamp: Equatable {
        let modified: Date?
        let size: UInt64?
    }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var loadedStamp: FileStamp?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private let persists: Bool
    /// The file exists but could not be read. Saving now would replace it, so nothing is saved until it reads again.
    @ObservationIgnored private var unreadable = false
    /// Clipboard contents captured right before copying a prompt for paste, so they can be restored after ⌘V.
    @ObservationIgnored private var pendingClipboardRestore: ClipboardSnapshot?
    /// Tracks the original user clipboard across overlapping quick pastes while Vibe Kit still owns the pasteboard.
    @ObservationIgnored private var activeClipboardRestore: ClipboardSnapshot?

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
        let stamp = currentStamp()
        if stamp == nil && loadedStamp == nil && !unreadable && prompts.isEmpty { return }
        // A file that failed to read is tried again every time: fixing its permissions does not change its date.
        guard unreadable || stamp == nil || stamp != loadedStamp else { return }
        loadedStamp = stamp
        do {
            let loaded = try PromptLibrary.load(from: file)
            if prompts != loaded { prompts = loaded }
            unreadable = false
            problem = nil
            // A hand-written entry with no id gets a new one on every read. Save once, so the ids stay put.
            if stamp != nil, PromptLibrary.hasMissingIDs(at: file) { save() }
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

    /// Puts raw text on the clipboard without changing prompt usage order.
    @discardableResult
    func copyToClipboard(_ text: String, pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Puts the prompt on the clipboard without changing its order yet.
    func copyToClipboard(_ prompt: Prompt) {
        copyToClipboard(prompt.text)
    }

    /// Snapshots the clipboard (when `restore` is true) and writes `text` ready to paste into the front app.
    /// Overlapping quick pastes carry the user's original clipboard forward while Vibe Kit still owns it.
    func copyForPaste(_ text: String, restore: Bool, pasteboard: NSPasteboard = .general) {
        guard restore else {
            pendingClipboardRestore = nil
            activeClipboardRestore = nil
            _ = copyToClipboard(text, pasteboard: pasteboard)
            return
        }
        let savedItems: [NSPasteboardItem]
        if let existing = pendingClipboardRestore ?? activeClipboardRestore,
           pasteboard.changeCount == existing.expectedChangeCount {
            savedItems = existing.items
        } else {
            savedItems = ClipboardSnapshot.capture(from: pasteboard)
        }
        let changeCount = copyToClipboard(text, pasteboard: pasteboard)
        let snapshot = ClipboardSnapshot(items: savedItems, expectedChangeCount: changeCount)
        pendingClipboardRestore = snapshot
        activeClipboardRestore = snapshot
    }

    func takePendingClipboardRestore() -> ClipboardSnapshot? {
        defer { pendingClipboardRestore = nil }
        return pendingClipboardRestore
    }

    func clearPendingClipboardRestore() {
        pendingClipboardRestore = nil
        activeClipboardRestore = nil
    }

    @discardableResult
    func finishClipboardRestore(_ snapshot: ClipboardSnapshot, pasteboard: NSPasteboard = .general) -> Bool {
        let restored = snapshot.restore(to: pasteboard)
        if activeClipboardRestore?.expectedChangeCount == snapshot.expectedChangeCount {
            activeClipboardRestore = nil
        }
        return restored
    }

    /// Counts one use of `id` and saves.
    func recordUse(_ id: UUID) {
        edit(id) {
            $0.uses += 1
            $0.lastUsed = Date()
        }
    }

    /// Puts the prompt (or its expanded text) on the clipboard and counts the use.
    func copy(_ prompt: Prompt, expandedText: String? = nil) {
        copyToClipboard(expandedText ?? prompt.text)
        recordUse(prompt.id)
    }

    func revealFile() {
        if !FileManager.default.fileExists(atPath: file.path) { reloadIfChanged(); save() }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func save() {
        guard persists, !unreadable else { return }
        do {
            try PromptLibrary.save(prompts, to: file)
            loadedStamp = currentStamp()
            problem = nil
        } catch {
            problem = "Could not save prompts: \(error.localizedDescription)"
        }
    }

    /// Read fresh every time. `URL.resourceValues` caches on the URL, which hid edits made outside Vibe Kit
    /// and then let the next save write over them. Include size so same-second edits are caught too.
    private func currentStamp() -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path) else {
            return nil
        }
        return FileStamp(modified: attributes[.modificationDate] as? Date, size: attributes[.size] as? UInt64)
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

/// All items on a pasteboard before a paste, restored afterward only if nothing else wrote to it meanwhile.
@MainActor
struct ClipboardSnapshot {
    let items: [NSPasteboardItem]
    let expectedChangeCount: Int

    static func capture(from pasteboard: NSPasteboard = .general) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        return true
    }
}
