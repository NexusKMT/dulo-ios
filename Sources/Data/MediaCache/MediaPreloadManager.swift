import Foundation

/// Industrial-grade, zero-player pre-buffering manager (ByteDance TTVideoEngine & KTVHTTPCache benchmark).
/// Pre-downloads the first 800KB (`bytes=0-819199`) of upcoming videos (N+1) and 400KB of Live Photo motion loops directly to disk.
/// Consumes 0 hardware decoders and negligible RAM, enabling true 0ms first-frame instant startup.
public final class MediaPreloadManager: NSObject, URLSessionDataDelegate {
    public static let shared = MediaPreloadManager()

    public static let videoPreloadSize: Int64 = 800 * 1024 // 800 KB (TTVideoEngine standard: covers moov + first 1-2 GOPs)
    public static let livePhotoPreloadSize: Int64 = 400 * 1024 // 400 KB (Live Photo loop)

    private struct TaskContext {
        let key: String
        let targetSize: Int64
        var currentOffset: Int64
        var totalLength: Int64
        var contentType: String
    }

    private let storage: MediaCacheStorage
    private let lock = NSLock()
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private var taskContexts: [Int: TaskContext] = [:] // taskIdentifier -> TaskContext

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 24
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(storage: MediaCacheStorage = .shared) {
        self.storage = storage
        super.init()
    }

    /// Preloads up to `targetSize` bytes (default 800KB) of the specified video/motion URL directly to disk.
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

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(MediaNetworkHeaders.douyinUA, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaNetworkHeaders.douyinReferer, forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-\(targetSize - 1)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        let taskId = task.taskIdentifier

        lock.lock()
        activeTasks[cacheKey] = task
        taskContexts[taskId] = TaskContext(
            key: cacheKey,
            targetSize: targetSize,
            currentOffset: 0,
            totalLength: 0,
            contentType: "video/mp4"
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

        // If target size reached (e.g. 800KB preloaded), gracefully stop!
        // This also protects against servers that return 200 OK (full file) ignoring Range header.
        if reachedLimit {
            dataTask.cancel()
            cleanupTask(dataTask.taskIdentifier, key: key)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let key = taskContexts[task.taskIdentifier]?.key
        lock.unlock()
        if let key = key {
            cleanupTask(task.taskIdentifier, key: key)
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
        let cleanKey = key.hasPrefix("k_") ? key : "k_\(key)"
        if let task = activeTasks.removeValue(forKey: cleanKey) {
            task.cancel()
            taskContexts.removeValue(forKey: task.taskIdentifier)
        }
    }

    public func cancel(url: URL, key: String? = nil) {
        let cacheKey = MediaCacheKey.compute(url: url, hint: key)
        lock.lock()
        defer { lock.unlock() }
        if let task = activeTasks.removeValue(forKey: cacheKey) {
            task.cancel()
            taskContexts.removeValue(forKey: task.taskIdentifier)
        }
    }

    public func cancelAllExcept(retainedKeys: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        var toRemove: [String] = []
        for (key, task) in activeTasks {
            let bareKey = key.hasPrefix("k_") ? String(key.dropFirst(2)) : key
            if !retainedKeys.contains(key) && !retainedKeys.contains(bareKey) {
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
