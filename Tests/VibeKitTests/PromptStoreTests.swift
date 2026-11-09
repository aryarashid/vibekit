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
}
