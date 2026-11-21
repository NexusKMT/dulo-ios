import AVFoundation
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The only playback state the UI-free feed needs: whether the screen should
/// stay awake, plus the natural display size (drives fit/zoom) and load
/// failures. Controls, position and scrubbing state were removed with the
/// control layer itself. Port of the Android `PlayerState`.
@MainActor
final class PlayerState: ObservableObject {
    let player: AVPlayer

    @Published private(set) var isPlaying = false
    @Published private(set) var presentationSize: CGSize = .zero

    /// Fired when the current item fails to load (mirrors ExoPlayer's
    /// `onPlayerError`).
    var onPlaybackError: ((Error?) -> Void)?

    private var timeObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?

    init() {
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true

        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }

        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusObservation?.invalidate()
                self.sizeObservation?.invalidate()
                guard let item = player.currentItem else {
                    self.presentationSize = .zero
                    return
                }
                self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    if item.status == .failed {
                        Task { @MainActor in
                            self?.onPlaybackError?(item.error)
                        }
                    }
                }
                self.sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        self?.presentationSize = item.presentationSize
                    }
                }
            }
        }
    }

    deinit {
        timeObservation?.invalidate()
        itemObservation?.invalidate()
        statusObservation?.invalidate()
        sizeObservation?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// Wide videos keep their aspect ratio (FIT); tall ones fill (ZOOM).
    /// If size is unknown (zero), default to FIT (.resizeAspect) to avoid initial zoom-in pop.
    /// On iPad, always use FIT to prevent aggressive 42%+ cropping on 4:3 displays.
    var usesFitGravity: Bool {
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return true
        }
        #endif
        if presentationSize == .zero { return true }
        return presentationSize.width > presentationSize.height
    }
}
