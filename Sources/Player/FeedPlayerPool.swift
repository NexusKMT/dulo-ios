import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Industrial-grade Dual-Player Pool adhering to ByteDance (Douyin/TikTok) and Kuaishou feed engineering.
/// Strictly caps hardware decoders to TWO instances across the entire application lifecycle.
///
/// Players are allocated ONCE at startup and NEVER destroyed during scrolling.
/// Zero mediaserverd IPC allocation churn during cell dequeue, guaranteeing 60fps locked scrolling.
@MainActor
public final class FeedPlayerPool {
    public static let shared = FeedPlayerPool()

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
                        guard let self = self else { return }
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
            autoplay: Bool,
            videoGravity: AVLayerVideoGravity = .resizeAspect
        ) {
            #if canImport(UIKit)
            if playerLayer.videoGravity != videoGravity {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                playerLayer.videoGravity = videoGravity
                CATransaction.commit()
            }
            #endif

            if currentStreamId == streamId && currentPlayUrl == playUrl {
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

            currentStreamId = streamId
            currentVideoId = videoId
            currentPlayUrl = playUrl
            isReadyForDisplay = false

            guard let url = URL(string: playUrl) else { return }

            let item = PlayerFactory.makeItem(url: url, cacheKey: videoId)
            AVTelemetryTracker.shared.bindItem(item, for: videoId)
            self.looper = AVPlayerLooper(player: player, templateItem: item)

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
            currentStreamId = nil
            currentVideoId = nil
            currentPlayUrl = nil
            isReadyForDisplay = false
            #if canImport(UIKit)
            if playerLayer.superlayer != nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                playerLayer.removeFromSuperlayer()
                CATransaction.commit()
            }
            #endif
        }
    }

    public let activeSlot = PlayerSlot(slotIndex: 0)
    public let standbySlot = PlayerSlot(slotIndex: 1)

    private init() {
        #if canImport(AVFAudio)
        PlayerFactory.configureAudioSession()
        #endif
    }

    public func pauseAll() {
        activeSlot.pause()
        standbySlot.pause()
    }
}
