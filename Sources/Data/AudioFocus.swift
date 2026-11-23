import Foundation

/// The one audible owner at a time. Video slots and gallery BGM are both
/// represented here so lifecycle events never need to guess from two
/// independent "current" properties.
public enum AudioOwner: Equatable {
    case idle
    case video(streamId: Int64)
    case gallery(streamId: Int64, bgmURL: URL?)
}

/// Reasons why the current owner is not playing. A set is required because
/// scene, interruption, route, and user intent can overlap.
public enum AudioPauseReason: Hashable {
    case user
    case sceneInactive
    case interruption
    case routeChange
}

public struct AudioFocusState: Equatable {
    public var owner: AudioOwner
    public var pauseReasons: Set<AudioPauseReason>
    public var epoch: UInt64

    public init(
        owner: AudioOwner = .idle,
        pauseReasons: Set<AudioPauseReason> = [],
        epoch: UInt64 = 0
    ) {
        self.owner = owner
        self.pauseReasons = pauseReasons
        self.epoch = epoch
    }

    public var shouldPlay: Bool {
        owner != .idle && pauseReasons.isEmpty
    }

    public var isUserPaused: Bool {
        pauseReasons.contains(.user)
    }

    public var hasSystemPauseReason: Bool {
        pauseReasons.contains(.sceneInactive)
            || pauseReasons.contains(.interruption)
            || pauseReasons.contains(.routeChange)
    }
}

public enum AudioFocusEvent: Equatable {
    case activateVideo(streamId: Int64)
    case activateGallery(streamId: Int64, bgmURL: URL?)
    case pageChanged
    case userPause
    case userPlay
    case sceneInactive
    case sceneActive
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeLost
}

public enum AudioFocusEffect: Equatable {
    case activateSession
    case deactivateSession
    case playVideo(streamId: Int64)
    case pauseVideo
    case playBGM(streamId: Int64, url: URL)
    case pauseBGM
    case stopBGM
}

/// Pure audio policy. All play/pause/stop decisions are made here; the player
/// pool only executes the returned effects.
public enum AudioFocusReducer {
    public static func reduce(
        state: inout AudioFocusState,
        event: AudioFocusEvent
    ) -> [AudioFocusEffect] {
        switch event {
        case .activateVideo(let streamId):
            let newOwner = AudioOwner.video(streamId: streamId)
            if state.owner != newOwner {
                let previous = state.owner
                state.owner = newOwner
                state.epoch &+= 1
                // A real page change is new playback intent; a repeated cell
                // refresh of the same owner must not clear a user pause.
                if previous != .idle {
                    state.pauseReasons.remove(.user)
                }
            }
            return reconcile(state)

        case .activateGallery(let streamId, let bgmURL):
            let newOwner = AudioOwner.gallery(streamId: streamId, bgmURL: bgmURL)
            let ownerChanged = state.owner != newOwner
            if ownerChanged {
                let previous = state.owner
                state.owner = newOwner
                state.epoch &+= 1
                if previous != .idle {
                    state.pauseReasons.remove(.user)
                }
            }
            var effects: [AudioFocusEffect] = ownerChanged ? [.stopBGM] : []
            effects.append(contentsOf: reconcile(state))
            return effects

        case .pageChanged:
            // Paging is a new ownership epoch. Revoke the previous owner
            // before the new cell has resolved its media, so a slow lease can
            // never leave old BGM playing into the next page.
            state.owner = .idle
            state.epoch &+= 1
            state.pauseReasons.remove(.user)
            return [.stopBGM, .pauseVideo]

        case .userPause:
            state.pauseReasons.insert(.user)
            return pauseEffects(for: state.owner) + [.deactivateSession]

        case .userPlay:
            state.pauseReasons.remove(.user)
            state.pauseReasons.remove(.interruption)
            state.pauseReasons.remove(.routeChange)
            return reconcile(state)

        case .sceneInactive:
            state.pauseReasons.insert(.sceneInactive)
            return pauseEffects(for: state.owner) + [.deactivateSession]

        case .sceneActive:
            state.pauseReasons.remove(.sceneInactive)
            return reconcile(state)

        case .interruptionBegan:
            state.pauseReasons.insert(.interruption)
            return pauseEffects(for: state.owner)

        case .interruptionEnded(let shouldResume):
            if shouldResume {
                state.pauseReasons.remove(.interruption)
                return reconcile(state)
            }
            // The system recommends against resuming. Keep the reason until
            // the user explicitly asks to play again.
            return pauseEffects(for: state.owner) + [.deactivateSession]

        case .routeLost:
            // Apple HIG: losing headphones/Bluetooth requires explicit user
            // interaction before audio starts again.
            state.pauseReasons.insert(.routeChange)
            return pauseEffects(for: state.owner) + [.deactivateSession]
        }
    }

    private static func reconcile(_ state: AudioFocusState) -> [AudioFocusEffect] {
        guard state.shouldPlay else {
            return pauseEffects(for: state.owner)
        }

        switch state.owner {
        case .idle:
            return [.pauseVideo, .stopBGM, .deactivateSession]

        case .video(let streamId):
            return [.stopBGM, .activateSession, .playVideo(streamId: streamId)]

        case .gallery(let streamId, let bgmURL):
            guard let bgmURL else {
                return [.pauseVideo, .stopBGM, .deactivateSession]
            }
            return [.pauseVideo, .activateSession, .playBGM(streamId: streamId, url: bgmURL)]
        }
    }

    private static func pauseEffects(for owner: AudioOwner) -> [AudioFocusEffect] {
        switch owner {
        case .idle:
            return [.pauseVideo, .stopBGM]
        case .video:
            return [.stopBGM, .pauseVideo]
        case .gallery(_, let bgmURL):
            return [.pauseVideo, bgmURL == nil ? .stopBGM : .pauseBGM]
        }
    }
}
