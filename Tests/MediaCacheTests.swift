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
        XCTAssertTrue(key1.hasPrefix("k_"))
        XCTAssertFalse(key1.isEmpty)
    }

    func testMediaCacheKeyUniformPrefix() {
        let url = URL(string: "https://cdn.example.com/stream/segment.mp4?query=1")!
        let key = MediaCacheKey.compute(url: url)
        XCTAssertTrue(key.hasPrefix("k_"))
        XCTAssertEqual(MediaCacheKey.key(for: "raw_id"), "k_raw_id")
        XCTAssertEqual(MediaCacheKey.key(for: "k_already_prefixed"), "k_already_prefixed")
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

    func testMediaCacheStorageUnpinAllowsEviction() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let storage = MediaCacheStorage(cacheDirectory: tempDir, maxDiskSize: 150, targetDiskSize: 50)
        defer { storage.clearAll() }

        let videoA = "video_a"
        let videoB = "video_b"
        let chunk = Data(repeating: 0x55, count: 100)

        storage.writeData(for: videoA, data: chunk, offset: 0, contentLength: 100, contentType: "video/mp4")
        storage.pin(key: videoA)
        XCTAssertTrue(storage.isPinned(key: videoA))

        // Multiple pins requirement
        storage.pin(key: videoA)
        storage.unpin(key: videoA)
        XCTAssertTrue(storage.isPinned(key: videoA)) // Still 1 pin active!

        storage.unpin(key: videoA)
        XCTAssertFalse(storage.isPinned(key: videoA)) // Now completely unpinned!

        // Exceed watermark
        storage.writeData(for: videoB, data: chunk, offset: 0, contentLength: 100, contentType: "video/mp4")
        storage.pin(key: videoB)

        storage.evictIfNeeded()

        // videoA was unpinned and should be evicted
        XCTAssertNil(storage.metadata(for: videoA))
        XCTAssertNotNil(storage.metadata(for: videoB))
    }

    func testImageDiskCacheStoreAndRead() {
        let uniqueDir = "TestImageDiskCache_\(UUID().uuidString)"
        let diskCache = ImageDiskCache(directoryName: uniqueDir)
        defer { diskCache.clearAll() }

        let testUrl = URL(string: "https://example.com/images/test.jpg?token=abc")!
        let rawBytes = Data("TestImageDataPayload_12345".utf8)

        XCTAssertFalse(diskCache.contains(url: testUrl))
        diskCache.store(data: rawBytes, for: testUrl)

        XCTAssertTrue(diskCache.contains(url: testUrl))
        let fetched = diskCache.data(for: testUrl)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched, rawBytes)
    }

    func testMoovBoundaryParsingShortVideo() {
        // Synthetic MP4: ftyp (32 bytes) + moov (133,717 bytes)
        var header = Data()
        var ftypSize: UInt32 = UInt32(32).bigEndian
        withUnsafeBytes(of: &ftypSize) { header.append(contentsOf: $0) }
        header.append("ftyp".data(using: .isoLatin1)!)
        header.append(Data(repeating: 0, count: 24))

        var moovSize: UInt32 = UInt32(133717).bigEndian
        withUnsafeBytes(of: &moovSize) { header.append(contentsOf: $0) }
        header.append("moov".data(using: .isoLatin1)!)

        let boundary = MediaPreloadManager.parseMoovBoundary(in: header)
        XCTAssertEqual(boundary, 133749)
    }

    func testMoovBoundaryParsingLongVideo() {
        // Synthetic 42-minute MP4 (e.g. 阳光谷一口气看完): ftyp (32 bytes) + moov (2,022,417 bytes)
        var header = Data()
        var ftypSize: UInt32 = UInt32(32).bigEndian
        withUnsafeBytes(of: &ftypSize) { header.append(contentsOf: $0) }
        header.append("ftyp".data(using: .isoLatin1)!)
        header.append(Data(repeating: 0, count: 24))

        var moovSize: UInt32 = UInt32(2022417).bigEndian
        withUnsafeBytes(of: &moovSize) { header.append(contentsOf: $0) }
        header.append("moov".data(using: .isoLatin1)!)

        let boundary = MediaPreloadManager.parseMoovBoundary(in: header)
        XCTAssertEqual(boundary, 2022449)
    }

    func testMoovBoundaryParsingMdatFirstReturnsNil() {
        // Synthetic MP4 with moov at EOF (mdat first)
        var header = Data()
        var ftypSize: UInt32 = UInt32(32).bigEndian
        withUnsafeBytes(of: &ftypSize) { header.append(contentsOf: $0) }
        header.append("ftyp".data(using: .isoLatin1)!)
        header.append(Data(repeating: 0, count: 24))

        var mdatSize: UInt32 = UInt32(100000).bigEndian
        withUnsafeBytes(of: &mdatSize) { header.append(contentsOf: $0) }
        header.append("mdat".data(using: .isoLatin1)!)

        let boundary = MediaPreloadManager.parseMoovBoundary(in: header)
        XCTAssertNil(boundary)
    }

    func testMediaCacheStorageReadDataPastPhysicalLengthReturnsNil() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let storage = MediaCacheStorage(cacheDirectory: tempDir, maxDiskSize: 10 * 1024 * 1024, targetDiskSize: 5 * 1024 * 1024)
        defer { storage.clearAll() }

        let testKey = "test_item_truncated"
        let testData = Data("SmallData".utf8) // 9 bytes
        storage.writeData(for: testKey, data: testData, offset: 0, contentLength: 1000, contentType: "video/mp4")

        // Reading within cached bytes succeeds
        let validChunk = storage.readData(for: testKey, offset: 0, length: 5)
        XCTAssertNotNil(validChunk)
        XCTAssertEqual(validChunk?.count, 5)

        // Reading past cached bytes MUST return nil, never empty Data()
        let pastChunk = storage.readData(for: testKey, offset: 9, length: 10)
        XCTAssertNil(pastChunk)
    }

    func testLocalMediaProxyServerLifecycleAndEnsureRunning() {
        let proxy = LocalMediaProxyServer.shared
        proxy.start()
        XCTAssertTrue(proxy.isRunning)
        XCTAssertTrue(proxy.port > 0)
        XCTAssertTrue(proxy.isHealthy())

        // Stop simulation
        proxy.stop()
        XCTAssertFalse(proxy.isRunning)
        XCTAssertFalse(proxy.isHealthy())

        // ensureRunning should detect and heal
        proxy.ensureRunning()
        XCTAssertTrue(proxy.isRunning)
        XCTAssertTrue(proxy.isHealthy())
        XCTAssertTrue(proxy.port > 0)
    }

    @MainActor
    func testPlaybackInterruptionCoordinatorIntentStateMachine() {
        let coordinator = PlaybackInterruptionCoordinator.shared
        coordinator.recordPlaybackStarted()
        XCTAssertFalse(coordinator.userPaused)
        XCTAssertFalse(coordinator.pausedByInterruption)
        XCTAssertFalse(coordinator.shouldResumeOnActive)

        // Lock screen / background interruption
        coordinator.handleAppResignActive()
        XCTAssertFalse(coordinator.userPaused)
        XCTAssertTrue(coordinator.pausedByInterruption)
        XCTAssertTrue(coordinator.shouldResumeOnActive)

        // Return to active -> auto resume
        coordinator.handleAppBecomeActive()
        XCTAssertFalse(coordinator.pausedByInterruption)

        // Explicit user pause (tap to pause)
        coordinator.setUserPaused(true)
        XCTAssertTrue(coordinator.userPaused)
        XCTAssertFalse(coordinator.shouldResumeOnActive)

        // Now lock screen while already paused by user
        coordinator.handleAppResignActive()
        XCTAssertTrue(coordinator.userPaused)
        XCTAssertFalse(coordinator.pausedByInterruption) // User pause takes precedence
        XCTAssertFalse(coordinator.shouldResumeOnActive) // MUST NOT auto-resume!

        // Unlock screen -> remains paused!
        coordinator.handleAppBecomeActive()
        XCTAssertTrue(coordinator.userPaused)

        // Normal feed scroll reset
        coordinator.recordPlaybackStarted()
        XCTAssertFalse(coordinator.userPaused)
    }
}
