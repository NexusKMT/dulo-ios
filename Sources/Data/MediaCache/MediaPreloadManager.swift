import Foundation

/// High-efficiency, zero-player pre-buffering manager.
/// Pre-downloads the first 1MB (`bytes=0-1048575`) of upcoming videos (N+1 / N+2) directly to disk.
/// Consumes 0 hardware decoders and negligible RAM, enabling true 0ms first-frame instant startup.
public final class MediaPreloadManager {
    public static let shared = MediaPreloadManager()

    public static let preloadChunkSize: Int64 = 1024 * 1024 // 1 MB (covers mp4 moov atom & first GOP)

    private let storage: MediaCacheStorage
    private let lock = NSLock()
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    public init(storage: MediaCacheStorage = .shared) {
        self.storage = storage
    }

    /// Preloads the first 1MB of the specified video URL if not already cached.
    public func preload(url: URL, key: String? = nil) {
        let cacheKey = MediaCacheKey.compute(url: url, hint: key)

        // 1. If already cached at least 1MB or completely cached, skip!
        if let meta = storage.metadata(for: cacheKey), meta.cachedBytes >= Self.preloadChunkSize || meta.isComplete {
            return
        }

        lock.lock()
        // If already actively downloading this key, do not duplicate
        if activeTasks[cacheKey] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(MediaNetworkHeaders.douyinUA, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaNetworkHeaders.douyinReferer, forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-\(Self.preloadChunkSize - 1)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            self.lock.lock()
            self.activeTasks.removeValue(forKey: cacheKey)
            self.lock.unlock()

            guard let data = data, !data.isEmpty, error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else {
                return
            }

            var totalLength: Int64 = 0
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"

            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let slashIdx = cr.lastIndex(of: "/") {
                let totalStr = cr[cr.index(after: slashIdx)...].trimmingCharacters(in: .whitespaces)
                totalLength = Int64(totalStr) ?? 0
            }

            if totalLength == 0, let cl = http.value(forHTTPHeaderField: "Content-Length"), let len = Int64(cl) {
                totalLength = len
            }

            if totalLength == 0 {
                totalLength = Int64(data.count)
            }

            self.storage.writeData(
                for: cacheKey,
                data: data,
                offset: 0,
                contentLength: totalLength,
                contentType: contentType
            )
            NSLog("[MediaPreloadManager] Successfully preloaded %d bytes for key: %@", data.count, cacheKey)
        }

        lock.lock()
        activeTasks[cacheKey] = task
        lock.unlock()

        task.resume()
    }

    /// Cancels active preloading for a given key (e.g. if skipped past).
    public func cancel(url: URL, key: String? = nil) {
        let cacheKey = MediaCacheKey.compute(url: url, hint: key)
        lock.lock()
        defer { lock.unlock() }
        if let task = activeTasks.removeValue(forKey: cacheKey) {
            task.cancel()
        }
    }

    /// Cancels all active preloading tasks.
    public func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
    }
}
