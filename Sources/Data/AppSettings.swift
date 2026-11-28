import Foundation

/// Static assets (manifest) and the two append-only sinks, served by Caddy.
/// No application server sits behind this any more.
enum AppSettings {
    static let assetsBaseUrl = "http://192.168.2.3:8082"
}
