import Foundation

/// The manifest server's base URL, persisted across launches.
enum AppSettings {
    static let defaultServerBaseUrl = "http://192.168.2.3:8080"
    private static let key = "serverBaseUrl"

    static var serverBaseUrl: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultServerBaseUrl }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
