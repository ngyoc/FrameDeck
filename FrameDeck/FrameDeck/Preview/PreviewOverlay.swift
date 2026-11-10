import AppKit
import SwiftUI

/// スペースキーで開く一時プレビュー。
/// 映像の明るさを正しく判断できるよう、この画面だけはダーク固定にする（要件 2.2）。
struct PreviewOverlay: View {
    @ObservedObject var model: PreviewModel
    /// 入れ子の ObservableObject は自動で伝播しないので、明示的に監視する
    @ObservedObject private var playback: PlaybackController
    let onClose: () -> Void

    init(model: PreviewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.playback = model.playback
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                content
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.10)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(model.isFullScreen ? 0 : 28)
        }
        .environment(\.colorScheme, .dark)
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.item?.kind.symbolName ?? "doc")
                .foregroundStyle(.secondary)
            Text(model.item?.name ?? "")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if playback.naturalSize != .zero {
                metaChip("\(Int(playback.naturalSize.width))x\(Int(playback.naturalSize.height))")
            }
            if playback.frameRate > 0 {
                metaChip(String(format: "%.2f fps", playback.frameRate))
            }
            if playback.hasAudio {
                metaChip("音声あり")
            } else if playback.isReady {
                metaChip("音声なし")
            }
            if let size = model.item?.size {
                metaChip(Fmt.bytes(size))
            }

            Spacer()

            Button {
                model.isFullScreen.toggle()
            } label: {
                Image(systemName: model.isFullScreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("表示を広げる（F）")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("閉じる（Esc）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var content: some View {
        if let reason = model.unsupportedReason {
            unsupportedView(reason)
        } else if let item = model.item {
            switch item.kind {
            case .video, .audio:
                MediaPreviewView(model: model)
            case .image:
                ImagePreviewView(url: item.url)
            case .folder, .other:
                unsupportedView(MediaSupport.unsupportedReason(for: item.url))
            }
        } else {
            Color.black
        }
    }

    private func unsupportedView(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let url = model.item?.url {
                Button("デフォルトのアプリで開く（⌘O）") {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color.black)
    }
}
