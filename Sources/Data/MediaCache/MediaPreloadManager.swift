import Foundation

/// Industrial-grade, zero-player pre-buffering manager (ByteDance TTVideoEngine & KTVHTTPCache benchmark).
/// Pre-downloads upcoming videos (N+1) and Live Photo motion loops directly to disk with moov-aware adaptive expansion.
/// Consumes 0 hardware decoders and negligible RAM, enabling true 0ms first-frame instant startup.
public final class MediaPreloadManager: NSObject, URLSessionDataDelegate {
    public static let shared = MediaPreloadManager()

    public static let videoPreloadSize: Int64 = 800 * 1024 // 800 KB (TTVideoEngine baseline: covers moov + first 1-2 GOPs for short videos)
    public static let livePhotoPreloadSize: Int64 = 400 * 1024 // 400 KB (Live Photo loop)
    public static let maxAdaptivePreloadSize: Int64 = 8 * 1024 * 1024 // 8 MB upper bound safety ceiling for super-long videos

    private struct TaskContext {
        let key: String
        var targetSize: Int64
        var currentOffset: Int64
        var totalLength: Int64
        var contentType: String
        var headerBuffer: Data
        var hasParsedHeader: Bool
    }

    private let storage: MediaCacheStorage
    private let lock = NSLock()
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private var taskContexts: [Int: TaskContext] = [:] // taskIdentifier -> TaskContext

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(storage: MediaCacheStorage = .shared) {
        self.storage = storage
        super.init()
    }

    /// Parses ISO BMFF (MP4) box headers (ftyp, moov) to calculate the exact byte boundary needed to decode the video.
    /// Returns the required byte offset (moov.offset + moov.size) if moov is at the file start, or nil.
    public static func parseMoovBoundary(in data: Data) -> Int64? {
        guard data.count >= 8 else { return nil }
        var offset = 0
        let count = data.count

        while offset >= 0, offset + 8 <= count {
            guard let boxSize32 = readUInt32BE(data, at: offset),
                  let rawBoxType = readBytes(data, at: offset + 4, count: 4) else { break }
            let boxType = String(data: rawBoxType, encoding: .isoLatin1) ?? ""

            var boxSize = Int64(boxSize32)
            if boxSize32 == 1 {
                // 64-bit largesize. Reject values that cannot be represented by Int64
                // instead of trapping in Int64(UInt64).
                guard offset + 16 <= count,
                      let rawSize = readUInt64BE(data, at: offset + 8),
                      rawSize <= UInt64(Int64.max) else { return nil }
                boxSize = Int64(rawSize)
            } else if boxSize32 == 0 {
                // Box extends to EOF; the caller only has a header prefix, so stop.
                break
            }

            guard boxSize > 0, boxSize <= 500 * 1024 * 1024 else { break }

            if boxType == "moov" {
                let (end, overflow) = Int64(offset).addingReportingOverflow(boxSize)
                return overflow ? nil : end
            } else if boxType == "mdat" {
                // mdat encountered before moov -> moov is located at EOF.
                break
            }

            guard boxSize <= Int64(Int.max) else { return nil }
            offset += Int(boxSize)
        }
        return nil
    }

    private static func readBytes(_ data: Data, at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        return data.subdata(in: offset..<offset + count)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
    }

    /// Preloads up to `targetSize` bytes (default 800KB) of the specified video/motion URL directly to disk.
    /// Dynamically expands targetSize if the MP4 moov atom exceeds the initial budget.
    public func preload(url: URL, key: String? = nil, targetSize: Int64 = videoPreloadSize) {
        let cacheKey = MediaCacheKey.compute(url: url, hint: key)

        // 1. If already cached at least targetSize or completely cached, skip!
        if let meta = storage.metadata(for: cacheKey), meta.cachedBytes >= targetSize || meta.isComplete {
            return
        }

        lock.lock()
        // If already actively downloading this key, do not duplicate
        if activeTasks[cacheKey] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        // Send Range header with room for dynamic moov expansion up to maxAdaptivePreloadSize
        let requestCeiling = max(targetSize, Self.maxAdaptivePreloadSize)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(MediaNetworkHeaders.douyinUA, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaNetworkHeaders.douyinReferer, forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-\(requestCeiling - 1)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        let taskId = task.taskIdentifier

        lock.lock()
        activeTasks[cacheKey] = task
        taskContexts[taskId] = TaskContext(
            key: cacheKey,
            targetSize: targetSize,
            currentOffset: 0,
            totalLength: 0,
            contentType: "video/mp4",
            headerBuffer: Data(),
            hasParsedHeader: false
        )
        lock.unlock()

        task.resume()
    }

    // MARK: - URLSessionDataDelegate (Streaming Chunks Directly to Disk)

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else {
            completionHandler(.cancel)
            return
        }

        var totalLen: Int64 = 0
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slashIdx = cr.lastIndex(of: "/") {
            let totalStr = cr[cr.index(after: slashIdx)...].trimmingCharacters(in: .whitespaces)
            totalLen = Int64(totalStr) ?? 0
        }
        if totalLen == 0, let cl = http.value(forHTTPHeaderField: "Content-Length") {
            totalLen = Int64(cl) ?? 0
        }

        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"

        lock.lock()
        if var ctx = taskContexts[dataTask.taskIdentifier] {
            ctx.totalLength = totalLen
            ctx.contentType = type
            taskContexts[dataTask.taskIdentifier] = ctx
        }
        lock.unlock()

        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        guard var ctx = taskContexts[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let writeOffset = ctx.currentOffset
        ctx.currentOffset += Int64(data.count)
        let key = ctx.key
        let totalLen = ctx.totalLength
        let cType = ctx.contentType

        // ByteDance TTVideoEngine moov-Aware Dynamic Expansion:
        // Parse ISO BMFF container on initial packet(s) to accurately calculate required moov boundary
        if !ctx.hasParsedHeader {
            if ctx.headerBuffer.count < 1024 {
                ctx.headerBuffer.append(data.prefix(1024 - ctx.headerBuffer.count))
            }
            if let requiredMoovBoundary = Self.parseMoovBoundary(in: ctx.headerBuffer) {
                ctx.hasParsedHeader = true
                ctx.headerBuffer.removeAll()
                let dynamicTarget = requiredMoovBoundary + (512 * 1024) // moov + first GOP
                ctx.targetSize = min(max(ctx.targetSize, dynamicTarget), Self.maxAdaptivePreloadSize)
            } else if ctx.currentOffset >= 65536 {
                // If 64KB passed without identifying moov at start, fallback to default targetSize
                ctx.hasParsedHeader = true
                ctx.headerBuffer.removeAll()
            }
        }

        let reachedLimit = ctx.currentOffset >= ctx.targetSize
        taskContexts[dataTask.taskIdentifier] = ctx
        lock.unlock()

        // Append chunk directly to disk storage
        storage.writeData(
            for: key,
            data: data,
            offset: writeOffset,
            contentLength: totalLen,
            contentType: cType
        )

        // If target size reached, gracefully stop!
        if reachedLimit {
            dataTask.cancel()
            cleanupTask(dataTask.taskIdentifier, key: key)
            storage.flushMetadata(for: key)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let key = taskContexts[task.taskIdentifier]?.key
        lock.unlock()
        if let key = key {
            cleanupTask(task.taskIdentifier, key: key)
            storage.flushMetadata(for: key)
        }
    }

    private func cleanupTask(_ taskId: Int, key: String) {
        lock.lock()
        defer { lock.unlock() }
        taskContexts.removeValue(forKey: taskId)
        if activeTasks[key]?.taskIdentifier == taskId {
            activeTasks.removeValue(forKey: key)
        }
    }

    // MARK: - Cancellation & Velocity Eviction

    public func cancel(key: String) {
        lock.lock()
        defer { lock.unlock() }
        let canonicalKey = MediaCacheKey.key(for: key)
        if let task = activeTasks.removeValue(forKey: canonicalKey) ?? activeTasks.removeValue(forKey: key) {
            task.cancel()
            taskContexts.removeValue(forKey: task.taskIdentifier)
        }
    }

    public func cancel(url: URL, key: String? = nil) {
        let cacheKey = MediaCacheKey.compute(url: url, hint: key)
        cancel(key: cacheKey)
    }

    public func cancelAllExcept(retainedKeys: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let canonicalRetained = Set(retainedKeys.map { MediaCacheKey.key(for: $0) })
        var toRemove: [String] = []
        for (key, task) in activeTasks {
            let bareKey = key.hasPrefix("k_") ? String(key.dropFirst(2)) : key
            if !canonicalRetained.contains(key) && !retainedKeys.contains(bareKey) {
                task.cancel()
                taskContexts.removeValue(forKey: task.taskIdentifier)
                toRemove.append(key)
            }
        }
        for k in toRemove {
            activeTasks.removeValue(forKey: k)
        }
    }

    public func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        taskContexts.removeAll()
    }
}
