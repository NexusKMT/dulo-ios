import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit

/// AVPlayerLayer host for the zero-UI feed. The layer stays inside bounds via
/// the container's own layout, so the SwiftUI resize mode maps 1:1 onto it.
/// Supports `onReadyForDisplay` callback fired the moment hardware decoder renders frame 0.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var isHidden: Bool = false
    var onReadyForDisplay: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var onReadyForDisplay: (() -> Void)?
        var observer: NSKeyValueObservation?
    }

    func makeUIView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.backgroundColor = .black
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.isHidden = isHidden
        CATransaction.commit()

        context.coordinator.onReadyForDisplay = onReadyForDisplay
        context.coordinator.observer = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            if layer.isReadyForDisplay {
                Task { @MainActor in
                    context.coordinator.onReadyForDisplay?()
                }
            }
        }
        return view
    }

    func updateUIView(_ view: PlayerLayerContainer, context: Context) {
        context.coordinator.onReadyForDisplay = onReadyForDisplay
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
            context.coordinator.observer = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                if layer.isReadyForDisplay {
                    Task { @MainActor in
                        context.coordinator.onReadyForDisplay?()
                    }
                }
            }
        }
        if view.playerLayer.videoGravity != videoGravity {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.playerLayer.videoGravity = videoGravity
            CATransaction.commit()
        }
        if view.isHidden != isHidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.isHidden = isHidden
            CATransaction.commit()
        }
    }

    final class PlayerLayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

#elseif canImport(AppKit)
import AppKit

/// macOS twin, used only for local type-checking with CommandLineTools.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var isHidden: Bool = false
    var onReadyForDisplay: (() -> Void)? = nil

    func makeNSView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: PlayerLayerContainer, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.isHidden = isHidden
    }

    final class PlayerLayerContainer: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            layer = playerLayer
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
#endif
