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

    @Test func longFirstLineIsCutAtAWordAndNotRepeatedMidWord() {
        let line = Array(repeating: "audit", count: 30).joined(separator: " ") // 179 characters
        let prompt = Prompt(text: line + "\nNext line.")
        #expect(prompt.displayTitle.hasSuffix("audit…"))
        #expect(prompt.displayTitle.count <= 121)
        // The preview starts after the whole first line, not part way through a word of it.
        #expect(prompt.preview == "Next line.")
        #expect(Prompt(text: line).preview == "")
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

    @Test func savingThroughASymlinkKeepsTheLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vk-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("dotfiles-prompts.json")
        let link = dir.appendingPathComponent("prompts.json")
        try PromptLibrary.save([], to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try PromptLibrary.save([Prompt(title: "T", text: "Body", created: now)], to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try PromptLibrary.load(from: target).map(\.text) == ["Body"])
    }

    @Test func expandsKnownVariablesAndLeavesUnknownOrMissingUntouched() {
        let context = PromptContext(
            clipboard: "TypeError: undefined",
            url: "http://localhost:3000",
            port: "3000",
            branch: "feat/checkout",
            project: "storefront"
        )
        let template = "Fix {{project}} ({{branch}}) at {{url}} (port {{port}}):\n{{clipboard}}\nKeep {{unknown}} intact."
        let expanded = PromptVariables.expand(template, context: context)
        #expect(expanded == "Fix storefront (feat/checkout) at http://localhost:3000 (port 3000):\nTypeError: undefined\nKeep {{unknown}} intact.")
    }

    @Test func leavesMissingOrEmptyContextValuesUntouched() {
        let context = PromptContext(clipboard: "", url: "http://localhost:5173", port: nil, branch: "", project: "web")
        let template = "{{project}} on {{url}}:{{port}} ({{branch}}) — {{clipboard}}"
        #expect(PromptVariables.expand(template, context: context) == "web on http://localhost:5173:{{port}} ({{branch}}) — {{clipboard}}")
    }

    @Test func doesNotDoubleExpandSubstitutedValuesAndHandlesMalformedBraces() {
        let context = PromptContext(clipboard: "Check {{url}} and {{project}}", url: "http://localhost:3000", project: "app")
        #expect(PromptVariables.expand("Paste: {{clipboard}}", context: context) == "Paste: Check {{url}} and {{project}}")
        #expect(PromptVariables.expand("Nested {{{{url}}}} and unclosed {{port", context: context) == "Nested {{http://localhost:3000}} and unclosed {{port")
    }

    @Test func extractsUniqueKnownTokensInOrder() {
        let tokens = PromptVariables.tokens(in: "In {{project}} ({{branch}}), open {{url}}, check {{unknown}} and {{url}} again with {{clipboard}} on {{port}}")
        #expect(tokens == ["project", "branch", "url", "clipboard", "port"])
        #expect(PromptVariables.tokens(in: "No placeholders or {{unknown}} only") == [])
    }

    @Test func worktreeSlugStripsProjectPrefixAndServerHelpersWork() {
        let p1 = Project(name: "design-system", root: "/tmp/design-system-tokens", subpath: "packages/ui", branch: "feat/tokens", worktree: "design-system-tokens")
        #expect(p1.worktreeSlug == "tokens")
        #expect(p1.folder == "/tmp/design-system-tokens/packages/ui")

        let p2 = Project(name: "app", root: "/tmp/wt", subpath: nil, branch: "main", worktree: "hotfix")
        #expect(p2.worktreeSlug == "hotfix")

        let bindingV4 = PortBinding(port: 3000, address: "127.0.0.1", isIPv6: false)
        let bindingV6 = PortBinding(port: 3000, address: "::1", isIPv6: true, acceptsIPv4: false)
        let mailpit = Server(
            id: "mailpit", pid: 10, rootPid: 10, listenerPids: [10], startDate: now,
            ports: [bindingV4, bindingV6], framework: .mailpit, project: nil,
            processName: "mailpit", executable: "/opt/homebrew/bin/mailpit",
            command: "mailpit", directory: "/tmp", launch: nil
        )
        #expect(mailpit.opensInBrowser)
        #expect(mailpit.httpCheckKey == "/tmp:3000")
        #expect(mailpit.localURL(for: bindingV4, explicitLoopback: true)?.absoluteString == "http://127.0.0.1:3000")
        #expect(mailpit.localURL(for: bindingV6, explicitLoopback: true)?.absoluteString == "http://[::1]:3000")

        let pg = Server(
            id: "pg", pid: 11, rootPid: 11, listenerPids: [11], startDate: now,
            ports: [PortBinding(port: 5432, address: "127.0.0.1", isIPv6: false)], framework: .postgres, project: nil,
            processName: "postgres", executable: "/opt/homebrew/bin/postgres",
            command: "postgres", directory: nil, launch: nil
        )
        #expect(!pg.opensInBrowser)
        #expect(pg.localURL(for: pg.ports[0])?.absoluteString == "postgresql://localhost:5432")
    }
}
