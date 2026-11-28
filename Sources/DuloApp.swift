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
        // Drains anything the previous run could not deliver; harmless if the
        // sink is unreachable.
        TelemetryUploader.shared.start()
        #if canImport(Foundation)
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let reason = exception.reason ?? "unknown reason"
            let name = exception.name.rawValue
            NSLog("[FATAL UNCAUGHT EXCEPTION] %@: %@\n%@", name, reason, stack)
            TelemetryUploader.shared.submitSynchronously(UncaughtExceptionTelemetry(
                name: name,
                reason: reason,
                callStack: stack
            ))
        }
        #endif
        // Must run before LocalMediaProxyServer touches MediaCacheStorage.
        ExperimentVariant.bootstrap()
        PlayerFactory.configureAudioSession()
        LocalMediaProxyServer.shared.start()
        PerformanceMonitor.shared.start()
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) {
            DuloMetricKitSubscriber.shared.start()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            FeedScreen(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
