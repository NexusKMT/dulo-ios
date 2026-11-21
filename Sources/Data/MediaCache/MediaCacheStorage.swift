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

/// Thread-safe media disk cache storage with double-watermark LRU eviction and active video pinning.
/// Manages partial video chunks (e.g. 1MB pre-buffers) and fully streamed video files.
public final class MediaCacheStorage {
    public static let shared = MediaCacheStorage()

    public let cacheDirectory: URL
    public let maxDiskSize: Int64
    public let targetDiskSize: Int64

    private let lock = NSLock()
    private var pinnedKeys: Set<String> = []
    private let fileManager = FileManager.default

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
    }

    // MARK: - Key Pinning (Active Video Protection)

    public func pin(key: String) {
        lock.lock()
        defer { lock.unlock() }
        pinnedKeys.insert(key)
        touchLocked(key: key)
    }

    public func unpin(key: String) {
        lock.lock()
        defer { lock.unlock() }
        pinnedKeys.remove(key)
    }

    public func isPinned(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pinnedKeys.contains(key)
    }

    // MARK: - Metadata & Access

    public func metadata(for key: String) -> CacheMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return readMetadataLocked(for: key)
    }

    public func touch(key: String) {
        lock.lock()
        defer { lock.unlock() }
        touchLocked(key: key)
    }

    private func touchLocked(key: String) {
        guard var meta = readMetadataLocked(for: key) else { return }
        meta.lastAccessTime = Date().timeIntervalSince1970
        writeMetadataLocked(meta, for: key)
    }

    public func setMetadata(for key: String, contentLength: Int64, contentType: String) {
        lock.lock()
        defer { lock.unlock() }
        var meta = readMetadataLocked(for: key) ?? CacheMetadata(
            contentLength: contentLength,
            contentType: contentType,
            cachedBytes: 0,
            lastAccessTime: Date().timeIntervalSince1970
        )
        meta.contentLength = contentLength
        meta.contentType = contentType
        meta.lastAccessTime = Date().timeIntervalSince1970
        writeMetadataLocked(meta, for: key)
    }

    // MARK: - Reading & Writing Bytes

    public func readData(for key: String, offset: Int64, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let meta = readMetadataLocked(for: key), meta.cachedBytes > offset else {
            return nil
        }

        let available = Int(min(Int64(length), meta.cachedBytes - offset))
        guard available > 0 else { return nil }

        let dataUrl = itemDirectory(for: key).appendingPathComponent("data")
        guard let fileHandle = try? FileHandle(forReadingFrom: dataUrl) else {
            return nil
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: UInt64(offset))
            let chunk = fileHandle.readData(ofLength: available)
            touchLocked(key: key)
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

        let itemDir = itemDirectory(for: key)
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

        var meta = readMetadataLocked(for: key) ?? CacheMetadata(
            contentLength: contentLength,
            contentType: contentType,
            cachedBytes: 0,
            lastAccessTime: Date().timeIntervalSince1970
        )
        meta.contentLength = max(meta.contentLength, contentLength)
        meta.contentType = contentType.isEmpty ? meta.contentType : contentType
        meta.cachedBytes = max(meta.cachedBytes, offset + Int64(data.count))
        meta.lastAccessTime = Date().timeIntervalSince1970
        writeMetadataLocked(meta, for: key)

        // Asynchronously check LRU watermark if needed
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.evictIfNeeded()
        }
    }

    // MARK: - Double-Watermark LRU Eviction

    public func currentDiskUsage() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return calculateDiskUsageLocked()
    }

    public func evictIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        var totalUsage = calculateDiskUsageLocked()
        guard totalUsage > maxDiskSize else { return }

        // Gather all cache items with their last access time and directory sizes
        guard let itemKeys = try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path) else { return }

        struct EvictionCandidate {
            let key: String
            let lastAccess: TimeInterval
            let size: Int64
        }

        var candidates: [EvictionCandidate] = []
        for key in itemKeys {
            if pinnedKeys.contains(key) { continue } // Never evict currently playing videos!
            let meta = readMetadataLocked(for: key)
            let lastAccess = meta?.lastAccessTime ?? 0
            let dirUrl = itemDirectory(for: key)
            let size = directorySizeLocked(dirUrl)
            candidates.append(EvictionCandidate(key: key, lastAccess: lastAccess, size: size))
        }

        // Sort oldest access time first (LRU)
        candidates.sort { $0.lastAccess < $1.lastAccess }

        for candidate in candidates {
            guard totalUsage > targetDiskSize else { break }
            let dirUrl = itemDirectory(for: candidate.key)
            try? fileManager.removeItem(at: dirUrl)
            totalUsage -= candidate.size
        }
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Internal Helpers

    private func itemDirectory(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key, isDirectory: true)
    }

    private func readMetadataLocked(for key: String) -> CacheMetadata? {
        let metaUrl = itemDirectory(for: key).appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaUrl),
              let meta = try? JSONDecoder().decode(CacheMetadata.self, from: data) else {
            return nil
        }
        return meta
    }

    private func writeMetadataLocked(_ meta: CacheMetadata, for key: String) {
        let itemDir = itemDirectory(for: key)
        if !fileManager.fileExists(atPath: itemDir.path) {
            try? fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)
        }
        let metaUrl = itemDir.appendingPathComponent("metadata.json")
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaUrl)
        }
    }

    private func calculateDiskUsageLocked() -> Int64 {
        directorySizeLocked(cacheDirectory)
    }

    private func directorySizeLocked(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
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
