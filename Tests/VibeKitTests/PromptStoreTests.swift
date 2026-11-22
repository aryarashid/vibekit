import XCTest
@testable import VibeKit
import VibeKitCore

@MainActor
final class PromptStoreTests: XCTestCase {
    func testAnEditMadeOutsideVibeKitIsSeenAndNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vk-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prompts.json")
        let store = PromptStore(file: file)
        let prompt = store.add(text: "Original")

        // Edit by hand, as a person in a text editor would.
        var edited = try PromptLibrary.load(from: file)
        edited[0].text = "Edited by hand"
        try PromptLibrary.save(edited, to: file)

        store.reloadIfChanged()
        XCTAssertEqual(store.prompt(prompt.id)?.text, "Edited by hand")
        store.togglePin(prompt)
        XCTAssertEqual(try PromptLibrary.load(from: file).first?.text, "Edited by hand")
    }

    func testAHandWrittenPromptKeepsItsIDAcrossReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vk-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prompts.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"title": "Review", "text": "Review this diff"}]"#.utf8).write(to: file)

        let store = PromptStore(file: file)
        let id = try XCTUnwrap(store.prompts.first?.id)
        XCTAssertFalse(PromptLibrary.hasMissingIDs(at: file))

        // Another edit by hand, then a reload: the same prompt is still the same row.
        var edited = try PromptLibrary.load(from: file)
        edited[0].text = "Review this diff carefully"
        try PromptLibrary.save(edited, to: file)
        store.reloadIfChanged()
        XCTAssertEqual(store.prompt(id)?.text, "Review this diff carefully")
        XCTAssertEqual(store.prompts.count, 1)
    }

    func testSameSecondExternalEditChangingLengthIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vk-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prompts.json")
        let store = PromptStore(file: file)
        let prompt = store.add(text: "Short")
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        var edited = try PromptLibrary.load(from: file)
        edited[0].text = "Much longer external edit"
        try PromptLibrary.save(edited, to: file)
        // Pin modification date back to the exact timestamp the store recorded.
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        store.reloadIfChanged()
        XCTAssertEqual(store.prompt(prompt.id)?.text, "Much longer external edit")
    }

    func testClipboardSnapshotRestoresOnlyWhenUnchanged() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)

        let store = PromptStore(persists: false)
        store.copyForPaste("expanded prompt", restore: true, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "expanded prompt")

        let snapshot = store.takePendingClipboardRestore()
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(snapshot?.restore(to: pasteboard) == true)
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")

        // If the user copies something else before restore runs, do not clobber it.
        store.copyForPaste("another prompt", restore: true, pasteboard: pasteboard)
        let second = store.takePendingClipboardRestore()
        pasteboard.clearContents()
        pasteboard.setString("user copied meanwhile", forType: .string)
        XCTAssertTrue(second?.restore(to: pasteboard) == false)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied meanwhile")
    }

    func testOverlappingQuickPastesPreserveOriginalClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("user original", forType: .string)

        let store = PromptStore(persists: false)
        // First paste writes prompt 1 and starts waiting to restore.
        store.copyForPaste("prompt one", restore: true, pasteboard: pasteboard)
        let first = try XCTUnwrap(store.takePendingClipboardRestore())
        XCTAssertEqual(pasteboard.string(forType: .string), "prompt one")

        // Second paste happens before first restore runs: must carry "user original", not "prompt one".
        store.copyForPaste("prompt two", restore: true, pasteboard: pasteboard)
        let second = try XCTUnwrap(store.takePendingClipboardRestore())
        XCTAssertEqual(pasteboard.string(forType: .string), "prompt two")

        // First timer fires and skips because prompt two owns the pasteboard.
        XCTAssertFalse(store.finishClipboardRestore(first, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "prompt two")

        // Second timer fires and restores the user's original clipboard.
        XCTAssertTrue(store.finishClipboardRestore(second, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "user original")
    }
}
