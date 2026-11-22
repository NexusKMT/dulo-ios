import Foundation

/// Disk cache metadata for a cached or partially cached media item.
public struct CacheMetadata: Codable, Equatable {
    public var contentLength: Int64
    public var contentType: String
    public var cachedBytes: Int64
    public var lastAccessTime: TimeInterval

    public init(contentLength: Int64, contentType: String, cachedBytes: Int64, lastAccessTime: TimeInterval) {
        self.contentLength = contentLength
        self.contentType = contentType
        self.cachedBytes = cachedBytes
        self.lastAccessTime = lastAccessTime
    }

    public var isComplete: Bool {
        contentLength > 0 && cachedBytes >= contentLength
    }
}

/// Thread-safe media disk cache storage with double-watermark LRU eviction and active video reference-counted pinning.
/// Manages partial video chunks (e.g. 800KB pre-buffers) and fully streamed video files with zero-amplification debounced metadata writes.
public final class MediaCacheStorage {
    public static let shared = MediaCacheStorage()

    public let cacheDirectory: URL
    public let maxDiskSize: Int64
    public let targetDiskSize: Int64

    private let lock = NSLock()
    private var pinCounts: [String: Int] = [:]
    private let fileManager = FileManager.default
    private var metadataMemoryCache: [String: CacheMetadata] = [:]
    private var dirtyMetadataKeys: Set<String> = []
    private var debounceWorkItem: DispatchWorkItem?
    private var totalDiskUsage: Int64 = 0
    private var lastEvictionCheckTime: TimeInterval = 0

    public init(
        cacheDirectory: URL? = nil,
        maxDiskSize: Int64 = 500 * 1024 * 1024,      // 500 MB High Watermark
        targetDiskSize: Int64 = 400 * 1024 * 1024    // 400 MB Low Watermark
    ) {
        if let cacheDirectory = cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.cacheDirectory = base.appendingPathComponent("MediaStreamCache", isDirectory: true)
        }
        self.maxDiskSize = maxDiskSize
        self.targetDiskSize = targetDiskSize

        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)

        // Exclude cache directory from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var dirUrl = self.cacheDirectory
        try? dirUrl.setResourceValues(resourceValues)

        purgeContaminatedLegacyKeys()
        totalDiskUsage = calculateInitialDiskUsage()
    }

    /// Purges legacy contaminated single/short-digit cache directories (e.g. k_0, k_1)
    /// caused by un-scoped slide indices from earlier versions.
    private func purgeContaminatedLegacyKeys() {
        guard let items = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix("k_") {
                let suffix = String(name.dropFirst(2))
                if !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) && suffix.count <= 4 {
                    try? fileManager.removeItem(at: item)
                }
            }
        }
    }

    // MARK: - Key Pinning (Active Video Protection with Reference Counting)

    public func pin(key: String) {
        lock.lock()
        defer { lock.unlock() }
        let k = MediaCacheKey.key(for: key)
        pinCounts[k, default: 0] += 1
        touchLocked(key: k)
    }

    public func unpin(key: String) {
        lock.lock()
        defer { lock.unlock() }
        let k = MediaCacheKey.key(for: key)
        if let count = pinCounts[k], count > 1 {
            pinCounts[k] = count - 1
        } else {
            pinCounts.removeValue(forKey: k)
            flushMetadataLocked(for: k)
        }
    }

    public func isPinned(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let k = MediaCacheKey.key(for: key)
        return (pinCounts[k] ?? 0) > 0
    }

    // MARK: - Metadata & Access

    public func metadata(for key: String) -> CacheMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return readMetadataLocked(for: MediaCacheKey.key(for: key))
    }

    public func touch(key: String) {
        lock.lock()
        defer { lock.unlock() }
        touchLocked(key: MediaCacheKey.key(for: key))
    }

    private func touchLocked(key: String) {
        guard var meta = readMetadataLocked(for: key) else { return }
        meta.lastAccessTime = Date().timeIntervalSince1970
        metadataMemoryCache[key] = meta
        dirtyMetadataKeys.insert(key)
        scheduleDebouncedFlushLocked()
    }

    public func setMetadata(for key: String, contentLength: Int64, contentType: String) {
        lock.lock()
        defer { lock.unlock() }
        let k = MediaCacheKey.key(for: key)
        var meta = readMetadataLocked(for: k) ?? CacheMetadata(
            contentLength: contentLength,
            contentType: contentType,
            cachedBytes: 0,
            lastAccessTime: Date().timeIntervalSince1970
        )
        meta.contentLength = contentLength
        meta.contentType = contentType
        meta.lastAccessTime = Date().timeIntervalSince1970
        writeMetadataLocked(meta, for: k, persistToDisk: true)
        dirtyMetadataKeys.remove(k)
    }

    public func flushMetadata(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        flushMetadataLocked(for: MediaCacheKey.key(for: key))
    }

    private func flushMetadataLocked(for key: String) {
        guard dirtyMetadataKeys.contains(key), let meta = metadataMemoryCache[key] else { return }
        writeMetadataLocked(meta, for: key, persistToDisk: true)
        dirtyMetadataKeys.remove(key)
    }

    public func flushAllMetadata() {
        lock.lock()
        defer { lock.unlock() }
        for k in dirtyMetadataKeys {
            if let meta = metadataMemoryCache[k] {
                writeMetadataLocked(meta, for: k, persistToDisk: true)
            }
        }
        dirtyMetadataKeys.removeAll()
    }

    // MARK: - Reading & Writing Bytes

    /// Opens an existing cached file handle for high-throughput zero-lock streaming.
    public func openReadingFileHandle(for key: String) -> (FileHandle, Int64)? {
        lock.lock()
        defer { lock.unlock() }

        let k = MediaCacheKey.key(for: key)
        guard let meta = readMetadataLocked(for: k), meta.cachedBytes > 0 else {
            return nil
        }
        let dataUrl = itemDirectory(for: k).appendingPathComponent("data")
        guard let fileHandle = try? FileHandle(forReadingFrom: dataUrl) else {
            return nil
        }
        metadataMemoryCache[k]?.lastAccessTime = Date().timeIntervalSince1970
        return (fileHandle, meta.cachedBytes)
    }

    public func readData(for key: String, offset: Int64, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let k = MediaCacheKey.key(for: key)
        guard let meta = readMetadataLocked(for: k), meta.cachedBytes > offset else {
            return nil
        }

        let available = Int(min(Int64(length), meta.cachedBytes - offset))
        guard available > 0 else { return nil }

        let dataUrl = itemDirectory(for: k).appendingPathComponent("data")
        guard let fileHandle = try? FileHandle(forReadingFrom: dataUrl) else {
            return nil
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: UInt64(offset))
            let chunk = fileHandle.readData(ofLength: available)
            metadataMemoryCache[k]?.lastAccessTime = Date().timeIntervalSince1970
            return chunk
        } catch {
            return nil
        }
    }

    public func writeData(
        for key: String,
        data: Data,
        offset: Int64,
        contentLength: Int64,
        contentType: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !data.isEmpty else { return }
        let k = MediaCacheKey.key(for: key)

        let itemDir = itemDirectory(for: k)
        if !fileManager.fileExists(atPath: itemDir.path) {
            try? fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)
        }

        let dataUrl = itemDir.appendingPathComponent("data")
        if !fileManager.fileExists(atPath: dataUrl.path) {
            fileManager.createFile(atPath: dataUrl.path, contents: nil)
        }

        if let fileHandle = try? FileHandle(forWritingTo: dataUrl) {
            defer { try? fileHandle.close() }
            do {
                try fileHandle.seek(toOffset: UInt64(offset))
                fileHandle.write(data)
            } catch {
                return
            }
        }

        var meta = readMetadataLocked(for: k) ?? CacheMetadata(
            contentLength: contentLength,
            contentType: contentType,
            cachedBytes: 0,
            lastAccessTime: Date().timeIntervalSince1970
        )
        let prevCached = meta.cachedBytes
        meta.contentLength = max(meta.contentLength, contentLength)
        meta.contentType = contentType.isEmpty ? meta.contentType : contentType
        if offset <= meta.cachedBytes {
            meta.cachedBytes = max(meta.cachedBytes, offset + Int64(data.count))
        }
        meta.lastAccessTime = Date().timeIntervalSince1970

        let addedBytes = max(0, meta.cachedBytes - prevCached)
        totalDiskUsage += addedBytes

        let isComplete = meta.isComplete
        if isComplete {
            writeMetadataLocked(meta, for: k, persistToDisk: true)
            dirtyMetadataKeys.remove(k)
        } else {
            metadataMemoryCache[k] = meta
            dirtyMetadataKeys.insert(k)
            scheduleDebouncedFlushLocked()
        }

        let now = Date().timeIntervalSince1970
        if isComplete || (now - lastEvictionCheckTime >= 30.0) {
            lastEvictionCheckTime = now
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.evictIfNeeded()
            }
        }
    }

    // MARK: - Double-Watermark LRU Eviction

    public func currentDiskUsage() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalDiskUsage
    }

    public func evictIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard totalDiskUsage > maxDiskSize else { return }

        guard let itemKeys = try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path) else { return }

        struct EvictionCandidate {
            let key: String
            let lastAccess: TimeInterval
            let size: Int64
        }

        var candidates: [EvictionCandidate] = []
        for key in itemKeys {
            if (pinCounts[key] ?? 0) > 0 { continue } // Never evict active/prewarm videos!
            let meta = readMetadataLocked(for: key)
            let lastAccess = meta?.lastAccessTime ?? 0
            let dataUrl = itemDirectory(for: key).appendingPathComponent("data")
            let size = meta?.cachedBytes ?? (try? fileManager.attributesOfItem(atPath: dataUrl.path)[.size] as? Int64) ?? 0
            candidates.append(EvictionCandidate(key: key, lastAccess: lastAccess, size: size))
        }

        // Sort oldest access time first (LRU)
        candidates.sort { $0.lastAccess < $1.lastAccess }

        for candidate in candidates {
            guard totalDiskUsage > targetDiskSize else { break }
            let dirUrl = itemDirectory(for: candidate.key)
            try? fileManager.removeItem(at: dirUrl)
            metadataMemoryCache.removeValue(forKey: candidate.key)
            dirtyMetadataKeys.remove(candidate.key)
            totalDiskUsage = max(0, totalDiskUsage - candidate.size)
        }
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        metadataMemoryCache.removeAll()
        dirtyMetadataKeys.removeAll()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        totalDiskUsage = 0
    }

    // MARK: - Internal Helpers

    private func itemDirectory(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key, isDirectory: true)
    }

    private func readMetadataLocked(for key: String) -> CacheMetadata? {
        if let cached = metadataMemoryCache[key] {
            return cached
        }
        let metaUrl = itemDirectory(for: key).appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaUrl),
              let meta = try? JSONDecoder().decode(CacheMetadata.self, from: data) else {
            return nil
        }
        metadataMemoryCache[key] = meta
        return meta
    }

    private func writeMetadataLocked(_ meta: CacheMetadata, for key: String, persistToDisk: Bool = true) {
        metadataMemoryCache[key] = meta
        guard persistToDisk else { return }
        let itemDir = itemDirectory(for: key)
        if !fileManager.fileExists(atPath: itemDir.path) {
            try? fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)
        }
        let metaUrl = itemDir.appendingPathComponent("metadata.json")
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaUrl)
        }
    }

    private func scheduleDebouncedFlushLocked() {
        guard debounceWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.debounceWorkItem = nil
            let keys = self.dirtyMetadataKeys
            for k in keys {
                if let meta = self.metadataMemoryCache[k] {
                    self.writeMetadataLocked(meta, for: k, persistToDisk: true)
                }
            }
            self.dirtyMetadataKeys.removeAll()
            self.lock.unlock()
        }
        debounceWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func calculateInitialDiskUsage() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileUrl as URL in enumerator {
            let values = try? fileUrl.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
