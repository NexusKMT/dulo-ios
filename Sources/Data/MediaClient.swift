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
    func listVideos(baseUrl: String) async throws -> [VideoItem] {
        let base = try Self.serverBase(baseUrl)
        let manifestUrl = base.appendingPathComponent("manifest.json")
        let (data, response) = try await session.data(from: manifestUrl)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MediaException("获取媒体清单异常: HTTP \(http.statusCode)")
        }
        let manifest = try JSONDecoder().decode(ManifestResponse.self, from: data)
        if manifest.schemaVersion != 1 {
            throw MediaException("媒体清单版本不支持: \(manifest.schemaVersion)")
        }
        return manifest.items.map { VideoItem(id: $0.id, title: $0.title) }
    }

    /// Asks the server for `id`'s media lease: a play URL for videos, an image
    /// list for posts. `force` bypasses the server cache after a CDN 403.
    func resolveMedia(baseUrl: String, id: String, force: Bool = false) async -> MediaResolution {
        let base: URL
        do {
            base = try Self.serverBase(baseUrl)
        } catch {
            return .internalFailure
        }
        var url = base.appendingPathComponent("resolve").appendingPathComponent(id)
        if force {
            url = url.appendingQueryItems([URLQueryItem(name: "force", value: "1")])
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            return .networkFailure
        }
        guard let http = response as? HTTPURLResponse else {
            return .networkFailure
        }
        if http.statusCode == 404 { return .notFound }
        if !(200...299).contains(http.statusCode) { return .httpFailure(statusCode: http.statusCode) }
        let body: ResolveResponse
        do {
            body = try JSONDecoder().decode(ResolveResponse.self, from: data)
        } catch {
            return .invalidResponse
        }
        let media: ResolvedMedia
        if !body.images.isEmpty {
            media = .images(urls: body.images, music: body.music)
        } else if let playUrl = body.url, !playUrl.isEmpty {
            media = .video(url: playUrl)
        } else {
            return .notFound
        }
        let ttlSeconds = max(body.ttlSeconds ?? Self.defaultTtlSeconds, 1)
        return .ready(Lease(media, expiresAtElapsedMs: monotonicNowMs() + ttlSeconds * 1000))
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
