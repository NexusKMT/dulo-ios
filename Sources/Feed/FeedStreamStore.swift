import Foundation
import SwiftUI

struct FeedStreamItem: Identifiable {
    let streamId: Int64
    let video: VideoItem

    var id: Int64 { streamId }
}

/// Mutable state shared between the vertical pager (UIKit) and the SwiftUI
/// pages: the growing stream, which page is active, scene phase, and the
/// keep-awake votes. Pages observe this store, so UIKit-driven changes
/// re-render SwiftUI.
@MainActor
final class FeedStreamStore: ObservableObject {
    @Published private(set) var items: [FeedStreamItem] = []
    @Published var activeStreamId: Int64 = 0
    @Published var sceneActive = true

    /// Stream ids of pages that currently demand the display stay awake.
    @Published private(set) var keepAwakeVotes: Set<Int64> = []

    private let queue: ShuffledVideoQueue
    private var nextStreamId: Int64 = 0

    init(videos: [VideoItem]) {
        precondition(!videos.isEmpty)
        queue = ShuffledVideoQueue(videos: videos)
        seed()
    }

    /// First page plus one prepared neighbour, mirroring the Android seed.
    private func seed() {
        items.append(FeedStreamItem(streamId: nextStreamId, video: queue.next()))
        nextStreamId += 1
        if queue.itemsCount > 1 {
            items.append(FeedStreamItem(streamId: nextStreamId, video: queue.next()))
            nextStreamId += 1
        }
        activeStreamId = items[0].streamId
    }

    /// Extends the stream when the user nears its end; existing pages keep
    /// their order for back-swipes.
    func appendNextIfNeeded(near index: Int) {
        guard index >= items.count - 2 else { return }
        items.append(FeedStreamItem(streamId: nextStreamId, video: queue.next()))
        nextStreamId += 1
    }

    func setKeepAwake(_ awake: Bool, for streamId: Int64) {
        if awake {
            keepAwakeVotes.insert(streamId)
        } else {
            keepAwakeVotes.remove(streamId)
        }
    }

    var keepAwake: Bool { !keepAwakeVotes.isEmpty }
}
