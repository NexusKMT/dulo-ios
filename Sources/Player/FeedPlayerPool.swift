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
        public let player: AVQueuePlayer
        #if canImport(UIKit)
        public let playerLayer: AVPlayerLayer
        #endif
        private var looper: AVPlayerLooper?
        private var readyObserver: NSKeyValueObservation?

        public private(set) var currentStreamId: Int64?
        public private(set) var currentVideoId: String?
        public private(set) var currentPlayUrl: String?
        public private(set) var isReadyForDisplay = false
        public var onReadyForDisplay: (() -> Void)?

        private var openavtInstrument: OAVTInstrument?
        private var openavtTrackerId: Int?
        private var hasRegisteredDecoder = false
        private var hasFiredReadyForDisplay = false

        public func setMuted(_ muted: Bool) {
            player.isMuted = muted
            player.volume = muted ? 0.0 : 1.0
        }

        public init(slotIndex: Int) {
            self.slotIndex = slotIndex
            let player = AVQueuePlayer()
            player.automaticallyWaitsToMinimizeStalling = false
            player.preventsDisplaySleepDuringVideoPlayback = true
            player.actionAtItemEnd = .none
            self.player = player

            #if canImport(UIKit)
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = UIColor.black.cgColor
            layer.isOpaque = true
            layer.actions = [
                "contents": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "opacity": NSNull(),
                "sublayers": NSNull()
            ]
            self.playerLayer = layer
            #endif

            let instrument = OAVTInstrument(hub: OAVTHubCore(), metricalc: OAVTMetricalcCore(), backend: OAVTBackendRemote())
            let tracker = OAVTTrackerAVPlayer(player: player)
            self.openavtTrackerId = instrument.addTracker(tracker)
            self.openavtInstrument = instrument

            #if canImport(UIKit)
            self.readyObserver = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                if layer.isReadyForDisplay {
                    Task { @MainActor in
                        guard let self, !self.hasFiredReadyForDisplay else { return }
                        self.hasFiredReadyForDisplay = true
                        self.isReadyForDisplay = true
                        if let vid = self.currentVideoId {
                            AVTelemetryTracker.shared.recordReadyForDisplay(for: vid)
                        }
                        self.onReadyForDisplay?()
                    }
                }
            }
            #endif
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
            #if canImport(UIKit)
            if playerLayer.videoGravity != videoGravity {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                playerLayer.videoGravity = videoGravity
                CATransaction.commit()
            }
            #endif

            player.isMuted = isMuted
            player.volume = isMuted ? 0.0 : 1.0

            if currentStreamId == streamId && currentPlayUrl == playUrl {
                if !isMuted {
                    if let item = player.currentItem {
                        for track in item.tracks where track.assetTrack?.mediaType == .audio {
                            track.isEnabled = true
                        }
                    }
                }
                if autoplay {
                    player.play()
                } else {
                    player.pause()
                }
                return
            }

            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            hasFiredReadyForDisplay = false
            isReadyForDisplay = false
            #if canImport(UIKit)
            playerLayer.player = nil
            playerLayer.player = player
            #endif

            currentStreamId = streamId
            currentVideoId = videoId
            currentPlayUrl = playUrl
            isReadyForDisplay = false

            guard let url = URL(string: playUrl) else { return }

            let playbackUrl = LocalMediaProxyServer.shared.proxyUrl(for: url, cacheKey: videoId)
            let asset = AVURLAsset(
                url: playbackUrl,
                options: ["AVURLAssetHTTPHeaderFieldsKey": PlayerFactory.httpHeaders]
            )
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 3.0

            if disableAudioTracks {
                // For Live Photo motion loops: disable all audio tracks to free CoreAudio resources
                for track in item.tracks where track.assetTrack?.mediaType == .audio {
                    track.isEnabled = false
                }
            } else if !isMuted {
                for track in item.tracks where track.assetTrack?.mediaType == .audio {
                    track.isEnabled = true
                }
            }

            AVTelemetryTracker.shared.bindItem(item, for: videoId)
            self.looper = AVPlayerLooper(player: player, templateItem: item)

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
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            hasFiredReadyForDisplay = false
            isReadyForDisplay = false
            currentStreamId = nil
            currentVideoId = nil
            currentPlayUrl = nil

            if hasRegisteredDecoder {
                hasRegisteredDecoder = false
                AVTelemetryTracker.shared.unregisterActiveDecoder()
            }

            #if canImport(UIKit)
            playerLayer.player = nil
            playerLayer.player = player
            if playerLayer.superlayer != nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                playerLayer.removeFromSuperlayer()
                CATransaction.commit()
            }
            #endif
        }
    }

    // MARK: - Background Audio Player (CoreAudio only, 0 VideoToolbox decoders)

    @MainActor
    public final class BgmAudioPlayer {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        public private(set) var currentUrl: String?

        public init() {
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .none
        }

        public func play(urlString: String) {
            if currentUrl == urlString {
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
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
        }

        public func pause() {
            player.pause()
        }

        public func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            currentUrl = nil
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
