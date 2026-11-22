import Foundation

/// A time-bounded grant of media, mirroring the server's /resolve lease.
/// Backed by Foundation `Date`, immune to Darwin device sleep clock freeze.
struct Lease<T> {
    let value: T
    let expiresAt: Date

    /// Renew this far before the server-declared expiry (60 seconds).
    static var defaultRenewalMargin: TimeInterval { 60.0 }
    static var defaultMarginMs: Int64 { 60_000 }

    init(_ value: T, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    init(_ value: T, ttlSeconds: TimeInterval) {
        self.init(value, expiresAt: Date().addingTimeInterval(max(ttlSeconds, 1.0)))
    }

    /// Backward-compatible constructor for elapsed milliseconds offset
    init(_ value: T, expiresAtElapsedMs: Int64) {
        self.init(value, expiresAt: Date().addingTimeInterval(Double(expiresAtElapsedMs) / 1000.0))
    }

    var expiresAtElapsedMs: Int64 {
        Int64(expiresAt.timeIntervalSince1970 * 1000.0)
    }

    func isFresh(asOf now: Date = Date(), margin: TimeInterval = defaultRenewalMargin) -> Bool {
        now.addingTimeInterval(margin) < expiresAt
    }

    /// Backward-compatible freshness check
    func isFresh(nowElapsedMs: Int64, marginMs: Int64 = Self.defaultMarginMs) -> Bool {
        isFresh(margin: Double(marginMs) / 1000.0)
    }
}
