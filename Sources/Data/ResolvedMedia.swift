import Foundation

public struct GallerySlide: Identifiable, Hashable, Equatable {
    public let id: String
    public let imageUrl: String
    public let motionVideoUrl: String?

    public init(id: String, imageUrl: String, motionVideoUrl: String? = nil) {
        self.id = id
        self.imageUrl = imageUrl
        self.motionVideoUrl = motionVideoUrl
    }

    public var isLivePhoto: Bool { motionVideoUrl != nil }
}

/// What a resolved identity actually contains: a video stream or an image/gallery post.
public enum ResolvedMedia: Equatable {
    case video(url: String, cover: String? = nil, width: Int = 0, height: Int = 0)

    /// `music` is the post's background track; it loops while the images/slides show.
    case images(urls: [String], music: String?, slides: [GallerySlide] = [])
}
