import SwiftUI
import VibeKitCore

/// Live output of a server Vibe Kit started, with terminal colors.
struct LogPage: View {
    let server: Server
    let store: ServerStore
    let back: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @State private var text = NSAttributedString()

    private var url: URL? { store.logURL(for: server) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Logs", subtitle: "\(server.title) · \(server.primaryPort)", back: back) {
                if let url {
                    IconButton(symbol: "arrow.up.forward.app", help: "Open in Console") {
                        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                    IconButton(symbol: "folder", help: "Reveal log file") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Divider().opacity(0.6)
            LogTextView(text: text)
        }
        .onAppear { onHeightChange(PanelMetrics.maxHeight) }
        .task(id: url) {
            guard let url else { return }
            var lastSize: UInt64 = .max
            while !Task.isCancelled {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
                if size != lastSize {
                    lastSize = size
                    let rendered = await Task.detached(priority: .utility) {
                        ANSI.render(Self.tail(of: url, bytes: 96 * 1024))
                    }.value
                    guard !Task.isCancelled else { return }
                    text = NSAttributedString(rendered)
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
        if start > 0, let newline = string.firstIndex(of: "\n") { string = String(string[string.index(after: newline)...]) }
        return string.isEmpty ? "Waiting for output…" : string
    }
}

/// Turns terminal output into styled text: SGR colors and bold, carriage-return progress lines collapsed,
/// and every other escape sequence dropped.
enum ANSI {
    // Fonts and paragraph styles are immutable, so sharing them across threads is safe.
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    nonisolated(unsafe) static let boldFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
    nonisolated(unsafe) private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1.5
        return style
    }()

    static func render(_ input: String) -> AttributedString {
        var result = AttributedString()
        var color: NSColor?
        var bold = false
        var dim = false

        for rawLine in input.split(separator: "\n", omittingEmptySubsequences: false) {
            // Progress bars redraw with \r; keep only what was drawn last.
            let line = rawLine.split(separator: "\r", omittingEmptySubsequences: false).last(where: { !$0.isEmpty }) ?? ""
            var segment = ""
            var index = line.startIndex

            func flush() {
                guard !segment.isEmpty else { return }
                var piece = AttributedString(segment)
                piece.appKit.font = bold ? boldFont : font
                piece.appKit.paragraphStyle = paragraph
                piece.appKit.foregroundColor = color ?? (dim ? .secondaryLabelColor : .labelColor)
                result.append(piece)
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
                        while end < line.endIndex, !(line[end].isLetter || line[end] == "~") { end = line.index(after: end) }
                        guard end < line.endIndex else { index = line.endIndex; continue }
                        if line[end] == "m" {
                            flush()
                            let codes = line[line.index(after: next)..<end].split(separator: ";", omittingEmptySubsequences: false)
                                .map { Int($0) ?? 0 }
                            apply(codes.isEmpty ? [0] : codes, color: &color, bold: &bold, dim: &dim)
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

    private static func apply(_ codes: [Int], color: inout NSColor?, bold: inout Bool, dim: inout Bool) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: color = nil; bold = false; dim = false
            case 1: bold = true
            case 2: dim = true
            case 22: bold = false; dim = false
            case 30, 90: color = .secondaryLabelColor
            case 31, 91: color = .systemRed
            case 32, 92: color = .systemGreen
            case 33, 93: color = .systemYellow
            case 34, 94: color = .systemBlue
            case 35, 95: color = .systemPurple
            case 36, 96: color = .systemTeal
            case 37, 97, 39: color = nil
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
private struct LogTextView: NSViewRepresentable {
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
        if !current.isEmpty, incoming.hasPrefix(current) {
            let added = NSRange(location: (current as NSString).length, length: (incoming as NSString).length - (current as NSString).length)
            storage.append(text.attributedSubstring(from: added))
        } else {
            storage.setAttributedString(text)
        }
        if atEnd { view.scrollToEndOfDocument(nil) }
    }
}
