import XCTest

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class ExperimentVariantTests: XCTestCase {
    func testLaunchSequenceUsesStickyArm() {
        XCTAssertEqual(ExperimentVariant.variant(forLaunchSeq: 0), .sticky)
        XCTAssertEqual(ExperimentVariant.variant(forLaunchSeq: 1), .sticky)
        XCTAssertEqual(ExperimentVariant.variant(forLaunchSeq: 2), .sticky)
        XCTAssertEqual(ExperimentVariant.variant(forLaunchSeq: 3), .sticky)
    }

    func testTelemetryFieldsIdentifyRuntimeArmAndLaunch() {
        ExperimentVariant.overrideForTesting(.sticky, launchSeq: 7)
        let fields = ExperimentVariant.telemetryFields

        XCTAssertEqual(fields["experiment_id"] as? String, ExperimentVariant.experimentID)
        XCTAssertEqual(fields["experiment_variant"] as? String, "sticky")
        XCTAssertEqual(fields["launch_seq"] as? Int, 7)
        XCTAssertEqual(fields["experiment_sticky_prewarm"] as? Bool, true)
        XCTAssertEqual(fields["prewarm_threshold_pages"] as? Double, PrewarmPolicy.enterThreshold)
        XCTAssertTrue(ExperimentVariant.stickyPrewarmEnabled)
        XCTAssertFalse(ExperimentVariant.audioFixEnabled)
    }
}
