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
    private var isPrewarm: Bool { store.prewarmStreamId == streamId }
    private var shouldHoldPlayerItem: Bool { isActive || isPrewarm }
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
        case .images(_, let music, _): return music
        case nil: return nil
        }
    }

    var body: some View {
        ZStack {
            Color.black
            if case .images(_, _, let slides)? = media {
                ImagePostPager(slides: slides, isActive: isActive)
            } else {
                PlayerLayerView(
                    player: playerState.player,
                    videoGravity: usesFitGravity ? .resizeAspect : .resizeAspectFill,
                    isHidden: false,
                    onReadyForDisplay: {
                        AVTelemetryTracker.shared.recordReadyForDisplay(for: video.id)
                        withAnimation(.linear(duration: 0.12)) {
                            isFirstFrameRendered = true
                        }
                    }
                )

                if let coverUrl = videoCoverUrl, let url = URL(string: coverUrl), !isFirstFrameRendered {
                    BulletproofRemoteImage(url: url)
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .task(id: video.id) { await resolveOnce() }
        .task(id: prepareToken) { await prepareOnce() }
        .onChange(of: shouldPlay) { play in
            if play {
                playerState.player.play()
            } else {
                playerState.player.pause()
            }
        }
        .onChange(of: isActive) { active in
            if active {
                if !video.id.isEmpty { MediaCacheStorage.shared.pin(key: "k_\(video.id)") }
            } else {
                if !video.id.isEmpty { MediaCacheStorage.shared.unpin(key: "k_\(video.id)") }
            }
        }
        .onDisappear {
            playerState.player.pause()
            if !video.id.isEmpty { MediaCacheStorage.shared.unpin(key: "k_\(video.id)") }
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
        "|\(shouldHoldPlayerItem ? 1 : 0)|\(isActive ? 1 : 0)|\(store.sceneActive ? 1 : 0)"
    }

    private func prepareOnce() async {
        // Strict hardware decoder budget (Max 2 on A9): release decoder if neither active nor prewarm
        guard shouldHoldPlayerItem else {
            if playerState.player.currentItem != nil {
                playerState.player.pause()
                playerState.clearItem()
                preparedUrl = nil
            }
            return
        }

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
        guard let playURL = URL(string: playUrl) else {
            playbackFailed = true
            return
        }
        let needsNewItem = (playUrl != preparedUrl) || (playerState.player.currentItem == nil)
        if needsNewItem {
            // Optimistic playback: 0ms TTFF from local proxy/disk cache without blocking preflight!
            playerState.setItem(url: playURL, cacheKey: video.id)
            preparedUrl = playUrl
        } else if isActive, playerState.player.currentItem?.error != nil {
            playerState.setItem(url: playURL, cacheKey: video.id)
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
            Task {
                // Reactive 403 / failure token renewal
                let result = await viewModel.resolveMedia(id: video.id, force: true)
                if case .ready(let fresh) = result {
                    self.lease = fresh
                    await self.prepareOnce()
                }
            }
        } else {
            playbackFailed = true
        }
    }
}

/// Dedicated lightweight motion video loop controller for Live Photo posts.
/// Uses AVQueuePlayer + AVPlayerLooper for zero-freeze, sample-accurate, gapless looping.
/// Keeps audio strictly muted to avoid clashing with the post's master background music.
/// Exactly ONE instance is maintained per post, attaching only to the active slide.
@MainActor
final class MotionLoopPlayerController: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var readyWatchdogTask: Task<Void, Never>?
    private var currentTransitionId = UUID()

    @Published private(set) var activeUrl: String? = nil
    @Published private(set) var isReadyForDisplay = false

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func play(urlString: String) {
        if activeUrl == urlString {
            player.play()
            return
        }
        reset()
        guard let url = URL(string: urlString) else { return }

        let transitionId = UUID()
        currentTransitionId = transitionId
        activeUrl = urlString
        isReadyForDisplay = false

        let playbackUrl = LocalMediaProxyServer.shared.proxyUrl(for: url)
        let asset = AVURLAsset(url: playbackUrl, options: [
            "AVURLAssetHTTPHeaderFieldsKey": PlayerFactory.httpHeaders
        ])
        let templateItem = AVPlayerItem(asset: asset)

        // Disable audio tracks to avoid CoreAudio resource allocation
        for track in templateItem.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = false
        }

        looper = AVPlayerLooper(player: player, templateItem: templateItem)
        player.play()

        // 180ms Watchdog Fallback: guarantees isReadyForDisplay flips to true
        // even if initial KVO was delayed or swallowed during offscreen layout
        readyWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self = self, !Task.isCancelled else { return }
            if self.currentTransitionId == transitionId && !self.isReadyForDisplay {
                self.isReadyForDisplay = true
            }
        }
    }

    func markReady(for urlString: String) {
        guard activeUrl == urlString else { return }
        readyWatchdogTask?.cancel()
        readyWatchdogTask = nil
        isReadyForDisplay = true
    }

    func pause() {
        player.pause()
    }

    func reset() {
        currentTransitionId = UUID()
        readyWatchdogTask?.cancel()
        readyWatchdogTask = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        activeUrl = nil
        isReadyForDisplay = false
    }

    func cleanup() {
        reset()
    }

    deinit {
        readyWatchdogTask?.cancel()
        looper?.disableLooping()
    }
}

/// A photo/Live Photo post: horizontal paging through its slides, fitting the screen without cropping.
/// Backed by multi-tier ImagePipeline with ImageDiskCache, bidirectional prefetching,
/// active card Pinning, and 0ms synchronous RAM hits. Completely eliminates black screens on back-swipes.
/// For Live Photos (media_type: 42), mounts a single floating AVPlayerLooper onto the active slide.
private struct ImagePostPager: View {
    let slides: [GallerySlide]
    let isActive: Bool

    @State private var currentIndex: Int = 0
    @StateObject private var motionController = MotionLoopPlayerController()

    private var slideUrls: [URL] {
        slides.compactMap { URL(string: $0.imageUrl) }
    }

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                ZStack {
                    Color.black

                    // Base Layer: Static downsampled cover image (Always visible at 0ms, never goes black!)
                    if let url = URL(string: slide.imageUrl) {
                        BulletproofRemoteImage(url: url)
                    }

                    // Motion Layer: Attached ONLY when this slide is active AND motionController is actively playing this slide's video
                    if slide.isLivePhoto,
                       index == currentIndex,
                       isActive,
                       let motionUrl = slide.motionVideoUrl,
                       motionController.activeUrl == motionUrl {
                        PlayerLayerView(
                            player: motionController.player,
                            videoGravity: .resizeAspect,
                            isHidden: !motionController.isReadyForDisplay,
                            onReadyForDisplay: {
                                motionController.markReady(for: motionUrl)
                            }
                        )
                    }
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Immediate synchronous reset the instant page index changes
        .onChange(of: currentIndex) { _ in
            motionController.reset()
        }
        // Deterministic lifecycle trigger: reliably fires autoplay on initial appearance or page switch
        .task(id: "\(isActive)-\(currentIndex)") {
            if isActive {
                ImagePipeline.shared.pin(urls: slideUrls)
                scheduleBidirectionalPrefetch(around: currentIndex)
                // 50ms debounce so user momentum swipe doesn't thrash decoder
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !Task.isCancelled {
                    updateMotionLoop(for: currentIndex)
                }
            } else {
                motionController.pause()
                ImagePipeline.shared.unpin(urls: slideUrls)
            }
        }
        .onDisappear {
            ImagePipeline.shared.unpin(urls: slideUrls)
            motionController.cleanup()
        }
    }

    // Bidirectional prefetching: warms up both next (N+1) and previous (N-1) images
    private func scheduleBidirectionalPrefetch(around index: Int) {
        guard isActive else { return }
        var urlsToWarm: [URL] = []
        if index + 1 < slides.count, let nextUrl = URL(string: slides[index + 1].imageUrl) {
            urlsToWarm.append(nextUrl)
        }
        if index - 1 >= 0, let prevUrl = URL(string: slides[index - 1].imageUrl) {
            urlsToWarm.append(prevUrl)
        }
        ImagePipeline.shared.prefetch(urls: urlsToWarm)
    }

    private func updateMotionLoop(for index: Int) {
        guard isActive, index >= 0, index < slides.count else {
            motionController.reset()
            return
        }
        let slide = slides[index]
        if let motionUrl = slide.motionVideoUrl {
            motionController.play(urlString: motionUrl)
        } else {
            motionController.reset()
        }
    }
}

/// Bulletproof remote image view:
/// 1. Synchronously probes L1 RAM in init() for instantaneous 0ms hits on reuse/back-swipe.
/// 2. Asynchronously loads from L2 flash disk cache (<2ms) or network, smoothly presenting the image.
/// 3. Never falls back to foreign slide images so each slide is purely its own content.
private struct BulletproofRemoteImage: View {
    let url: URL

    @State private var image: UIImage?

    init(url: URL) {
        self.url = url

        // Synchronous probe: if image is in L1 or pinned, present in frame 0!
        if let cached = ImagePipeline.shared.cachedImage(for: url) {
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
        .task(id: url) {
            if image == nil || image != ImagePipeline.shared.cachedImage(for: url) {
                if let loaded = await ImagePipeline.shared.loadImage(for: url) {
                    self.image = loaded
                }
            }
        }
    }
}
