import Foundation

/// Any failure whose message is worth showing to the user verbatim.
struct MediaException: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Reads the media manifest and mints media leases from the configured HTTP
/// server. One shared URLSession for the process: Dulo has exactly one
/// destination (the manifest server).
struct MediaClient {
    static let shared = MediaClient()

    static let defaultTtlSeconds: Int64 = 600 // Pre-lease-metadata servers.

    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20 // OkHttp read timeout.
        config.httpMaximumConnectionsPerHost = 10
        config.httpShouldSetCookies = false
        // First launch may present the local-network permission alert. Without
        // this, the request is denied immediately and the feed never loads
        // until the user taps Retry.
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Parses `baseUrl` into a valid http(s) URL without trailing slash,
    /// mirroring OkHttp's `toHttpUrlOrNull`.
    private static func serverBase(_ baseUrl: String) throws -> URL {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var base = URL(string: trimmed),
              let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              base.host != nil else {
            throw MediaException("地址格式无效")
        }
        if base.path.hasSuffix("/") {
            base = base.deletingLastPathComponent()
        }
        return base
    }

    /// Loads the identity list from `{base}/manifest.json`.
    ///
    /// The manifest is a static file with an ETag, so the request revalidates
    /// instead of re-downloading 6.8 MB: a 304 replays the cached body.
    func listVideos(baseUrl: String) async throws -> [VideoItem] {
        let base = try Self.serverBase(baseUrl)
        let manifestUrl = base.appendingPathComponent("manifest.json")
        var request = URLRequest(
            url: manifestUrl,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MediaException("获取媒体清单异常: HTTP \(http.statusCode)")
        }
        let manifest = try JSONDecoder().decode(ManifestResponse.self, from: data)
        if manifest.schemaVersion != 1 {
            throw MediaException("媒体清单版本不支持: \(manifest.schemaVersion)")
        }
        return manifest.items.map { VideoItem(id: $0.id, title: $0.title, aspectRatio: $0.ar) }
    }

}

private extension URL {
    func appendingQueryItems(_ queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var existing = components?.queryItems ?? []
        existing.append(contentsOf: queryItems)
        components?.queryItems = existing
        return components?.url ?? self
    }
}
