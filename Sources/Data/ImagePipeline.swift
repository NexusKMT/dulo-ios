import Foundation
#if canImport(UIKit)
import UIKit
import ImageIO

/// Production-grade asynchronous semaphore for Swift Concurrency task limiting.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }
}

/// High-performance multi-tier image pipeline optimized for low-spec iOS devices (Apple A9 / 2GB RAM).
/// Tier 1: 60 MB `NSCache` of decoded images (main-actor only).
/// Tier 2: Bounded persistent disk cache (`ImageDiskCache`).
/// Tier 3: Network fetch + ImageIO downsampling on a detached task.
///
/// All disk I/O and ImageIO work runs off the main actor. Earlier versions
/// created an unstructured `Task` from this `@MainActor` class, which inherited
/// main-actor isolation and blocked scrolling on every cache miss.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    // L1 memory cache (60 MB / 30 images, purges on memory pressure)
    private let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 60 * 1024 * 1024
        cache.countLimit = 30
        return cache
    }()

    // A9 dual-core concurrency limiter for ImageIO decode work.
    private static let decodeSemaphore = AsyncSemaphore(value: 2)
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.memoryCache.removeAllObjects()
        }
    }

    // MARK: - Compatibility Stubs (Pinned Images Removed for Jetsam Safety)

    func pin(urls: [URL]) {}
    func unpin(urls: [URL]) {}

    // MARK: - Synchronous RAM Probe

    /// Synchronously retrieves a decoded image from RAM if available.
    func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    // MARK: - Multi-Tier Loading Pipeline

    /// Retrieves an image: L1 RAM -> L2 Disk -> Network -> downsampled decode.
    func loadImage(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) {
            return cached
        }

        if let pending = inFlight[url] {
            return await pending.value
        }

        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // L2 disk cache read.
            var rawData = ImageDiskCache.shared.data(for: url)

            // L3 network fetch.
            if rawData == nil {
                do {
                    let request = URLRequest(
                        url: url,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 15
                    )
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse,
                       http.statusCode == 200,
                       !data.isEmpty {
                        rawData = data
                        ImageDiskCache.shared.store(data: data, for: url)
                    }
                } catch {
                    return nil
                }
            }

            guard let data = rawData else { return nil }

            await ImagePipeline.decodeSemaphore.wait()
            defer {
                Task { await ImagePipeline.decodeSemaphore.signal() }
            }

            // ImageIO DCT downsampling: 1920 px max for the 6s Plus panel.
            return ImagePipeline.decodeAndDownsample(data: data, maxPixelSize: 1920)
        }

        inFlight[url] = task
        let image = await task.value
        inFlight.removeValue(forKey: url)

        if let image {
            let cost = (image.cgImage?.bytesPerRow ?? Int(image.size.width * 4))
                * (image.cgImage?.height ?? Int(image.size.height))
            memoryCache.setObject(image, forKey: url as NSURL, cost: max(cost, 1))
        }
        return image
    }

    /// Prefetches images with utility priority.
    func prefetch(urls: [URL]) {
        for url in urls {
            guard cachedImage(for: url) == nil, inFlight[url] == nil else { continue }
            Task(priority: .utility) {
                _ = await self.loadImage(for: url)
            }
        }
    }

    /// Decodes and downsamples image data using ImageIO. Safe to call off-main.
    nonisolated private static func decodeAndDownsample(data: Data, maxPixelSize: CGFloat = 1920) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
#endif
