import XCTest
@testable import Dulo

final class LeaseTests: XCTestCase {
    func testFreshOutsideMargin() {
        let lease = Lease("media", expiresAtElapsedMs: 100_000)
        XCTAssertTrue(lease.isFresh(nowElapsedMs: 0, marginMs: 60_000))
    }

    func testStaleInsideMargin() {
        let lease = Lease("media", expiresAtElapsedMs: 100_000)
        XCTAssertFalse(lease.isFresh(nowElapsedMs: 50_000, marginMs: 60_000))
    }

    func testStaleAfterExpiry() {
        let lease = Lease("media", expiresAtElapsedMs: 100_000)
        XCTAssertFalse(lease.isFresh(nowElapsedMs: 100_001, marginMs: 0))
    }
}
