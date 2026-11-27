import Foundation

#if canImport(os)
import os
#endif

#if canImport(QuartzCore)
import QuartzCore
#endif

// Instruments, without a network.
// ------------------------------
// The typed events in `TelemetryEvent.swift` explain *what* happened to the
// sink; these signposts explain *where the time went* while the phone is in
// your hand, on the device, with no server and no upload. Both share the same
// three phases so a profile and a JSONL line can be read side by side:
//
//   manifest  — `GET /manifest.json` (cold start, or a conditional refetch)
//   resolver  — turning an id into a playable URL (`slim` in-app, `app` legacy)
//   player    — first frame, stalls, CDN rejections
//
// Everything here is `OSSignposter`, which is inert until someone is recording
// with Instruments: no allocation on the hot path when tracing is off.
//
// Categories are fixed strings rather than an enum because `OSSignposter`'s
// `category` is a plain `String` and Instruments groups by it.
//
// Deliberate omission: span *messages* (status/bytes/durations). `OSSignposter`
// supports attaching a message to `beginInterval`/`emitEvent`, but this file was
// written without a compiler in the loop, so it sticks to the two overloads that
// are unambiguous (`beginInterval(_:id:)`, `endInterval(_:_:)`, `emitEvent(_:id:)`).
// The numeric details already travel in the typed events. If you want them in
// Instruments too, add the message argument in the three private helpers at the
// bottom of this file — nothing outside this file changes.

#if canImport(os)

/// Instruments spans for the three phases of a playback.
public enum Signposts {
    /// Subsystem for every category. Matches the app bundle's reverse-DNS root.
    public static let subsystem = "dev.dulo.player"

    public static let manifestCategory = "manifest"
    public static let resolverCategory = "resolver"
    public static let playerCategory = "player"

    private static let manifestPoster = OSSignposter(subsystem: subsystem, category: manifestCategory)
    private static let resolverPoster = OSSignposter(subsystem: subsystem, category: resolverCategory)
    private static let playerPoster = OSSignposter(subsystem: subsystem, category: playerCategory)

    /// A running interval. Ending it returns the wall time it covered, so call
    /// sites can feed the same number into the typed event instead of measuring
    /// twice (and diverging).
    public struct Span {
        let poster: OSSignposter
        let name: StaticString
        let state: OSSignpostIntervalState
        let startedAt: Double

        /// Milliseconds since the span began.
        public var elapsedMs: Double {
            (Signposts.now() - startedAt) * 1000.0
        }
    }

    // MARK: Manifest

    /// `GET /manifest.json`, including a conditional refetch.
    public static func beginManifestFetch() -> Span {
        begin(manifestPoster, "manifest_fetch")
    }

    /// Returns the span's duration in milliseconds.
    @discardableResult
    public static func endManifestFetch(_ span: Span) -> Double {
        end(span)
    }

    // MARK: Resolver

    public static func beginResolve() -> Span {
        begin(resolverPoster, "resolve")
    }

    @discardableResult
    public static func endResolve(_ span: Span) -> Double {
        end(span)
    }

    /// Time spent waiting on the network only (excludes the local lease cache).
    public static func beginResolverNetwork() -> Span {
        begin(resolverPoster, "resolve_network")
    }

    @discardableResult
    public static func endResolverNetwork(_ span: Span) -> Double {
        end(span)
    }

    // MARK: Player

    /// Frame 0 on screen. Start it when the resolve starts, not when the swipe
    /// ends: that is the interval `ttff_ms` reports.
    public static func beginFirstFrame() -> Span {
        begin(playerPoster, "first_frame")
    }

    @discardableResult
    public static func endFirstFrame(_ span: Span) -> Double {
        end(span)
    }

    /// Start when `AVPlayerItemPlaybackStalled` arrives, end when playback
    /// resumes. The stall *duration* is exactly the interval Instruments draws.
    public static func beginStall() -> Span {
        begin(playerPoster, "stall")
    }

    @discardableResult
    public static func endStall(_ span: Span) -> Double {
        end(span)
    }

    // MARK: Points in time

    /// Discrete markers. Names must be static strings, so the interesting cases
    /// are enumerated instead of formatted.
    public enum Event {
        /// `304` from the static origin: the cached manifest was reused.
        case manifestNotModified
        /// The CDN refused a minted URL.
        case cdn403
        /// The rejected URL was replaced and playback recovered.
        case cdn403Recovered
        /// `POST /dislike/{id}` was issued.
        case dislike
        /// The dislike was accepted by the sink.
        case dislikeAccepted
    }

    public static func emit(_ event: Event) {
        switch event {
        case .manifestNotModified:
            manifestPoster.emitEvent("manifest_not_modified", id: manifestPoster.makeSignpostID())
        case .cdn403:
            playerPoster.emitEvent("cdn_403", id: playerPoster.makeSignpostID())
        case .cdn403Recovered:
            playerPoster.emitEvent("cdn_403_recovered", id: playerPoster.makeSignpostID())
        case .dislike:
            playerPoster.emitEvent("dislike", id: playerPoster.makeSignpostID())
        case .dislikeAccepted:
            playerPoster.emitEvent("dislike_accepted", id: playerPoster.makeSignpostID())
        }
    }

    // MARK: Plumbing

    private static func begin(_ poster: OSSignposter, _ name: StaticString) -> Span {
        let signpostID = poster.makeSignpostID()
        let state = poster.beginInterval(name, id: signpostID)
        return Span(poster: poster, name: name, state: state, startedAt: now())
    }

    @discardableResult
    private static func end(_ span: Span) -> Double {
        _ = span.poster.endInterval(span.name, span.state)
        return span.elapsedMs
    }

    /// Monotonic clock. `CACurrentMediaTime` is what `AVTelemetryTracker` already
    /// uses for TTFF, so the two numbers are comparable.
    static func now() -> Double {
        #if canImport(QuartzCore)
        return CACurrentMediaTime()
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }
}

#endif
