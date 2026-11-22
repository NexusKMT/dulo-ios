import Foundation
import AVFoundation
import Combine

#if canImport(QuartzCore)
import QuartzCore
#endif

/// Playback telemetry engine for measuring Time-to-First-Frame (TTFF),
/// AVPlayerItem access QoS logs, stall duration, and active hardware decoder concurrency.
public final class AVTelemetryTracker: ObservableObject {
    public static let shared = AVTelemetryTracker()

    public struct VideoPlaybackTelemetry: Equatable {
        public let videoId: String
        public var ttffMs: Double = 0.0
        public var cacheTier: String = "UNKNOWN"
        public var isCacheHit: Bool = false
        public var numberOfStalls: Int = 0
        public var observedBitrateKbps: Double = 0.0
        public var indicatedBitrateKbps: Double = 0.0
        public var isReadyForDisplay: Bool = false
        public var hasPlaybackFailed: Bool = false
        public var lastError: String? = nil
    }

    @Published public private(set) var latestTelemetry: VideoPlaybackTelemetry?
    @Published public private(set) var activeDecoderCount: Int = 0

    private var trackingSessions: [String: SessionState] = [:]
    private var itemObservers: [AVPlayerItem: String] = [:]
    private let lock = NSLock()

    private struct SessionState {
        let triggerTime: CFTimeInterval
        let cacheTier: String
        let isCacheHit: Bool
        var telemetry: VideoPlaybackTelemetry
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessLogEntry(_:)),
            name: .AVPlayerItemNewAccessLogEntry,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleErrorLogEntry(_:)),
            name: .AVPlayerItemNewErrorLogEntry,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackStalled(_:)),
            name: .AVPlayerItemPlaybackStalled,
            object: nil
        )
    }

    // MARK: - Hardware Decoder Tracker (Apple A9 hardware budget: strictly max 2 concurrent in feed)

    public func registerActiveDecoder() {
        lock.lock()
        activeDecoderCount += 1
        lock.unlock()
    }

    public func unregisterActiveDecoder() {
        lock.lock()
        activeDecoderCount = max(0, activeDecoderCount - 1)
        lock.unlock()
    }

    // MARK: - TTFF Instrumentation

    /// Invoked the exact microsecond the user swipes or transitions to a streamId / video.
    public func recordSwipeTrigger(for videoId: String, cacheTier: String, isCacheHit: Bool) {
        let now = CACurrentMediaTime()
        lock.lock()
        let initial = VideoPlaybackTelemetry(
            videoId: videoId,
            ttffMs: 0.0,
            cacheTier: cacheTier,
            isCacheHit: isCacheHit
        )
        trackingSessions[videoId] = SessionState(
            triggerTime: now,
            cacheTier: cacheTier,
            isCacheHit: isCacheHit,
            telemetry: initial
        )
        lock.unlock()
    }

    /// Binds an active AVPlayerItem to its videoId for access log event routing.
    public func bindItem(_ item: AVPlayerItem, for videoId: String) {
        lock.lock()
        itemObservers[item] = videoId
        lock.unlock()
    }

    public func unbindItem(_ item: AVPlayerItem) {
        lock.lock()
        itemObservers.removeValue(forKey: item)
        lock.unlock()
    }

    /// Invoked the exact moment `AVPlayerLayer.isReadyForDisplay` transitions to `true`.
    /// This proves hardware decoder frame 0 presentation on screen.
    public func recordReadyForDisplay(for videoId: String) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard var session = trackingSessions[videoId] else {
            lock.unlock()
            return
        }

        // Idempotency guard: ignore duplicate calls across AVPlayerLooper queue cycles
        if session.telemetry.isReadyForDisplay {
            lock.unlock()
            return
        }

        let elapsedMs = (now - session.triggerTime) * 1000.0
        session.telemetry.ttffMs = elapsedMs
        session.telemetry.isReadyForDisplay = true
        trackingSessions[videoId] = session
        let updatedTelemetry = session.telemetry
        lock.unlock()

        Task { @MainActor in
            self.latestTelemetry = updatedTelemetry
        }

        // Asynchronously report to remote exporter
        RemoteTelemetryExporter.shared.submit(event: [
            "event_type": "video_startup_trace",
            "video_id": videoId,
            "ttff_ms": elapsedMs,
            "cache_tier": updatedTelemetry.cacheTier,
            "cache_hit": updatedTelemetry.isCacheHit,
            "timestamp": Date().timeIntervalSince1970
        ])
    }

    // MARK: - AVPlayerItem Access & Error Log Handlers

    @objc private func handleAccessLogEntry(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              let accessLog = item.accessLog(),
              let lastEvent = accessLog.events.last else { return }

        lock.lock()
        guard let videoId = itemObservers[item], var session = trackingSessions[videoId] else {
            lock.unlock()
            return
        }

        session.telemetry.numberOfStalls = lastEvent.numberOfStalls
        session.telemetry.observedBitrateKbps = lastEvent.observedBitrate / 1000.0
        session.telemetry.indicatedBitrateKbps = lastEvent.indicatedBitrate / 1000.0
        trackingSessions[videoId] = session
        let snapshot = session.telemetry
        lock.unlock()

        Task { @MainActor in
            self.latestTelemetry = snapshot
        }
    }

    @objc private func handleErrorLogEntry(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              let errorLog = item.errorLog(),
              let lastEvent = errorLog.events.last else { return }

        lock.lock()
        guard let videoId = itemObservers[item], var session = trackingSessions[videoId] else {
            lock.unlock()
            return
        }

        session.telemetry.hasPlaybackFailed = true
        session.telemetry.lastError = "\(lastEvent.errorDomain) (\(lastEvent.errorStatusCode))"
        trackingSessions[videoId] = session
        let snapshot = session.telemetry
        lock.unlock()

        Task { @MainActor in
            self.latestTelemetry = snapshot
        }
    }

    @objc private func handlePlaybackStalled(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem else { return }
        lock.lock()
        guard let videoId = itemObservers[item], var session = trackingSessions[videoId] else {
            lock.unlock()
            return
        }
        session.telemetry.numberOfStalls += 1
        trackingSessions[videoId] = session
        let snapshot = session.telemetry
        lock.unlock()

        Task { @MainActor in
            self.latestTelemetry = snapshot
        }
    }
}
