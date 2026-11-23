import XCTest

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class ExperimentVariantTests: XCTestCase {
    func testTelemetryFieldsIdentifyTheCompiledArm() {
        let fields = ExperimentVariant.telemetryFields
        XCTAssertEqual(fields["experiment_id"] as? String, ExperimentVariant.experimentID)
        XCTAssertEqual(fields["experiment_variant"] as? String, ExperimentVariant.current.rawValue)
        XCTAssertEqual(fields["experiment_prewarm_fix"] as? Bool, ExperimentVariant.prewarmFixEnabled)
        XCTAssertEqual(fields["experiment_audio_fix"] as? Bool, ExperimentVariant.audioFixEnabled)
    }

    func testOnlyTheMatchingArmEnablesAFix() {
        XCTAssertEqual(ExperimentVariant.prewarmFixEnabled, ExperimentVariant.current == .prewarm)
        XCTAssertEqual(ExperimentVariant.audioFixEnabled, ExperimentVariant.current == .audio)
    }
}
