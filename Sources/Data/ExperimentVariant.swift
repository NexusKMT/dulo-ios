import Foundation

/// Production runtime policy. Sticky prewarm is graduated as the standard
/// architecture for all launches, eliminating micro-drag direction churn
/// and preserving prewarmed player layers across gesture deceleration.
public enum ExperimentVariant: String, CaseIterable {
    case control
    case sticky

    public static let experimentID = "production-sticky"
    private static let launchSeqKey = "dulo.launchSeq"

    /// Set before `LocalMediaProxyServer.shared.start()`, because that is the
    /// first access to `MediaCacheStorage.shared`.
    public private(set) static var current: ExperimentVariant = .sticky
    public private(set) static var launchSeq: Int = 0

    private static var didBootstrap = false

    public static func variant(forLaunchSeq seq: Int) -> ExperimentVariant {
        // Sticky prewarm is graduated as the standard production arm for all launches.
        .sticky
    }

    public static func bootstrap(defaults: UserDefaults = .standard) {
        guard !didBootstrap else { return }
        didBootstrap = true
        let seq = defaults.integer(forKey: launchSeqKey) + 1
        defaults.set(seq, forKey: launchSeqKey)
        launchSeq = seq
        current = .sticky
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

    /// Graduated as standard production behaviour.
    public static var stickyPrewarmEnabled: Bool {
        current == .sticky
    }

    /// Kept so audio routing is clean.
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
