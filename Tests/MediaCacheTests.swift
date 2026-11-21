import XCTest
@testable import Dulo

final class MediaCacheTests: XCTestCase {
    func testMediaCacheKeyWithHint() {
        let url = URL(string: "https://example.com/video.mp4?token=123&exp=456")!
        let key = MediaCacheKey.compute(url: url, hint: "video123")
        XCTAssertEqual(key, "k_video123")
    }

    func testMediaCacheKeyTOSPathNormalization() {
        let url1 = URL(string: "https://v3-dy-o.zjcdn.com/abc/123/video/tos/cn/tos-cn-ve-15c800-ce/oAigHEvzsAI2EnrQ/?token=aaa&x-expires=100")!
        let url2 = URL(string: "https://v26-dy.zjcdn.com/xyz/456/video/tos/cn/tos-cn-ve-15c800-ce/oAigHEvzsAI2EnrQ/?token=bbb&x-expires=200")!

        let key1 = MediaCacheKey.compute(url: url1)
        let key2 = MediaCacheKey.compute(url: url2)

        // Both URLs point to the same underlying ByteDance TOS object; they MUST produce identical cache keys!
        XCTAssertEqual(key1, key2)
        XCTAssertFalse(key1.isEmpty)
    }

    func testMediaCacheStorageWriteAndRead() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let storage = MediaCacheStorage(cacheDirectory: tempDir, maxDiskSize: 10 * 1024 * 1024, targetDiskSize: 5 * 1024 * 1024)
        defer { storage.clearAll() }

        let testKey = "test_item_1"
        let testData = Data("HelloWorld1234567890".utf8)
        storage.writeData(for: testKey, data: testData, offset: 0, contentLength: 100, contentType: "video/mp4")

        let meta = storage.metadata(for: testKey)
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.contentLength, 100)
        XCTAssertEqual(meta?.cachedBytes, Int64(testData.count))
        XCTAssertEqual(meta?.contentType, "video/mp4")

        let readChunk = storage.readData(for: testKey, offset: 5, length: 5)
        XCTAssertNotNil(readChunk)
        XCTAssertEqual(String(data: readChunk!, encoding: .utf8), "World")
    }

    func testMediaCacheStoragePinningProtectsAgainstEviction() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        // High watermark: 150 bytes, Target: 50 bytes
        let storage = MediaCacheStorage(cacheDirectory: tempDir, maxDiskSize: 150, targetDiskSize: 50)
        defer { storage.clearAll() }

        let pinnedKey = "pinned_video"
        let unpinnedKey = "unpinned_video"
        let chunk = Data(repeating: 0x41, count: 100)

        // Write pinned item
        storage.writeData(for: pinnedKey, data: chunk, offset: 0, contentLength: 100, contentType: "video/mp4")
        storage.pin(key: pinnedKey)

        // Write unpinned item -> total exceeds high watermark (200 > 150)
        storage.writeData(for: unpinnedKey, data: chunk, offset: 0, contentLength: 100, contentType: "video/mp4")

        // Force eviction
        storage.evictIfNeeded()

        // Pinned item MUST survive!
        XCTAssertNotNil(storage.metadata(for: pinnedKey))
        // Unpinned item should have been evicted to reduce usage below target watermark
        XCTAssertNil(storage.metadata(for: unpinnedKey))
    }
}
