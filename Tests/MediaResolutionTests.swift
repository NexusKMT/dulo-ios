import XCTest
@testable import Dulo

final class MediaResolutionTests: XCTestCase {
    func testNetworkFailureGetsOnlyOneRetry() {
        XCTAssertTrue(shouldRetryResolution(.networkFailure, retries: 0))
        XCTAssertFalse(shouldRetryResolution(.networkFailure, retries: 1))
    }

    func testMissingAndServerErrorsAdvanceWithoutRetry() {
        XCTAssertFalse(shouldRetryResolution(.notFound, retries: 0))
        XCTAssertFalse(shouldRetryResolution(.httpFailure(statusCode: 502), retries: 0))
    }
}
