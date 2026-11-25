import Foundation
import XCTest

#if canImport(UIKit)
import AVFAudio
@testable import Dulo
#else
@testable import DuloCore
#endif

final class AudioSessionEventMapperTests: XCTestCase {
    #if canImport(UIKit)
    func testMapperConstantsMatchAVFoundationRawValues() {
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionTypeEnded,
            AVAudioSession.InterruptionType.ended.rawValue
        )
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionTypeBegan,
            AVAudioSession.InterruptionType.began.rawValue
        )
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionOptionShouldResume,
            AVAudioSession.InterruptionOptions.shouldResume.rawValue
        )
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionReasonAppWasSuspended,
            AVAudioSession.InterruptionReason.appWasSuspended.rawValue
        )
        XCTAssertEqual(
            AudioSessionEventMapper.routeReasonNewDeviceAvailable,
            AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        )
        XCTAssertEqual(
            AudioSessionEventMapper.routeReasonOldDeviceUnavailable,
            AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        )
    }
    #endif

    func testInterruptionBeganMapsToEvent() {
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionEvent(
                type: AudioSessionEventMapper.interruptionTypeBegan,
                reason: nil,
                options: 0
            ),
            .interruptionBegan
        )
    }

    func testAppWasSuspendedBeganIsIgnored() {
        XCTAssertNil(
            AudioSessionEventMapper.interruptionEvent(
                type: AudioSessionEventMapper.interruptionTypeBegan,
                reason: AudioSessionEventMapper.interruptionReasonAppWasSuspended,
                options: 0
            )
        )
    }

    func testInterruptionEndedReadsShouldResume() {
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionEvent(
                type: AudioSessionEventMapper.interruptionTypeEnded,
                reason: nil,
                options: AudioSessionEventMapper.interruptionOptionShouldResume
            ),
            .interruptionEnded(shouldResume: true)
        )
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionEvent(
                type: AudioSessionEventMapper.interruptionTypeEnded,
                reason: nil,
                options: 0
            ),
            .interruptionEnded(shouldResume: false)
        )
    }

    func testInterruptionEndedDoesNotDropShouldResumeBecauseOfReason() {
        // The reason field is only meaningful for `.began`; an ended event
        // must still be honored so the sticky interruption can be cleared.
        XCTAssertEqual(
            AudioSessionEventMapper.interruptionEvent(
                type: AudioSessionEventMapper.interruptionTypeEnded,
                reason: AudioSessionEventMapper.interruptionReasonAppWasSuspended,
                options: AudioSessionEventMapper.interruptionOptionShouldResume
            ),
            .interruptionEnded(shouldResume: true)
        )
    }

    func testUnknownInterruptionTypeIsIgnored() {
        XCTAssertNil(
            AudioSessionEventMapper.interruptionEvent(
                type: 99,
                reason: nil,
                options: 0
            )
        )
    }

    func testHeadphoneRemovalMapsToRouteLost() {
        XCTAssertEqual(
            AudioSessionEventMapper.routeChangeEvent(
                reason: AudioSessionEventMapper.routeReasonOldDeviceUnavailable
            ),
            .routeLost
        )
    }

    func testHeadphoneArrivalMapsToRouteAvailable() {
        XCTAssertEqual(
            AudioSessionEventMapper.routeChangeEvent(
                reason: AudioSessionEventMapper.routeReasonNewDeviceAvailable
            ),
            .routeAvailable
        )
    }

    func testOtherRouteReasonsAreIgnored() {
        XCTAssertNil(AudioSessionEventMapper.routeChangeEvent(reason: 0))
        XCTAssertNil(AudioSessionEventMapper.routeChangeEvent(reason: 3))
        XCTAssertNil(AudioSessionEventMapper.routeChangeEvent(reason: 99))
    }
}
