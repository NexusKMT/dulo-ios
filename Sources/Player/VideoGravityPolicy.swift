import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

/// How one piece of media should occupy the feed canvas.
///
/// Contract: `dulo-ios/docs/video-layout.md`. Portrait items fill (edges are
/// cropped, accepted); landscape and square items keep their full frame and
/// letterbox. Every surface that draws media — video layer, cover image, gallery
/// image, live-photo layer — must resolve to the *same* mode for the same item,
/// otherwise the cross-fade between cover and first frame jumps.
enum MediaContentMode: Equatable {
    case fill
    case fit

    /// `aspectRatio` is `width / height`; nil or non-positive falls back to fit.
    static func resolve(aspectRatio: Double?) -> MediaContentMode {
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else {
            return .fit
        }
        return aspectRatio < 1 ? .fill : .fit
    }

    var videoGravity: AVLayerVideoGravity {
        self == .fill ? .resizeAspectFill : .resizeAspect
    }

    /// `fill` draws past the view's bounds, so every host view must clip exactly
    /// when the mode is `fill`.
    var clipsContent: Bool { self == .fill }

    #if canImport(UIKit)
    var imageContentMode: UIImageView.ContentMode {
        self == .fill ? .scaleAspectFill : .scaleAspectFit
    }
    #endif
}

/// Thin façade kept for call sites that only need the layer gravity.
enum VideoGravityPolicy {
    static func mode(forAspectRatio aspectRatio: Double?) -> MediaContentMode {
        MediaContentMode.resolve(aspectRatio: aspectRatio)
    }

    static func gravity(forAspectRatio aspectRatio: Double?) -> AVLayerVideoGravity {
        mode(forAspectRatio: aspectRatio).videoGravity
    }
}
