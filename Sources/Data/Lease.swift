/// A time-bounded grant of media, mirroring the server's /resolve lease.
/// `expiresAtElapsedMs` uses the monotonic clock, so wall-clock changes
/// cannot extend or shorten the lease.
struct Lease<T> {
    let value: T
    let expiresAtElapsedMs: Int64

    init(_ value: T, expiresAtElapsedMs: Int64) {
        self.value = value
        self.expiresAtElapsedMs = expiresAtElapsedMs
    }

    func isFresh(nowElapsedMs: Int64, marginMs: Int64 = Self.defaultMarginMs) -> Bool {
        nowElapsedMs + marginMs < expiresAtElapsedMs
    }

    /// Renew this far before the server-declared expiry.
    static let defaultMarginMs: Int64 = 60_000
}
