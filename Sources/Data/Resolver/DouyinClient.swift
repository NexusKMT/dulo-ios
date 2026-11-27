import Foundation

// The types in this file describe what the *client* needs — media it can play —
// not what any server used to hand over.

/// Playable content for one Douyin aweme id.
enum MediaContent: Equatable {
    case video(url: URL, cover: URL?, width: Int, height: Int)

    /// A 图文 post. `slides` is never empty; `music` is the background track that
    /// loops while the slides show.
    case images(slides: [ImageSlide], music: URL?)
}

/// One slide of an image post. Live Photos carry a `motionUrl` the slide loops as
/// video instead of showing the still.
struct ImageSlide: Equatable {
    let imageUrl: URL
    let motionUrl: URL?
    /// The slide's own `width / height`, exact. `nil` when upstream omitted the
    /// dimensions — the caller then fits the slide instead of guessing.
    let aspectRatio: Double?
}

extension MediaContent {
    /// When the CDN-signed URLs inside this content stop working, read from the
    /// `x-expires` query parameter Douyin puts on them.
    ///
    /// This is the earliest expiry across every URL in the content, because one
    /// dead URL (a slide, the track, the cover) is enough to need a re-resolve.
    /// `nil` when no URL carries `x-expires`: callers should then fall back to
    /// their own horizon (30 minutes matches what Douyin signs for).
    var expiresAt: Date? {
        signedUrls.compactMap { douyinExpiry(of: $0) }.min()
    }

    /// Every URL that has to stay alive for this content to render.
    var signedUrls: [URL] {
        switch self {
        case .video(let url, let cover, _, _):
            return [url] + (cover.map { [$0] } ?? [])
        case .images(let slides, let music):
            let stills = slides.map(\.imageUrl)
            let motions = slides.compactMap(\.motionUrl)
            return stills + motions + (music.map { [$0] } ?? [])
        }
    }
}

/// Resolves one Douyin aweme id into playable content, in-app.
///
/// Two transports, in order:
/// 1. the web detail endpoint — covers videos *and* image posts;
/// 2. the Android app feed — videos only, used when the web endpoint answers with
///    a risk-control block instead of data.
///
/// Nothing is cached here: every call mints fresh, expiring CDN URLs, which is
/// what the deleted server did on the app's behalf.
struct DouyinClient {
    /// Why a resolve produced no content. Kept this small on purpose: a caller
    /// either skips the post (`.notFound`) or retries later (everything else).
    enum Failure: Error, Equatable {
        case notFound
        case network
        case http(Int)
        case malformed
    }

    static let shared = DouyinClient()

    /// 12 s: when the endpoint answers at all it answers in well under a second.
    static let requestTimeout: TimeInterval = 12

    /// A current desktop Chrome. Douyin rejects older shared identities on the
    /// detail endpoint, and the UA has to match the Origin/Referer pair below.
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    /// The app identity the mobile feed endpoint expects.
    static let appUserAgent = "com.ss.android.ugc.aweme/300201 (Linux; U; Android 13; "
        + "zh_CN; Pixel 7; Build/TQ3A.230805.001)"

    /// The app-feed mirror, primary host first, then its twin.
    static let feedHosts = ["aweme.snssdk.com", "api5-normal-c-lf.amemv.com"]

    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    init() {
        self.init(session: URLSession(configuration: Self.makeConfiguration()))
    }

    /// Resolves `awemeId` into playable content.
    ///
    /// - Throws: `Failure` for any outcome that is not content. A cancelled task
    ///   surfaces as `CancellationError` rather than `.network`, so a caller can
    ///   tell "the page scrolled away" from "Douyin is unreachable".
    func content(for awemeId: String) async throws -> MediaContent {
        do {
            return try await contentFromDetail(awemeId: awemeId)
        } catch let primary as Failure {
            // The mirror never carries image posts, but for videos it is the only
            // path left once the web endpoint starts answering with a block.
            do {
                return try await contentFromFeed(awemeId: awemeId)
            } catch {
                throw primary
            }
        }
    }

    // MARK: - Transports

    private func contentFromDetail(awemeId: String) async throws -> MediaContent {
        let request = try Self.detailRequest(awemeId: awemeId)
        let data = try await fetch(request)
        return try Self.content(fromDetail: data)
    }

    private func contentFromFeed(awemeId: String) async throws -> MediaContent {
        var lastFailure = Failure.notFound
        for host in Self.feedHosts {
            do {
                let request = try Self.feedRequest(awemeId: awemeId, host: host)
                let data = try await fetch(request)
                return try Self.content(fromFeed: data, awemeId: awemeId)
            } catch let failure as Failure {
                lastFailure = failure
            } catch {
                throw error // Cancellation: do not try the next host.
            }
        }
        throw lastFailure
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.network
        }
        guard http.statusCode == 200 else {
            throw Failure.http(http.statusCode)
        }
        return data
    }

    // MARK: - Request shape
    //
    // Internal, not private: `DouyinClientTests` asserts the exact shape here,
    // because getting it wrong is what makes the endpoint answer 403.

    static func detailRequest(awemeId: String) throws -> URLRequest {
        guard isPlausible(awemeId: awemeId) else { throw Failure.notFound }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.douyin.com"
        components.path = "/aweme/v1/web/aweme/detail/"
        // Exactly two parameters. The browser client's device_platform /
        // version_code / screen_width set is what trips the Argus gate.
        components.queryItems = [
            URLQueryItem(name: "aweme_id", value: awemeId),
            URLQueryItem(name: "aid", value: "6383"),
        ]
        guard let url = components.url else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        // No cookies, no signature: this is the anonymous slim form.
        request.setValue(webUserAgent, forHTTPHeaderField: "user-agent")
        request.setValue("https://open.douyin.com", forHTTPHeaderField: "origin")
        request.setValue("https://open.douyin.com", forHTTPHeaderField: "referer")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    static func feedRequest(awemeId: String, host: String) throws -> URLRequest {
        guard isPlausible(awemeId: awemeId) else { throw Failure.notFound }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/aweme/v1/feed/"
        // Here the device parameters *are* the identity we claim: the Android app.
        components.queryItems = [
            URLQueryItem(name: "aweme_id", value: awemeId),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "aid", value: "1128"),
            URLQueryItem(name: "version_code", value: "300201"),
            URLQueryItem(name: "device_platform", value: "android"),
            URLQueryItem(name: "os", value: "android"),
        ]
        guard let url = components.url else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue(appUserAgent, forHTTPHeaderField: "user-agent")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        // Signed URLs expire and cookies are the identity the WAF validates, so
        // this session keeps neither: every resolve is a fresh mint.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // There is no local-network prompt on this path: fail fast when offline.
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        return configuration
    }

    static func isPlausible(awemeId: String) -> Bool {
        !awemeId.isEmpty && awemeId.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter) }
    }

    // MARK: - Decoding
    //
    // Internal, not private: these are the pure seams `DouyinClientTests` drives
    // with fixture bodies. The DTOs they decode stay private to this file.

    /// Maps a `/aweme/v1/web/aweme/detail/` body onto content.
    static func content(fromDetail data: Data) throws -> MediaContent {
        let envelope: DetailEnvelope
        do {
            envelope = try JSONDecoder().decode(DetailEnvelope.self, from: data)
        } catch {
            throw Failure.malformed
        }
        // A 200 whose body has no `status_code` is Douyin's soft block: the
        // identity is burnt, the aweme is not gone. Nothing usable in the body.
        guard let statusCode = envelope.statusCode else { throw Failure.notFound }
        guard statusCode == 0 else { throw Failure.notFound }
        guard let aweme = envelope.awemeDetail else { throw Failure.notFound }
        return try media(from: aweme)
    }

    /// Maps a `/aweme/v1/feed/` body onto content for exactly `awemeId`.
    static func content(fromFeed data: Data, awemeId: String) throws -> MediaContent {
        let envelope: FeedEnvelope
        do {
            envelope = try JSONDecoder().decode(FeedEnvelope.self, from: data)
        } catch {
            throw Failure.malformed
        }
        guard let statusCode = envelope.statusCode, statusCode == 0 else { throw Failure.notFound }
        guard let entries = envelope.awemeList else { throw Failure.notFound }
        // `count=1` is a hint, not a contract: match on the id instead of taking
        // the first entry, which may be a recommendation.
        guard let entry = entries.first(where: { $0.awemeId == awemeId }) else {
            throw Failure.notFound
        }
        guard let video = entry.video, let content = videoContent(video) else {
            throw Failure.notFound
        }
        return content
    }

    private static func media(from aweme: Aweme) throws -> MediaContent {
        // An image post sometimes carries a `video` block (the rendered track);
        // images win, exactly like the post's own player does.
        let slides = (aweme.images ?? []).compactMap { slide(from: $0) }
        if !slides.isEmpty {
            let music = aweme.music?.playUrl?.urlList?.first.flatMap { URL(string: $0) }
            return .images(slides: slides, music: music)
        }
        if let video = aweme.video, let content = videoContent(video) {
            return content
        }
        throw Failure.notFound
    }

    private static func videoContent(_ video: Video) -> MediaContent? {
        guard let url = playURL(of: video) else { return nil }
        let cover = firstURL([video.originCover, video.dynamicCover, video.cover])
        return .video(
            url: url,
            cover: cover,
            width: video.width ?? 0,
            height: video.height ?? 0
        )
    }

    private static func slide(from image: Image) -> ImageSlide? {
        guard let raw = image.urlList?.first, !raw.isEmpty, let url = URL(string: raw) else {
            return nil
        }
        let motion = image.video?.playAddr?.urlList?.first.flatMap { URL(string: $0) }
        return ImageSlide(
            imageUrl: url,
            motionUrl: motion,
            aspectRatio: aspectRatio(width: image.width, height: image.height)
        )
    }

    /// A slide's own geometry from its real pixel size. Exact, not quantized: the
    /// one decision the app makes from it is fit-vs-fill at ratio 1.
    private static func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    /// Highest-bitrate non-H.265 rendition, else `video.play_addr`.
    private static func playURL(of video: Video) -> URL? {
        let renditions: [Rendition] = (video.bitRate ?? []).compactMap { stream -> Rendition? in
            guard let raw = stream.playAddr?.urlList?.first,
                  !raw.isEmpty,
                  let url = URL(string: raw) else { return nil }
            let flagged = stream.isH265 ?? false
            return Rendition(
                url: url,
                isH265: flagged || looksLikeH265(url: raw, gearName: stream.gearName),
                bitRate: stream.bitRate ?? 0
            )
        }
        let ordered = renditions.sorted { lhs, rhs in
            if lhs.isH265 != rhs.isH265 { return !lhs.isH265 }
            if lhs.bitRate != rhs.bitRate { return lhs.bitRate > rhs.bitRate }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
        if let best = ordered.first { return best.url }
        guard let raw = video.playAddr?.urlList?.first, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Douyin flags H.265 in the bitrate record, but not always: the rendition's
    /// own URL and gear name carry it too (`bytevc1` is Douyin's H.265 name).
    private static func looksLikeH265(url: String, gearName: String?) -> Bool {
        let haystack = (url + " " + (gearName ?? "")).lowercased()
        return haystack.contains("h265") || haystack.contains("hvc1") || haystack.contains("bytevc1")
    }

    private static func firstURL(_ holders: [URLList?]) -> URL? {
        for holder in holders {
            if let raw = holder?.urlList?.first, !raw.isEmpty, let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }

    private struct Rendition {
        let url: URL
        let isH265: Bool
        let bitRate: Int64
    }
}

// MARK: - Expiry

/// Reads Douyin's `x-expires` (epoch seconds) off a signed CDN URL.
private func douyinExpiry(of url: URL) -> Date? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let raw = components.queryItems?.first(where: { $0.name == "x-expires" })?.value,
          let seconds = Double(raw),
          seconds.isFinite,
          seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

// MARK: - Wire format (private to this file)
//
// Every field Douyin may omit, renumber or return as a string is read leniently:
// one unexpected field type must not turn a resolvable post into `.malformed`.

private struct DetailEnvelope: Decodable {
    let statusCode: Int?
    let awemeDetail: Aweme?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = container.lenientInt(.statusCode)
        awemeDetail = try? container.decode(Aweme.self, forKey: .awemeDetail)
    }

    private enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case awemeDetail = "aweme_detail"
    }
}

private struct FeedEnvelope: Decodable {
    let statusCode: Int?
    let awemeList: [Aweme]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = container.lenientInt(.statusCode)
        awemeList = try? container.decode([Aweme].self, forKey: .awemeList)
    }

    private enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case awemeList = "aweme_list"
    }
}

private struct Aweme: Decodable {
    let awemeId: String?
    let video: Video?
    let images: [Image]?
    let music: Music?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        awemeId = container.lenientString(.awemeId)
        video = try? container.decode(Video.self, forKey: .video)
        images = try? container.decode([Image].self, forKey: .images)
        music = try? container.decode(Music.self, forKey: .music)
    }

    private enum CodingKeys: String, CodingKey {
        case awemeId = "aweme_id"
        case video, images, music
    }
}

private struct Video: Decodable {
    let width: Int?
    let height: Int?
    let bitRate: [BitRate]?
    let playAddr: URLList?
    let originCover: URLList?
    let dynamicCover: URLList?
    let cover: URLList?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = container.lenientInt(.width)
        height = container.lenientInt(.height)
        bitRate = try? container.decode([BitRate].self, forKey: .bitRate)
        playAddr = try? container.decode(URLList.self, forKey: .playAddr)
        originCover = try? container.decode(URLList.self, forKey: .originCover)
        dynamicCover = try? container.decode(URLList.self, forKey: .dynamicCover)
        cover = try? container.decode(URLList.self, forKey: .cover)
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, cover
        case bitRate = "bit_rate"
        case playAddr = "play_addr"
        case originCover = "origin_cover"
        case dynamicCover = "dynamic_cover"
    }
}

private struct BitRate: Decodable {
    let bitRate: Int64?
    let gearName: String?
    let isH265: Bool?
    let playAddr: URLList?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bitRate = container.lenientInt64(.bitRate)
        gearName = container.lenientString(.gearName)
        isH265 = container.lenientBool(.isH265)
        playAddr = try? container.decode(URLList.self, forKey: .playAddr)
    }

    private enum CodingKeys: String, CodingKey {
        case bitRate = "bit_rate"
        case gearName = "gear_name"
        case isH265 = "is_h265"
        case playAddr = "play_addr"
    }
}

private struct Image: Decodable {
    let urlList: [String]?
    let width: Int?
    let height: Int?
    /// Present on Live Photos: the motion clip the slide loops.
    let video: Video?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlList = container.stringArray(.urlList)
        width = container.lenientInt(.width)
        height = container.lenientInt(.height)
        video = try? container.decode(Video.self, forKey: .video)
    }

    private enum CodingKeys: String, CodingKey {
        case urlList = "url_list"
        case width, height, video
    }
}

private struct Music: Decodable {
    let playUrl: URLList?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playUrl = try? container.decode(URLList.self, forKey: .playUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case playUrl = "play_url"
    }
}

/// The `{ "url_list": [...] }` shape every CDN reference uses — covers, covers'
/// motion twins, play addresses, music, slide images.
private struct URLList: Decodable {
    let urlList: [String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlList = container.stringArray(.urlList)
    }

    private enum CodingKeys: String, CodingKey {
        case urlList = "url_list"
    }
}

private extension KeyedDecodingContainer {
    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func lenientInt64(_ key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int64(value) }
        if let value = try? decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    /// `is_h265` arrives as `true`, as `1`, and (sometimes) as `"1"`.
    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return nil
    }

    /// `aweme_id` is a string in the web payload and a number in some mirrors.
    func lenientString(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    func stringArray(_ key: Key) -> [String]? {
        try? decode([String].self, forKey: key)
    }
}

// MARK: - Request shape, and why it looks like this
//
// The web endpoint is called in its *slim* form: `aweme_id` + `aid=6383` only,
// with a current desktop Chrome UA and an `open.douyin.com` Origin/Referer. That
// combination is served anonymously. Asking the same endpoint the way the
// browser client does — the full `device_platform` / `version_code` /
// `screen_width` / `browser_version` parameter set, or presenting cookies — is
// what makes ArgusSecurityPlugin reject the call with `403 Uifid Not Found`,
// because those parameters promise a signed web session we do not have. So we
// send no cookies, no `X-Bogus`/`a_bogus` signature, and no device parameters;
// the `URLSession` is cookie-less and cache-less (signed URLs expire, cookies are
// the identity the WAF validates). The app-feed fallback is the opposite case:
// there the Android app parameters *are* the identity we claim, so they stay —
// and that transport returns videos only, never 图文.
//
// MARK: - Integration notes
//
// The FastAPI service is being deleted; Caddy will serve `/manifest.json` and
// front the two POST sinks. These are the call sites that must change, and what
// each one becomes. Nothing in this file touches them.
//
// 1. `FeedViewModel.resolveMedia(id:force:priority:)` (Sources/Feed/FeedViewModel.swift)
//    becomes `func content(for id: String, force: Bool = false) async -> Result<MediaContent, DouyinClient.Failure>`
//    backed by `DouyinClient.shared.content(for:)`:
//    - keep the in-flight singleflight map and the LRU cache — both are client
//      concerns and stay; retype the cache from `LeaseLruCache<ResolvedMedia>` to
//      `LeaseLruCache<MediaContent>`;
//    - `force` now means "ignore my own cache" only, since there is no server
//      cache left to bypass;
//    - the freshness horizon comes from `MediaContent.expiresAt` (the `x-expires`
//      of the signed URLs), falling back to 30 minutes when it is nil; the 60 s
//      renewal margin stays as is;
//    - `priority` (0 = VIP, 1 = prewarm) existed only to order the server's queue.
//      Drop it: prewarming is just resolving early, and the callers already decide
//      when that happens.
//
// 2. `FeedScreen` dislike (`FeedDebugHUD.recordDislike(_:)`, Sources/Feed/FeedScreen.swift)
//    keeps the same POST — `POST {assetsBase}/dislike/{id}` — but it now lands on
//    the Caddy sink instead of FastAPI, so the HUD code itself does not change.
//    While that file is open, move the inline `URLSession.shared.data(for:)` into
//    a `MediaClient.postDislike(id:)` so the endpoint lives in one place.
//
// 3. `AppSettings.serverBaseUrl` (Sources/Data/AppSettings.swift) stops being a
//    resolve backend. Rename it to `assetsBaseUrl` (its only jobs from now on:
//    `/manifest.json` and the two POST sinks), and note that the comments around
//    the old value — "the manifest server" — are still true only for those three
//    routes. No behaviour change: same host, Caddy on 80/443 in front.
//
// 4. `RemoteTelemetryExporter` (Sources/Data/Telemetry/RemoteTelemetryExporter.swift,
//    lines 73 and 91) builds `\(AppSettings.serverBaseUrl)/api/telemetry` twice.
//    The path and body stay identical; only the constant rename in (3) applies,
//    plus a comment that the route is now a Caddy reverse proxy to a tiny sink.
//
// Delete along with the server: `MediaClient.resolveMedia` (server response
// shape), `ResolveResponse` and `SlideResponse` (pure wire mirrors, in
// ManifestResponse.swift), and `MediaResolution` (its `.internalFailure` /
// `.cancelled` cases exist to translate the server's answers). `ResolvedMedia`
// and `GallerySlide` are the same kind of artifact — string URLs, plus a `id`
// field whose only job was to be a server-side cache hint — and can go once
// `VerticalPager` renders `MediaContent`/`ImageSlide` directly; `VerticalPager`
// is not edited here. `Lease` is *almost* client-side: `expiresAt`/`isFresh` are
// genuine, but `expiresAtElapsedMs` and `isFresh(nowElapsedMs:)` only exist
// because the server sent `ttlSeconds`, so drop those overloads with the rest.
// `LeaseLruCache` is client-side and stays.
//
// One thing not carried over from the server: its pacing and cooldown (minimum
// 800 ms between calls, exponential backoff after a block). The feed fans out to
// N+1 prefetches, so tripping Argus is now the app's risk to manage — a simple
// gate in `DouyinClient` (space requests, back off on `.http(403)` / soft block)
// is the natural next step, deliberately left out of this file.
