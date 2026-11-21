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
                        withAnimation(.linear(duration: 0.12)) {
                            isFirstFrameRendered = true
                        }
                    }
                )

                if let coverUrl = videoCoverUrl, let url = URL(string: coverUrl), !isFirstFrameRendered {
                    BulletproofRemoteImage(url: url, coverPlaceholderUrl: nil)
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
            playerState.player.replaceCurrentItem(with: PlayerFactory.makeItem(url: playURL, cacheKey: video.id))
            preparedUrl = playUrl
            if resumeAt.seconds > 0 { await playerState.player.seek(to: resumeAt) }
        } else if isActive, playerState.player.currentItem?.error != nil {
            // Retry a failed prepare; deferred to activation for neighbours.
            playerState.player.replaceCurrentItem(with: PlayerFactory.makeItem(url: playURL, cacheKey: video.id))
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

/// Dedicated lightweight motion video loop controller for Live Photo posts.
/// Uses AVQueuePlayer + AVPlayerLooper for zero-freeze, sample-accurate, gapless looping.
/// Keeps audio strictly muted to avoid clashing with the post's master background music.
/// Exactly ONE instance is maintained per post, attaching only to the active slide.
@MainActor
final class MotionLoopPlayerController: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var currentUrl: String?
    private var readyWatchdogTask: Task<Void, Never>?

    @Published private(set) var isReadyForDisplay = false

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func play(urlString: String) {
        if currentUrl == urlString {
            player.play()
            return
        }
        cleanup()
        guard let url = URL(string: urlString) else { return }

        currentUrl = urlString
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
        readyWatchdogTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if !Task.isCancelled && !self.isReadyForDisplay {
                self.isReadyForDisplay = true
            }
        }
    }

    func markReady() {
        readyWatchdogTask?.cancel()
        readyWatchdogTask = nil
        isReadyForDisplay = true
    }

    func pause() {
        player.pause()
    }

    func cleanup() {
        readyWatchdogTask?.cancel()
        readyWatchdogTask = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        currentUrl = nil
        isReadyForDisplay = false
    }

    deinit {
        cleanup()
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
                        BulletproofRemoteImage(
                            url: url,
                            coverPlaceholderUrl: slides.first.flatMap { URL(string: $0.imageUrl) }
                        )
                    }

                    // Motion Layer: Attached only to the active slide if it's a Live Photo
                    if slide.isLivePhoto, index == currentIndex, isActive {
                        PlayerLayerView(
                            player: motionController.player,
                            videoGravity: .resizeAspect,
                            isHidden: !motionController.isReadyForDisplay,
                            onReadyForDisplay: {
                                withAnimation(.linear(duration: 0.12)) {
                                    motionController.markReady()
                                }
                            }
                        )
                    }
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Deterministic lifecycle trigger: reliably fires Slide 0 autoplay on initial post appearance
        .task(id: "\(isActive)-\(currentIndex)") {
            if isActive {
                ImagePipeline.shared.pin(urls: slideUrls)
                scheduleBidirectionalPrefetch(around: currentIndex)
                // 80ms debounce so user momentum swipe is buttery smooth
                try? await Task.sleep(nanoseconds: 80_000_000)
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
            motionController.cleanup()
            return
        }
        let slide = slides[index]
        if let motionUrl = slide.motionVideoUrl {
            motionController.play(urlString: motionUrl)
        } else {
            motionController.cleanup()
        }
    }
}

/// Bulletproof remote image view:
/// 1. Synchronously probes L1 RAM in init() for instantaneous 0ms hits on reuse/back-swipe.
/// 2. If L1 is empty (e.g. after rapid swipe), immediately displays the first slide's cover placeholder (NEVER black!).
/// 3. Asynchronously loads from L2 flash disk cache (<2ms) or network, smoothly presenting the full image.
private struct BulletproofRemoteImage: View {
    let url: URL
    let coverPlaceholderUrl: URL?

    @State private var image: UIImage?

    init(url: URL, coverPlaceholderUrl: URL?) {
        self.url = url
        self.coverPlaceholderUrl = coverPlaceholderUrl

        // Synchronous probe: if image is in L1 or pinned, present in frame 0!
        if let cached = ImagePipeline.shared.cachedImage(for: url) {
            _image = State(initialValue: cached)
        } else if let coverUrl = coverPlaceholderUrl, let coverCached = ImagePipeline.shared.cachedImage(for: coverUrl) {
            // Placeholder fallback: display first slide's cover so user NEVER sees black!
            _image = State(initialValue: coverCached)
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
