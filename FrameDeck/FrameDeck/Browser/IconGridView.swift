import SwiftUI

struct IconGridView: View {
    @ObservedObject var store: DirectoryStore
    let onActivate: (FileItem) -> Void

    private var spacing: CGFloat { 14 }
    private var cellWidth: CGFloat { CGFloat(store.iconSize) + 24 }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth * 1.4),
                                           spacing: spacing)],
                        spacing: spacing
                    ) {
                        ForEach(store.visibleItems) { item in
                            cell(item).id(item.id)
                        }
                    }
                    .padding(spacing)
                }
                // 十字キーで選択が画面外に出ないよう追従させる
                .onChange(of: store.selection) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
            .onAppear { updateColumns(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, newValue in updateColumns(width: newValue) }
            .onChange(of: store.iconSize) { _, _ in updateColumns(width: geo.size.width) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func updateColumns(width: CGFloat) {
        let available = max(1, width - spacing * 2)
        store.iconColumnsPerRow = max(1, Int(available / (cellWidth + spacing)))
    }

    private func cell(_ item: FileItem) -> some View {
        let selected = store.selectedIDs.contains(item.id)
        return VStack(spacing: 6) {
            ThumbnailImage(item: item, size: CGFloat(store.iconSize))
                .frame(width: CGFloat(store.iconSize), height: CGFloat(store.iconSize))

            Text(item.name)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Color.accentColor : .clear)
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .padding(6)
        .frame(width: cellWidth)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
        .fileClickGesture(select: { store.select(item, extending: $0) }, activate: { onActivate(item) })
        .contextMenu { FileContextMenu(urls: [item.url]) }
    }
}

/// 一覧共通の右クリックメニュー。読み取り専用なので開く系とコピーだけ。
struct FileContextMenu: View {
    let urls: [URL]

    var body: some View {
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        Button("デフォルトのアプリで開く") { urls.forEach { NSWorkspace.shared.open($0) } }
        Divider()
        Button("パスをコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }
}
