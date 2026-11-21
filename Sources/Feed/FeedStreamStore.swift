import Foundation
import SwiftUI

struct FeedStreamItem: Identifiable {
    let streamId: Int64
    let video: VideoItem

    var id: Int64 { streamId }
}

/// Mutable state shared between the vertical pager (UIKit) and the SwiftUI
/// pages: the growing stream, which page is active, and scene phase.
/// Pages observe this store, so UIKit-driven changes re-render SwiftUI.
@MainActor
final class FeedStreamStore: ObservableObject {
    @Published private(set) var items: [FeedStreamItem] = []
    @Published var activeStreamId: Int64 = 0
    @Published var prewarmStreamId: Int64? = nil
    @Published var sceneActive = true

    private let queue: ShuffledVideoQueue<SystemRandomNumberGenerator>
    private var nextStreamId: Int64 = 0

    init(videos: [VideoItem]) {
        precondition(!videos.isEmpty)
        queue = ShuffledVideoQueue(videos: videos)
        seed()
    }

    /// First page plus prepared neighbours for N+2 preloading.
    private func seed() {
        while items.count < 3 && items.count < queue.itemsCount {
            items.append(FeedStreamItem(streamId: nextStreamId, video: queue.next()))
            nextStreamId += 1
        }
        if let first = items.first {
            activeStreamId = first.streamId
        }
        if items.count > 1 {
            prewarmStreamId = items[1].streamId
        }
    }

    /// Extends the stream when the user nears its end, maintaining an N+2 queue horizon.
    func appendNextIfNeeded(near index: Int) {
        guard index >= items.count - 3 else { return }
        items.append(FeedStreamItem(streamId: nextStreamId, video: queue.next()))
        nextStreamId += 1
    }
}
