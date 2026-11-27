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
    /// width / height, written by `build_manifest.py`; nil for 图文 and older catalogs.
    let ar: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        ar = try? c.decodeIfPresent(Double.self, forKey: .ar)
    }

    private enum CodingKeys: String, CodingKey { case title, id, ar }
}
