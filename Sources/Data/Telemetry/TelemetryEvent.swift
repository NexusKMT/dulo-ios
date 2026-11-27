import Foundation

// MARK: - Scalar values
//
// Why this file exists
// --------------------
// Until now every event was a `[String: Any]`. Nothing checked the shape, the
// types or the field names, so a typo ("ttff_ms" vs "ttffMs") or a `Date`
// dumped straight into JSON reached the sink as garbage that nobody noticed
// until a dashboard broke. Telemetry now wears a schema:
//
//   * `TelemetryValue`      — the only scalar that can be written.
//   * `TelemetryHeader`     — app/platform fields every event carries.
//   * `TelemetryPayload`    — one typed struct per product question.
//   * `TelemetryEvent`      — envelope + payload, flattened into ONE flat JSON
//                             object per line so the append-only JSONL sink can
//                             read `event_type`, `ts`, `video_id`, ... directly.
//
// The sink and the schema are the same contract: adding a field means adding a
// typed payload property here, never a dictionary literal at a call site.

/// The only value types that may appear next to `event_type` in the JSONL sink.
public enum TelemetryValue: Codable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(_ value: String) { self = .string(value) }
    public init(_ value: Int) { self = .int(value) }
    public init(_ value: Double) { self = .double(value) }
    public init(_ value: Bool) { self = .bool(value) }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Integers survive a JSON round trip; a non-integral `.double` returns `nil`
    /// instead of silently truncating.
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded(.towardZero) == value && abs(value) <= 9_007_199_254_740_992:
            return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

extension TelemetryValue {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // `JSONDecoder` refuses booleans for numeric types and vice versa, so the
        // order below is unambiguous for JSON produced by this model.
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "unsupported telemetry value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

// MARK: - Failure kinds

/// Transport-level failure of a static-origin request (`manifest.json`).
public enum TelemetryFailureKind: String, Codable, Equatable {
    case timeout
    /// Radio off / no route / local network permission denied.
    case offline
    case cancelled
    case tls
    case dns
    /// The request reached the origin but the status was not acceptable (see `status`).
    case http
    /// Body arrived but did not decode as the expected schema.
    case decoding
    /// `schema_version` the app does not understand.
    case unsupportedVersion = "unsupported_version"
    case other

    /// Best-effort classification of a thrown `URLSession` error. Call sites use
    /// this so the sink never has to guess what a failure string meant.
    public static func from(_ error: Error) -> TelemetryFailureKind {
        guard let urlError = error as? URLError else {
            return error is DecodingError ? .decoding : .other
        }
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dataNotAllowed,
             .internationalRoamingOff,
             .callIsActive:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .dns
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .appTransportSecurityRequiresSecureConnection:
            return .tls
        default:
            return .other
        }
    }
}

/// Why a media resolve produced no playable lease. Mirrors `MediaResolution`'s
/// failure cases one-for-one, minus `.ready`.
public enum TelemetryResolveFailure: String, Codable, Equatable {
    case notFound = "not_found"
    case httpFailure = "http_failure"
    case networkFailure = "network_failure"
    case invalidResponse = "invalid_response"
    case internalFailure = "internal_failure"
    case cancelled
}

/// How the app was told to obtain the play URL.
public enum TelemetryResolverTransport: String, Codable, Equatable {
    /// New architecture: the manifest already carries the CDN URL, the app does
    /// the resolving itself (works away from home, no server round trip).
    case slim
    /// Legacy: a `/resolve/{id}` call answered by the (now deleted) app server.
    case app
}

// MARK: - Header

/// App/platform identity carried by every event.
///
/// Snapshotted once per process: none of these change while the app runs, and
/// re-reading `Bundle`/`uname` per event is pure waste on an A9.
public struct TelemetryHeader: Equatable {
    public let appVersion: String
    public let buildNumber: String
    public let versionTag: String
    public let deviceModel: String
    public let osVersion: String
    /// `"ios"` / `"macos"`: the sink sees one app but two build loops.
    public let platform: String
    public let experimentID: String
    public let experimentVariant: String
    public let launchSeq: Int
    public let stickyPrewarm: Bool
    public let prewarmThresholdPages: Double

    public init(
        appVersion: String = "0",
        buildNumber: String = "0",
        versionTag: String = "0 (0)",
        deviceModel: String = "unknown",
        osVersion: String = "0",
        platform: String = TelemetryHeader.currentPlatform,
        experimentID: String = "",
        experimentVariant: String = "",
        launchSeq: Int = 0,
        stickyPrewarm: Bool = false,
        prewarmThresholdPages: Double = 0
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.versionTag = versionTag
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.platform = platform
        self.experimentID = experimentID
        self.experimentVariant = experimentVariant
        self.launchSeq = launchSeq
        self.stickyPrewarm = stickyPrewarm
        self.prewarmThresholdPages = prewarmThresholdPages
    }

    /// Cached process-wide snapshot. First access must happen after
    /// `ExperimentVariant.bootstrap()` (DuloApp does that in `init`), otherwise
    /// `launch_seq` reads as 0 for this launch.
    public static let current: TelemetryHeader = TelemetryHeader.capture()

    public static func capture() -> TelemetryHeader {
        TelemetryHeader(
            appVersion: AppVersion.marketingVersion,
            buildNumber: AppVersion.buildNumber,
            versionTag: AppVersion.displayString,
            deviceModel: AppVersion.deviceModelIdentifier,
            osVersion: TelemetryHeader.operatingSystemVersion,
            platform: TelemetryHeader.currentPlatform,
            experimentID: ExperimentVariant.experimentID,
            experimentVariant: ExperimentVariant.current.rawValue,
            launchSeq: ExperimentVariant.launchSeq,
            stickyPrewarm: ExperimentVariant.stickyPrewarmEnabled,
            prewarmThresholdPages: ExperimentVariant.stickyPrewarmEnabled
                ? PrewarmPolicy.enterThreshold
                : 0.0
        )
    }

    public static var currentPlatform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    public static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Merged into every event by `TelemetryEvent`.
    public var fields: [String: TelemetryValue] {
        [
            "app_version": .string(appVersion),
            "build_number": .string(buildNumber),
            "version_tag": .string(versionTag),
            "device_model": .string(deviceModel),
            "os_version": .string(osVersion),
            "platform": .string(platform),
            "experiment_id": .string(experimentID),
            "experiment_variant": .string(experimentVariant),
            "launch_seq": .int(launchSeq),
            "experiment_sticky_prewarm": .bool(stickyPrewarm),
            "prewarm_threshold_pages": .double(prewarmThresholdPages)
        ]
    }
}

// MARK: - Session

public enum TelemetrySession {
    /// One id per process launch. The spool outlives launches, so `session_id` is
    /// how a reader tells "buffered while away from home" from "sent at home",
    /// and how it groups events of one run without trusting wall-clock order.
    public static let id = UUID().uuidString
}

// MARK: - Payloads

/// A typed event body. Conforming types own their snake_case field names: the
/// sink reads them verbatim, so renaming a property is a schema migration.
public protocol TelemetryPayload {
    /// Value of the sink's `event_type` column, e.g. `"resolve"`.
    var eventType: String { get }
    /// Payload fields, merged next to the header fields. Reserved envelope keys
    /// (`event_id`, `event_type`, `ts`, `session_id`) are dropped by
    /// `TelemetryEvent` if a payload tries to set them.
    var fields: [String: TelemetryValue] { get }
}

/// `GET {static}/manifest.json` — is the catalog load cheap when away from home?
public struct ManifestFetchTelemetry: TelemetryPayload {
    /// HTTP status, `nil` when no response was received.
    public let status: Int?
    /// Body bytes; `0` for `304` (the cached body was reused).
    public let bytes: Int
    public let durationMs: Double
    /// Whether the request carried a validator (`If-None-Match`).
    public let conditional: Bool
    public let failure: TelemetryFailureKind?

    public init(
        status: Int?,
        bytes: Int = 0,
        durationMs: Double,
        conditional: Bool = false,
        failure: TelemetryFailureKind? = nil
    ) {
        self.status = status
        self.bytes = bytes
        self.durationMs = durationMs
        self.conditional = conditional
        self.failure = failure
    }

    public var eventType: String { "manifest_fetch" }

    /// Explicit 200-vs-304 flag so the sink does not have to special-case 304.
    public var notModified: Bool { status == 304 }

    public var fields: [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [
            "bytes": .int(bytes),
            "duration_ms": .double(durationMs),
            "not_modified": .bool(notModified),
            "conditional": .bool(conditional)
        ]
        if let status = status { fields["status"] = .int(status) }
        if let failure = failure { fields["failure_kind"] = .string(failure.rawValue) }
        return fields
    }
}

/// One resolver call: how long the app waited and what came back.
/// A `nil` `failure` plus a 2xx `status` is a success; anything else is not.
public struct ResolveTelemetry: TelemetryPayload {
    public let videoID: String
    public let transport: TelemetryResolverTransport
    /// HTTP status, `nil` when no response was received.
    public let status: Int?
    public let durationMs: Double
    public let failure: TelemetryResolveFailure?
    /// `0` = active playback, `1` = speculative N+1 prewarm.
    public let priority: Int
    /// `force=1` re-resolve, used to escape a poisoned CDN URL.
    public let forced: Bool

    public init(
        videoID: String,
        transport: TelemetryResolverTransport,
        status: Int?,
        durationMs: Double,
        failure: TelemetryResolveFailure? = nil,
        priority: Int = 0,
        forced: Bool = false
    ) {
        self.videoID = videoID
        self.transport = transport
        self.status = status
        self.durationMs = durationMs
        self.failure = failure
        self.priority = priority
        self.forced = forced
    }

    public var eventType: String { "resolve" }

    public var fields: [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [
            "video_id": .string(videoID),
            "transport": .string(transport.rawValue),
            "duration_ms": .double(durationMs),
            "priority": .int(priority),
            "forced": .bool(forced)
        ]
        if let status = status { fields["status"] = .int(status) }
        if let failure = failure { fields["failure_kind"] = .string(failure.rawValue) }
        return fields
    }
}

/// First presented frame. `ttff_ms` is the product metric: the gap between the
/// moment the app starts resolving and the moment frame 0 is on screen.
public struct FirstFrameTelemetry: TelemetryPayload {
    public let videoID: String
    /// Milliseconds from resolve start to `isReadyForDisplay == true`.
    public let ttffMs: Double
    /// Milliseconds from the page/swipe trigger to the first frame — the value
    /// `AVTelemetryTracker` measures from its own session start.
    public let triggerToFrameMs: Double?
    public let cacheTier: String
    public let cacheHit: Bool

    public init(
        videoID: String,
        ttffMs: Double,
        triggerToFrameMs: Double? = nil,
        cacheTier: String = "UNKNOWN",
        cacheHit: Bool = false
    ) {
        self.videoID = videoID
        self.ttffMs = ttffMs
        self.triggerToFrameMs = triggerToFrameMs
        self.cacheTier = cacheTier
        self.cacheHit = cacheHit
    }

    public var eventType: String { "first_frame" }

    public var fields: [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [
            "video_id": .string(videoID),
            "ttff_ms": .double(ttffMs),
            "cache_tier": .string(cacheTier),
            "cache_hit": .bool(cacheHit)
        ]
        if let triggerToFrameMs = triggerToFrameMs { fields["trigger_to_frame_ms"] = .double(triggerToFrameMs) }
        return fields
    }
}

/// Playback stall. `stall_count` is cumulative for the playback session (what
/// `AVPlayerItem` reports); `stall_ms` is only present when this app could
/// actually measure the stalled interval.
public struct StallTelemetry: TelemetryPayload {
    public let videoID: String
    public let stallCount: Int
    public let stallMs: Double?
    /// From the AVPlayer access log — distinguishes "network starved" from
    /// "decoder could not keep up" without a second event type.
    public let observedBitrateKbps: Double?

    public init(
        videoID: String,
        stallCount: Int,
        stallMs: Double? = nil,
        observedBitrateKbps: Double? = nil
    ) {
        self.videoID = videoID
        self.stallCount = stallCount
        self.stallMs = stallMs
        self.observedBitrateKbps = observedBitrateKbps
    }

    public var eventType: String { "stall" }

    public var fields: [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [
            "video_id": .string(videoID),
            "stall_count": .int(stallCount)
        ]
        if let stallMs = stallMs { fields["stall_ms"] = .double(stallMs) }
        if let observedBitrateKbps = observedBitrateKbps { fields["observed_bitrate_kbps"] = .double(observedBitrateKbps) }
        return fields
    }
}

/// The CDN rejected the minted URL. `recovered` answers the only question that
/// matters: did the user still get their video?
public struct CDN403Telemetry: TelemetryPayload {
    public let videoID: String
    public let status: Int
    public let recovered: Bool
    /// Milliseconds from the rejection to the first frame of the rebuilt item.
    public let recoveryMs: Double?

    public init(
        videoID: String,
        status: Int = 403,
        recovered: Bool,
        recoveryMs: Double? = nil
    ) {
        self.videoID = videoID
        self.status = status
        self.recovered = recovered
        self.recoveryMs = recoveryMs
    }

    public var eventType: String { "cdn_403" }

    public var fields: [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [
            "video_id": .string(videoID),
            "status": .int(status),
            "recovered": .bool(recovered)
        ]
        if let recoveryMs = recoveryMs { fields["recovery_ms"] = .double(recoveryMs) }
        return fields
    }
}

/// `POST {static}/dislike/{id}` — did the append-only sink accept the dislike?
public struct DislikeTelemetry: TelemetryPayload {
    public let videoID: String
    /// HTTP status of the dislike POST, `nil` when it was fire-and-forget.
    public let status: Int?

    public init(videoID: String, status: Int? = nil) {
        self.videoID = videoID
        self.status = status
    }

    public var eventType: String { "dislike" }

    /// `nil` when the call site did not await a response.
    public var ok: Bool? {
        status.map { (200...299).contains($0) }
    }

    public var fields: [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = ["video_id": .string(videoID)]
        if let status = status { fields["status"] = .int(status) }
        if let ok = ok { fields["ok"] = .bool(ok) }
        return fields
    }
}

/// Low-frequency device/player health sample (formerly `perf_snapshot`).
///
/// Replaces the old unconditional 3-second heartbeat: a static sink and a 2 MB
/// local spool cannot absorb 20 events/minute forever. Emit once per playback
/// session, plus when the jank window is actually bad.
public struct PerfSnapshotTelemetry: TelemetryPayload {
    public let fps: Double
    public let hitchRatioMsPerSec: Double
    public let droppedFrames: Int
    public let memoryMB: Double
    public let cpuPercent: Double
    public let thermalState: Int
    public let activeDecoders: Int

    public init(
        fps: Double,
        hitchRatioMsPerSec: Double,
        droppedFrames: Int,
        memoryMB: Double,
        cpuPercent: Double,
        thermalState: Int,
        activeDecoders: Int
    ) {
        self.fps = fps
        self.hitchRatioMsPerSec = hitchRatioMsPerSec
        self.droppedFrames = droppedFrames
        self.memoryMB = memoryMB
        self.cpuPercent = cpuPercent
        self.thermalState = thermalState
        self.activeDecoders = activeDecoders
    }

    public var eventType: String { "perf_snapshot" }

    public var fields: [String: TelemetryValue] {
        [
            "fps": .double(fps),
            "hitch_ratio_ms_per_sec": .double(hitchRatioMsPerSec),
            "dropped_frames": .int(droppedFrames),
            "memory_mb": .double(memoryMB),
            "cpu_percent": .double(cpuPercent),
            "thermal_state": .int(thermalState),
            "active_decoders": .int(activeDecoders)
        ]
    }
}

/// `NSSetUncaughtExceptionHandler` payload. Written with the synchronous spool
/// API because the process is about to die.
public struct UncaughtExceptionTelemetry: TelemetryPayload {
    /// Symbol names are ASCII, so 4k characters is ≈ 4k bytes — comfortably under
    /// the spool's per-record cap, and enough to see the top of the stack.
    public static let maxCallStackCharacters = 4_000
    public static let maxReasonCharacters = 500

    public let name: String
    public let reason: String
    public let callStack: String

    public init(name: String, reason: String, callStack: String) {
        self.name = String(name.prefix(Self.maxReasonCharacters))
        self.reason = String(reason.prefix(Self.maxReasonCharacters))
        self.callStack = String(callStack.prefix(Self.maxCallStackCharacters))
    }

    public var eventType: String { "uncaught_exception" }

    public var fields: [String: TelemetryValue] {
        [
            "exception_name": .string(name),
            "exception_reason": .string(reason),
            "call_stack": .string(callStack)
        ]
    }
}

/// MetricKit stays native and stays on-device-first: payloads are OS JSON blobs,
/// so they travel verbatim as a string instead of being re-modelled field by
/// field (Apple changes them without notice).
public struct MetricKitTelemetry: TelemetryPayload {
    public enum Kind: String {
        case metric
        case diagnostic
    }

    /// Cap before JSON escaping doubles the size and evicts the rest of the spool.
    public static let maxPayloadCharacters = 16_000

    public let kind: Kind
    public let payloadJSON: String
    /// Byte size *before* truncation, so a reader knows what was lost.
    public let payloadBytes: Int
    public let truncated: Bool

    public init(kind: Kind, payloadJSON: String) {
        self.kind = kind
        self.payloadBytes = payloadJSON.utf8.count
        if payloadJSON.count > Self.maxPayloadCharacters {
            self.payloadJSON = String(payloadJSON.prefix(Self.maxPayloadCharacters))
            self.truncated = true
        } else {
            self.payloadJSON = payloadJSON
            self.truncated = false
        }
    }

    public var eventType: String { "metrickit_payload" }

    public var fields: [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [
            "kind": .string(kind.rawValue),
            "payload_json": .string(payloadJSON),
            "payload_bytes": .int(payloadBytes)
        ]
        if truncated { fields["truncated"] = .bool(true) }
        return fields
    }
}

/// Escape hatch for one-off diagnostics that do not deserve a schema commit.
/// Prefer a typed payload: free-form keys are exactly what this model replaced.
public struct RawTelemetryPayload: TelemetryPayload {
    public let eventType: String
    public let fields: [String: TelemetryValue]

    public init(eventType: String, fields: [String: TelemetryValue]) {
        self.eventType = eventType
        self.fields = fields
    }
}

// MARK: - Event envelope

/// One line of the JSONL sink: envelope keys plus the payload's own snake_case
/// fields, flattened into a single object.
public struct TelemetryEvent: Equatable {
    /// Envelope keys a payload may not override.
    public static let reservedKeys: Set<String> = ["event_id", "event_type", "ts", "session_id"]

    /// Unique per event. Delivery is at-least-once (the spool deletes a record
    /// only after a 2xx), so the sink dedupes on this.
    public let eventID: String
    public let eventType: String
    /// Unix epoch seconds (double, so sub-second order survives).
    public let ts: Double
    public let sessionID: String
    /// Header fields plus payload fields, ready to be written flat.
    public let fields: [String: TelemetryValue]

    public init<P: TelemetryPayload>(
        _ payload: P,
        header: TelemetryHeader = .current,
        sessionID: String = TelemetrySession.id,
        eventID: String = UUID().uuidString,
        ts: Double = Date().timeIntervalSince1970
    ) {
        var merged = header.fields
        for (key, value) in payload.fields where !Self.reservedKeys.contains(key) {
            merged[key] = value
        }
        self.eventID = eventID
        self.eventType = payload.eventType
        self.ts = ts
        self.sessionID = sessionID
        self.fields = merged
    }

    /// Used by decoding and by tooling that replays a line.
    public init(
        eventID: String,
        eventType: String,
        ts: Double,
        sessionID: String,
        fields: [String: TelemetryValue]
    ) {
        self.eventID = eventID
        self.eventType = eventType
        self.ts = ts
        self.sessionID = sessionID
        self.fields = fields
    }

    /// Deterministic `JSONEncoder`: sorted keys keep the spool diffable and make
    /// tests assert on bytes.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The exact bytes the spool stores and the uploader POSTs (no newline).
    public func encodedLine() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public func value(for key: String) -> TelemetryValue? {
        fields[key]
    }
}

extension TelemetryEvent: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TelemetryCodingKey.self)
        self.eventID = try container.decode(String.self, forKey: TelemetryCodingKey("event_id"))
        self.eventType = try container.decode(String.self, forKey: TelemetryCodingKey("event_type"))
        self.ts = try container.decode(Double.self, forKey: TelemetryCodingKey("ts"))
        self.sessionID = try container.decode(String.self, forKey: TelemetryCodingKey("session_id"))

        var fields: [String: TelemetryValue] = [:]
        for key in container.allKeys where !Self.reservedKeys.contains(key.stringValue) {
            if let value = try? container.decode(TelemetryValue.self, forKey: key) {
                fields[key.stringValue] = value
            }
        }
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TelemetryCodingKey.self)
        try container.encode(eventID, forKey: TelemetryCodingKey("event_id"))
        try container.encode(eventType, forKey: TelemetryCodingKey("event_type"))
        try container.encode(ts, forKey: TelemetryCodingKey("ts"))
        try container.encode(sessionID, forKey: TelemetryCodingKey("session_id"))
        for key in fields.keys.sorted(by: { $0 < $1 }) {
            if let value = fields[key] {
                try container.encode(value, forKey: TelemetryCodingKey(key))
            }
        }
    }
}

/// Lets the flat envelope encode arbitrary (snake_case) field names.
struct TelemetryCodingKey: CodingKey {
    let stringValue: String

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int? { nil }

    init?(intValue: Int) { nil }
}
