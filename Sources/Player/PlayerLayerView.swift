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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        // NEVER set view.isHidden = true! isHidden suspends CoreAnimation decoding.
        // Use alpha for smooth micro-fade so hardware decoder pushes frame 0 immediately.
        view.alpha = isHidden ? 0.0 : 1.0
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.playerLayer.player = player
            CATransaction.commit()

            context.coordinator.observer?.invalidate()
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
        let targetAlpha: CGFloat = isHidden ? 0.0 : 1.0
        if view.alpha != targetAlpha {
            if isHidden {
                // Instantly hide and disable actions when transitioning away so no stale frame lingers
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                view.alpha = 0.0
                CATransaction.commit()
            } else {
                // Smooth cross-fade when hardware decoder confirms frame 0 is ready
                UIView.animate(withDuration: 0.12, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                    view.alpha = 1.0
                }
            }
        }
    }

    static func dismantleUIView(_ view: PlayerLayerContainer, coordinator: Coordinator) {
        coordinator.observer?.invalidate()
        coordinator.observer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.playerLayer.player = nil
        view.alpha = 0.0
        CATransaction.commit()
    }

    final class PlayerLayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setupLayer()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupLayer()
        }

        private func setupLayer() {
            backgroundColor = .clear
            // Strip out implicit CALayer animations to prevent 250ms stretch or morph bugs
            playerLayer.actions = [
                "contents": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "opacity": NSNull(),
                "sublayers": NSNull()
            ]
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                playerLayer.frame = bounds
                CATransaction.commit()
            }
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
