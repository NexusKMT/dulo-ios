import XCTest
#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class LeaseTests: XCTestCase {
    func testFreshOutsideMargin() {
        let lease = Lease("media", expiresAt: Date().addingTimeInterval(100))
        XCTAssertTrue(lease.isFresh(asOf: Date(), margin: 60))
    }

    func testStaleInsideMargin() {
        let lease = Lease("media", expiresAt: Date().addingTimeInterval(50))
        XCTAssertFalse(lease.isFresh(asOf: Date(), margin: 60))
    }

    func testStaleAfterExpiry() {
        let lease = Lease("media", expiresAt: Date().addingTimeInterval(-1))
        XCTAssertFalse(lease.isFresh(asOf: Date(), margin: 0))
    }
}
