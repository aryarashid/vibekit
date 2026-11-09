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
}
