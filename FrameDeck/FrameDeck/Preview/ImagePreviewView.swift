import SwiftUI

struct ImagePreviewView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(12)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text("画像を読み込めませんでした")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = nil
            failed = false
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            if let loaded {
                image = loaded
            } else {
                failed = true
                Log.media.warning("画像の読み込みに失敗: \(url.lastPathComponent, privacy: .public)")
            }
        }
    }
}
