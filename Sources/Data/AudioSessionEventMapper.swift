import Foundation

/// Pure mapping from the raw values carried in `AVAudioSession` notifications
/// into audio-focus events. Keeping this free of AVFoundation lets the policy
/// be compiled and tested with CommandLineTools, and keeps the notification
/// observer free of branching policy.
public enum AudioSessionEventMapper {
    // Apple's public raw values. Kept here instead of importing AVFAudio so
    // this file is part of DuloCore on macOS as well.
    public static let interruptionTypeEnded: UInt = 0
    public static let interruptionTypeBegan: UInt = 1
    public static let interruptionOptionShouldResume: UInt = 1
    public static let interruptionReasonAppWasSuspended: UInt = 1
    public static let routeReasonNewDeviceAvailable: UInt = 1
    public static let routeReasonOldDeviceUnavailable: UInt = 2

    /// Maps an interruption notification. A `.began` caused by app suspension
    /// is ignored: the system may deliver it without a matching `.ended`, and
    /// treating it as a real interruption would leave the zero-UI feed stuck.
    public static func interruptionEvent(
        type: UInt,
        reason: UInt?,
        options: UInt
    ) -> AudioFocusEvent? {
        switch type {
        case interruptionTypeBegan:
            guard reason != interruptionReasonAppWasSuspended else { return nil }
            return .interruptionBegan

        case interruptionTypeEnded:
            return .interruptionEnded(
                shouldResume: options & interruptionOptionShouldResume != 0
            )

        default:
            return nil
        }
    }

    /// Only device arrival/removal changes the user's audio intent. Category
    /// and configuration changes are not playback-intent events.
    public static func routeChangeEvent(reason: UInt) -> AudioFocusEvent? {
        switch reason {
        case routeReasonNewDeviceAvailable:
            return .routeAvailable
        case routeReasonOldDeviceUnavailable:
            return .routeLost
        default:
            return nil
        }
    }
}
