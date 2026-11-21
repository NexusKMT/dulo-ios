/// One entry of the feed: the eternal video identity plus a display title.
/// The play URL is never part of this model — it is minted on demand by id.
struct VideoItem: Identifiable, Hashable {
    var id: String
    var title: String

    init(id: String = "", title: String) {
        self.id = id
        self.title = title
    }
}
