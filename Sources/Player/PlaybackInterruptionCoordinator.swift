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

        // `willEnterForeground` only fires on a real background -> foreground
        // transition, not when Control Center or a notification banner merely
        // deactivates the app. That makes it usable as explicit user intent
        // without resurrecting audio just because an overlay was dismissed.
        let foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppWillEnterForeground()
            }
        }
        observers.append(contentsOf: [o1, o2, foreground])
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

    public func handleAppWillEnterForeground() {
        FeedPlayerPool.shared.handleForegroundEntered()
    }

    public func handleAppBecomeActive() {
        // sceneActive clears only the scene reason. Sticky interruption and
        // route reasons are cleared by willEnterForeground or a page change;
        // `.user` still requires an explicit play in all cases.
        FeedPlayerPool.shared.handleAppBecomeActive()
    }

    #if canImport(AVFAudio)
    public func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt else {
            return
        }

        let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt
        let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        guard let event = AudioSessionEventMapper.interruptionEvent(
            type: typeValue,
            reason: reasonValue,
            options: optionsValue
        ) else {
            // Most commonly `.appWasSuspended`: the system can deliver this
            // without a matching `.ended`, so it must not become sticky state.
            NSLog("[PlaybackInterruptionCoordinator] Ignoring non-playback interruption")
            return
        }

        switch event {
        case .interruptionBegan:
            NSLog("[PlaybackInterruptionCoordinator] Audio session interruption began (call/alarm/siri)")
            FeedPlayerPool.shared.handleAudioInterruptionBegan()

        case .interruptionEnded(let shouldResume):
            NSLog("[PlaybackInterruptionCoordinator] Audio session interruption ended (shouldResume=\(shouldResume))")
            FeedPlayerPool.shared.handleAudioInterruptionEnded(shouldResume: shouldResume)

        default:
            break
        }
    }

    public func handleAudioRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let event = AudioSessionEventMapper.routeChangeEvent(reason: reasonValue) else {
            return
        }

        switch event {
        case .routeLost:
            NSLog("[PlaybackInterruptionCoordinator] Audio route changed (headphones disconnected); pausing per Apple HIG")
            FeedPlayerPool.shared.handleAudioRouteLost()

        case .routeAvailable:
            NSLog("[PlaybackInterruptionCoordinator] Audio route changed (headphones connected); clearing route pause")
            FeedPlayerPool.shared.handleAudioRouteAvailable()

        default:
            break
        }
    }
    #endif
}
