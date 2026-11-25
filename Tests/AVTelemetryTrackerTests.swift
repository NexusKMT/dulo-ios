import XCTest

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class AVTelemetryTrackerTests: XCTestCase {
    func testSettleDoesNotResetReleaseTrigger() {
        let tracker = AVTelemetryTracker.shared
        let videoId = "settle-\(UUID().uuidString)"

        tracker.recordSwipeTrigger(for: videoId, cacheTier: "L2_FLASH", isCacheHit: true)
        guard let releaseStart = tracker.trackingSessionStart(for: videoId) else {
            return XCTFail("release trigger did not create a session")
        }

        Thread.sleep(forTimeInterval: 0.05)
        guard let settledStart = tracker.trackingSessionStart(for: videoId) else {
            return XCTFail("settle removed the release session")
        }

        XCTAssertEqual(settledStart, releaseStart, accuracy: 0.0001)

    }

    func testSettleCreatesSessionWhenNoReleaseTriggerRan() {
        let tracker = AVTelemetryTracker.shared
        let videoId = "tap-\(UUID().uuidString)"

        XCTAssertNil(tracker.trackingSessionStart(for: videoId))
        tracker.recordPageSettled(for: videoId, cacheTier: "L2_FLASH", isCacheHit: true)
        XCTAssertNotNil(tracker.trackingSessionStart(for: videoId))
    }

    func testNewPageChangeStillStartsANewSession() {
        let tracker = AVTelemetryTracker.shared
        let videoId = "again-\(UUID().uuidString)"

        tracker.recordSwipeTrigger(for: videoId, cacheTier: "L2_FLASH", isCacheHit: true)
        guard let first = tracker.trackingSessionStart(for: videoId) else {
            return XCTFail("first trigger did not create a session")
        }

        Thread.sleep(forTimeInterval: 0.02)
        tracker.recordSwipeTrigger(for: videoId, cacheTier: "L2_FLASH", isCacheHit: true)
        guard let second = tracker.trackingSessionStart(for: videoId) else {
            return XCTFail("second trigger did not create a session")
        }

        XCTAssertGreaterThan(second, first)
    }
}
