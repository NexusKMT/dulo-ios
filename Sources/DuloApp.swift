import SwiftUI

#if canImport(UIKit)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}
#endif

@main
struct DuloApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @StateObject private var viewModel = FeedViewModel()

    init() {
        PlayerFactory.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            FeedScreen(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
