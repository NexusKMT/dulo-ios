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

/// Industrial-grade playback interruption coordinator adhering to Apple HIG,
/// ZFPlayer (`pauseByEvent`), and ByteDance audio session interruption patterns.
///
/// Disentangles user-initiated pause actions (`userPaused`) from hardware/system-driven
/// interruptions (`pausedByInterruption`), such as lock screen, backgrounding, phone calls,
/// Siri, alarms, and headphone unplugging.
@MainActor
public final class PlaybackInterruptionCoordinator {
    public static let shared = PlaybackInterruptionCoordinator()

    /// Explicit user intention (user tapped the screen or explicitly triggered pause).
    public private(set) var userPaused: Bool = false

    /// System/Hardware event-driven pause (lock screen, background, phone call, Siri, route change).
    public private(set) var pausedByInterruption: Bool = false

    /// Whether playback should automatically resume when the system or app returns to active state.
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

    // MARK: - User Intent Tracking

    /// Records explicit user playback intent (e.g. user tapped screen to play/pause).
    public func setUserPaused(_ paused: Bool) {
        userPaused = paused
        if paused {
            pausedByInterruption = false
        }
    }

    /// Resets all pause flags when playback starts normally (e.g. feed paging settlement).
    public func recordPlaybackStarted() {
        userPaused = false
        pausedByInterruption = false
    }

    // MARK: - Lifecycle & Hardware Notification Observers

    private func setupObservers() {
        #if canImport(UIKit)
        let o1 = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppResignActive()
        }

        let o2 = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppBecomeActive()
        }
        observers.append(contentsOf: [o1, o2])
        #endif

        #if canImport(AVFAudio)
        // 1. Phone call, Siri, alarm interruptions (AVAudioSession.interruptionNotification)
        let o3 = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification: notification)
        }

        // 2. Headphone / AirPods unplugged (AVAudioSession.routeChangeNotification)
        let o4 = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification: notification)
        }
        observers.append(contentsOf: [o3, o4])
        #endif
    }

    // MARK: - Interruption Handlers

    public func handleAppResignActive() {
        if !userPaused {
            pausedByInterruption = true
        }
        FeedPlayerPool.shared.handleAppResignActive()
    }

    public func handleAppBecomeActive() {
        guard shouldResumeOnActive else {
            pausedByInterruption = false
            return
        }
        pausedByInterruption = false
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
            if !userPaused {
                pausedByInterruption = true
            }
            FeedPlayerPool.shared.pauseAll()

        case .ended:
            NSLog("[PlaybackInterruptionCoordinator] Audio session interruption ended")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) && shouldResumeOnActive {
                pausedByInterruption = false
                FeedPlayerPool.shared.handleAppBecomeActive()
            } else {
                pausedByInterruption = false
            }

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

        // Apple HIG: When headphones or Bluetooth audio devices disconnect,
        // MUST immediately pause video playback and force explicit user interaction to prevent blasting audio in public!
        if reason == .oldDeviceUnavailable {
            NSLog("[PlaybackInterruptionCoordinator] Audio route changed (headphones disconnected); pausing per Apple HIG")
            userPaused = true
            pausedByInterruption = false
            FeedPlayerPool.shared.pauseAll()
        }
    }
    #endif
}
