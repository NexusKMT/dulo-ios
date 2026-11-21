import SwiftUI

@main
struct DuloApp: App {
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
