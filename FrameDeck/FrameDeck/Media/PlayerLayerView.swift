import AVFoundation
import SwiftUI

/// 段階 1 の描画層（AVPlayerLayer）。
/// M4 で Metal 描画（AVPlayerItemVideoOutput + MTKView）に差し替える前提で、
/// 上位からは VideoRenderer 越しにしか触らない。
protocol VideoRenderer {
    associatedtype Body: View
    @ViewBuilder func makeView(player: AVPlayer) -> Body
}

struct PlayerLayerRenderer: VideoRenderer {
    func makeView(player: AVPlayer) -> some View {
        PlayerLayerView(player: player)
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

final class PlayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    /// 検証用。レイヤーが最初のフレームを描画できた状態かどうか。
    var isReadyForDisplay: Bool { playerLayer.isReadyForDisplay }
    var videoRect: CGRect { playerLayer.videoRect }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使用しません") }

    override func layout() {
        super.layout()
        // リサイズ時の暗黙アニメーションを止める（残像が出るため）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
