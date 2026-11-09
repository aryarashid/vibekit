import Foundation
import XCTest
@testable import VibeKit

final class LogTests: XCTestCase {
    func testTailReadsOnlyTheBudgetAndDropsPartialLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("discarded prefix\nfirst complete line\nlast line\n".utf8).write(to: url)
        XCTAssertEqual(LogPage.tail(of: url, bytes: 32), "first complete line\nlast line\n")
        XCTAssertEqual(LogPage.tail(of: url, bytes: 0), "")
    }

    func testTerminalColorsDoNotLeakEscapeSequences() {
        let output = ANSI.render("\u{1B}[31mError\u{1B}[0m\nprogress 1\rprogress 2")
        XCTAssertEqual(String(output.characters), "Error\nprogress 2\n")
    }

    func testTwoCharacterEscapesDoNotSwallowTheLine() {
        // `tput sgr0` emits ESC ( B; ESC 7 saves the cursor.
        let output = ANSI.render("\u{1B}(B\u{1B}[mready\u{1B}7 in 120 ms\n\u{1B}]0;title\u{07}next")
        XCTAssertEqual(String(output.characters), "ready in 120 ms\nnext\n")
    }

    func testTruecolorBackgroundIsNotReadAsDimOrRed() {
        let output = ANSI.render("\u{1B}[48;2;31;2;0mplain")
        let run = output.runs.first!
        XCTAssertEqual(run.appKit.foregroundColor, .labelColor)
        XCTAssertEqual(run.appKit.font, ANSI.font)
    }

    func testColonFormColorsDoNotResetTheLine() {
        let output = ANSI.render("\u{1B}[1m\u{1B}[38:2:255:0:0mbold")
        XCTAssertEqual(output.runs.first?.appKit.font, ANSI.boldFont)
    }

    func testASlidingTailWindowIsAnOverlapNotANewText() {
        let old = "line 1\nline 2\nprogress 4"
        // The window moved: line 1 fell off, and the progress line was redrawn.
        let slid = LogTextView.overlap(from: old, to: "line 2\nprogress 100%\nline 3\n")
        XCTAssertEqual(slid?.dropped, 7)
        XCTAssertEqual(slid?.kept, 7)
        // Plain growth keeps everything before the last line, which may still change.
        XCTAssertEqual(LogTextView.overlap(from: "a\nb\n", to: "a\nb\nc\n")?.kept, 2)
        // A cleared log is new text.
        XCTAssertNil(LogTextView.overlap(from: old, to: "Waiting for output…"))
    }

    func testRepetitiveLogsOverlapQuickly() {
        let old = String(repeating: "polling\n", count: 12_000) + "old tail\n"
        let grown = old + String(repeating: "other line\n", count: 4_300)
        let new = String(grown.suffix(98_000))
        let start = Date()
        let result = LogTextView.overlap(from: String(old.suffix(96_000)), to: new)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        // Only what really slid off is dropped, not most of the repeated text.
        XCTAssertNotNil(result)
        XCTAssertLessThan(result?.dropped ?? .max, 49_000)
        if let result {
            let oldText = String(old.suffix(96_000)) as NSString
            XCTAssertEqual(oldText.substring(with: NSRange(location: result.dropped, length: result.kept)),
                           (new as NSString).substring(to: result.kept))
        }
    }

    func testRepeatedLinesKeepTheLongestOverlap() {
        let old = String(repeating: "polling\n", count: 3_000)
        let new = String(repeating: "polling\n", count: 2_995) + "ready\n"
        // The last old line is always redone, so of the 2,999 lines before it, 4 slid off and 2,995 are kept.
        let result = LogTextView.overlap(from: old, to: new)
        XCTAssertEqual(result?.dropped, 4 * 8)
        XCTAssertEqual(result?.kept, 2_995 * 8)
    }

    func testADistinctLineAmongRepeatsKeepsThePlaceAfterALongSlide() {
        func polling(_ n: Int) -> String { String(repeating: "GET /api/health 200\n", count: n) }
        let old = polling(100) + "compiled in 120 ms\n" + polling(500)
        let new = polling(50) + "compiled in 120 ms\n" + polling(550)  // 50 lines slid off.
        let start = Date()
        let result = LogTextView.overlap(from: old, to: new)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(result?.dropped, 50 * 20)
    }

    func testOutputEndingInANewlineHasNoBlankLastLine() {
        XCTAssertEqual(String(ANSI.render("a\nb\n").characters), "a\nb\n")
    }
}
