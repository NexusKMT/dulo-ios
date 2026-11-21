import AVFoundation
import Foundation

/// Douyin CDN rejects requests without a browser UA + Referer (403).
/// Media lease minting goes through `MediaClient`; player bytes go through
/// AVURLAsset with these headers injected on every request.
enum PlayerFactory {
    static let douyinUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36"
    static let douyinReferer = "https://www.douyin.com/"

    static let httpHeaders = [
        "User-Agent": douyinUA,
        "Referer": douyinReferer,
    ]

    /// One item per prepare; the asset carries the CDN headers. Resuming after
    /// a lease renewal replaces the item, never mutates the old one.
    static func makeItem(url: String) -> AVPlayerItem {
        let asset = AVURLAsset(
            url: URL(string: url)!,
            options: [AVURLAssetHTTPHeaderFieldsKey: httpHeaders]
        )
        return AVPlayerItem(asset: asset)
    }

    /// Deterministic 403 detection before playback: a one-byte ranged GET
    /// with the CDN headers. AVFoundation hides HTTP status codes in its
    /// errors, so the renewal path keys off this instead of error parsing.
    static func preflightStatus(url: String) async -> Int? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        for (key, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }
}
