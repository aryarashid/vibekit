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
}
