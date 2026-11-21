import SwiftUI

@main
struct DuloApp: App {
    @StateObject private var viewModel = FeedViewModel()

    var body: some Scene {
        WindowGroup {
            FeedScreen(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
