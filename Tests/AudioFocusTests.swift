import Foundation
import XCTest

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class AudioFocusTests: XCTestCase {
    private let galleryA = URL(fileURLWithPath: "/tmp/gallery-a.m4a")
    private let galleryB = URL(fileURLWithPath: "/tmp/gallery-b.m4a")

    private func containsPlayBGM(_ effects: [AudioFocusEffect]) -> Bool {
        effects.contains {
            if case .playBGM = $0 { return true }
            return false
        }
    }

    func testGalleryToVideoThenSceneRoundTripDoesNotResumeStaleBgm() {
        var state = AudioFocusState()

        let gallery = AudioFocusReducer.reduce(
            state: &state,
            event: .activateGallery(streamId: 1, bgmURL: galleryA)
        )
        XCTAssertEqual(state.owner, .gallery(streamId: 1, bgmURL: galleryA))
        XCTAssertTrue(gallery.contains(.playBGM(streamId: 1, url: galleryA)))

        let video = AudioFocusReducer.reduce(
            state: &state,
            event: .activateVideo(streamId: 2)
        )
        XCTAssertEqual(state.owner, .video(streamId: 2))
        XCTAssertTrue(video.contains(.stopBGM))
        XCTAssertFalse(containsPlayBGM(video))

        _ = AudioFocusReducer.reduce(state: &state, event: .sceneInactive)
        XCTAssertFalse(state.shouldPlay)
        XCTAssertEqual(state.owner, .video(streamId: 2))

        let active = AudioFocusReducer.reduce(state: &state, event: .sceneActive)
        XCTAssertTrue(state.shouldPlay)
        XCTAssertTrue(active.contains(.playVideo(streamId: 2)))
        XCTAssertFalse(containsPlayBGM(active))
    }

    func testGalleryToGalleryStopsPreviousBgmAndStartsNewOne() {
        var state = AudioFocusState()

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateGallery(streamId: 1, bgmURL: galleryA)
        )
        let second = AudioFocusReducer.reduce(
            state: &state,
            event: .activateGallery(streamId: 2, bgmURL: galleryB)
        )

        XCTAssertEqual(state.owner, .gallery(streamId: 2, bgmURL: galleryB))
        XCTAssertTrue(second.contains(.stopBGM))
        XCTAssertTrue(second.contains(.playBGM(streamId: 2, url: galleryB)))
        XCTAssertFalse(second.contains(.playBGM(streamId: 1, url: galleryA)))
    }

    func testUserPauseSurvivesSceneRoundTrip() {
        var state = AudioFocusState()

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateVideo(streamId: 7)
        )
        _ = AudioFocusReducer.reduce(state: &state, event: .userPause)
        XCTAssertTrue(state.pauseReasons.contains(.user))

        _ = AudioFocusReducer.reduce(state: &state, event: .sceneInactive)
        let active = AudioFocusReducer.reduce(state: &state, event: .sceneActive)

        XCTAssertTrue(state.pauseReasons.contains(.user))
        XCTAssertFalse(state.shouldPlay)
        XCTAssertFalse(active.contains(.playVideo(streamId: 7)))
    }

    func testInterruptionWithoutShouldResumeWaitsForUserPlay() {
        var state = AudioFocusState()

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateVideo(streamId: 8)
        )
        _ = AudioFocusReducer.reduce(state: &state, event: .interruptionBegan)
        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .interruptionEnded(shouldResume: false)
        )
        XCTAssertTrue(state.pauseReasons.contains(.interruption))

        let active = AudioFocusReducer.reduce(state: &state, event: .sceneActive)
        XCTAssertFalse(active.contains(.playVideo(streamId: 8)))

        let userPlay = AudioFocusReducer.reduce(state: &state, event: .userPlay)
        XCTAssertTrue(state.shouldPlay)
        XCTAssertTrue(userPlay.contains(.playVideo(streamId: 8)))
    }

    func testRouteLossRequiresExplicitUserPlay() {
        var state = AudioFocusState()

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateGallery(streamId: 9, bgmURL: galleryA)
        )
        _ = AudioFocusReducer.reduce(state: &state, event: .routeLost)
        XCTAssertTrue(state.pauseReasons.contains(.routeChange))

        let active = AudioFocusReducer.reduce(state: &state, event: .sceneActive)
        XCTAssertFalse(containsPlayBGM(active))

        let userPlay = AudioFocusReducer.reduce(state: &state, event: .userPlay)
        XCTAssertTrue(state.shouldPlay)
        XCTAssertTrue(containsPlayBGM(userPlay))
    }

    func testGalleryWithoutBgmStopsLeftoverTrack() {
        var state = AudioFocusState()

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateGallery(streamId: 3, bgmURL: galleryA)
        )
        let noBgm = AudioFocusReducer.reduce(
            state: &state,
            event: .activateGallery(streamId: 4, bgmURL: nil)
        )

        XCTAssertEqual(state.owner, .gallery(streamId: 4, bgmURL: nil))
        XCTAssertTrue(noBgm.contains(.stopBGM))
        XCTAssertFalse(containsPlayBGM(noBgm))
        XCTAssertTrue(state.shouldPlay)
    }

    func testPageChangeRevokesOwnerBeforeNewMediaResolves() {
        var state = AudioFocusState()

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateGallery(streamId: 5, bgmURL: galleryA)
        )
        let pageChanged = AudioFocusReducer.reduce(
            state: &state,
            event: .pageChanged
        )

        XCTAssertEqual(state.owner, .idle)
        XCTAssertFalse(state.shouldPlay)
        XCTAssertTrue(pageChanged.contains(.stopBGM))
        XCTAssertTrue(pageChanged.contains(.pauseVideo))

        let active = AudioFocusReducer.reduce(state: &state, event: .sceneActive)
        XCTAssertFalse(containsPlayBGM(active), "an idle owner must not resurrect BGM on wake")
    }

    func testEpochAdvancesOnlyWhenOwnerChanges() {
        var state = AudioFocusState()
        XCTAssertEqual(state.epoch, 0)

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateVideo(streamId: 1)
        )
        XCTAssertEqual(state.epoch, 1)

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateVideo(streamId: 1)
        )
        XCTAssertEqual(state.epoch, 1)

        _ = AudioFocusReducer.reduce(
            state: &state,
            event: .activateVideo(streamId: 2)
        )
        XCTAssertEqual(state.epoch, 2)
    }
}
