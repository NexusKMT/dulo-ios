import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Transport

/// What the sink answered.
public struct TelemetryHTTPResult: Equatable {
    public let statusCode: Int
    public let retryAfter: TimeInterval?

    public init(statusCode: Int, retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }
}

/// The one seam between the uploader and the network, so batching and
/// delete-on-2xx can be tested without a socket.
public protocol TelemetryUploadTransport {
    func post(_ body: Data, to url: URL) async throws -> TelemetryHTTPResult
}

public enum TelemetryTransportError: Error {
    case invalidResponse
}

/// `URLSession` implementation aimed at the static Caddy origin.
/// Ephemeral, one connection per host, no cookies, no cache: the spool is the
/// buffer, not `URLCache`.
public struct URLSessionTelemetryTransport: TelemetryUploadTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSessionTelemetryTransport.makeSession()
    }

    public func post(_ body: Data, to url: URL) async throws -> TelemetryHTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TelemetryTransportError.invalidResponse
        }
        return TelemetryHTTPResult(statusCode: http.statusCode, retryAfter: nil)
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

// MARK: - Retry policy

/// Exponential backoff for the drain loop.
public struct TelemetryRetryPolicy: Equatable {
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval

    public init(
        baseDelay: TimeInterval = 2,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 300
    ) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
    }

    /// 2s, 4s, 8s, ... capped at `maxDelay`. Attempt 0 means "no failure yet".
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = Double(min(attempt - 1, 16))
        return min(maxDelay, baseDelay * pow(multiplier, exponent))
    }
}

// MARK: - Uploader

/// Batched, offline-first drain of the local spool into the static sink.
///
/// Replaces `RemoteTelemetryExporter`, which could only work at home: it held
/// events in RAM and POSTed to the (now deleted) app backend, so everything
/// collected away from home died with the process. The contract now is:
///
///   * `submit` -> encode + append to `TelemetrySpool` (utility queue). It never
///     waits for the network and never touches the main thread, so a scroll or a
///     playback transition is never delayed by telemetry.
///   * `flush` -> POST at most `batchLimit` (50) events / `batchByteLimit` bytes
///     as one JSON array to `{base}/api/telemetry`.
///   * **Delete only on 2xx.** A 5xx, a timeout or a missing network leaves the
///     spool untouched and retries with exponential backoff (2s..5min). The only
///     exception is a payload-shape rejection (400/413/415/422): those bytes will
///     never be accepted, so dropping them is what keeps the queue moving.
///   * Pauses while the app is in the background — the network is the OS's
///     resource to reclaim, and a suspended process has nothing to upload anyway.
public final class TelemetryUploader {
    public struct Configuration: Equatable {
        public var baseURL: URL
        /// Appended to `baseURL`; `{base}/api/telemetry`.
        public var endpointPath: String
        /// Hard cap on events per POST.
        public var batchLimit: Int
        /// Soft cap on body bytes per POST.
        public var batchByteLimit: Int
        public var retry: TelemetryRetryPolicy
        /// Debounce after a submit, so a burst becomes one request.
        public var submitDelay: TimeInterval
        /// Gap between drains while the spool still holds more than one batch.
        public var drainDelay: TimeInterval

        public init(
            baseURL: URL = TelemetryUploader.defaultBaseURL,
            endpointPath: String = "api/telemetry",
            batchLimit: Int = 50,
            batchByteLimit: Int = 256 * 1024,
            retry: TelemetryRetryPolicy = TelemetryRetryPolicy(),
            submitDelay: TimeInterval = 3,
            drainDelay: TimeInterval = 1
        ) {
            self.baseURL = baseURL
            self.endpointPath = endpointPath
            self.batchLimit = batchLimit
            self.batchByteLimit = batchByteLimit
            self.retry = retry
            self.submitDelay = submitDelay
            self.drainDelay = drainDelay
        }

        public var endpointURL: URL {
            // Split by component instead of passing "api/telemetry" to
            // `appendingPathComponent`, which is happy to encode the slash.
            endpointPath
                .split(separator: "/")
                .reduce(baseURL) { url, component in
                    url.appendingPathComponent(String(component))
                }
        }
    }

    /// The static Caddy origin that replaced the app backend (manifest, telemetry
    /// and dislikes). This literal is the single swap point for
    /// `AppSettings.staticBaseUrl` once that constant lands.
    public static let defaultBaseURL = URL(string: "http://192.168.2.3:8082")!

    /// Process-wide uploader. `start()`s itself so the app only has to submit.
    public static let shared: TelemetryUploader = {
        let uploader = TelemetryUploader()
        uploader.start()
        return uploader
    }()

    public let spool: TelemetrySpool
    public let configuration: Configuration
    private let transport: TelemetryUploadTransport

    private let stateQueue = DispatchQueue(label: "dev.dulo.telemetry.uploader", qos: .utility)
    private let lock = NSLock()

    private var attempt = 0
    private var isFlushing = false
    private var isPaused = false
    private var isStarted = false
    private var timer: DispatchSourceTimer?
    private var droppedBatches = 0
    private var observers: [NSObjectProtocol] = []

    public init(
        spool: TelemetrySpool = TelemetrySpool.applicationSupport(),
        transport: TelemetryUploadTransport = URLSessionTelemetryTransport(),
        configuration: Configuration = Configuration()
    ) {
        self.spool = spool
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: Lifecycle

    /// Starts the drain loop and follows background/foreground transitions.
    /// Idempotent; the app does not need to call it when it uses `.shared`.
    public func start() {
        lock.lock()
        let alreadyStarted = isStarted
        isStarted = true
        lock.unlock()
        guard !alreadyStarted else { return }
        registerLifecycleObservers()
        scheduleFlush(after: 5)
    }

    public func stop() {
        lock.lock()
        isStarted = false
        lock.unlock()
        clearTimer()
        removeLifecycleObservers()
    }

    // MARK: Producing events

    public func submit(_ event: TelemetryEvent) {
        spool.append(event)
        scheduleFlush(after: configuration.submitDelay)
    }

    public func submit<P: TelemetryPayload>(_ payload: P) {
        submit(TelemetryEvent(payload))
    }

    /// Crash path: durable before returning, uploaded on the next launch.
    public func submitSynchronously(_ event: TelemetryEvent) {
        spool.appendSynchronously(event)
    }

    public func submitSynchronously<P: TelemetryPayload>(_ payload: P) {
        submitSynchronously(TelemetryEvent(payload))
    }

    // MARK: Draining

    /// One drain attempt. Safe to call concurrently: extra callers return early
    /// instead of stacking requests.
    public func flush() async {
        guard beginFlush() else { return }
        defer { endFlush() }
        // Spool reads and compaction are file IO: keep them off the main thread
        // even if someone awaits this from a UI context.
        await hopOffMainIfNeeded()

        let batch = spool.peekBatch(
            limit: configuration.batchLimit,
            maxBytes: configuration.batchByteLimit
        )
        guard !batch.isEmpty else {
            resetAttempt()
            return
        }

        let body = Self.encodeBody(batch)
        let acknowledged = Set(batch.map { $0.eventID })

        do {
            let result = try await transport.post(body, to: configuration.endpointURL)
            if Self.isSuccess(result.statusCode) {
                spool.acknowledge(eventIDs: acknowledged)
                resetAttempt()
                if spool.eventCount > 0 {
                    scheduleFlush(after: configuration.drainDelay)
                }
            } else if Self.isPermanentFailure(result.statusCode) {
                // These bytes will never be accepted; keep the queue moving.
                spool.acknowledge(eventIDs: acknowledged)
                recordDroppedBatch()
                resetAttempt()
            } else {
                noteFailure()
            }
        } catch {
            noteFailure()
        }
    }

    // MARK: Observability

    /// Consecutive failed attempts; drives the backoff and is asserted in tests.
    public var consecutiveFailures: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempt
    }

    /// Batches the sink refused as unparseable (400/413/415/422).
    public var droppedBatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedBatches
    }

    public var spooledEventCount: Int {
        spool.eventCount
    }

    // MARK: Pause / resume

    /// Called when the app is backgrounded.
    public func pause() {
        lock.lock()
        isPaused = true
        lock.unlock()
        clearTimer()
    }

    /// Called when the app returns to the foreground.
    public func resume() {
        lock.lock()
        isPaused = false
        let started = isStarted
        lock.unlock()
        guard started else { return }
        scheduleFlush(after: 2)
    }

    // MARK: Body encoding

    /// One POST body: a JSON array of the spooled lines, byte-for-byte. Re-encoding
    /// would mean decoding every event again just to serialize it back.
    public static func encodeBody(_ records: [TelemetrySpoolRecord]) -> Data {
        var body = Data()
        body.append(0x5B) // [
        for (index, record) in records.enumerated() {
            if index > 0 { body.append(0x2C) } // ,
            body.append(record.line)
        }
        body.append(0x5D) // ]
        return body
    }

    public static func isSuccess(_ statusCode: Int) -> Bool {
        (200...299).contains(statusCode)
    }

    /// Payload-shape rejections only: retrying them cannot help, everything else
    /// (timeouts, 401/403/404, 429, 5xx) is retried with backoff.
    public static func isPermanentFailure(_ statusCode: Int) -> Bool {
        [400, 413, 415, 422].contains(statusCode)
    }

    // MARK: Scheduling

    /// One-way hop to the uploader's utility queue. Suspension points never
    /// migrate a task to another thread, so a single hop at the top of `flush()`
    /// is enough to keep every file operation below off the main thread.
    private func hopOffMainIfNeeded() async {
        guard Thread.isMainThread else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateQueue.async {
                continuation.resume()
            }
        }
    }

    private func scheduleFlush(after delay: TimeInterval) {
        lock.lock()
        guard isStarted, !isPaused, timer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: DispatchTime.now() + max(0, delay))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.clearTimer()
            Task { await self.flush() }
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func clearTimer() {
        lock.lock()
        let pending = self.timer
        self.timer = nil
        lock.unlock()
        pending?.cancel()
    }

    private func beginFlush() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isPaused || isFlushing { return false }
        isFlushing = true
        return true
    }

    private func endFlush() {
        lock.lock()
        isFlushing = false
        lock.unlock()
    }

    private func noteFailure() {
        lock.lock()
        attempt += 1
        let delay = configuration.retry.delay(forAttempt: attempt)
        lock.unlock()
        if delay > 0 {
            scheduleFlush(after: delay)
        }
    }

    private func resetAttempt() {
        lock.lock()
        attempt = 0
        lock.unlock()
    }

    private func recordDroppedBatch() {
        lock.lock()
        droppedBatches += 1
        lock.unlock()
    }

    // MARK: App lifecycle

    private func registerLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.pause()
        }
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resume()
        }
        lock.lock()
        observers = [background, foreground]
        lock.unlock()
        #endif
    }

    private func removeLifecycleObservers() {
        #if canImport(UIKit)
        lock.lock()
        let tokens = observers
        observers = []
        lock.unlock()
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        #endif
    }
}

// MARK: - INTEGRATION NOTES (read before deleting RemoteTelemetryExporter)
//
// This file replaces `Sources/Data/Telemetry/RemoteTelemetryExporter.swift`.
// Nothing else in this branch was touched; the steps below are the follow-up
// commit that makes the app compile and produce the new schema.
//
// 1. DELETE `RemoteTelemetryExporter.swift`.
//
// 2. `Sources/Data/Telemetry/AVTelemetryTracker.swift` — KEEP the AVPlayer
//    notification/KVO collection, drop the dictionary submit.
//    * Keep: `.AVPlayerItemNewAccessLogEntry` (stall count, observed/indicated
//      bitrate), `.AVPlayerItemNewErrorLogEntry` (error domain/status),
//      `.AVPlayerItemPlaybackStalled`, and the `CACurrentMediaTime()` session
//      clock. This is client-side player truth: a static JSONL sink cannot
//      observe the device's decoder, so deleting it would blind us on stalls and
//      on "did the CDN starve us or did the A9 miss a deadline". Bitrate in
//      particular exists nowhere else.
//    * In `recordReadyForDisplay(for:)`, replace the `submit(event: [...])` call
//      with the typed model, keeping the existing idempotency guard:
//          TelemetryUploader.shared.submit(FirstFrameTelemetry(
//              videoID: videoId,
//              ttffMs: <ms from FeedViewModel's resolve-start timestamp>,
//              triggerToFrameMs: elapsedMs,          // its own trigger -> frame
//              cacheTier: updatedTelemetry.cacheTier,
//              cacheHit: updatedTelemetry.isCacheHit
//          ))
//      `ttffMs` must come from the resolve, not from the swipe: the product
//      metric is "how long after the resolver started did frame 0 appear". The
//      tracker only owns the trigger->frame half, hence both fields.
//    * In `handleAccessLogEntry` / `handlePlaybackStalled`, emit
//      `StallTelemetry(videoID:stallCount:stallMs:observedBitrateKbps:)` when the
//      stall count increases (not on every access-log entry — those fire
//      constantly). Measure `stallMs` by timestamping the stall notification and
//      the next `timeControlStatus == .playing` transition; leave it `nil` when
//      playback never resumed (that is an `uncaught_exception`/`cdn_403` story,
//      not a stall story).
//    * `VideoPlaybackTelemetry` stays as the in-app model the UI observes
//      (`FeedScreen` binds it). It is the tracker's state; `TelemetryEvent` is the
//      wire format. Do not merge the two.
//
// 3. `Sources/Data/Telemetry/PerformanceMonitor.swift` — replace the
//    `perf_snapshot` submit with
//    `TelemetryUploader.shared.submit(PerfSnapshotTelemetry(...))` AND change the
//    cadence: the 3s heartbeat was fine for a server that swallowed everything,
//    but 20 events/minute into a 2 MB spool on a device that may be offline for
//    days is pure eviction pressure. Emit once per playback session plus when the
//    hitch window is genuinely bad.
//
// 4. `Sources/Data/Telemetry/MetricKitSubscriber.swift` — replace both submits
//    with `MetricKitTelemetry(kind:payloadJSON:)` (`.metric` / `.diagnostic`).
//    One event type, `metrickit_payload`, with a `kind` column; payloads are
//    capped at 16k characters so one blob cannot evict the spool.
//
// 5. `Sources/Feed/FeedScreen.swift` (`recordDislike`) — point the POST at
//    `\(AppSettings.staticBaseUrl)/dislike/\(id)`, read the status instead of
//    `try?`-ing it away, and submit
//    `DislikeTelemetry(videoID: status:)`. `subscribe`-style fire-and-forget is
//    why we currently cannot answer "did the dislike actually land".
//
// 6. `Sources/Feed/FeedViewModel.swift` / `MediaClient.swift` — add the spans and
//    the two new events. This is additive instrumentation, owned by whoever lands
//    the resolver work:
//    * `listVideos`: `let span = Signposts.beginManifestFetch()` ->
//      `Signposts.endManifestFetch(span)` -> `ManifestFetchTelemetry(status:bytes:
//      durationMs:conditional:failure:)`. `conditional` is whether an
//      `If-None-Match` validator was sent (that is what makes 304 possible);
//      `bytes` is `0` for a 304 and the body count otherwise.
//    * `resolveMedia`: record `CACurrentMediaTime()` before the call and emit
//      `ResolveTelemetry(videoID:transport:status:durationMs:failure:priority:forced:)`
//      mapped from `MediaResolution` (`notFound` -> `.notFound`, `httpFailure` ->
//      `.httpFailure` with its status, `networkFailure` -> `.networkFailure`,
//      `invalidResponse` -> `.invalidResponse`, `internalFailure` ->
//      `.internalFailure`, `cancelled` -> `.cancelled`).
//      `transport` is `slim` when the manifest path resolves locally and `app`
//      only for the legacy `/resolve/{id}` call. Cache hits emit nothing: they
//      never touched the network, and counting them as "resolve latency" is how
//      dashboards start lying.
//    * Remember the resolve-start timestamp per video id so
//      `recordReadyForDisplay` can fill `ttff_ms` (see 2).
//
// 7. `Sources/Feed/VerticalPager.swift:1759,1767` — `prewarm_switch` and
//    `drag_window` have no home in the new schema on purpose (see the dropped
//    list in the PR description). Delete both call sites; if a specific question
//    comes back, add a typed payload, do not reopen `[String: Any]`.
//
// 8. `Sources/DuloApp.swift:31` — crash handler becomes
//    `TelemetryUploader.shared.submitSynchronously(UncaughtExceptionTelemetry(
//        name: name, reason: reason, callStack: stack))`.
//    Do not attempt the old synchronous POST: the process is dying, the sink may
//    be unreachable, and blocking here only delays the crash. The next launch
//    drains the spool.
//    Also call `TelemetryUploader.shared.start()` in `DuloApp.init` (it is
//    implicit through `.shared`, but being explicit documents the 5s launch
//    delay) and, if you want, `flush()` inside
//    `applicationDidEnterBackground` before pausing.
//
// 9. `Sources/Data/AppSettings.swift` — add
//    `static let staticBaseUrl = "http://192.168.2.3:8082"` and replace the single
//    literal in `TelemetryUploader.defaultBaseURL`. The URL was not referenced
//    directly here because the constant does not exist on `main` yet and this
//    branch must keep `swift build --target DuloCore` green.
//
// 10. `project.yml` — CI fails a PR that does not bump `CURRENT_PROJECT_VERSION`.
//     That file was out of scope for this branch.
//
// DELIBERATELY DROPPED from `RemoteTelemetryExporter` (do not resurrect):
//   * `exportCrashSynchronously`'s `URLSession` POST + `DispatchSemaphore` wait:
//     up to 2s of blocking inside the uncaught-exception handler, on a network
//     that is usually unreachable. Now: one fsync'd spool append, no network.
//   * The 512-entry in-memory ring buffer and its 2s flush timer. It was bounded
//     by count, not bytes, lived only in RAM, and every relaunch threw it away —
//     which is exactly the case the new architecture creates.
//   * "Remove the batch from the buffer, then POST": a failed POST silently
//     dropped the events. Deletion now depends on the sink's 2xx.
//   * `[String: Any]` + `JSONSerialization` for the wire format (including the
//     nested MetricKit payload). Every event is a typed model now.
//   * `AppSettings.serverBaseUrl` (:8080) as the telemetry destination — the app
//     server is gone; the static origin (:8082) owns `/api/telemetry`.
//   * `prewarm_switch` and `drag_window`. They were instrumentation for the
//     sticky-prewarm experiment, which is graduated to 100% (`ExperimentVariant`
//     always returns `.sticky`); the drag counters in `FeedPlayerPool` existed to
//     feed them.
//   * `ExperimentVariant.telemetryFields` (`[String: Any]`) as the header source.
//     Same five field names survive, now typed in `TelemetryHeader`.
//   * The `timestamp` key. Envelope fields are `ts` (epoch seconds), plus new
//     `event_id` and `session_id` for dedupe and grouping.
// Kept on purpose: `DuloMetricKitSubscriber` (native, off the hot path),
// `PerformanceMonitor`'s mach/CoreAnimation collection (only its telemetry
// cadence changes), and `AVTelemetryTracker`'s AVPlayer notification collection.
//
// Sink contract (for whoever writes the Caddy handler):
//   * `POST /api/telemetry` body is a JSON array of flat objects; each object is
//     also exactly one line of the local JSONL spool. Append each element as its
//     own line.
//   * Delivery is at-least-once: a crash between the 2xx and the local delete
//     replays a batch. Dedupe on `event_id`.
//   * Every event carries `event_id`, `event_type`, `ts` (epoch seconds),
//     `session_id`, plus the header fields below. Unknown extra fields must be
//     tolerated: that is what makes adding a payload a non-event.
//   * Header fields on every line: `app_version`, `build_number`, `version_tag`,
//     `device_model`, `os_version`, `platform`, `experiment_id`,
//     `experiment_variant`, `launch_seq`, `experiment_sticky_prewarm`,
//     `prewarm_threshold_pages`.
