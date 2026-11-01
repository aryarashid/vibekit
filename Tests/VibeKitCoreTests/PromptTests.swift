import Foundation
import Testing
@testable import VibeKitCore

@Suite("Prompts")
struct PromptTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func titleFallsBackToFirstLine() {
        let prompt = Prompt(text: "\n  Fix the bug  \nThen add a test.")
        #expect(prompt.displayTitle == "Fix the bug")
        #expect(prompt.preview == "Then add a test.")
        #expect(Prompt(text: "   ").displayTitle == "Untitled")
        #expect(Prompt(title: "Named", text: "Body\ntext").preview == "Body text")
    }

    @Test func pinnedFirstThenOftenAndRecentlyUsed() {
        let day: TimeInterval = 86_400
        let stale = Prompt(title: "stale", text: "a", uses: 50, lastUsed: now.addingTimeInterval(-60 * day))
        let fresh = Prompt(title: "fresh", text: "b", uses: 10, lastUsed: now.addingTimeInterval(-day / 2))
        let pinned = Prompt(title: "pinned", text: "c", pinned: true)
        let newer = Prompt(title: "newer", text: "d", created: now)
        let older = Prompt(title: "older", text: "e", created: now.addingTimeInterval(-day))
        let order = PromptLibrary.sorted([older, stale, newer, fresh, pinned], now: now).map(\.title)
        #expect(order == ["pinned", "fresh", "stale", "newer", "older"])
    }

    @Test func searchNeedsEveryWordAndRanksTitleMatchesFirst() {
        let a = Prompt(title: "Review the diff", text: "Look for bugs")
        let b = Prompt(title: "Plan", text: "Review the plan and the diff first")
        let c = Prompt(title: "Unrelated", text: "Nothing here")
        #expect(PromptLibrary.search([b, a, c], query: "diff review", now: now).map(\.title) == ["Review the diff", "Plan"])
        #expect(PromptLibrary.search([a, b, c], query: "BUGS", now: now).map(\.title) == ["Review the diff"])
        #expect(PromptLibrary.search([a, b, c], query: "  ", now: now).count == 3)
    }

    @Test func savesAndLoadsAndToleratesHandEdits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vk-prompts-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let prompt = Prompt(title: "T", text: "Body", pinned: true, uses: 3, lastUsed: now, created: now)
        try PromptLibrary.save([prompt], to: url)
        #expect(try PromptLibrary.load(from: url) == [prompt])

        try Data(#"[{"text": "Only text"}]"#.utf8).write(to: url)
        let loaded = try PromptLibrary.load(from: url)
        #expect(loaded.count == 1)
        #expect(loaded[0].text == "Only text")
        #expect(loaded[0].uses == 0 && !loaded[0].pinned)
    }

    @Test func missingFileIsEmptyButBrokenFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vk-prompts-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try PromptLibrary.load(from: url) == [])

        // Half way through a hand edit: must not read as an empty library.
        try Data(#"[{"text": "Only text"},"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try PromptLibrary.load(from: url) }
    }
}
