import Foundation
import SwiftUI

/// Feed data and on-demand media leases. Port of the Android `DuloViewModel`.
/// No player lives here: every feed page owns its own AVPlayer, so switching
/// pages is a play/pause between prepared players.
@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var videos: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let client = MediaClient.shared

    /// Main-actor access-order cache; it does not participate in SwiftUI state.
    private let resolvedMediaCache = LeaseLruCache<ResolvedMedia>()

    /// One in-flight resolve per id; a force refresh replaces a pending
    /// request. Identity is tracked by request id because Swift's `Task` is a
    /// value type with no equality.
    private struct InFlight {
        let requestId: Int
        let priority: Int
        let task: Task<MediaResolution, Never>
    }

    private var inFlight: [String: InFlight] = [:]
    private var nextRequestId = 0

    init() {
        loadFeed()
    }

    /// Initial lease for a page, if one is already cached and fresh.
    func cachedLease(for id: String) -> Lease<ResolvedMedia>? {
        resolvedMediaCache[id].flatMap { $0.isFresh() ? $0 : nil }
    }

    /// Loads or retries the video feed from the configured server.
    func loadFeed() {
        if isLoading { return }
        error = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let loaded = try await client.listVideos(baseUrl: AppSettings.assetsBaseUrl)
                videos = loaded
                if videos.isEmpty {
                    self.error = "服务器目录中无可用视频"
                }
            } catch let mediaError as MediaException {
                videos = []
                self.error = mediaError.message
            } catch {
                videos = []
                self.error = "读取视频列表失败"
            }
        }
    }

    /// Returns a fresh lease for `id`, resolving or renewing it on demand.
    /// Concurrent callers share one request; `force` bypasses both the client
    /// lease and the server cache (used after a CDN 403).
    /// `priority`: 0 for VIP active playback, 1 for speculative background prewarm.
    @discardableResult
    func resolveMedia(id: String, force: Bool = false, priority: Int = 0) async -> MediaResolution {
        if !force, let cached = cachedLease(for: id) {
            return .ready(cached)
        }
        if let pending = inFlight[id], !force {
            if priority >= pending.priority {
                return await pending.task.value
            }
            // VIP Promotion: promote pending preload task by issuing a priority 0 request
        }
        let requestId = nextRequestId
        nextRequestId += 1
        let task = Task<MediaResolution, Never> {
            // The app mints its own URLs now; there is no server to ask.
            do {
                let content = try await DouyinClient.shared.content(for: id)
                return .ready(Lease(Self.media(from: content, id: id), expiresAt: Self.expiry(of: content)))
            } catch let failure as DouyinClient.Failure {
                switch failure {
                case .notFound: return .notFound
                case .network: return .networkFailure
                case .http(let statusCode): return .httpFailure(statusCode: statusCode)
                case .malformed: return .invalidResponse
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .internalFailure
            }
        }
        inFlight[id] = InFlight(requestId: requestId, priority: priority, task: task)
        let result = await task.value
        if inFlight[id]?.requestId == requestId {
            inFlight.removeValue(forKey: id)
            if case .ready(let lease) = result {
                resolvedMediaCache.put(key: id, lease: lease)
            }
        }
        return result
    }

    /// Bridges the client-native content into the shape the pager renders.
    private static func media(from content: MediaContent, id: String) -> ResolvedMedia {
        switch content {
        case .video(let url, let cover, let width, let height):
            return .video(
                url: url.absoluteString,
                cover: cover?.absoluteString,
                width: width,
                height: height
            )
        case .images(let slides, let music):
            return .images(
                urls: slides.map { $0.imageUrl.absoluteString },
                music: music?.absoluteString,
                slides: slides.enumerated().map { index, slide in
                    GallerySlide(
                        id: "\(id)_\(index)",
                        imageUrl: slide.imageUrl.absoluteString,
                        motionVideoUrl: slide.motionUrl?.absoluteString,
                        aspectRatio: slide.aspectRatio
                    )
                }
            )
        }
    }

    /// A signed URL lives as long as its `x-expires`; without one, assume the
    /// old server default so a long session still refreshes.
    private static func expiry(of content: MediaContent) -> Date {
        content.expiresAt ?? Date().addingTimeInterval(TimeInterval(MediaClient.defaultTtlSeconds))
    }

    /// Cancels any in-flight resolution for `id` when the page is scrolled away.
    func cancelResolve(for id: String) {
        if let pending = inFlight.removeValue(forKey: id) {
            pending.task.cancel()
        }
    }
}
