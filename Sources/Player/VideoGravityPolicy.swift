import AVFoundation

/// Rendering policy for the zero-UI feed.
///
/// Portrait content fills the canvas (edges are cropped, which is accepted);
/// landscape and square content keep `AVPlayerLayer`'s default fit so nothing is
/// lost. Both platforms are portrait-locked, so the policy depends only on the
/// item's aspect ratio and never on the canvas.
///
/// Contract: `Dulo-server/docs/video-layout.md`.
enum VideoGravityPolicy {
    /// `ar` is `width / height`, rounded to two decimals by the server.
    static func gravity(forAspectRatio aspectRatio: Double?) -> AVLayerVideoGravity {
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else {
            return .resizeAspect
        }
        return aspectRatio < 1 ? .resizeAspectFill : .resizeAspect
    }
}
