import XCTest

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class PrewarmPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PrewarmPolicy.mode = .hysteresis
    }

    func testMicroDragNeverFlipsDirection() {
        var direction = PrewarmDirection.next
        var delta = 0.0
        var flips = 0

        // Deterministic random walk strictly inside the ±0.2 page deadband.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<10_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let step = (Double(seed >> 11) / Double(UInt64.max >> 11)) * 0.08 - 0.04
            delta = min(0.2, max(-0.2, delta + step))
            let next = PrewarmPolicy.direction(current: direction, deltaPages: delta)
            if next != direction { flips += 1 }
            direction = next
        }

        XCTAssertEqual(flips, 0)
        XCTAssertEqual(direction, .next)
    }

    func testHysteresisRequiresCrossingBothEdges() {
        XCTAssertEqual(
            PrewarmPolicy.direction(current: .next, deltaPages: -0.24),
            .next
        )
        XCTAssertEqual(
            PrewarmPolicy.direction(current: .next, deltaPages: -0.25),
            .previous
        )
        XCTAssertEqual(
            PrewarmPolicy.direction(current: .previous, deltaPages: 0),
            .previous
        )
        XCTAssertEqual(
            PrewarmPolicy.direction(current: .previous, deltaPages: 0.24),
            .previous
        )
        XCTAssertEqual(
            PrewarmPolicy.direction(current: .previous, deltaPages: 0.25),
            .next
        )
    }

    func testTargetIndexRespectsFeedBoundaries() {
        XCTAssertNil(PrewarmPolicy.targetIndex(anchor: 0, direction: .previous, count: 10))
        XCTAssertEqual(PrewarmPolicy.targetIndex(anchor: 0, direction: .next, count: 10), 1)
        XCTAssertEqual(PrewarmPolicy.targetIndex(anchor: 9, direction: .previous, count: 10), 8)
        XCTAssertNil(PrewarmPolicy.targetIndex(anchor: 9, direction: .next, count: 10))
        XCTAssertNil(PrewarmPolicy.targetIndex(anchor: 0, direction: .next, count: 0))
    }

    func testFixedNextModeAlwaysReturnsNext() {
        PrewarmPolicy.mode = .fixedNext
        XCTAssertEqual(
            PrewarmPolicy.direction(current: .previous, deltaPages: -10),
            .next
        )
    }

    func testCellRoleUsesActiveBeforePrewarm() {
        XCTAssertEqual(CellRole.of(streamId: 7, active: 7, prewarm: 7), .active)
        XCTAssertEqual(CellRole.of(streamId: 8, active: 7, prewarm: 8), .prewarm)
        XCTAssertEqual(CellRole.of(streamId: 9, active: 7, prewarm: 8), .none)
        XCTAssertEqual(CellRole.of(streamId: 8, active: 7, prewarm: nil), .none)
    }
}
