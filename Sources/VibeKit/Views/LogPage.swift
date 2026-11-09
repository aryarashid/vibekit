import SwiftUI
import VibeKitCore

/// Live output of a server Vibe Kit started, with terminal colors.
struct LogPage: View {
    let server: Server
    let store: ServerStore
    let back: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @State private var text = AttributedString()
    @State private var follow = true

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
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    Text(text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(1.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { _, _ in
                    if follow { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
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
                    text = rendered
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
    static func render(_ input: String) -> AttributedString {
        var result = AttributedString()
        var color: Color?
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
                if let color { piece.foregroundColor = color }
                if bold { piece.font = .system(size: 10.5, weight: .bold, design: .monospaced) }
                if dim && color == nil { piece.foregroundColor = .secondary }
                result.append(piece)
                segment = ""
            }

            while index < line.endIndex {
                let char = line[index]
                if char == "\u{1B}" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "[" {
                        var end = line.index(after: next)
                        while end < line.endIndex, !(line[end].isLetter || line[end] == "~") { end = line.index(after: end) }
                        guard end < line.endIndex else { break }
                        if line[end] == "m" {
                            flush()
                            let codes = line[line.index(after: next)..<end].split(separator: ";").compactMap { Int($0) }
                            apply(codes.isEmpty ? [0] : codes, color: &color, bold: &bold, dim: &dim)
                        }
                        index = line.index(after: end)
                        continue
                    }
                    // Other escapes (OSC titles and so on): skip to the terminator.
                    index = next
                    while index < line.endIndex, line[index] != "\u{07}", line[index] != "\\" { index = line.index(after: index) }
                    if index < line.endIndex { index = line.index(after: index) }
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

    private static func apply(_ codes: [Int], color: inout Color?, bold: inout Bool, dim: inout Bool) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: color = nil; bold = false; dim = false
            case 1: bold = true
            case 2: dim = true
            case 22: bold = false; dim = false
            case 30, 90: color = .secondary
            case 31, 91: color = Color(nsColor: .systemRed)
            case 32, 92: color = Color(nsColor: .systemGreen)
            case 33, 93: color = Color(nsColor: .systemYellow)
            case 34, 94: color = Color(nsColor: .systemBlue)
            case 35, 95: color = Color(nsColor: .systemPurple)
            case 36, 96: color = Color(nsColor: .systemTeal)
            case 37, 97, 39: color = nil
            case 38:
                // 256-color and truecolor: skip the parameters and keep the default color.
                i += codes.count > i + 1 && codes[i + 1] == 5 ? 2 : 4
            default: break
            }
            i += 1
        }
    }
}
