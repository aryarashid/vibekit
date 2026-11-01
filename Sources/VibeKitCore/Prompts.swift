import Foundation

/// A saved prompt: text you paste into an agent or chat again and again.
public struct Prompt: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Optional. Without one, the first line of the text stands in.
    public var title: String
    public var text: String
    public var pinned: Bool
    public var uses: Int
    public var lastUsed: Date?
    public var created: Date

    public init(id: UUID = UUID(), title: String = "", text: String, pinned: Bool = false, uses: Int = 0,
                lastUsed: Date? = nil, created: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.pinned = pinned
        self.uses = uses
        self.lastUsed = lastUsed
        self.created = created
    }

    /// The title, or the first non-empty line of the text.
    public var displayTitle: String {
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.isEmpty ? "Untitled" : String(line.prefix(80))
    }

    /// The text with runs of whitespace folded to single spaces, for a one or two line preview.
    public var preview: String {
        var body = text
        // Without a title the first line is already the title, so the preview starts after it.
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let range = text.range(of: displayTitle) {
            body = String(text[range.upperBound...])
        }
        return body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Ranks often and recently used prompts first. Each use counts fully for a day, then fades by half every week.
    public func score(now: Date = Date()) -> Double {
        guard uses > 0, let lastUsed else { return 0 }
        let days = max(0, now.timeIntervalSince(lastUsed) / 86_400 - 1)
        return Double(uses) * pow(0.5, days / 7)
    }

    private enum CodingKeys: String, CodingKey { case id, title, text, pinned, uses, lastUsed, created }

    /// Lenient, so a hand-edited file with missing fields still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        uses = try c.decodeIfPresent(Int.self, forKey: .uses) ?? 0
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

public enum PromptLibrary {
    /// Pinned first, then by how often and how recently each was used, then newest first.
    public static func sorted(_ prompts: [Prompt], now: Date = Date()) -> [Prompt] {
        prompts.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let sa = a.score(now: now), sb = b.score(now: now)
            if sa != sb { return sa > sb }
            return a.created > b.created
        }
    }

    /// Prompts whose title or text contains every word of the query. Title matches come first.
    public static func search(_ prompts: [Prompt], query: String, now: Date = Date()) -> [Prompt] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let ordered = sorted(prompts, now: now)
        guard !words.isEmpty else { return ordered }
        var inTitle: [Prompt] = [], inText: [Prompt] = []
        for prompt in ordered {
            let title = prompt.displayTitle.lowercased()
            let all = title + "\n" + prompt.text.lowercased()
            guard words.allSatisfy(all.contains) else { continue }
            if words.allSatisfy(title.contains) { inTitle.append(prompt) } else { inText.append(prompt) }
        }
        return inTitle + inText
    }

    /// No file means no prompts yet. A file that cannot be read or parsed throws, so it is never mistaken for an
    /// empty library and overwritten.
    public static func load(from url: URL) throws -> [Prompt] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Prompt].self, from: data)
    }

    public static func save(_ prompts: [Prompt], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Readable, so the file can be edited by hand or kept in a dotfiles repo.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(prompts).write(to: url, options: .atomic)
    }
}
