import AVFoundation
import XCTest
#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class VideoGravityPolicyTests: XCTestCase {
    func testPortraitContentFills() {
        // 9:16 phone video, the dominant portrait case.
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: 0.56), .resizeAspectFill)
        // Exactly the iPad portrait canvas ratio still fills.
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: 0.75), .resizeAspectFill)
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: 0.99), .resizeAspectFill)
    }

    func testLandscapeAndSquareKeepDefaultFit() {
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: 1.0), .resizeAspect)
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: 1.78), .resizeAspect)
    }

    func testUnknownOrInvalidAspectFallsBackToFit() {
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: nil), .resizeAspect)
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: 0), .resizeAspect)
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: -1.5), .resizeAspect)
        XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: .nan), .resizeAspect)
    }

    func testManifestItemDecodesOptionalAspect() throws {
        let withAr = #"{"id":"1","title":"a","ar":0.56}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ManifestItem.self, from: withAr).ar, 0.56)

        // Older servers omit `ar`; decoding must stay tolerant.
        let withoutAr = #"{"id":"2","title":"b"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(ManifestItem.self, from: withoutAr).ar)
    }
}
