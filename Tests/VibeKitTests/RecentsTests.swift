import XCTest
@testable import VibeKit

@MainActor
final class RecentsTests: XCTestCase {
    func testShortLivedServersThatExitOnTheirOwnAreNotRemembered() {
        // A test harness server that lived a few seconds.
        XCTAssertFalse(ServerStore.isWorthRemembering(reason: .exited, lifetime: 3))
        // A real dev server stopped with Ctrl-C after a while.
        XCTAssertTrue(ServerStore.isWorthRemembering(reason: .exited, lifetime: 600))
        // Stopped from Vibe Kit, or crashed, is always worth a row, however short.
        XCTAssertTrue(ServerStore.isWorthRemembering(reason: .stopped, lifetime: 2))
        XCTAssertTrue(ServerStore.isWorthRemembering(reason: .crashed(code: 1), lifetime: 2))
    }
}
