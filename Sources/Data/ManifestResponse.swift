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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case title, id }
}

/// Response of GET /resolve/{id}: a media lease with an explicit expiry.
/// `expiresAt` is carried by the server but the client drives renewal off
/// `ttlSeconds`, matching the Android client's behaviour.
struct ResolveResponse: Decodable {
    let url: String?
    let images: [String]
    let music: String?
    let ttlSeconds: Int64?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
        music = try? c.decodeIfPresent(String.self, forKey: .music)
        if let intVal = try? c.decodeIfPresent(Int64.self, forKey: .ttlSeconds) {
            ttlSeconds = intVal
        } else if let doubleVal = try? c.decodeIfPresent(Double.self, forKey: .ttlSeconds) {
            ttlSeconds = Int64(doubleVal)
        } else {
            ttlSeconds = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case url, images, music, ttlSeconds }
}
