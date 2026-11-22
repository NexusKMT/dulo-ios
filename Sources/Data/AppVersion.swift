import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

public enum AppVersion {
    public static let marketingVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.2.0"
    }()

    public static let buildNumber: String = {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "21"
    }()

    public static var displayString: String {
        "v\(marketingVersion) (\(buildNumber))"
    }

    public static var deviceModelIdentifier: String {
        #if os(iOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? "iPhone" : identifier
        #else
        return "macOS"
        #endif
    }
}
