import XCTest

final class LeaseLruCacheTests: XCTestCase {
    func testAccessMovesLeaseToMostRecentlyUsedBeforeEviction() {
        let cache = LeaseLruCache<String>(maxSize: 2)
        cache.put(key: "first", lease: lease("first"), nowElapsedMs: 0)
        cache.put(key: "second", lease: lease("second"), nowElapsedMs: 0)

        XCTAssertEqual("first", cache["first"]?.value)
        cache.put(key: "third", lease: lease("third"), nowElapsedMs: 0)

        XCTAssertTrue(cache.contains("first"), "the accessed lease stays resident")
        XCTAssertFalse(cache.contains("second"), "the least-recently-used lease is evicted")
        XCTAssertTrue(cache.contains("third"))
        XCTAssertEqual(2, cache.size)
    }

    func testExpiredLeasesArePrunedBeforeTheNextWrite() {
        let cache = LeaseLruCache<String>(maxSize: 2)
        cache.put(key: "expired", lease: Lease("expired", expiresAtElapsedMs: 10), nowElapsedMs: 0)
        cache.put(key: "fresh", lease: Lease("fresh", expiresAtElapsedMs: 100), nowElapsedMs: 0)

        cache.put(key: "next", lease: Lease("next", expiresAtElapsedMs: 100), nowElapsedMs: 10)

        XCTAssertNil(cache["expired"])
        XCTAssertEqual("fresh", cache["fresh"]?.value)
        XCTAssertEqual("next", cache["next"]?.value)
        XCTAssertEqual(2, cache.size)
    }

    private func lease(_ value: String) -> Lease<String> {
        Lease(value, expiresAtElapsedMs: 100)
    }
}
