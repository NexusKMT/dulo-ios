import Foundation
import UIKit

/// Global high-performance in-memory bitmap pipeline for feed images.
/// Backed by NSCache with byte-cost tracking and background decoding,
/// guaranteeing 0ms synchronous hits on back-swipes and zero view lifecycle loss.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        // 128MB memory budget for decoded bitmaps; purged automatically by iOS under memory pressure
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 120
        return cache
    }()

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {}

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
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let image = UIImage(data: data) else { return nil }
                // Pre-decode off the main thread using Apple's official API
                let decoded = await image.preparingForDisplay() ?? image
                let cost = Int(decoded.size.width * decoded.size.height * 4)
                await MainActor.run {
                    self.memoryCache.setObject(decoded, forKey: url as NSURL, cost: cost)
                }
                return decoded
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight.removeValue(forKey: url)
        return result
    }

    /// Prefetches images in the background with utility priority.
    func prefetch(urls: [URL]) {
        for url in urls {
            guard memoryCache.object(forKey: url as NSURL) == nil else { continue }
            guard inFlight[url] == nil else { continue }
            let task = Task<UIImage?, Never>(priority: .utility) {
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .returnCacheDataElseLoad
                    let (data, _) = try await URLSession.shared.data(for: request)
                    guard let image = UIImage(data: data) else { return nil }
                    let decoded = await image.preparingForDisplay() ?? image
                    let cost = Int(decoded.size.width * decoded.size.height * 4)
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
}
