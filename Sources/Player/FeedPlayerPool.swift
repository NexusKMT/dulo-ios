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

        public init() {
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .none

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self,
                      let currentItem = self.player.currentItem,
                      (notification.object as? AVPlayerItem) === currentItem else { return }
                // A queued end notification must not revive music after a pause,
                // route change, or background transition.
                guard !PlaybackInterruptionCoordinator.shared.userPaused,
                      self.player.timeControlStatus != .paused else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self = self,
                          !PlaybackInterruptionCoordinator.shared.userPaused,
                          self.player.timeControlStatus != .paused else { return }
                    self.player.play()
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

    public private(set) weak var currentPlayingSlot: PlayerSlot?
    public var userPaused: Bool {
        get { PlaybackInterruptionCoordinator.shared.userPaused }
        set { PlaybackInterruptionCoordinator.shared.setUserPaused(newValue) }
    }

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

    /// Guarantees strict single-playback invariant: exactly ONE audio/video source plays at any moment.
    /// This is intentionally idempotent: scroll/layout refreshes must not reset interruption
    /// or user-pause intent.
    public func play(slot: PlayerSlot) {
        let coordinator = PlaybackInterruptionCoordinator.shared
        guard !coordinator.userPaused, !coordinator.pausedByInterruption else { return }

        // A video taking audio focus revokes any gallery BGM ownership. Pausing
        // alone leaves `currentUrl` behind, and wake-from-lock would resume that
        // stale gallery track underneath the current video.
        bgmPlayer.stop()

        if currentPlayingSlot === slot,
           slot.player.timeControlStatus == .playing {
            return
        }
        PlayerFactory.activateAudioSession()
        currentPlayingSlot = slot
        if slot === activeSlot {
            standbySlot.pause()
        } else {
            activeSlot.pause()
        }
        slot.play()
    }

    public func playBgm(urlString: String) {
        let coordinator = PlaybackInterruptionCoordinator.shared
        guard !coordinator.userPaused, !coordinator.pausedByInterruption else { return }
        if currentPlayingSlot == nil,
           bgmPlayer.currentUrl == urlString,
           bgmPlayer.isPlaying {
            return
        }
        PlayerFactory.activateAudioSession()
        currentPlayingSlot = nil
        activeSlot.pause()
        standbySlot.pause()
        bgmPlayer.play(urlString: urlString)
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
        _ = PlaybackInterruptionCoordinator.shared
    }

    // MARK: - App Interruption & Lock Screen Lifecycle (Decoupled from Feed Paging)

    public func handleAppResignActive() {
        activeSlot.pause()
        standbySlot.pause()
        bgmPlayer.pause()
        PlayerFactory.deactivateAudioSession()
    }

    public func handleAppBecomeActive() {
        LocalMediaProxyServer.shared.ensureRunning()

        // Audio focus is exclusive. If a video is the current owner, drop any
        // gallery BGM left over from a previous page before resuming video.
        if currentPlayingSlot != nil {
            bgmPlayer.stop()
        }

        #if canImport(AVFAudio)
        PlayerFactory.configureAudioSession()
        if currentPlayingSlot != nil || bgmPlayer.currentUrl != nil {
            PlayerFactory.activateAudioSession()
        }
        #endif

        if let slot = currentPlayingSlot {
            if slot.player.currentItem?.status == .failed || slot.player.error != nil {
                if let sId = slot.currentStreamId, let vId = slot.currentVideoId, let url = slot.currentPlayUrl {
                    slot.prepare(streamId: sId, videoId: vId, playUrl: url, autoplay: true)
                }
            } else {
                let currentTime = slot.player.currentTime()
                // If stream stalled due to socket reset during lock screen, seeking to currentTime forces
                // AVURLAsset to issue a fresh HTTP Range request to LocalMediaProxyServer, reconnecting cleanly!
                if slot.player.timeControlStatus != .playing {
                    slot.player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak slot] _ in
                        slot?.play()
                    }
                } else {
                    slot.play()
                }
            }
        }

        // Also ensure the standby slot's item is self-healed if its socket was severed
        let standby = (currentPlayingSlot === activeSlot) ? standbySlot : activeSlot
        if standby.player.currentItem?.status == .failed || standby.player.error != nil {
            if let sId = standby.currentStreamId, let vId = standby.currentVideoId, let url = standby.currentPlayUrl {
                standby.prepare(streamId: sId, videoId: vId, playUrl: url, autoplay: false)
            }
        }

        if currentPlayingSlot == nil, bgmPlayer.currentUrl != nil {
            bgmPlayer.resume()
        }
    }

    public func pauseAll() {
        activeSlot.pause()
        standbySlot.pause()
        bgmPlayer.pause()
    }
}
