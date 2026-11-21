import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit

/// AVPlayerLayer host for the zero-UI feed. The layer stays inside bounds via
/// the container's own layout, so the SwiftUI resize mode maps 1:1 onto it.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var isHidden: Bool = false

    func makeUIView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerContainer, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
        if view.isHidden != isHidden {
            view.isHidden = isHidden
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
