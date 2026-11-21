import AVFoundation
import SwiftUI

/// One feed page: owns its AVPlayer, resolves its lease, and drives
/// play/pause from the pager. Port of the Android `FeedVideoPage`.
@MainActor
struct FeedVideoPage: View {
    let streamId: Int64
    let video: VideoItem
    @ObservedObject var store: FeedStreamStore
    @ObservedObject var viewModel: FeedViewModel

    @StateObject private var playerState = PlayerState()
    @State private var lease: Lease<ResolvedMedia>?
    @State private var resolutionFailed = false
    @State private var playbackFailed = false
    @State private var renewAttempted = false
    @State private var retryOnActivation = false
    @State private var retryCount = 0
    @State private var retryNonce = 0
    @State private var preparedUrl: String?
    @State private var isFirstFrameRendered = false

    init(streamId: Int64, video: VideoItem, store: FeedStreamStore, viewModel: FeedViewModel) {
        self.streamId = streamId
        self.video = video
        self.store = store
        self.viewModel = viewModel
        _lease = State(initialValue: viewModel.cachedLease(for: video.id))
    }

    private var isActive: Bool { store.activeStreamId == streamId }
    private var shouldPlay: Bool { isActive && store.sceneActive }

    private var media: ResolvedMedia? { lease?.value }

    private var isImagePost: Bool {
        if case .images = media { return true }
        return false
    }

    private var videoCoverUrl: String? {
        if case .video(_, let cover, _, _) = media {
            return cover
        }
        return nil
    }

    private var usesFitGravity: Bool {
        if case .video(_, _, let w, let h) = media, w > 0 && h > 0 {
            return w > h
        }
        return playerState.usesFitGravity
    }

    /// Videos play their stream; image posts play their background track.
    private var playUrl: String? {
        switch media {
        case .video(let url, _, _, _): return url
        case .images(_, let music): return music
        case nil: return nil
        }
    }

    var body: some View {
        ZStack {
            Color.black
            if case .images(let urls, _)? = media {
                ImagePostPager(urls: urls, isActive: isActive)
            } else {
                PlayerLayerView(
                    player: playerState.player,
                    videoGravity: usesFitGravity ? .resizeAspect : .resizeAspectFill,
                    isHidden: false,
                    onReadyForDisplay: {
                        withAnimation(.linear(duration: 0.12)) {
                            isFirstFrameRendered = true
                        }
                    }
                )

                if let coverUrl = videoCoverUrl, let url = URL(string: coverUrl), !isFirstFrameRendered {
                    FastRemoteImage(url: url, shouldLoad: true)
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === playerState.player.currentItem else { return }
            guard isActive else { return }
            playerState.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            playerState.player.play()
        }
        .task(id: video.id) { await resolveOnce() }
        .task(id: prepareToken) { await prepareOnce() }
        .onChange(of: shouldPlay) { play in
            if play {
                playerState.player.play()
            } else {
                playerState.player.pause()
            }
        }
        .onDisappear {
            playerState.player.pause()
        }
        .onAppear {
            playerState.onPlaybackError = { [self] error in
                _ = error
                handlePlaybackError()
            }
        }
    }

    // MARK: - Resolution

    private func resolveOnce() async {
        if lease?.isFresh(nowElapsedMs: monotonicNowMs()) == true { return }
        var retries = 0
        while !Task.isCancelled {
            let result = await viewModel.resolveMedia(id: video.id, force: false)
            if Task.isCancelled { return }
            switch result {
            case .ready(let fresh):
                lease = fresh
                resolutionFailed = false
                return
            default:
                if shouldRetryResolution(result, retries: retries) {
                    retries += 1
                } else {
                    resolutionFailed = true
                    return
                }
            }
        }
    }

    // MARK: - Playback

    private var prepareToken: String {
        "\(playUrl ?? "-")|\(lease?.expiresAtElapsedMs ?? 0)|\(retryNonce)" +
        "|\(isActive ? 1 : 0)|\(retryOnActivation ? 1 : 0)|\(store.sceneActive ? 1 : 0)"
    }

    private func prepareOnce() async {
        guard let lease, lease.isFresh(nowElapsedMs: monotonicNowMs()) else {
            playerState.player.pause()
            if isActive {
                let result = await viewModel.resolveMedia(id: video.id, force: false)
                if !Task.isCancelled {
                    switch result {
                    case .ready(let fresh): self.lease = fresh
                    default: resolutionFailed = true
                    }
                }
            }
            return
        }
        guard let playUrl else {
            playerState.player.pause()
            return
        }
        guard URL(string: playUrl) != nil else {
            playbackFailed = true
            return
        }
        let playURL = URL(string: playUrl)!
        let needsNewItem = (playUrl != preparedUrl) || (playerState.player.currentItem == nil)
        if needsNewItem {
            // 403 -> renew the lease with force=1 once, mirroring the
            // Android player-error path. Preflight keeps this deterministic:
            // AVFoundation hides HTTP status codes in its errors.
            if let status = await PlayerFactory.preflightStatus(url: playUrl),
               status == 403, !video.id.isEmpty, !renewAttempted {
                renewAttempted = true
                let result = await viewModel.resolveMedia(id: video.id, force: true)
                if !Task.isCancelled {
                    switch result {
                    case .ready(let fresh): self.lease = fresh
                    default: playbackFailed = true
                    }
                }
                return
            }
            let resumeAt = (preparedUrl == nil) ? CMTime.zero : playerState.player.currentTime()
            playerState.player.replaceCurrentItem(with: PlayerFactory.makeItem(url: playURL))
            preparedUrl = playUrl
            if resumeAt.seconds > 0 { await playerState.player.seek(to: resumeAt) }
        } else if isActive, playerState.player.currentItem?.error != nil {
            // Retry a failed prepare; deferred to activation for neighbours.
            playerState.player.replaceCurrentItem(with: PlayerFactory.makeItem(url: playURL))
        }
        if shouldPlay {
            playerState.player.play()
        } else {
            playerState.player.pause()
        }
    }

    private func handlePlaybackError() {
        if !isActive {
            retryOnActivation = true
            return
        }
        if retryCount < 2 {
            retryCount += 1
            retryNonce += 1
        } else {
            playbackFailed = true
        }
    }
}

/// A photo post: horizontal paging through its images, fitting the screen without cropping.
/// Backed by global in-memory ImagePipeline, guaranteeing instant 0ms hits on back-swipes,
/// no ProgressView spinners, and strictly windowed sliding-cache prefetching.
private struct ImagePostPager: View {
    let urls: [String]
    let isActive: Bool

    @State private var currentIndex: Int = 0

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, urlString in
                if let url = URL(string: urlString) {
                    FastRemoteImage(
                        url: url,
                        shouldLoad: shouldLoad(at: index)
                    )
                    .tag(index)
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: currentIndex) { index in
            schedulePrefetch(around: index)
        }
        .onChange(of: isActive) { active in
            if active {
                schedulePrefetch(around: currentIndex)
            }
        }
        .onAppear {
            if isActive {
                schedulePrefetch(around: currentIndex)
            } else if let first = urls.first, let url = URL(string: first) {
                // When vertically prefetching (N+1), only prefetch the cover image!
                ImagePipeline.shared.prefetch(urls: [url])
            }
        }
    }

    private func shouldLoad(at index: Int) -> Bool {
        guard isActive else {
            // When prefetching vertically (N+1 / N+2), only load the cover photo (index 0)
            return index == 0
        }
        // Enforce sliding window: active image and immediate neighbours (index ± 1)
        return abs(index - currentIndex) <= 1
    }

    private func schedulePrefetch(around index: Int) {
        guard isActive else { return }
        // Pre-warm the next image in the scroll path
        let nextIndex = index + 1
        if nextIndex < urls.count, let url = URL(string: urls[nextIndex]) {
            ImagePipeline.shared.prefetch(urls: [url])
        }
    }
}

/// Instantaneous remote image view: probes L1 NSCache synchronously in init,
/// completely eliminating the 1-frame empty phase and ProgressView spinners on reuse.
/// Releases decoded bitmaps outside the sliding window to protect against Jetsam OOM.
private struct FastRemoteImage: View {
    let url: URL
    let shouldLoad: Bool

    @State private var image: UIImage?

    init(url: URL, shouldLoad: Bool) {
        self.url = url
        self.shouldLoad = shouldLoad
        if shouldLoad, let cached = ImagePipeline.shared.cachedImage(for: url) {
            _image = State(initialValue: cached)
        }
    }

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: shouldLoad) {
            if shouldLoad && image == nil {
                if let cached = ImagePipeline.shared.cachedImage(for: url) {
                    image = cached
                    return
                }
                if let loaded = await ImagePipeline.shared.loadImage(for: url) {
                    image = loaded
                }
            }
        }
    }
}
