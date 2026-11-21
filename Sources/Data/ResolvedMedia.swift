/// What a resolved identity actually contains: a video stream or an image post.
enum ResolvedMedia: Equatable {
    case video(url: String, cover: String? = nil, width: Int = 0, height: Int = 0)

    /// `music` is the post's background track; it loops while the images show.
    case images(urls: [String], music: String?)
}
