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

    /// Configures the iOS audio session for video playback so that sound
    /// is routed through speakers even when the device hardware mute switch is on.
    static func configureAudioSession() {
        #if canImport(AVFAudio)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            NSLog("[PlayerFactory] Failed to configure AVAudioSession: %@", error.localizedDescription)
        }
        #endif
    }

    /// One item per prepare; routed through LocalMediaProxyServer for 0ms cached
    /// streaming and chunk caching. Resuming after a lease renewal replaces the item.
    static func makeItem(url: URL, cacheKey: String? = nil) -> AVPlayerItem {
        let playbackUrl = LocalMediaProxyServer.shared.proxyUrl(for: url, cacheKey: cacheKey)
        let asset = AVURLAsset(
            url: playbackUrl,
            options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        // Set buffer duration to 3.0s to avoid high RAM footprint on low-spec hardware (2GB A9)
        item.preferredForwardBufferDuration = 3.0
        return item
    }

    /// Deterministic 403 detection before playback: a one-byte ranged GET
    /// with the CDN headers. AVFoundation hides HTTP status codes in its
    /// errors, so the renewal path keys off this instead of error parsing.
    static func preflightStatus(url: String) async -> Int? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        for (key, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }
}
