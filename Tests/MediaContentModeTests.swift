import AVFoundation
import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
@testable import Dulo
#else
@testable import DuloCore
#endif

/// Regression coverage for the single decision that drives *every* media
/// surface: video layer gravity, cover/gallery image content mode and host-view
/// clipping.
///
/// Contract (`Dulo-server/docs/video-layout.md`): `ar = width / height`;
/// `ar < 1` fills the canvas (edges cropped, host view must clip), every other
/// valid ratio keeps its full frame and letterboxes; `nil` / non-positive /
/// non-finite falls back to fit.
///
/// The point of `testVideoAndImageComeFromTheSameModeForEveryRatio` is that the
/// video path and the image path must never be able to answer differently for
/// the same `ar`: editing only one of the two mappings has to turn this suite red.
final class MediaContentModeTests: XCTestCase {

    // MARK: - Fixtures

    /// Ratios whose expected mode is pinned literally, so the table cannot drift
    /// silently along with the implementation (unlike a copied rule).
    private static let pinnedRatios: [(aspectRatio: Double?, expected: MediaContentMode)] = [
        (aspectRatio: 0.56, expected: .fill),   // 9:16 phone video, the dominant portrait case
        (aspectRatio: 0.75, expected: .fill),   // portrait canvas ratio
        (aspectRatio: 0.99, expected: .fill),   // just under the unit boundary
        (aspectRatio: 1.0, expected: .fit),     // square: nothing may be cropped
        (aspectRatio: 1.78, expected: .fit),    // 16:9
        (aspectRatio: nil, expected: .fit),     // older catalogs omit `ar`
        (aspectRatio: 0, expected: .fit),       // non-positive
        (aspectRatio: -1, expected: .fit),
        (aspectRatio: Double.nan, expected: .fit),
    ]

    /// Broad sweep for the cross-surface regression. Deliberately includes the
    /// unit boundary on both sides, invalids, and extreme magnitudes.
    private static let consistencyRatios: [Double?] = [
        nil,
        Double.nan,
        Double.infinity,
        -Double.infinity,
        0,
        -0.0,
        -1,
        -0.001,
        1e-9,
        0.01,
        0.25,
        0.5,
        0.56,
        0.5625,
        0.75,
        0.9,
        0.99,
        0.999,
        1.0,
        1.000_000_1,
        1.001,
        1.333,
        1.5,
        1.78,
        2.39,
        Double.leastNonzeroMagnitude,
        Double.greatestFiniteMagnitude,
    ]

    private static func label(_ aspectRatio: Double?) -> String {
        "ar=\(String(describing: aspectRatio))"
    }

    // MARK: - 1. resolve(aspectRatio:)

    func testPinnedRatiosResolveToTheirDocumentedMode() {
        for pinned in Self.pinnedRatios {
            XCTAssertEqual(
                MediaContentMode.resolve(aspectRatio: pinned.aspectRatio),
                pinned.expected,
                "resolve disagreed with the pinned table for \(Self.label(pinned.aspectRatio))"
            )
        }
    }

    func testPortraitRatiosResolveToFill() {
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 0.56), .fill)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 0.75), .fill)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 0.99), .fill)
    }

    func testSquareAndLandscapeRatiosResolveToFit() {
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 1.0), .fit)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 1.78), .fit)
    }

    func testMissingZeroNegativeAndNaNRatioResolveToFit() {
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: nil), .fit)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 0), .fit)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: -1), .fit)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: -1.5), .fit)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: Double.nan), .fit)
    }

    func testUnitRatioBoundaryBelongsToFit() {
        // `< 1` is exclusive: 0.999 still fills, 1.0 and just above must not.
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 0.999), .fill)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 1.0), .fit)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 1.000_000_1), .fit)
    }

    func testNonFiniteRatiosResolveToFit() {
        // The guard must stay `isFinite`-aware so infinity does not slip through
        // as a "valid landscape" ratio.
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: Double.infinity), .fit)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: -Double.infinity), .fit)
    }

    func testTinyPositiveRatioResolvesToFill() {
        // Sub-unit is sub-unit: no lower bound may creep into the rule.
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: 1e-9), .fill)
    }

    // MARK: - 2. Per-mode mapping

    func testFillMapsToAspectFillGravityAndClips() {
        let mode = MediaContentMode.fill
        XCTAssertEqual(mode.videoGravity, .resizeAspectFill)
        XCTAssertTrue(mode.clipsContent, "fill draws past its bounds and must clip")
    }

    func testFitMapsToAspectGravityAndDoesNotClip() {
        let mode = MediaContentMode.fit
        XCTAssertEqual(mode.videoGravity, .resizeAspect)
        XCTAssertFalse(mode.clipsContent, "fit stays inside its bounds and must not clip")
    }

    #if canImport(UIKit)
    func testImageContentModeMapping() {
        XCTAssertEqual(MediaContentMode.fill.imageContentMode, .scaleAspectFill)
        XCTAssertEqual(MediaContentMode.fit.imageContentMode, .scaleAspectFit)
    }

    func testImageContentModeMatchesGravityPerMode() {
        XCTAssertEqual(
            MediaContentMode.fill.imageContentMode == .scaleAspectFill,
            MediaContentMode.fill.videoGravity == .resizeAspectFill
        )
        XCTAssertEqual(
            MediaContentMode.fit.imageContentMode == .scaleAspectFit,
            MediaContentMode.fit.videoGravity == .resizeAspect
        )
    }
    #endif

    // MARK: - 3. Video + image must come from one mode

    /// The regression that fails when only one side of the mapping is edited:
    /// for the same `ar`, `videoGravity` and `imageContentMode` (and clipping)
    /// have to agree, and the façade must delegate to `resolve` instead of
    /// re-implementing the rule.
    func testVideoAndImageComeFromTheSameModeForEveryRatio() {
        for aspectRatio in Self.consistencyRatios {
            let label = Self.label(aspectRatio)
            let mode = MediaContentMode.resolve(aspectRatio: aspectRatio)

            // Façade parity: `VideoGravityPolicy` may not grow a second rule.
            XCTAssertEqual(VideoGravityPolicy.mode(forAspectRatio: aspectRatio), mode, label)
            XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: aspectRatio), mode.videoGravity, label)

            // Per-mode mapping, written out independently of the implementation.
            switch mode {
            case .fill:
                XCTAssertEqual(mode.videoGravity, .resizeAspectFill, label)
                XCTAssertTrue(mode.clipsContent, label)
            case .fit:
                XCTAssertEqual(mode.videoGravity, .resizeAspect, label)
                XCTAssertFalse(mode.clipsContent, label)
            }

            // Clipping and gravity are two views of the same decision.
            XCTAssertEqual(
                mode.clipsContent,
                mode.videoGravity == .resizeAspectFill,
                "clipping and video gravity came from different modes for \(label)"
            )

            #if canImport(UIKit)
            let imageContentMode = mode.imageContentMode
            let expectedImageContentMode: UIImageView.ContentMode = mode == .fill ? .scaleAspectFill : .scaleAspectFit
            XCTAssertEqual(
                imageContentMode,
                expectedImageContentMode,
                "image content mode came from a different mode than video gravity for \(label)"
            )
            // The single assertion that catches "someone edited only the image switch".
            XCTAssertEqual(
                imageContentMode == .scaleAspectFill,
                VideoGravityPolicy.gravity(forAspectRatio: aspectRatio) == .resizeAspectFill,
                "video and image disagreed for \(label)"
            )
            XCTAssertEqual(imageContentMode == .scaleAspectFill, mode.clipsContent, label)
            #endif
        }
    }

    /// Same regression, driven by the pinned (literature-expected) table rather
    /// than by `resolve` itself.
    func testPinnedRatiosDriveBothSurfaces() {
        for pinned in Self.pinnedRatios {
            let label = Self.label(pinned.aspectRatio)
            let mode = MediaContentMode.resolve(aspectRatio: pinned.aspectRatio)

            XCTAssertEqual(mode, pinned.expected, label)
            XCTAssertEqual(VideoGravityPolicy.mode(forAspectRatio: pinned.aspectRatio), pinned.expected, label)

            switch pinned.expected {
            case .fill:
                XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: pinned.aspectRatio), .resizeAspectFill, label)
                XCTAssertEqual(mode.videoGravity, .resizeAspectFill, label)
                XCTAssertTrue(mode.clipsContent, label)
                #if canImport(UIKit)
                XCTAssertEqual(mode.imageContentMode, .scaleAspectFill, label)
                #endif
            case .fit:
                XCTAssertEqual(VideoGravityPolicy.gravity(forAspectRatio: pinned.aspectRatio), .resizeAspect, label)
                XCTAssertEqual(mode.videoGravity, .resizeAspect, label)
                XCTAssertFalse(mode.clipsContent, label)
                #if canImport(UIKit)
                XCTAssertEqual(mode.imageContentMode, .scaleAspectFit, label)
                #endif
            }
        }
    }

    /// Closed-world check: each mode may only ever produce one of the two legal
    /// (gravity, clips, image) triples. A half-applied edit breaks this on one
    /// property without needing a ratio to reach it.
    func testEachModeProducesOneOfTwoLegalTriples() {
        for mode in [MediaContentMode.fill, .fit] {
            let gravity = mode.videoGravity
            let clips = mode.clipsContent

            let isFillTriple = gravity == .resizeAspectFill && clips
            let isFitTriple = gravity == .resizeAspect && !clips
            XCTAssertTrue(
                isFillTriple || isFitTriple,
                "gravity \(gravity.rawValue) and clips \(clips) is not a legal pair for \(mode)"
            )

            #if canImport(UIKit)
            let image = mode.imageContentMode
            XCTAssertTrue(
                (image == .scaleAspectFill && isFillTriple) || (image == .scaleAspectFit && isFitTriple),
                "image \(image.rawValue) does not belong to the same mode as gravity \(gravity.rawValue)"
            )
            #endif
        }
    }

    // MARK: - 4. Manifest `ar` reaches the shared decision

    func testManifestAspectRatioFeedsResolve() throws {
        let portrait = #"{"id":"1","title":"a","ar":0.56}"#.data(using: .utf8)!
        let portraitItem = try JSONDecoder().decode(ManifestItem.self, from: portrait)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: portraitItem.ar), .fill)

        let landscape = #"{"id":"2","title":"b","ar":1.78}"#.data(using: .utf8)!
        let landscapeItem = try JSONDecoder().decode(ManifestItem.self, from: landscape)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: landscapeItem.ar), .fit)

        // Older servers omit `ar`; the whole pipeline must fall back to fit.
        let missing = #"{"id":"3","title":"c"}"#.data(using: .utf8)!
        let missingItem = try JSONDecoder().decode(ManifestItem.self, from: missing)
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: missingItem.ar), .fit)
    }

    #if canImport(UIKit)
    /// One image post mixes orientations, so each slide is decided on its own
    /// geometry: the post-level `ar` is absent for 图文 by design.
    func testSlideAspectRatioDrivesItsOwnMode() throws {
        let portrait = ImageSlide(
            imageUrl: try XCTUnwrap(URL(string: "https://example.com/a.webp")),
            motionUrl: nil,
            aspectRatio: 1279.0 / 1706.0
        )
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: portrait.aspectRatio), .fill)

        let landscape = ImageSlide(
            imageUrl: try XCTUnwrap(URL(string: "https://example.com/b.webp")),
            motionUrl: nil,
            aspectRatio: 1356.0 / 882.0
        )
        XCTAssertEqual(MediaContentMode.resolve(aspectRatio: landscape.aspectRatio), .fit)

        // Unknown geometry stays unknown: the caller then inherits the post's mode.
        let bare = ImageSlide(
            imageUrl: try XCTUnwrap(URL(string: "https://example.com/c.webp")),
            motionUrl: nil,
            aspectRatio: nil
        )
        XCTAssertNil(bare.aspectRatio)
    }
    #endif
}
