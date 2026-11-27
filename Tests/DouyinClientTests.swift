import XCTest
import Foundation

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

/// Fixture-driven tests for `DouyinClient`. No network: every case drives the
/// pure decoding seams with an inline body, and the two request-shape tests read
/// the `URLRequest` that would be sent without sending it.
final class DouyinClientTests: XCTestCase {

    // MARK: - Videos

    /// Two renditions, one H.265. The H.265 one has the higher bitrate, and must
    /// still lose: hardware that can play it is the minority on this fleet.
    func testDetailPrefersNonH265OverHigherBitrateH265() throws {
        let content = try DouyinClient.content(fromDetail: Self.videoDetail)

        assertVideo(
            content,
            url: "https://v3.douyinvod.com/h264-1080.mp4?x-expires=1767225600",
            cover: "https://p3.douyinpic.com/origin-cover.jpg",
            width: 1080,
            height: 1920
        )
    }

    /// Among the non-H.265 renditions the highest bitrate wins, and a rendition is
    /// H.265 when its URL says so even if `is_h265` is missing.
    func testDetailPicksHighestBitrateNonH265Rendition() throws {
        let content = try DouyinClient.content(fromDetail: Self.renditionDetail)

        assertVideo(
            content,
            url: "https://v3.douyinvod.com/h264-high.mp4",
            cover: nil,
            width: 720,
            height: 1280
        )
    }

    /// No `bit_rate` list at all: fall back to `video.play_addr`.
    func testDetailFallsBackToPlayAddrWithoutRenditions() throws {
        let content = try DouyinClient.content(fromDetail: Self.plainVideoDetail)

        assertVideo(
            content,
            url: "https://v3.douyinvod.com/plain.mp4",
            cover: "https://p3.douyinpic.com/plain-cover.jpg",
            width: 1080,
            height: 1920
        )
    }

    // MARK: - Image posts

    /// Three slides, three orientations, one of them a Live Photo — and a sibling
    /// `video` block that must be ignored because the post is 图文.
    func testDetailImagePostKeepsThreeMixedOrientationSlides() throws {
        let content = try DouyinClient.content(fromDetail: Self.imageDetail)
        let (slides, music) = unpackImages(content)

        XCTAssertEqual(slides.count, 3)
        XCTAssertEqual(
            slides.map(\.imageUrl.absoluteString),
            [
                "https://p3.douyinpic.com/slide-0.jpg",
                "https://p3.douyinpic.com/slide-1.jpg",
                "https://p3.douyinpic.com/slide-2.jpg",
            ]
        )
        // Real pixel geometry per slide: 1080x1920, 1920x1080, 1080x1350.
        XCTAssertEqual(try XCTUnwrap(slides[0].aspectRatio), 1080.0 / 1920.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(slides[1].aspectRatio), 1920.0 / 1080.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(slides[2].aspectRatio), 1080.0 / 1350.0, accuracy: 1e-12)

        // Only the middle slide is a Live Photo.
        XCTAssertNil(slides[0].motionUrl)
        XCTAssertEqual(
            slides[1].motionUrl?.absoluteString,
            "https://v3.douyinvod.com/slide-1-live.mp4"
        )
        XCTAssertNil(slides[2].motionUrl)

        XCTAssertEqual(music?.absoluteString, "https://lf3.douyinmusic.com/bgm.mp3")
        XCTAssertEqual(content.signedUrls.count, 5) // 3 stills + 1 motion clip + track
    }

    /// The first slide has no usable URL and the second has no dimensions: the
    /// broken slide is dropped (never rendered as a blank poster) and the slide
    /// that survives reports `nil` rather than a guessed ratio.
    func testDetailDropsSlideWithoutURLAndOmitsUnknownAspectRatio() throws {
        let content = try DouyinClient.content(fromDetail: Self.partialImageDetail)
        let (slides, music) = unpackImages(content)

        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides[0].imageUrl.absoluteString, "https://p3.douyinpic.com/only-slide.jpg")
        XCTAssertNil(slides[0].aspectRatio)
        XCTAssertNil(slides[0].motionUrl)
        XCTAssertNil(music)
    }

    // MARK: - Failures

    /// A 200 whose body carries no `status_code` is Douyin's soft block for a
    /// burnt identity — no content, but nothing malformed about the transport.
    func testDetailSoftBlockWithoutStatusCodeIsNotFound() {
        assertFailure(.notFound) {
            try DouyinClient.content(fromDetail: Self.softBlockDetail)
        }
    }

    func testDetailNonZeroStatusCodeIsNotFound() {
        assertFailure(.notFound) {
            try DouyinClient.content(fromDetail: Self.blockedDetail)
        }
    }

    func testDetailWithoutAwemeDetailIsNotFound() {
        assertFailure(.notFound) {
            try DouyinClient.content(fromDetail: Self.emptyDetail)
        }
    }

    /// A verification page instead of JSON: the transport worked, the body is junk.
    func testDetailGarbledBodyIsMalformed() {
        assertFailure(.malformed) {
            try DouyinClient.content(fromDetail: Data("<html>验证码</html>".utf8))
        }
    }

    func testDetailEmptyBodyIsMalformed() {
        assertFailure(.malformed) {
            try DouyinClient.content(fromDetail: Data())
        }
    }

    // MARK: - App-feed fallback

    /// `count=1` is a hint: the mirror may hand back recommendations too, so the
    /// requested id has to be matched, not taken from index 0.
    func testFeedPicksRequestedAwemeWhenItIsNotFirst() throws {
        let content = try DouyinClient.content(
            fromFeed: Self.feedJSON,
            awemeId: "7440000000000000012"
        )

        assertVideo(
            content,
            url: "https://v3.douyinvod.com/wanted.mp4",
            cover: "https://p3.douyinpic.com/feed-cover.jpg",
            width: 1080,
            height: 1920
        )
    }

    func testFeedWithoutRequestedAwemeIsNotFound() {
        assertFailure(.notFound) {
            try DouyinClient.content(fromFeed: Self.feedJSON, awemeId: "7440000000000000099")
        }
    }

    /// The mirror is videos only: an image-only entry is not content.
    func testFeedEntryWithoutPlayableVideoIsNotFound() {
        assertFailure(.notFound) {
            try DouyinClient.content(fromFeed: Self.feedJSON, awemeId: "7440000000000000013")
        }
    }

    // MARK: - Expiry

    func testExpiryComesFromSignedURL() throws {
        let content = try DouyinClient.content(fromDetail: Self.videoDetail)
        let expiresAt = try XCTUnwrap(content.expiresAt)

        XCTAssertEqual(expiresAt.timeIntervalSince1970, 1_767_225_600, accuracy: 0.5)
    }

    func testExpiryIsNilWithoutXExpires() throws {
        let content = try DouyinClient.content(fromDetail: Self.imageDetail)

        XCTAssertNil(content.expiresAt)
    }

    // MARK: - Request shape
    //
    // These two assertions are the ones that keep the endpoint answering: the
    // slim parameter set and the UA/Origin/Referer trio are the whole trick.

    func testDetailRequestIsTheSlimAnonymousForm() throws {
        let request = try DouyinClient.detailRequest(awemeId: "7440000000000000001")
        let url = try XCTUnwrap(request.url)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.douyin.com")
        XCTAssertEqual(url.path, "/aweme/v1/web/aweme/detail/")

        let query = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(query.map(\.name).sorted(), ["aid", "aweme_id"])
        XCTAssertEqual(query.first { $0.name == "aweme_id" }?.value, "7440000000000000001")
        XCTAssertEqual(query.first { $0.name == "aid" }?.value, "6383")

        // Nothing from the browser client's device set: these trip the Argus gate.
        for forbidden in ["device_platform", "version_code", "screen_width",
                          "screen_height", "pc_client_type", "browser_version"] {
            XCTAssertFalse(url.absoluteString.contains(forbidden), "must not send \(forbidden)")
        }

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "user-agent"),
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "origin"), "https://open.douyin.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "referer"), "https://open.douyin.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "cookie2"))
    }

    func testFeedRequestSpeaksTheAndroidAppIdentity() throws {
        XCTAssertEqual(DouyinClient.feedHosts, ["aweme.snssdk.com", "api5-normal-c-lf.amemv.com"])

        for host in DouyinClient.feedHosts {
            let request = try DouyinClient.feedRequest(awemeId: "7440000000000000012", host: host)
            let url = try XCTUnwrap(request.url)

            XCTAssertEqual(url.host, host)
            XCTAssertEqual(url.path, "/aweme/v1/feed/")

            let query = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            )
            XCTAssertEqual(
                Set(query.map(\.name)),
                ["aweme_id", "count", "aid", "version_code", "device_platform", "os"]
            )
            XCTAssertEqual(query.first { $0.name == "aweme_id" }?.value, "7440000000000000012")
            XCTAssertEqual(query.first { $0.name == "count" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "aid" }?.value, "1128")
            XCTAssertEqual(query.first { $0.name == "device_platform" }?.value, "android")
            XCTAssertEqual(query.first { $0.name == "os" }?.value, "android")

            XCTAssertEqual(
                request.value(forHTTPHeaderField: "user-agent"),
                "com.ss.android.ugc.aweme/300201 (Linux; U; Android 13; zh_CN; "
                    + "Pixel 7; Build/TQ3A.230805.001)"
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "cookie"))
        }
    }

    /// An id that cannot even be addressed is not worth a round trip.
    func testImplausibleIDIsRejectedWithoutARequest() {
        XCTAssertThrowsError(try DouyinClient.detailRequest(awemeId: "744/../1")) { error in
            XCTAssertEqual(error as? DouyinClient.Failure, .notFound)
        }
        XCTAssertThrowsError(try DouyinClient.detailRequest(awemeId: "")) { error in
            XCTAssertEqual(error as? DouyinClient.Failure, .notFound)
        }
    }

    // MARK: - Helpers

    private func assertVideo(
        _ content: MediaContent,
        url expectedUrl: String,
        cover expectedCover: String?,
        width expectedWidth: Int,
        height expectedHeight: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .video(let url, let cover, let width, let height) = content else {
            return XCTFail("expected a video, got \(content)", file: file, line: line)
        }
        XCTAssertEqual(url.absoluteString, expectedUrl, file: file, line: line)
        XCTAssertEqual(cover?.absoluteString, expectedCover, file: file, line: line)
        XCTAssertEqual(width, expectedWidth, file: file, line: line)
        XCTAssertEqual(height, expectedHeight, file: file, line: line)
    }

    private func unpackImages(
        _ content: MediaContent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ([ImageSlide], URL?) {
        guard case .images(let slides, let music) = content else {
            XCTFail("expected an image post, got \(content)", file: file, line: line)
            return ([], nil)
        }
        return (slides, music)
    }

    private func assertFailure(
        _ expected: DouyinClient.Failure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> MediaContent
    ) {
        do {
            let content = try body()
            XCTFail("expected \(expected), got \(content)", file: file, line: line)
        } catch let failure as DouyinClient.Failure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    /// A video with two renditions: H.265 at 2.8 Mbps, H.264 at 1.8 Mbps.
    private static let videoDetail = Data("""
    {
      "status_code": 0,
      "aweme_detail": {
        "aweme_id": "7440000000000000001",
        "media_type": 4,
        "video": {
          "width": 1080,
          "height": 1920,
          "origin_cover": { "url_list": ["https://p3.douyinpic.com/origin-cover.jpg"] },
          "dynamic_cover": { "url_list": ["https://p3.douyinpic.com/dynamic-cover.webp"] },
          "cover": { "url_list": ["https://p3.douyinpic.com/cover.jpg"] },
          "bit_rate": [
            {
              "gear_name": "adapt_540_1",
              "bit_rate": 2800000,
              "is_h265": 1,
              "play_addr": { "url_list": ["https://v3.douyinvod.com/h265-540.mp4"] }
            },
            {
              "gear_name": "adapt_1080_1",
              "bit_rate": 1800000,
              "is_h265": 0,
              "play_addr": {
                "url_list": ["https://v3.douyinvod.com/h264-1080.mp4?x-expires=1767225600"]
              }
            }
          ],
          "play_addr": { "url_list": ["https://v3.douyinvod.com/play-fallback.mp4"] }
        }
      }
    }
    """.utf8)

    /// Four renditions, only one of them H.265 by flag; another is H.265 by URL.
    private static let renditionDetail = Data("""
    {
      "status_code": 0,
      "aweme_detail": {
        "aweme_id": "7440000000000000002",
        "video": {
          "width": 720,
          "height": 1280,
          "bit_rate": [
            {
              "bit_rate": 5000000,
              "is_h265": 1,
              "play_addr": { "url_list": ["https://v3.douyinvod.com/flag-h265.mp4"] }
            },
            {
              "bit_rate": 9000000,
              "play_addr": { "url_list": ["https://v3.douyinvod.com/bytevc1-720.mp4"] }
            },
            {
              "bit_rate": 1200000,
              "play_addr": { "url_list": ["https://v3.douyinvod.com/h264-low.mp4"] }
            },
            {
              "bit_rate": 2400000,
              "play_addr": { "url_list": ["https://v3.douyinvod.com/h264-high.mp4"] }
            }
          ]
        }
      }
    }
    """.utf8)

    private static let plainVideoDetail = Data("""
    {
      "status_code": 0,
      "aweme_detail": {
        "aweme_id": "7440000000000000005",
        "video": {
          "width": 1080,
          "height": 1920,
          "cover": { "url_list": ["https://p3.douyinpic.com/plain-cover.jpg"] },
          "play_addr": { "url_list": ["https://v3.douyinvod.com/plain.mp4"] }
        }
      }
    }
    """.utf8)

    /// 图文 post: three slides (1080x1920, 1920x1080 Live Photo, 1080x1350) plus a
    /// sibling `video` block that must lose to the slides.
    private static let imageDetail = Data("""
    {
      "status_code": 0,
      "aweme_detail": {
        "aweme_id": "7440000000000000003",
        "media_type": 2,
        "images": [
          {
            "url_list": ["https://p3.douyinpic.com/slide-0.jpg"],
            "width": 1080,
            "height": 1920
          },
          {
            "url_list": ["https://p3.douyinpic.com/slide-1.jpg"],
            "width": 1920,
            "height": 1080,
            "video": { "play_addr": { "url_list": ["https://v3.douyinvod.com/slide-1-live.mp4"] } }
          },
          {
            "url_list": ["https://p3.douyinpic.com/slide-2.jpg"],
            "width": 1080,
            "height": 1350
          }
        ],
        "music": { "play_url": { "url_list": ["https://lf3.douyinmusic.com/bgm.mp3"] } },
        "video": {
          "width": 1080,
          "height": 1920,
          "play_addr": { "url_list": ["https://v3.douyinvod.com/rendered-track.mp4"] }
        }
      }
    }
    """.utf8)

    /// First slide has no URL, the second carries no dimensions.
    private static let partialImageDetail = Data("""
    {
      "status_code": 0,
      "aweme_detail": {
        "aweme_id": "7440000000000000004",
        "images": [
          { "url_list": [], "width": 1080, "height": 1920 },
          { "url_list": ["https://p3.douyinpic.com/only-slide.jpg"] }
        ]
      }
    }
    """.utf8)

    /// 200 with no `status_code` at all: the soft block.
    private static let softBlockDetail = Data("{ }".utf8)

    /// 200 with a real status code and no payload.
    private static let blockedDetail = Data("""
    { "status_code": 2154, "status_code_msg": "blocked", "aweme_detail": null }
    """.utf8)

    /// A well-formed envelope with nothing in it.
    private static let emptyDetail = Data("""
    { "status_code": 0, "aweme_detail": null }
    """.utf8)

    /// The requested aweme is the second entry; the third is image-only.
    private static let feedJSON = Data("""
    {
      "status_code": 0,
      "aweme_list": [
        {
          "aweme_id": "7440000000000000011",
          "video": {
            "width": 720,
            "height": 1280,
            "play_addr": { "url_list": ["https://v3.douyinvod.com/someone-else.mp4"] }
          }
        },
        {
          "aweme_id": "7440000000000000012",
          "video": {
            "width": 1080,
            "height": 1920,
            "cover": { "url_list": ["https://p3.douyinpic.com/feed-cover.jpg"] },
            "play_addr": { "url_list": ["https://v3.douyinvod.com/wanted.mp4"] }
          }
        },
        {
          "aweme_id": "7440000000000000013",
          "images": [{ "url_list": ["https://p3.douyinpic.com/feed-slide.jpg"] }]
        }
      ]
    }
    """.utf8)
}
