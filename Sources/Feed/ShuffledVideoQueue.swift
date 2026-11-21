import Foundation

/// Each video appears once per round; consecutive rounds never repeat the
/// boundary video. Port of the Android `ShuffledVideoQueue`.
final class ShuffledVideoQueue<Random: RandomNumberGenerator> {
    private let videos: [VideoItem]
    private var random: Random
    private var remaining: [VideoItem] = []
    private var headIndex = 0
    private var lastId: String?

    var itemsCount: Int { videos.count }

    init(videos: [VideoItem], random: Random = SystemRandomNumberGenerator()) {
        precondition(!videos.isEmpty, "an empty library cannot create a queue")
        self.videos = videos
        self.random = random
    }

    func next() -> VideoItem {
        if headIndex >= remaining.count {
            remaining = videos.shuffled(using: &random)
            headIndex = 0
            if remaining.count > 1, remaining[0].id == lastId {
                let swapIndex = Int.random(in: 1..<remaining.count, using: &random)
                remaining.swapAt(0, swapIndex)
            }
        }
        let item = remaining[headIndex]
        headIndex += 1
        lastId = item.id
        return item
    }
}
