import XCTest
#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

final class MediaResolutionTests: XCTestCase {
    func testDecodeVideoResolveResponseWithExpiresAt() throws {
        let json = """
        {
            "type": "video",
            "url": "https://example.com/video.mp4",
            "expiresAt": 1700000000,
            "ttlSeconds": 1800,
            "cached": true
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ResolveResponse.self, from: json)
        XCTAssertEqual(resp.url, "https://example.com/video.mp4")
        XCTAssertEqual(resp.expiresAt, 1700000000)
        XCTAssertEqual(resp.ttlSeconds, 1800)
    }

    func testDecodeVideoResolveResponseWithoutImagesField() throws {
        let json = """
        {
            "type": "video",
            "url": "https://example.com/video.mp4",
            "expiresAt": 1700000000,
            "ttlSeconds": 1800,
            "cached": true
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ResolveResponse.self, from: json)
        XCTAssertEqual(resp.url, "https://example.com/video.mp4")
        XCTAssertEqual(resp.images, [])
        XCTAssertNil(resp.music)
        XCTAssertEqual(resp.ttlSeconds, 1800)
    }

    func testDecodeImageResolveResponseWithImagesField() throws {
        let json = """
        {
            "type": "images",
            "images": ["https://example.com/1.jpg", "https://example.com/2.jpg"],
            "music": "https://example.com/bgm.mp3",
            "expiresAt": 1700000000,
            "ttlSeconds": 1800,
            "cached": false
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ResolveResponse.self, from: json)
        XCTAssertNil(resp.url)
        XCTAssertEqual(resp.images.count, 2)
        XCTAssertEqual(resp.music, "https://example.com/bgm.mp3")
        XCTAssertEqual(resp.ttlSeconds, 1800)
    }

    func testDecodeResolveResponseWithDoubleTtl() throws {
        let json = """
        {
            "type": "video",
            "url": "https://example.com/video.mp4",
            "ttlSeconds": 120.5
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ResolveResponse.self, from: json)
        XCTAssertEqual(resp.ttlSeconds, 120)
    }

    func testDecodeManifestResponseWithMissingOrEmptyFields() throws {
        let json = """
        {
            "items": [
                {"title": "Test 1", "id": "123"},
                {"title": "Test 2"}
            ]
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ManifestResponse.self, from: json)
        XCTAssertEqual(resp.schemaVersion, 1)
        XCTAssertEqual(resp.items.count, 2)
        XCTAssertEqual(resp.items[0].id, "123")
        XCTAssertEqual(resp.items[1].id, "")
    }
}
