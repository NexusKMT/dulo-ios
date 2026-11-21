import XCTest
@testable import Dulo

@MainActor
final class FeedPlayerPoolTests: XCTestCase {
    func testParityAlternation() {
        let pool = FeedPlayerPool()
        XCTAssertTrue(pool.player(for: 0) === pool.playerA)
        XCTAssertTrue(pool.player(for: 1) === pool.playerB)
        XCTAssertTrue(pool.player(for: 2) === pool.playerA)
        XCTAssertTrue(pool.player(for: 3) === pool.playerB)
        XCTAssertTrue(pool.player(for: 100) === pool.playerA)
        XCTAssertTrue(pool.player(for: 101) === pool.playerB)
    }

    func testSyncPlaybackPausesOtherPlayer() {
        let pool = FeedPlayerPool()

        // When scene is active and stream 0 is active: Player B must be strictly paused
        pool.syncPlayback(activeStreamId: 0, sceneActive: true)
        XCTAssertEqual(pool.playerB.player.rate, 0)

        // When switching to stream 1: Player A must be strictly paused
        pool.syncPlayback(activeStreamId: 1, sceneActive: true)
        XCTAssertEqual(pool.playerA.player.rate, 0)

        // When scene is inactive: both pause
        pool.syncPlayback(activeStreamId: 1, sceneActive: false)
        XCTAssertEqual(pool.playerA.player.rate, 0)
        XCTAssertEqual(pool.playerB.player.rate, 0)
    }
}
