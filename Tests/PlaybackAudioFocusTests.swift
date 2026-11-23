import Foundation
import XCTest

#if canImport(UIKit)
@testable import Dulo

/// Regression coverage for gallery BGM surviving a transition to video and
/// then being revived by the lock-screen wake path.
final class PlaybackAudioFocusTests: XCTestCase {
    @MainActor
    private func resetSharedPlaybackState() {
        FeedPlayerPool.shared.resetAudioFocusForTesting()
    }

    @MainActor
    func testVideoAudioFocusStopsGalleryBgm() {
        let pool = FeedPlayerPool.shared
        let bgmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-gallery-\(UUID().uuidString).m4a")

        resetSharedPlaybackState()
        defer { resetSharedPlaybackState() }

        pool.activateGallery(streamId: 1, bgmURL: bgmURL)
        XCTAssertEqual(pool.audioOwner, .gallery(streamId: 1, bgmURL: bgmURL))
        XCTAssertEqual(pool.bgmPlayer.currentUrl, bgmURL.absoluteString)

        pool.play(slot: pool.activeSlot, streamId: 2)

        XCTAssertEqual(pool.audioOwner, .video(streamId: 2))
        XCTAssertNil(pool.bgmPlayer.currentUrl, "video focus must revoke stale gallery BGM ownership")
        XCTAssertFalse(pool.bgmPlayer.isPlaying)
    }

    @MainActor
    func testWakeFromLockDoesNotResumeBgmUnderVideo() {
        let pool = FeedPlayerPool.shared
        let coordinator = PlaybackInterruptionCoordinator.shared
        let bgmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-gallery-\(UUID().uuidString).m4a")

        resetSharedPlaybackState()
        defer { resetSharedPlaybackState() }

        // Simulate: gallery BGM was playing, then the user swiped to a video.
        pool.activateGallery(streamId: 1, bgmURL: bgmURL)
        pool.play(slot: pool.activeSlot, streamId: 2)
        XCTAssertNil(pool.bgmPlayer.currentUrl)

        coordinator.handleAppResignActive()
        coordinator.handleAppBecomeActive()

        XCTAssertEqual(pool.audioOwner, .video(streamId: 2))
        XCTAssertNil(pool.bgmPlayer.currentUrl, "wake must not revive a previous gallery's BGM")
        XCTAssertFalse(pool.bgmPlayer.isPlaying)
        XCTAssertFalse(pool.userPaused)
    }
}
#endif
