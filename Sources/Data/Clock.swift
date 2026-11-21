import Dispatch

/// Monotonic milliseconds, mirroring Android's `SystemClock.elapsedRealtime()`.
/// Wall-clock changes cannot extend or shorten a media lease.
func monotonicNowMs() -> Int64 {
    Int64(bitPattern: DispatchTime.now().uptimeNanoseconds) / 1_000_000
}
