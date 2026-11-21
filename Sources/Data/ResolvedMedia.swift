/// What a resolved identity actually contains: a video stream or an image post.
enum ResolvedMedia {
    case video(url: String)

    /// `music` is the post's background track; it loops while the images show.
    case images(urls: [String], music: String?)
}
