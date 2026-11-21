import Foundation
#if canImport(UIKit)
import UIKit
import ImageIO

/// Global high-performance in-memory bitmap pipeline for feed images.
/// Backed by NSCache with byte-cost tracking, ImageIO downsampling,
/// and background decoding, guaranteeing 0ms synchronous hits on back-swipes,
/// zero memory leaks, and automatic eviction under memory pressure.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        // 32MB memory budget for decoded bitmaps (suited for iPhone 6s Plus 2GB RAM limits)
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 30
        return cache
    }()

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        // Enforce safe memory/disk caps on URLCache
        URLCache.shared = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024,
            diskPath: "dulo_image_cache"
        )

        // Purge bitmap cache immediately upon OS memory warnings
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.memoryCache.removeAllObjects()
        }
    }

    /// Synchronously retrieves a pre-decoded UIImage from RAM if available.
    func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    /// Loads or retrieves a decoded UIImage from memory, HTTP/URLCache, or network.
    func loadImage(for url: URL) async -> UIImage? {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }
        if let pending = inFlight[url] {
            return await pending.value
        }
        let task = Task<UIImage?, Never>(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    self.inFlight.removeValue(forKey: url)
                }
            }
            do {
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let decoded = self.decodeAndDownsample(data: data) else { return nil }
                let cost = Int(decoded.size.width * decoded.scale * decoded.size.height * decoded.scale * 4)
                await MainActor.run {
                    self.memoryCache.setObject(decoded, forKey: url as NSURL, cost: cost)
                }
                return decoded
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        return await task.value
    }

    /// Prefetches images in the background with utility priority.
    func prefetch(urls: [URL]) {
        for url in urls {
            guard memoryCache.object(forKey: url as NSURL) == nil else { continue }
            guard inFlight[url] == nil else { continue }
            let task = Task<UIImage?, Never>(priority: .utility) {
                defer {
                    Task { @MainActor in
                        self.inFlight.removeValue(forKey: url)
                    }
                }
                do {
                    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
                    let (data, _) = try await URLSession.shared.data(for: request)
                    guard let decoded = self.decodeAndDownsample(data: data) else { return nil }
                    let cost = Int(decoded.size.width * decoded.scale * decoded.size.height * decoded.scale * 4)
                    await MainActor.run {
                        self.memoryCache.setObject(decoded, forKey: url as NSURL, cost: cost)
                    }
                    return decoded
                } catch {
                    return nil
                }
            }
            inFlight[url] = task
        }
    }

    /// Decodes and downsamples image data to screen dimensions using ImageIO.
    /// Eliminates full-size bitmap allocation (e.g. 12.5MB down to ~2.5MB).
    private nonisolated func decodeAndDownsample(data: Data, maxPixelSize: CGFloat = 1280) -> UIImage? {
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
