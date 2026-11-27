/// One entry of the feed: the eternal video identity plus a display title.
/// The play URL is never part of this model — it is minted on demand by id.
struct VideoItem: Identifiable, Hashable {
    var id: String
    var title: String
    /// `width / height` from the manifest; nil when the server did not report it.
    var aspectRatio: Double?

    init(id: String = "", title: String, aspectRatio: Double? = nil) {
        self.id = id
        self.title = title
        self.aspectRatio = aspectRatio
    }
}
