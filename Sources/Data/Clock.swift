import Foundation

/// Continuous monotonic time helper.
/// Uses `ProcessInfo.processInfo.systemUptime` to measure elapsed duration,
/// avoiding sleep-induced freeze on Darwin.
func monotonicNowMs() -> Int64 {
    Int64(ProcessInfo.processInfo.systemUptime * 1000.0)
}
