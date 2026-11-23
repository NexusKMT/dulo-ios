import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Industrial-grade Multi-Modal Player Pool adhering to ByteDance (Douyin/TikTok) and Kuaishou feed engineering.
///
/// Hardware Decoders Budget on Apple A9 (iPhone 6s Plus):
/// Strictly caps hardware video decoders (VTDecompressionSession) to TWO concurrent instances:
/// - Slot 0: Active Full-Screen Video OR Active Live Photo Motion Loop
/// - Slot 1: Standby Prewarm Video (N+1)
/// - BGM Audio Player: Dedicated CoreAudio background music player (0 VideoToolbox decoders)
///
/// Players are allocated ONCE at startup and NEVER destroyed during scrolling.
/// Zero mediaserverd IPC allocation churn during cell dequeue, guaranteeing 60fps locked scrolling.
@MainActor
public final class FeedPlayerPool {
    public static let shared = FeedPlayerPool()

    // MARK: - Video Slot (Hardware VTDecompressionSession)

    @MainActor
    public final class PlayerSlot {
        public let slotIndex: Int
        public let player = AVPlayer()
        private var endObserver: NSObjectProtocol?

        public private(set) var currentStreamId: Int64?
        public private(set) var currentVideoId: String?
        public private(set) var currentPlayUrl: String?

        private var hasRegisteredDecoder = false

        public func setMuted(_ muted: Bool) {
            player.isMuted = muted
            player.volume = muted ? 0.0 : 1.0
        }

        public init(slotIndex: Int) {
            self.slotIndex = slotIndex
            player.automaticallyWaitsToMinimizeStalling = true
            player.preventsDisplaySleepDuringVideoPlayback = true
            player.actionAtItemEnd = .none

            // Gapless single-item loop: keeps the existing VTDecompressionSession alive across loops
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self,
                      let currentItem = self.player.currentItem,
                      (notification.object as? AVPlayerItem) === currentItem else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self = self, self.player.timeControlStatus != .paused else { return }
                    self.player.play()
                }
            }
        }

        public func prepare(
            streamId: Int64,
            videoId: String,
            playUrl: String,
            isMuted: Bool = false,
            autoplay: Bool,
            videoGravity: AVLayerVideoGravity = .resizeAspect,
            disableAudioTracks: Bool = false
        ) {
            let effectiveMuted = isMuted || disableAudioTracks
            setMuted(effectiveMuted)

            if currentStreamId == streamId && currentPlayUrl == playUrl && player.currentItem != nil {
                if player.currentItem?.status == .failed || player.error != nil {
                    // Item failed (e.g. proxy severed during lock screen); fall through to recreate
                } else {
                    if autoplay {
                        player.play()
                    } else {
                        player.pause()
                    }
                    return
                }
            }

            clear()

            currentStreamId = streamId
            currentVideoId = videoId
            currentPlayUrl = playUrl

            guard let url = URL(string: playUrl) else { return }

            let playbackUrl = LocalMediaProxyServer.shared.proxyUrl(for: url, cacheKey: videoId)
            // Headers (UA/Referer) are injected by LocalMediaProxyServer; AVURLAsset
            // does not expose a supported per-asset HTTP header dictionary on iOS 15.
            let asset = AVURLAsset(url: playbackUrl)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2.0 // 2.0s lean buffer for A9 2GB RAM

            if disableAudioTracks {
                for track in item.tracks where track.assetTrack?.mediaType == .audio {
                    track.isEnabled = false
                }
            }

            AVTelemetryTracker.shared.bindItem(item, for: videoId)
            player.replaceCurrentItem(with: item)

            if !hasRegisteredDecoder {
                hasRegisteredDecoder = true
                AVTelemetryTracker.shared.registerActiveDecoder()
            }

            if autoplay {
                player.play()
            } else {
                player.pause()
            }
        }

        public func play() {
            player.playImmediately(atRate: 1.0)
        }

        public func pause() {
            player.pause()
        }

        public func clear() {
            currentStreamId = nil
            currentVideoId = nil
            currentPlayUrl = nil
            player.pause()
            if let item = player.currentItem {
                AVTelemetryTracker.shared.unbindItem(item)
            }
            player.replaceCurrentItem(with: nil) // Immediately release VTDecompressionSession to mediaserverd!

            if hasRegisteredDecoder {
                hasRegisteredDecoder = false
                AVTelemetryTracker.shared.unregisterActiveDecoder()
            }
        }

        deinit {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }

    // MARK: - Background Audio Player (CoreAudio only, 0 VideoToolbox decoders)

    @MainActor
    public final class BgmAudioPlayer {
        private let player = AVPlayer()
        private var endObserver: NSObjectProtocol?
        public private(set) var currentUrl: String?

        /// Set by the pool. A queued end notification must only loop while
        /// this gallery still owns audio focus and is allowed to play.
        public var shouldLoop: (() -> Bool)?

        public init() {
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .none

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self = self,
                          let currentItem = self.player.currentItem,
                          (notification.object as? AVPlayerItem) === currentItem else { return }
                    guard self.shouldLoop?() == true,
                          self.player.timeControlStatus != .paused else { return }
                    self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self = self,
                                  self.shouldLoop?() == true,
                                  self.player.timeControlStatus != .paused else { return }
                            self.player.play()
                        }
                    }
                }
            }
        }

        public var isPlaying: Bool {
            player.timeControlStatus == .playing
        }

        public func resume() {
            player.play()
        }

        public func play(urlString: String) {
            if currentUrl == urlString && player.currentItem != nil {
                player.play()
                return
            }
            stop()
            guard let url = URL(string: urlString) else { return }
            currentUrl = urlString

            let playbackUrl = LocalMediaProxyServer.shared.proxyUrl(for: url)
            let asset = AVURLAsset(url: playbackUrl)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2.0
            player.replaceCurrentItem(with: item)
            player.play()
        }

        public func pause() {
            player.pause()
        }

        public func stop() {
            guard currentUrl != nil || player.currentItem != nil else { return }
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentUrl = nil
        }

        deinit {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }

    public let activeSlot = PlayerSlot(slotIndex: 0)
    public let standbySlot = PlayerSlot(slotIndex: 1)
    public let bgmPlayer = BgmAudioPlayer()

    /// Actual implementation state. Never use this as the source of truth for
    /// lifecycle decisions; `audioFocus` is the policy state.
    public private(set) weak var currentPlayingSlot: PlayerSlot?

    /// The single policy state for video and gallery audio.
    private(set) var audioFocus = AudioFocusState()

    public var audioOwner: AudioOwner { audioFocus.owner }
    public var userPaused: Bool { audioFocus.isUserPaused }
    public var hasSystemPauseReason: Bool { audioFocus.hasSystemPauseReason }
    public var shouldPlayAudio: Bool { audioFocus.shouldPlay }

    /// Dynamic symmetric 2-decoder allocation adhering to TikTok/Douyin Ping-Pong architecture.
    /// Preserves existing playback session when transitioning between active and prewarm states,
    /// completely eliminating video layer teardown, buffer re-fetches, and black screen flicker.
    public func acquireSlot(for streamId: Int64, visibleStreamIds: Set<Int64>) -> PlayerSlot {
        // 1. If this streamId is already bound to a slot, keep it!
        if activeSlot.currentStreamId == streamId { return activeSlot }
        if standbySlot.currentStreamId == streamId { return standbySlot }

        // 2. Otherwise allocate the slot that is NOT currently visible on screen
        let activeInUse = activeSlot.currentStreamId.map { visibleStreamIds.contains($0) } ?? false
        let standbyInUse = standbySlot.currentStreamId.map { visibleStreamIds.contains($0) } ?? false

        if !activeInUse {
            return activeSlot
        } else if !standbyInUse {
            return standbySlot
        } else {
            return standbySlot
        }
    }

    /// Feeds a video page activation into the single audio reducer. The pool
    /// executes effects; it no longer decides whether BGM or a video wins.
    public func play(slot: PlayerSlot, streamId: Int64? = nil) {
        guard let streamId = streamId ?? slot.currentStreamId else { return }
        if ExperimentVariant.audioFixEnabled,
           audioFocus.owner == .video(streamId: streamId),
           audioFocus.shouldPlay {
            // Same owner: `prepare(autoplay: false)` has just paused the slot,
            // so call play() directly instead of re-running the reducer and
            // synchronously re-activating AVAudioSession on every refresh.
            if currentPlayingSlot !== slot {
                if slot === activeSlot {
                    standbySlot.pause()
                } else {
                    activeSlot.pause()
                }
                currentPlayingSlot = slot
            }
            slot.play()
            return
        }
        applyAudio(.activateVideo(streamId: streamId), preferredSlot: slot)
    }

    /// A gallery page owns audio for its stream, with or without BGM. Passing
    /// `nil` is an explicit "this page has no BGM" and stops any leftover track.
    public func activateGallery(streamId: Int64, bgmURL: URL?) {
        applyAudio(.activateGallery(streamId: streamId, bgmURL: bgmURL))
    }

    public func slot(for streamId: Int64) -> PlayerSlot? {
        if activeSlot.currentStreamId == streamId { return activeSlot }
        if standbySlot.currentStreamId == streamId { return standbySlot }
        return nil
    }

    private init() {
        #if canImport(AVFAudio)
        PlayerFactory.configureAudioSession()
        #endif
        bgmPlayer.shouldLoop = { [weak self] in
            guard let self else { return false }
            guard case .gallery = self.audioFocus.owner else { return false }
            return self.audioFocus.shouldPlay
        }
        _ = PlaybackInterruptionCoordinator.shared
    }

    // MARK: - Audio Focus Reducer

    private func applyAudio(
        _ event: AudioFocusEvent,
        preferredSlot: PlayerSlot? = nil
    ) {
        let effects = AudioFocusReducer.reduce(state: &audioFocus, event: event)
        for effect in effects {
            performAudio(effect, preferredSlot: preferredSlot)
        }
    }

    private func performAudio(
        _ effect: AudioFocusEffect,
        preferredSlot: PlayerSlot? = nil
    ) {
        switch effect {
        case .activateSession:
            if ExperimentVariant.audioFixEnabled {
                PlayerFactory.activateAudioSessionIfNeeded()
            } else {
                PlayerFactory.activateAudioSession()
            }

        case .deactivateSession:
            PlayerFactory.deactivateAudioSession()

        case .playVideo(let streamId):
            guard audioFocus.owner == .video(streamId: streamId) else { return }
            guard let slot = slot(for: streamId) ?? preferredSlot else { return }
            if slot === activeSlot {
                standbySlot.pause()
            } else {
                activeSlot.pause()
            }
            currentPlayingSlot = slot
            slot.play()

        case .pauseVideo:
            activeSlot.pause()
            standbySlot.pause()
            currentPlayingSlot = nil

        case .playBGM(let streamId, let url):
            guard case .gallery(let ownerStreamId, _) = audioFocus.owner,
                  ownerStreamId == streamId else { return }
            currentPlayingSlot = nil
            activeSlot.pause()
            standbySlot.pause()
            bgmPlayer.play(urlString: url.absoluteString)

        case .pauseBGM:
            bgmPlayer.pause()

        case .stopBGM:
            bgmPlayer.stop()
        }
    }

    // MARK: - App Interruption & Lock Screen Lifecycle

    public func handlePageChanged() {
        applyAudio(.pageChanged)
    }

    public func handleAppResignActive() {
        if ExperimentVariant.audioFixEnabled {
            PlayerFactory.noteAudioSessionInterrupted()
        }
        applyAudio(.sceneInactive)
    }

    public func handleForegroundEntered() {
        // A real background -> foreground transition is explicit user intent.
        // Restore the proxy before the reducer replays the current owner, so a
        // socket that died while suspended cannot be reused.
        LocalMediaProxyServer.shared.ensureRunning()
        applyAudio(.foregroundEntered)
    }

    public func handleAppBecomeActive() {
        LocalMediaProxyServer.shared.ensureRunning()
        #if canImport(AVFAudio)
        PlayerFactory.configureAudioSession()
        #endif
        applyAudio(.sceneActive)
        healVideoAfterForeground()
    }

    public func handleAudioInterruptionBegan() {
        if ExperimentVariant.audioFixEnabled {
            PlayerFactory.noteAudioSessionInterrupted()
        }
        applyAudio(.interruptionBegan)
    }

    public func handleAudioInterruptionEnded(shouldResume: Bool) {
        if ExperimentVariant.audioFixEnabled {
            PlayerFactory.noteAudioSessionInterrupted()
        }
        applyAudio(.interruptionEnded(shouldResume: shouldResume))
        if shouldResume {
            healVideoAfterForeground()
        }
    }

    public func handleAudioRouteLost() {
        if ExperimentVariant.audioFixEnabled {
            PlayerFactory.noteAudioSessionInterrupted()
        }
        applyAudio(.routeLost)
    }

    public func handleAudioRouteAvailable() {
        applyAudio(.routeAvailable)
        if audioFocus.shouldPlay {
            healVideoAfterForeground()
        }
    }

    public func setUserPaused(_ paused: Bool) {
        applyAudio(paused ? .userPause : .userPlay)
    }

    private func healVideoAfterForeground() {
        guard case .video(let streamId) = audioFocus.owner,
              let slot = slot(for: streamId) else {
            healFailedVideo(activeSlot)
            healFailedVideo(standbySlot)
            return
        }

        let autoplay = audioFocus.shouldPlay
        if slot.player.currentItem?.status == .failed || slot.player.error != nil {
            if let sId = slot.currentStreamId,
               let vId = slot.currentVideoId,
               let url = slot.currentPlayUrl {
                slot.prepare(
                    streamId: sId,
                    videoId: vId,
                    playUrl: url,
                    autoplay: autoplay
                )
            }
        } else if autoplay && slot.player.timeControlStatus != .playing {
            let currentTime = slot.player.currentTime()
            // Force a fresh Range request if the proxy socket was severed
            // while the app was locked.
            slot.player.seek(
                to: currentTime,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak slot] _ in
                Task { @MainActor [weak self, weak slot] in
                    guard let self,
                          let slot,
                          self.audioFocus.shouldPlay,
                          self.audioFocus.owner == .video(streamId: streamId) else { return }
                    slot.play()
                }
            }
        } else if autoplay {
            slot.play()
        }

        healFailedVideo(slot === activeSlot ? standbySlot : activeSlot)
    }

    private func healFailedVideo(_ slot: PlayerSlot) {
        guard slot.player.currentItem?.status == .failed || slot.player.error != nil else {
            return
        }
        guard let streamId = slot.currentStreamId,
              let videoId = slot.currentVideoId,
              let url = slot.currentPlayUrl else { return }
        slot.prepare(
            streamId: streamId,
            videoId: videoId,
            playUrl: url,
            autoplay: false
        )
    }

    public func pauseAll() {
        activeSlot.pause()
        standbySlot.pause()
        bgmPlayer.pause()
        currentPlayingSlot = nil
    }

    /// Test-only reset that also clears the policy state.
    func resetAudioFocusForTesting() {
        audioFocus = AudioFocusState()
        activeSlot.clear()
        standbySlot.clear()
        bgmPlayer.stop()
        currentPlayingSlot = nil
    }
}
