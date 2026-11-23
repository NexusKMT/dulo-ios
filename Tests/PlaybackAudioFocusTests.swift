import Foundation
import XCTest

#if canImport(UIKit)
@testable import Dulo

/// Regression coverage for gallery BGM surviving a transition to video and
/// then being revived by the lock-screen wake path.
final class PlaybackAudioFocusTests: XCTestCase {
    @MainActor
    private func resetSharedPlaybackState() {
        let pool = FeedPlayerPool.shared
        let coordinator = PlaybackInterruptionCoordinator.shared
        pool.pauseAll()
        pool.bgmPlayer.stop()
        pool.activeSlot.clear()
        pool.standbySlot.clear()
        coordinator.recordPlaybackStarted()
    }

    @MainActor
    func testVideoAudioFocusStopsGalleryBgm() {
        let pool = FeedPlayerPool.shared
        let coordinator = PlaybackInterruptionCoordinator.shared
        let bgmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-gallery-\(UUID().uuidString).m4a")
            .absoluteString

        resetSharedPlaybackState()
        defer { resetSharedPlaybackState() }

        pool.playBgm(urlString: bgmURL)
        XCTAssertEqual(pool.bgmPlayer.currentUrl, bgmURL)
        XCTAssertNil(pool.currentPlayingSlot)

        pool.play(slot: pool.activeSlot)

        XCTAssertTrue(pool.currentPlayingSlot === pool.activeSlot)
        XCTAssertNil(pool.bgmPlayer.currentUrl, "video focus must revoke stale gallery BGM ownership")
        XCTAssertFalse(pool.bgmPlayer.isPlaying)
    }

    @MainActor
    func testWakeFromLockDoesNotResumeBgmUnderVideo() {
        let pool = FeedPlayerPool.shared
        let coordinator = PlaybackInterruptionCoordinator.shared
        let bgmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-gallery-\(UUID().uuidString).m4a")
            .absoluteString

        resetSharedPlaybackState()
        defer { resetSharedPlaybackState() }

        // Simulate: gallery BGM was playing, then the user swiped to a video.
        pool.playBgm(urlString: bgmURL)
        pool.play(slot: pool.activeSlot)
        XCTAssertNil(pool.bgmPlayer.currentUrl)

        coordinator.handleAppResignActive()
        coordinator.handleAppBecomeActive()

        XCTAssertNil(pool.bgmPlayer.currentUrl, "wake must not revive a previous gallery's BGM")
        XCTAssertFalse(pool.bgmPlayer.isPlaying)
        XCTAssertTrue(pool.currentPlayingSlot === pool.activeSlot)
    }
}
#endif
