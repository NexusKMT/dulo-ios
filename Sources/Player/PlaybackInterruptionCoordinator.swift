import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Translates app/audio-session notifications into events for the single audio
/// focus reducer. It keeps no independent pause truth of its own; all decisions
/// live in `AudioFocusState` inside `FeedPlayerPool`.
@MainActor
public final class PlaybackInterruptionCoordinator {
    public static let shared = PlaybackInterruptionCoordinator()

    /// Explicit user intention, derived from the reducer state.
    public var userPaused: Bool {
        FeedPlayerPool.shared.userPaused
    }

    /// System/hardware pause (scene, call/Siri, route loss), derived from the
    /// reducer state. User pause always wins for UI purposes.
    public var pausedByInterruption: Bool {
        guard !userPaused else { return false }
        return FeedPlayerPool.shared.hasSystemPauseReason
    }

    /// Whether playback is allowed to resume automatically when the app or
    /// audio session returns to active state.
    public var shouldResumeOnActive: Bool {
        !userPaused && pausedByInterruption
    }

    private var observers: [NSObjectProtocol] = []

    public init() {
        setupObservers()
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - User Intent

    /// Records explicit user playback intent (e.g. tapped screen to play/pause).
    public func setUserPaused(_ paused: Bool) {
        FeedPlayerPool.shared.setUserPaused(paused)
    }

    // MARK: - Lifecycle & Hardware Notification Observers

    private func setupObservers() {
        #if canImport(UIKit)
        let o1 = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppResignActive()
            }
        }

        let o2 = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppBecomeActive()
            }
        }
        observers.append(contentsOf: [o1, o2])
        #endif

        #if canImport(AVFAudio)
        let o3 = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(notification: notification)
            }
        }

        let o4 = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleAudioRouteChange(notification: notification)
            }
        }
        observers.append(contentsOf: [o3, o4])
        #endif
    }

    // MARK: - Interruption Handlers

    public func handleAppResignActive() {
        FeedPlayerPool.shared.handleAppResignActive()
    }

    public func handleAppBecomeActive() {
        // The reducer removes only the scene reason. It will not resume a
        // user-paused, interrupted, or route-lost owner.
        FeedPlayerPool.shared.handleAppBecomeActive()
    }

    #if canImport(AVFAudio)
    public func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            NSLog("[PlaybackInterruptionCoordinator] Audio session interruption began (call/alarm/siri)")
            FeedPlayerPool.shared.handleAudioInterruptionBegan()

        case .ended:
            NSLog("[PlaybackInterruptionCoordinator] Audio session interruption ended")
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            // If `.shouldResume` is absent, the reducer deliberately keeps the
            // interruption reason and waits for an explicit user play.
            FeedPlayerPool.shared.handleAudioInterruptionEnded(
                shouldResume: options.contains(.shouldResume)
            )

        @unknown default:
            break
        }
    }

    public func handleAudioRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        // Apple HIG: losing headphones/Bluetooth must pause immediately and
        // require explicit user interaction before audio starts again.
        if reason == .oldDeviceUnavailable {
            NSLog("[PlaybackInterruptionCoordinator] Audio route changed (headphones disconnected); pausing per Apple HIG")
            FeedPlayerPool.shared.handleAudioRouteLost()
        }
    }
    #endif
}
