import CryptoKit
import Foundation

/// Canonical cache key generator for media streaming URLs.
/// Solves cache key fragmentation caused by ephemeral CDN tokens (e.g. `x-expires`, `x-signature`, `dy_q`).
public enum MediaCacheKey {
    /// Computes a stable disk cache key.
    /// - Parameters:
    ///   - url: The remote video or audio URL.
    ///   - hint: An optional high-level identifier (e.g. `aweme_id` or `slide_id`).
    /// - Returns: A deterministic, filesystem-safe string identifier.
    public static func compute(url: URL, hint: String? = nil) -> String {
        if let hint = hint, !hint.isEmpty {
            // Reject naked short-number hints to prevent slide index cache collisions
            let isShortNumber = hint.allSatisfy { $0.isNumber } && hint.count <= 4
            if !isShortNumber {
                let cleanHint = hint.replacingOccurrences(of: "/", with: "_")
                return "k_\(cleanHint)"
            }
        }

        let urlString = url.absoluteString

        // 1. ByteDance TOS object path extraction (e.g. video/tos/cn/tos-cn-ve-.../ or /tos/...)
        if let tosRange = urlString.range(of: "video/tos/") ?? urlString.range(of: "tos/") {
            let sub = urlString[tosRange.lowerBound...]
            let endIdx = sub.firstIndex(of: "?") ?? sub.endIndex
            let canonicalTos = String(sub[..<endIdx]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !canonicalTos.isEmpty {
                return sha256Hex(canonicalTos)
            }
        }

        // 2. Generic media URL normalization: strip volatile query parameters
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.query = nil
            components.fragment = nil
            if let cleanUrl = components.string {
                return sha256Hex(cleanUrl)
            }
        }

        return sha256Hex(urlString)
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
