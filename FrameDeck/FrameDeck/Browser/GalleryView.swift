import SwiftUI

/// 上に大きなプレビュー、下にサムネイルのストリップ。素材をざっと見ていく用。
struct GalleryView: View {
    @ObservedObject var store: DirectoryStore
    let onActivate: (FileItem) -> Void

    private let stripHeight: CGFloat = 128
    private let stripThumbSize: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            stage
            Divider()
            strip
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: store.visibleItems.count) { _, _ in selectFirstIfNeeded() }
    }

    /// ギャラリーは選択がないと大きな余白になるだけなので、先頭を選んでおく
    private func selectFirstIfNeeded() {
        guard store.selectedIDs.isEmpty, let first = store.visibleItems.first else { return }
        store.select(first)
    }

    @ViewBuilder
    private var stage: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12)
            if let item = store.selectedItem {
                VStack(spacing: 10) {
                    ThumbnailImage(item: item, size: 512)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 10) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(item.typeLabel)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let size = item.displaySize {
                            Text(Fmt.bytes(size))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .padding(18)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onActivate(item) }
            } else {
                Text("項目を選択するとここに表示されます")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(store.visibleItems) { item in
                        let selected = store.selectedIDs.contains(item.id)
                        VStack(spacing: 4) {
                            ThumbnailImage(item: item, size: stripThumbSize)
                                .frame(width: stripThumbSize, height: stripThumbSize)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                                )
                            Text(item.name)
                                .font(.system(size: 9))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: stripThumbSize)
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        }
                        .id(item.id)
                        .contentShape(Rectangle())
                        .fileClickGesture(select: { store.select(item, extending: $0) }, activate: { onActivate(item) })
                        .contextMenu { FileContextMenu(urls: [item.url]) }
                    }
                }
                .padding(10)
            }
            .frame(height: stripHeight)
            .onChange(of: store.selection) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}
