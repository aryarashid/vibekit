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

    /// The title, or the first non-empty line of the text, cut at a word near 120 characters.
    public var displayTitle: String {
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let line = firstLine
        guard !line.isEmpty else { return "Untitled" }
        guard line.count > 120 else { return line }
        let cut = line.prefix(120)
        let word = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The text with runs of whitespace folded to single spaces, for a one line preview.
    /// Without a title the first line is the title, so the preview is what comes after that whole line.
    public var preview: String {
        var body = Substring(text)
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let range = text.range(of: firstLine) {
            body = text[range.upperBound...]
        }
        return body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var firstLine: String {
        text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
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

    /// True when an entry in the file has no id, as in one written by hand.
    public static func hasMissingIDs(at url: URL) -> Bool {
        struct Entry: Decodable { let id: UUID? }
        guard let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return false }
        return entries.contains { $0.id == nil }
    }

    public static func save(_ prompts: [Prompt], to link: URL) throws {
        // A prompts.json kept in a dotfiles repo is often a symlink. Write to its target, so the link survives.
        let url = link.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Readable, so the file can be edited by hand or kept in a dotfiles repo.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(prompts).write(to: url, options: .atomic)
    }
}

/// Live values a prompt template can pull in when used.
public struct PromptContext: Equatable, Sendable {
    public var clipboard: String?
    public var url: String?
    public var port: String?
    public var branch: String?
    public var project: String?

    public init(clipboard: String? = nil, url: String? = nil, port: String? = nil, branch: String? = nil, project: String? = nil) {
        self.clipboard = clipboard
        self.url = url
        self.port = port
        self.branch = branch
        self.project = project
    }

    func value(for token: String) -> String? {
        let raw: String? = switch token {
        case "clipboard": clipboard
        case "url": url
        case "port": port
        case "branch": branch
        case "project": project
        default: nil
        }
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}

/// Expands `{{variable}}` placeholders in saved prompts.
public enum PromptVariables {
    public static let supported: [String] = ["clipboard", "url", "port", "branch", "project"]
    private static let supportedSet: Set<String> = Set(supported)

    /// Expands known placeholders (`{{clipboard}}`, `{{url}}`, `{{port}}`, `{{branch}}`, `{{project}}`) in a single
    /// pass so substituted text is never re-expanded. Unknown tokens and missing or empty values stay untouched.
    public static func expand(_ template: String, context: PromptContext) -> String {
        guard template.contains("{{") else { return template }
        var output = ""
        output.reserveCapacity(template.count)
        var cursor = template.startIndex

        while let open = template.range(of: "{{", range: cursor..<template.endIndex) {
            output.append(contentsOf: template[cursor..<open.lowerBound])
            let afterOpen = open.upperBound
            guard let close = template.range(of: "}}", range: afterOpen..<template.endIndex) else {
                output.append(contentsOf: template[open.lowerBound..<template.endIndex])
                return output
            }
            // If another `{{` appears before `}}`, treat the earlier `{{` as literal text and try again from the inner one.
            if let nested = template.range(of: "{{", range: afterOpen..<close.lowerBound) {
                output.append(contentsOf: template[open.lowerBound..<nested.lowerBound])
                cursor = nested.lowerBound
                continue
            }
            let name = String(template[afterOpen..<close.lowerBound])
            if let value = context.value(for: name) {
                output.append(value)
            } else {
                output.append(contentsOf: template[open.lowerBound..<close.upperBound])
            }
            cursor = close.upperBound
        }

        output.append(contentsOf: template[cursor..<template.endIndex])
        return output
    }

    /// Unique known placeholder names present in `template`, in order of first appearance.
    public static func tokens(in template: String) -> [String] {
        guard template.contains("{{") else { return [] }
        var found: [String] = []
        var seen: Set<String> = []
        var cursor = template.startIndex

        while let open = template.range(of: "{{", range: cursor..<template.endIndex) {
            let afterOpen = open.upperBound
            guard let close = template.range(of: "}}", range: afterOpen..<template.endIndex) else { break }
            if let nested = template.range(of: "{{", range: afterOpen..<close.lowerBound) {
                cursor = nested.lowerBound
                continue
            }
            let name = String(template[afterOpen..<close.lowerBound])
            if supportedSet.contains(name), seen.insert(name).inserted {
                found.append(name)
            }
            cursor = close.upperBound
        }

        return found
    }
}
