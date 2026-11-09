import XCTest
@testable import VibeKit

@MainActor
final class RecentsTests: XCTestCase {
    func testShortLivedServersThatExitOnTheirOwnAreNotRemembered() {
        // A test harness server that lived a few seconds.
        XCTAssertFalse(ServerStore.isWorthRemembering(reason: .exited, lifetime: 3, managed: false))
        // A real dev server stopped with Ctrl-C after a while.
        XCTAssertTrue(ServerStore.isWorthRemembering(reason: .exited, lifetime: 600, managed: false))
        // Stopped from Vibe Kit, or crashed, is always worth a row, however short.
        XCTAssertTrue(ServerStore.isWorthRemembering(reason: .stopped, lifetime: 2, managed: false))
        XCTAssertTrue(ServerStore.isWorthRemembering(reason: .crashed(code: 1), lifetime: 2, managed: false))
        // One Vibe Kit started is kept, so an exit code that arrives after the port closed can still mark a crash.
        XCTAssertTrue(ServerStore.isWorthRemembering(reason: .exited, lifetime: 3, managed: true))
    }
}
