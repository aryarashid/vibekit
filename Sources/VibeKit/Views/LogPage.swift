import SwiftUI
import VibeKitCore

/// Live output of a server Vibe Kit started, with terminal colors.
struct LogPage: View {
    let subtitle: String
    let url: URL
    let back: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @State private var text = NSAttributedString()

    private struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date?
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Logs", subtitle: subtitle, back: back) {
                IconButton(symbol: "arrow.up.forward.app", help: "Open in Console") {
                    NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
                IconButton(symbol: "folder", help: "Reveal log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider().opacity(0.6)
            LogTextView(text: text)
        }
        .onAppear { onHeightChange(PanelMetrics.maxHeight) }
        .task(id: url) {
            var lastStamp: FileStamp?
            while !Task.isCancelled {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let stamp = FileStamp(size: (attrs?[.size] as? UInt64) ?? 0, modified: attrs?[.modificationDate] as? Date)
                if stamp != lastStamp {
                    lastStamp = stamp
                    let url = url
                    let runs = await Task.detached(priority: .utility) {
                        ANSI.parse(Self.tail(of: url, bytes: 96 * 1024))
                    }.value
                    guard !Task.isCancelled else { return }
                    text = ANSI.attributed(runs)
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    nonisolated static func tail(of url: URL, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        var string = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = string.firstIndex(of: "\n") {
            let after = string[string.index(after: newline)...]
            if !after.isEmpty { string = String(after) }
        }
        return string.isEmpty ? "Waiting for output…" : string
    }
}

/// Turns terminal output into styled text: SGR colors and bold, carriage-return progress lines collapsed,
/// and every other escape sequence dropped.
enum ANSI {
    enum Tone: Equatable, Sendable {
        case muted, red, green, yellow, blue, purple, teal

        @MainActor var color: NSColor {
            switch self {
            case .muted: .secondaryLabelColor
            case .red: .systemRed
            case .green: .systemGreen
            case .yellow: .systemYellow
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .teal: .systemTeal
            }
        }
    }

    struct Run: Equatable, Sendable {
        let text: String
        let tone: Tone?
        let bold: Bool
        let dim: Bool
    }

    @MainActor static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    @MainActor static let boldFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
    @MainActor private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1.5
        return style
    }()

    @MainActor static func render(_ input: String) -> NSAttributedString {
        attributed(parse(input))
    }

    @MainActor static func attributed(_ runs: [Run]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            let color = run.tone?.color ?? (run.dim ? .secondaryLabelColor : .labelColor)
            result.append(NSAttributedString(string: run.text, attributes: [
                .font: run.bold ? boldFont : font,
                .paragraphStyle: paragraph,
                .foregroundColor: color,
            ]))
        }
        return result
    }

    static func parse(_ input: String) -> [Run] {
        var result: [Run] = []
        var tone: Tone?
        var bold = false
        var dim = false

        var lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        // Output that ends with a newline has no line after it. Without this, the text would end in a blank line.
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        for rawLine in lines {
            // Progress bars redraw with \r; keep only what was drawn last.
            let line = rawLine.split(separator: "\r", omittingEmptySubsequences: false).last(where: { !$0.isEmpty }) ?? ""
            var segment = ""
            var index = line.startIndex

            func flush() {
                guard !segment.isEmpty else { return }
                result.append(Run(text: segment, tone: tone, bold: bold, dim: dim))
                segment = ""
            }

            while index < line.endIndex {
                let char = line[index]
                if char == "\u{1B}" {
                    let next = line.index(after: index)
                    guard next < line.endIndex else { break }
                    switch line[next] {
                    case "[":
                        var end = line.index(after: next)
                        // ECMA-48 CSI final bytes span 0x40 ('@') through 0x7E ('~').
                        while end < line.endIndex, !(line[end].asciiValue.map({ $0 >= 0x40 && $0 <= 0x7E }) ?? false) {
                            end = line.index(after: end)
                        }
                        guard end < line.endIndex else { index = line.endIndex; continue }
                        if line[end] == "m" {
                            flush()
                            // Colon form (38:2:255:0:0, 4:3) carries its own sub-parameters: keep the first number,
                            // and drop colors entirely, since their values are not the next codes.
                            let codes = line[line.index(after: next)..<end].split(separator: ";", omittingEmptySubsequences: false)
                                .compactMap { param -> Int? in
                                    guard param.contains(":") else { return Int(param) ?? 0 }
                                    let first = param.split(separator: ":").first.flatMap { Int($0) } ?? 0
                                    return [38, 48, 58].contains(first) ? nil : first
                                }
                            apply(codes, tone: &tone, bold: &bold, dim: &dim)
                        }
                        index = line.index(after: end)
                    case "]", "P", "_", "^":
                        // OSC (window titles, links) and other strings: skip to BEL or ESC \.
                        index = line.index(after: next)
                        while index < line.endIndex, line[index] != "\u{07}", line[index] != "\u{1B}" { index = line.index(after: index) }
                        if index < line.endIndex, line[index] == "\u{1B}" {
                            index = line.index(after: index)
                            if index < line.endIndex, line[index] == "\\" { index = line.index(after: index) }
                        } else if index < line.endIndex {
                            index = line.index(after: index)
                        }
                    case "(", ")", "*", "+", "#", "%":
                        // Character set and line size selection, such as `tput sgr0`'s ESC ( B: one more character.
                        index = line.index(after: next)
                        if index < line.endIndex { index = line.index(after: index) }
                    default:
                        // Two-character escapes such as ESC 7 and ESC =.
                        index = line.index(after: next)
                    }
                    continue
                }
                segment.append(char)
                index = line.index(after: index)
            }
            segment.append("\n")
            flush()
        }
        return result
    }

    private static func apply(_ codes: [Int], tone: inout Tone?, bold: inout Bool, dim: inout Bool) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: tone = nil; bold = false; dim = false
            case 1: bold = true
            case 2: dim = true
            case 22: bold = false; dim = false
            case 30, 90: tone = .muted
            case 31, 91: tone = .red
            case 32, 92: tone = .green
            case 33, 93: tone = .yellow
            case 34, 94: tone = .blue
            case 35, 95: tone = .purple
            case 36, 96: tone = .teal
            case 37, 97, 39: tone = nil
            case 38, 48, 58:
                // 256-color and truecolor foreground, background and underline: skip their parameters.
                // Foreground keeps the default color; backgrounds are not drawn.
                i += codes.count > i + 1 && codes[i + 1] == 5 ? 2 : 4
            default: break
            }
            i += 1
        }
    }
}

/// The log text, in a native text view: selectable, and quick with long output. New output is appended, so a
/// selection survives, and the view follows the end only while you are at the end.
struct LogTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.isRichText = true
            view.textContainerInset = NSSize(width: 8, height: 10)
            view.font = ANSI.font
            view.setAccessibilityLabel("Log output")
            // TextKit 1 from the start: trimming old lines measures their height through the layout manager.
            _ = view.layoutManager
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let current = storage.string
        let incoming = text.string
        guard current != incoming else { return }
        let visible = scroll.contentView.bounds
        let atEnd = current.isEmpty || visible.maxY >= view.bounds.height - 30
        let oldLength = (current as NSString).length, newLength = (incoming as NSString).length
        if let (dropped, kept) = Self.overlap(from: current, to: incoming) {
            // Edit the text in place instead of replacing it, so a selection survives and, while you read further
            // up, the text stays where it is: drop lines that left the window, redo a last line that changed, add the rest.
            var removedHeight: CGFloat = 0
            if dropped > 0, let layout = view.layoutManager {
                layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: dropped))
                let glyph = layout.glyphIndexForCharacter(at: dropped)
                if glyph < layout.numberOfGlyphs {
                    removedHeight = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                }
            }
            // NSTextView collapses the selection when its storage changes, so carry it across, shifted.
            let selection = view.selectedRanges.map(\.rangeValue).compactMap { range -> NSValue? in
                guard range.length > 0, range.location >= dropped, NSMaxRange(range) <= dropped + kept else { return nil }
                return NSValue(range: NSRange(location: range.location - dropped, length: range.length))
            }
            storage.beginEditing()
            storage.deleteCharacters(in: NSRange(location: dropped + kept, length: oldLength - dropped - kept))
            storage.deleteCharacters(in: NSRange(location: 0, length: dropped))
            storage.append(text.attributedSubstring(from: NSRange(location: kept, length: newLength - kept)))
            // Colors can depend on an escape that just left the window, so the kept text takes the new render's style.
            if dropped > 0 {
                text.enumerateAttributes(in: NSRange(location: 0, length: kept)) { attributes, range, _ in
                    storage.setAttributes(attributes, range: range)
                }
            }
            storage.endEditing()
            if !selection.isEmpty { view.selectedRanges = selection }
            if removedHeight > 0, !atEnd {
                let origin = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y - removedHeight)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } else {
            storage.setAttributedString(text)
        }
        if atEnd { view.scrollToEndOfDocument(nil) }
    }

    /// How `new` continues `old`: the characters that fell off the front of `old` as the tail window moved, and how
    /// many after them `new` begins with. The last line of `old` is never kept, since a progress line redraws.
    /// Nil when the two do not overlap, such as after a restart cleared the log.
    nonisolated static func overlap(from old: String, to new: String) -> (dropped: Int, kept: Int)? {
        let old = old as NSString, new = new as NSString
        guard old.length > 0, new.length > 0 else { return nil }
        // Everything before the last line.
        let trimmed = old.hasSuffix("\n") ? old.length - 1 : old.length
        let lastBreak = old.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: trimmed))
        guard lastBreak.location != NSNotFound else { return nil }
        let body = old.substring(to: lastBreak.location + 1) as NSString
        if new.hasPrefix(body as String) { return (0, body.length) }
        let kept = longestSuffixThatStarts(Array((body as String).utf16), Array((new as String).utf16))
        return kept > 0 ? (body.length - kept, kept) : nil
    }

    /// The length of the longest end of `text` that is also the start of `pattern`, in one linear pass
    /// (Knuth–Morris–Pratt). However much output repeats, this finds the real overlap without a stall.
    nonisolated static func longestSuffixThatStarts(_ text: [UInt16], _ pattern: [UInt16]) -> Int {
        let pattern = pattern.prefix(text.count)
        guard !pattern.isEmpty else { return 0 }
        // failure[i]: the longest proper border of pattern[0...i].
        var failure = [Int](repeating: 0, count: pattern.count)
        var k = 0
        for i in 1..<pattern.count {
            while k > 0, pattern[i] != pattern[k] { k = failure[k - 1] }
            if pattern[i] == pattern[k] { k += 1 }
            failure[i] = k
        }
        var q = 0
        for unit in text {
            // A full match before the end cannot be the answer; fall back to its longest border and go on.
            if q == pattern.count { q = failure[q - 1] }
            while q > 0, unit != pattern[q] { q = failure[q - 1] }
            if unit == pattern[q] { q += 1 }
        }
        return q
    }
}
