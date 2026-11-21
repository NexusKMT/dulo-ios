import AVFoundation
import SwiftUI

/// One feed page: owns its AVPlayer, resolves its lease, and drives
/// play/pause from the pager. Port of the Android `FeedVideoPage`.
struct FeedVideoPage: View {
    let streamId: Int64
    let video: VideoItem
    @ObservedObject var store: FeedStreamStore
    @ObservedObject var viewModel: FeedViewModel
    let onNextVideo: () -> Void

    @StateObject private var playerState = PlayerState()
    @State private var lease: Lease<ResolvedMedia>?
    @State private var resolutionFailed = false
    @State private var playbackFailed = false
    @State private var renewAttempted = false
    @State private var retryOnActivation = false
    @State private var retryCount = 0
    @State private var retryNonce = 0
    @State private var preparedUrl: String?

    init(streamId: Int64, video: VideoItem, store: FeedStreamStore,
         viewModel: FeedViewModel, onNextVideo: @escaping () -> Void) {
        self.streamId = streamId
        self.video = video
        self.store = store
        self.viewModel = viewModel
        self.onNextVideo = onNextVideo
        _lease = State(initialValue: viewModel.cachedLease(for: video.id))
    }

    private var isActive: Bool { store.activeStreamId == streamId }
    private var shouldPlay: Bool { isActive && store.sceneActive }

    private var media: ResolvedMedia? { lease?.value }

    private var isImagePost: Bool {
        if case .images = media { return true }
        return false
    }

    /// Videos play their stream; image posts play their background track.
    private var playUrl: String? {
        switch media {
        case .video(let url): return url
        case .images(_, let music): return music
        case nil: return nil
        }
    }

    var body: some View {
        ZStack {
            Color.black
            if case .images(let urls, _)? = media {
                ImagePostPager(urls: urls)
            } else {
                PlayerLayerView(
                    player: playerState.player,
                    videoGravity: playerState.usesFitGravity ? .resizeAspect : .resizeAspectFill,
                    isHidden: playerState.presentationSize == .zero
                )
            }
        }
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard isImagePost,
                  let item = note.object as? AVPlayerItem,
                  item === playerState.player.currentItem else { return }
            playerState.player.seek(to: .zero)
            playerState.player.play()
        }
        .task(id: video.id) { await resolveOnce() }
        .task(id: prepareToken) { await prepareOnce() }
        .onChange(of: playerState.isPlaying) { playing in
            store.setKeepAwake(playing, for: streamId)
        }
        .onChange(of: isImagePost && isActive) { awake in
            store.setKeepAwake(awake, for: streamId)
        }
        .onChange(of: skipToken) {
            if isActive && (resolutionFailed || playbackFailed) { onNextVideo() }
        }
        .onDisappear {
            store.setKeepAwake(false, for: streamId)
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
        func handle(_ result: MediaResolution) {
            switch result {
            case .ready(let fresh):
                lease = fresh
                resolutionFailed = false
            default:
                if shouldRetryResolution(result, retries: retries) {
                    retries += 1
                    viewModel.resolveMedia(id: video.id, force: false, onResult: handle)
                } else {
                    resolutionFailed = true
                }
            }
        }
        viewModel.resolveMedia(id: video.id, force: false, onResult: handle)
    }

    // MARK: - Playback

    private var prepareToken: String {
        "\(playUrl ?? "-")|\(lease?.expiresAtElapsedMs ?? 0)|\(retryNonce)" +
        "|\(isActive ? 1 : 0)|\(retryOnActivation ? 1 : 0)|\(store.sceneActive ? 1 : 0)"
    }

    private var skipToken: String {
        "\(isActive ? 1 : 0)|\(resolutionFailed ? 1 : 0)|\(playbackFailed ? 1 : 0)"
    }

    private func prepareOnce() async {
        guard let lease, lease.isFresh(nowElapsedMs: monotonicNowMs()) else {
            playerState.player.pause()
            if isActive {
                viewModel.resolveMedia(id: video.id, force: false) { result in
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
        if playUrl != preparedUrl {
            // 403 -> renew the lease with force=1 once, mirroring the
            // Android player-error path. Preflight keeps this deterministic:
            // AVFoundation hides HTTP status codes in its errors.
            if let status = await PlayerFactory.preflightStatus(url: playUrl),
               status == 403, !video.id.isEmpty, !renewAttempted {
                renewAttempted = true
                viewModel.resolveMedia(id: video.id, force: true) { result in
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
            if resumeAt.seconds > 0 { playerState.player.seek(to: resumeAt) }
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

/// A photo post: horizontal paging through its images, filling the screen.
private struct ImagePostPager: View {
    let urls: [String]

    var body: some View {
        TabView {
            ForEach(urls, id: \.self) { url in
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.black
                    default:
                        Color.black
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}
