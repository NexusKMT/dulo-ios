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

    /// One in-flight resolve per id; a force refresh replaces a pending request.
    private var inFlight: [String: Task<MediaResolution, Never>] = [:]

    init() {
        loadFeed()
    }

    /// Initial lease for a page, if one is already cached and fresh.
    func cachedLease(for id: String) -> Lease<ResolvedMedia>? {
        resolvedMediaCache[id].flatMap { $0.isFresh(nowElapsedMs: monotonicNowMs()) ? $0 : nil }
    }

    /// Loads or retries the video feed from the configured server.
    func loadFeed() {
        if isLoading { return }
        error = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let loaded = try await client.listVideos(baseUrl: AppSettings.serverBaseUrl)
                videos = loaded
                if videos.isEmpty {
                    error = "服务器目录中无可用视频"
                }
            } catch let error as MediaException {
                videos = []
                self.error = error.message
            } catch {
                videos = []
                error = "读取视频列表失败"
            }
        }
    }

    /// Returns a fresh lease for `id`, resolving or renewing it on demand.
    /// Concurrent callers share one request; `force` bypasses both the client
    /// lease and the server cache (used after a CDN 403). `onResult` runs on
    /// the main actor with the specific resolution outcome.
    func resolveMedia(id: String, force: Bool = false, onResult: ((MediaResolution) -> Void)? = nil) {
        let now = monotonicNowMs()
        if !force, let cached = cachedLease(for: id) {
            onResult?(.ready(cached))
            return
        }
        if let pending = inFlight[id], !force {
            Task { onResult?(await pending.value) }
            return
        }
        let task = Task { [client] in
            await client.resolveMedia(baseUrl: AppSettings.serverBaseUrl, id: id, force: force)
        }
        inFlight[id] = task
        Task {
            let result = await task.value
            if inFlight[id] === task {
                inFlight.removeValue(forKey: id)
                if case .ready(let lease) = result {
                    resolvedMediaCache.put(key: id, lease: lease, nowElapsedMs: monotonicNowMs())
                }
            }
            onResult?(result)
        }
    }
}
