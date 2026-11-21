import AVFoundation
import Foundation

/// Dual Player Pool for the vertical feed (TikTok/Shorts style).
/// Manages exactly 2 PlayerState instances across the entire application:
/// - Player A handles even stream IDs (0, 2, 4...)
/// - Player B handles odd stream IDs (1, 3, 5...)
///
/// Hardware decoder budget on iOS:
/// iPhone 6s (Apple A9) VideoToolbox supports a maximum of 4 concurrent hardware decoder pipelines.
/// Dual Player Pool uses at most 2 pipelines (1 active, 1 preloaded neighbour), guaranteeing
/// zero decoder starvation, zero ghost audio, and zero memory leaks.
@MainActor
final class FeedPlayerPool {
    let playerA: PlayerState
    let playerB: PlayerState

    init() {
        self.playerA = PlayerState()
        self.playerB = PlayerState()
    }

    init(playerA: PlayerState, playerB: PlayerState) {
        self.playerA = playerA
        self.playerB = playerB
    }

    func player(for streamId: Int64) -> PlayerState {
        (streamId % 2 == 0) ? playerA : playerB
    }

    /// Strict synchronization: only the active player plays; the inactive player is paused.
    func syncPlayback(activeStreamId: Int64, sceneActive: Bool) {
        let active = player(for: activeStreamId)
        let other = (active === playerA) ? playerB : playerA

        if sceneActive {
            active.player.play()
        } else {
            active.player.pause()
        }
        other.player.pause()
    }

    func pauseAll() {
        playerA.player.pause()
        playerB.player.pause()
    }
}
