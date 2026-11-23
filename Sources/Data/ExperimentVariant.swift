import Foundation

/// One CI run produces three IPAs from the same commit. The build number is
/// the primary discriminator (32/33/34), and this compile-time variant is a
/// second, explicit discriminator embedded in every telemetry event so a
/// mislabeled artifact can never be mistaken for another arm.
public enum ExperimentVariant: String, CaseIterable {
    case control
    case prewarm
    case audio

    public static let experimentID = "jank-abc-2026-11-23"

    public static var current: ExperimentVariant {
        #if DULO_EXPERIMENT_PREWARM
        return .prewarm
        #elseif DULO_EXPERIMENT_AUDIO
        return .audio
        #else
        return .control
        #endif
    }

    /// Keep the target page attached during deceleration instead of replacing
    /// the prewarm target with target±1 and detaching it.
    public static var prewarmFixEnabled: Bool {
        current == .prewarm
    }

    /// Skip redundant `AVAudioSession.setActive(true)` calls and repeated
    /// play requests for an owner that is already playing.
    public static var audioFixEnabled: Bool {
        current == .audio
    }

    public static var telemetryFields: [String: Any] {
        [
            "experiment_id": experimentID,
            "experiment_variant": current.rawValue,
            "experiment_prewarm_fix": prewarmFixEnabled,
            "experiment_audio_fix": audioFixEnabled
        ]
    }
}
