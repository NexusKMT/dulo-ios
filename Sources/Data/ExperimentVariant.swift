import Foundation

/// Build 35 ships one IPA with two runtime arms. Each cold launch increments
/// `dulo.launchSeq`; odd launches use sticky prewarm and even launches use the
/// build-32 control behaviour. The build number is still the primary version
/// discriminator, while every telemetry event carries the exact runtime arm.
public enum ExperimentVariant: String, CaseIterable {
    case control
    case sticky

    public static let experimentID = "jank-sticky-2026-11-24"
    private static let launchSeqKey = "dulo.launchSeq"

    /// Set before `LocalMediaProxyServer.shared.start()`, because that is the
    /// first access to `MediaCacheStorage.shared`.
    public private(set) static var current: ExperimentVariant = .control
    public private(set) static var launchSeq: Int = 0

    private static var didBootstrap = false

    public static func variant(forLaunchSeq seq: Int) -> ExperimentVariant {
        // First launch is sticky so a fresh install immediately exercises the
        // candidate; the second cold launch is the same-build control.
        seq % 2 == 1 ? .sticky : .control
    }

    public static func bootstrap(defaults: UserDefaults = .standard) {
        guard !didBootstrap else { return }
        didBootstrap = true
        let seq = defaults.integer(forKey: launchSeqKey) + 1
        defaults.set(seq, forKey: launchSeqKey)
        launchSeq = seq
        current = variant(forLaunchSeq: seq)
        PrewarmPolicy.mode = .hysteresis
    }

    /// Test-only hook. Production code must call `bootstrap()`.
    static func overrideForTesting(
        _ variant: ExperimentVariant,
        launchSeq seq: Int
    ) {
        didBootstrap = true
        current = variant
        launchSeq = seq
        PrewarmPolicy.mode = .hysteresis
    }

    /// The only experimental behaviour in this build. Control keeps the
    /// visible-set prewarm selection from build 32.
    public static var stickyPrewarmEnabled: Bool {
        current == .sticky
    }

    /// Kept so the build-34 audio experiment can never be enabled accidentally
    /// by a stale compilation condition. Both build-35 arms use control audio.
    public static var audioFixEnabled: Bool { false }

    public static var telemetryFields: [String: Any] {
        [
            "experiment_id": experimentID,
            "experiment_variant": current.rawValue,
            "launch_seq": launchSeq,
            "experiment_sticky_prewarm": stickyPrewarmEnabled,
            "prewarm_threshold_pages": stickyPrewarmEnabled ? PrewarmPolicy.enterThreshold : 0.0
        ]
    }
}
