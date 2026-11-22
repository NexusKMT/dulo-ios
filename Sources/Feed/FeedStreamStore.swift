import Foundation
import SwiftUI

struct FeedStreamItem: Identifiable {
    let streamId: Int64
    let video: VideoItem

    var id: Int64 { streamId }
}

/// Mutable state shared between the vertical pager (UIKit) and the SwiftUI
/// pages: the growing stream, which page is active, and scene phase.
/// Performance Isolation: visibleStreamIds and prewarmStreamId are non-@Published
/// to prevent 60Hz/120Hz scroll events from invalidating the SwiftUI view graph.
@MainActor
final class FeedStreamStore: ObservableObject {
    @Published private(set) var items: [FeedStreamItem] = []
    @Published var activeStreamId: Int64 = 0
    var prewarmStreamId: Int64? = nil
    var visibleStreamIds: Set<Int64> = []
    @Published var sceneActive = true

    private let queue: ShuffledVideoQueue<SystemRandomNumberGenerator>
    private var nextStreamId: Int64 = 0

    init(videos: [VideoItem]) {
        precondition(!videos.isEmpty)
        queue = ShuffledVideoQueue(videos: videos)
        seed()
    }

    /// Pre-seeds a generous buffer (e.g. 60-100 items) from the cyclic queue.
    /// Eliminates all runtime array mutations and UICollectionView insertions during scrolling.
    private func seed() {
        let initialBatch = min(100, max(40, queue.itemsCount * 5))
        for _ in 0..<initialBatch {
            items.append(FeedStreamItem(streamId: nextStreamId, video: queue.next()))
            nextStreamId += 1
        }
        if let first = items.first {
            activeStreamId = first.streamId
            visibleStreamIds = [first.streamId]
        }
        if items.count > 1 {
            prewarmStreamId = items[1].streamId
        }
    }

    /// Extends the stream in generous batches only when approaching the end of the pre-seeded buffer.
    func appendNextIfNeeded(near index: Int) {
        guard index >= items.count - 10 else { return }
        for _ in 0..<30 {
            items.append(FeedStreamItem(streamId: nextStreamId, video: queue.next()))
            nextStreamId += 1
        }
    }
}
