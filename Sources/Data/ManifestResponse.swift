import Foundation

/// GET /manifest.json — identity list; play URLs are minted on demand.
struct ManifestResponse: Decodable {
    let schemaVersion: Int
    let items: [ManifestItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        items = (try? c.decode([ManifestItem].self, forKey: .items)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, items }
}

struct ManifestItem: Decodable {
    let title: String
    let id: String
    /// width / height, written by the server; nil for older catalogs.
    let ar: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        ar = try? c.decodeIfPresent(Double.self, forKey: .ar)
    }

    private enum CodingKeys: String, CodingKey { case title, id, ar }
}

/// Slide response for multi-image / Live Photo posts.
struct SlideResponse: Decodable {
    let id: String
    let imageUrl: String?
    let videoUrl: String?
    let width: Int?
    let height: Int?
    let ar: Double?

    /// A slide's own geometry: one image post mixes orientations, so the post's
    /// mode cannot describe it. `nil` when the server has no real dimensions,
    /// in which case the slide falls back to the post's mode.
    var aspectRatio: Double? {
        if let ar, ar > 0, ar.isFinite { return ar }
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case imageUrl = "image_url"
        case videoUrl = "video_url"
        case width
        case height
        case ar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        imageUrl = try? c.decodeIfPresent(String.self, forKey: .imageUrl)
        videoUrl = try? c.decodeIfPresent(String.self, forKey: .videoUrl)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        ar = try? c.decodeIfPresent(Double.self, forKey: .ar)
    }
}

/// Response of GET /resolve/{id}: a media lease with an explicit expiry.
struct ResolveResponse: Decodable {
    let url: String?
    let cover: String?
    let width: Int?
    let height: Int?
    let images: [String]
    let slides: [SlideResponse]?
    let music: String?
    let mediaType: Int?
    let expiresAt: Double?
    let ttlSeconds: Int64?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
        slides = try? c.decodeIfPresent([SlideResponse].self, forKey: .slides)
        music = try? c.decodeIfPresent(String.self, forKey: .music)
        mediaType = try? c.decodeIfPresent(Int.self, forKey: .mediaType)
        if let exp = (try? c.decodeIfPresent(Int64.self, forKey: .expiresAt)) ?? (try? c.decodeIfPresent(Int64.self, forKey: .expiresAtSnake)) {
            expiresAt = Double(exp)
        } else if let expDouble = (try? c.decodeIfPresent(Double.self, forKey: .expiresAt)) ?? (try? c.decodeIfPresent(Double.self, forKey: .expiresAtSnake)) {
            expiresAt = expDouble
        } else {
            expiresAt = nil
        }
        if let intVal = try? c.decodeIfPresent(Int64.self, forKey: .ttlSeconds) {
            ttlSeconds = intVal
        } else if let doubleVal = try? c.decodeIfPresent(Double.self, forKey: .ttlSeconds) {
            ttlSeconds = Int64(doubleVal)
        } else {
            ttlSeconds = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case url, cover, width, height, images, slides, music, mediaType = "media_type", expiresAt, expiresAtSnake = "expires_at", ttlSeconds
    }
}
