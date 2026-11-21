import XCTest

/// Deterministic RNG for the queue tests, mirroring Kotlin's `Random(seed)`.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class ShuffledVideoQueueTests: XCTestCase {
    func testEveryRoundContainsTheWholeLibraryWithoutRepeats() {
        let videos = (0..<158).map { VideoItem(id: "id-\($0)", title: "Video \($0)") }
        for seed in 0..<20 {
            let queue = ShuffledVideoQueue(videos: videos, random: SplitMix64(seed: UInt64(seed)))
            var last: VideoItem?
            for _ in 0..<10 {
                let round = (0..<videos.count).map { _ in queue.next() }
                XCTAssertEqual(Set(videos), Set(round))
                if let last { XCTAssertNotEqual(last, round.first) }
                last = round.last
            }
        }
    }

    func testTwoVideosKeepAlternatingAcrossRounds() {
        let videos = [VideoItem(id: "id-a", title: "A"), VideoItem(id: "id-b", title: "B")]
        for seed in 0..<20 {
            let queue = ShuffledVideoQueue(videos: videos, random: SplitMix64(seed: UInt64(seed)))
            var last = queue.next()
            for _ in 0..<100 {
                let next = queue.next()
                XCTAssertNotEqual(last, next)
                last = next
            }
        }
    }

    func testASingleVideoRemainsAvailableAcrossRounds() {
        let video = VideoItem(id: "id-only", title: "Only video")
        let queue = ShuffledVideoQueue(videos: [video], random: SplitMix64(seed: 0))
        for _ in 0..<10 { XCTAssertEqual(video, queue.next()) }
    }
}
