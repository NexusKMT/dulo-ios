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
            player.automaticallyWaitsToMinimizeStalling = false
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
            let asset = AVURLAsset(
                url: playbackUrl,
                options: ["AVURLAssetHTTPHeaderFieldsKey": PlayerFactory.httpHeaders]
            )
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
            player.play()
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
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.player.play()
                }
            }
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
            let asset = AVURLAsset(url: playbackUrl, options: [
                "AVURLAssetHTTPHeaderFieldsKey": PlayerFactory.httpHeaders
            ])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2.0
            player.replaceCurrentItem(with: item)
            player.play()
        }

        public func pause() {
            player.pause()
        }

        public func stop() {
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
    public func play(slot: PlayerSlot) {
        if slot === activeSlot {
            standbySlot.pause()
        } else {
            activeSlot.pause()
        }
        bgmPlayer.pause()
        slot.play()
    }

    public func playBgm(urlString: String) {
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
    }

    public func pauseAll() {
        activeSlot.pause()
        standbySlot.pause()
        bgmPlayer.pause()
    }
}
