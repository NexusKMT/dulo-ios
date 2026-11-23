import XCTest

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class ExperimentVariantTests: XCTestCase {
    func testLaunchSequenceAlternatesArms() {
        XCTAssertEqual(ExperimentVariant.variant(forLaunchSeq: 0), .control)
        XCTAssertEqual(ExperimentVariant.variant(forLaunchSeq: 1), .sticky)
        XCTAssertEqual(ExperimentVariant.variant(forLaunchSeq: 2), .control)
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

        ExperimentVariant.overrideForTesting(.control, launchSeq: 8)
        let control = ExperimentVariant.telemetryFields
        XCTAssertEqual(control["experiment_variant"] as? String, "control")
        XCTAssertEqual(control["experiment_sticky_prewarm"] as? Bool, false)
        XCTAssertEqual(control["prewarm_threshold_pages"] as? Double, 0.0)
        XCTAssertFalse(ExperimentVariant.stickyPrewarmEnabled)
    }
}
