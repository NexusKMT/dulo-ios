import XCTest
#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class LeaseLruCacheTests: XCTestCase {
    func testAccessMovesLeaseToMostRecentlyUsedBeforeEviction() {
        let cache = LeaseLruCache<String>(maxSize: 2)
        cache.put(key: "first", lease: lease("first"))
        cache.put(key: "second", lease: lease("second"))

        XCTAssertEqual("first", cache["first"]?.value)
        cache.put(key: "third", lease: lease("third"))

        XCTAssertTrue(cache.contains("first"), "the accessed lease stays resident")
        XCTAssertFalse(cache.contains("second"), "the least-recently-used lease is evicted")
        XCTAssertTrue(cache.contains("third"))
        XCTAssertEqual(2, cache.size)
    }

    func testExpiredLeasesArePrunedOnAccess() {
        let cache = LeaseLruCache<String>(maxSize: 2)
        cache.put(key: "expired", lease: Lease("expired", expiresAt: Date().addingTimeInterval(-10)))
        cache.put(key: "fresh", lease: Lease("fresh", expiresAt: Date().addingTimeInterval(100)))

        XCTAssertNil(cache["expired"])
        XCTAssertFalse(cache.contains("expired"))
        XCTAssertEqual("fresh", cache["fresh"]?.value)
    }

    private func lease(_ value: String) -> Lease<String> {
        Lease(value, expiresAt: Date().addingTimeInterval(100))
    }
}
