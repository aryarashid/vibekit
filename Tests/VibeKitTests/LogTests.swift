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
        XCTAssertEqual(slid?.kept, 16)
        // Plain growth keeps everything.
        XCTAssertEqual(LogTextView.overlap(from: "a\nb\n", to: "a\nb\nc\n")?.kept, 4)
        // A cleared log is new text.
        XCTAssertNil(LogTextView.overlap(from: old, to: "Waiting for output…"))
    }

    func testOutputEndingInANewlineHasNoBlankLastLine() {
        XCTAssertEqual(String(ANSI.render("a\nb\n").characters), "a\nb\n")
    }
}
