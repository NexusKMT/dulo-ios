import AVFoundation
import Foundation

/// Owns the app-wide audio-session lifecycle.
///
/// The category is configured once at launch so the first playback is cheap,
/// but activation is deliberately deferred until audio actually starts. Apple
/// recommends this to avoid interrupting other apps' background audio merely
/// because Dulo was opened.
enum PlayerFactory {
    private static var isConfigured = false
    private static var isActive = false

    /// Configures category/mode only. This does not activate the session and
    /// therefore does not interrupt other audio.
    static func configureAudioSession() {
        #if canImport(AVFAudio)
        guard !isConfigured else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            isConfigured = true
        } catch {
            NSLog("[PlayerFactory] Failed to configure AVAudioSession: %@", error.localizedDescription)
        }
        #endif
    }

    /// Activates the session immediately before the first audible playback.
    static func activateAudioSession() {
        #if canImport(AVFAudio)
        configureAudioSession()
        // setActive(true) is idempotent and must run again after a system
        // interruption, which may deactivate the session without notifying us.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isActive = true
        } catch {
            NSLog("[PlayerFactory] Failed to activate AVAudioSession: %@", error.localizedDescription)
        }
        #endif
    }

    /// Audio-fix arm: avoid a synchronous `setActive(true)` on every cell
    /// refresh. Interruptions invalidate the flag so the next playback still
    /// re-activates the session.
    static func activateAudioSessionIfNeeded() {
        #if canImport(AVFAudio)
        guard !isActive else { return }
        activateAudioSession()
        #endif
    }

    static func noteAudioSessionInterrupted() {
        isActive = false
    }

    /// Releases the session so other apps can resume their audio. Safe to call
    /// repeatedly; the next playback activates it again.
    static func deactivateAudioSession() {
        #if canImport(AVFAudio)
        guard isActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            isActive = false
        } catch {
            NSLog("[PlayerFactory] Failed to deactivate AVAudioSession: %@", error.localizedDescription)
        }
        #endif
    }
}
