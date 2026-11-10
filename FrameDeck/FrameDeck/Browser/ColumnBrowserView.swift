import SwiftUI

/// カラム表示。フォルダを選ぶと右に列が増えていく Finder と同じ挙動。
/// 階層と選択は ColumnBrowserState が持つので、十字キーからも操作できる。
struct ColumnBrowserView: View {
    @ObservedObject var store: DirectoryStore
    @ObservedObject var state: ColumnBrowserState
    let onActivate: (FileItem) -> Void

    private let previewWidth: CGFloat = 260
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 0) {
                        ForEach(Array(state.chain.enumerated()), id: \.element) { index, url in
                            ColumnPane(state: state, index: index, directory: url, onActivate: onActivate)
                                .frame(width: state.width(for: url))
                                .id(url)
                            columnResizeHandle(for: url)
                        }
                        if let leaf = state.activeItem, !leaf.isDirectory {
                            ColumnPreviewPane(item: leaf, onActivate: onActivate)
                                .frame(width: previewWidth)
                            Divider()
                        }
                        // Finder と同じく、右側の余りは空の列で埋める
                        ForEach(0..<filler(availableWidth: geo.size.width), id: \.self) { _ in
                            Color.clear.frame(width: ColumnBrowserState.defaultWidth)
                            Divider()
                        }
                    }
                }
                .onChange(of: state.chain) { _, newValue in
                    guard let last = newValue.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            state.reset(to: store.url)
            ListFocus.suppressColumnHighlightsSoon()
        }
        .onChange(of: store.url) { _, newValue in
            state.reset(to: newValue)
            ListFocus.suppressColumnHighlightsSoon()
        }
        .onChange(of: state.chain) { _, _ in ListFocus.suppressColumnHighlightsSoon() }
        .onChange(of: state.focusedIndex) { _, _ in ListFocus.suppressColumnHighlightsSoon() }
        .onChange(of: sortKey) { _, _ in state.reapplySort() }
    }

    /// 列の右端の仕切り。ドラッグで幅を変える。⌥ドラッグで全列を同じ幅にする。
    private func columnResizeHandle(for url: URL) -> some View {
        Divider()
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = state.width(for: url) }
                                guard let start = dragStartWidth else { return }
                                let newWidth = start + value.translation.width
                                if NSEvent.modifierFlags.contains(.option) {
                                    state.applyWidthToAll(newWidth)
                                } else {
                                    state.setWidth(newWidth, for: url)
                                }
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .onTapGesture(count: 2) {
                        // ダブルクリックでいちばん長い名前に合わせる
                        state.setWidth(idealWidth(for: url), for: url)
                    }
            )
    }

    /// その列でいちばん長いファイル名が収まる幅の目安
    private func idealWidth(for url: URL) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let longest = state.items(in: url)
            .map { ($0.name as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? ColumnBrowserState.defaultWidth
        // アイコン・矢印・余白のぶんを足す
        return min(ColumnBrowserState.maximumWidth, longest + 60)
    }

    private var sortKey: String {
        "\(store.sortField.rawValue)|\(store.sortAscending)|\(store.foldersFirst)|\(store.showsHiddenFiles)"
    }

    /// 余白を埋めるための空列の本数
    private func filler(availableWidth: CGFloat) -> Int {
        let hasPreview = state.activeItem.map { !$0.isDirectory } ?? false
        let used = state.chain.reduce(CGFloat(0)) { $0 + state.width(for: $1) }
            + (hasPreview ? previewWidth : 0)
        let remaining = availableWidth - used
        guard remaining > 0 else { return 0 }
        return Int(remaining / ColumnBrowserState.defaultWidth) + 1
    }
}

/// 1 列ぶんのファイル一覧
private struct ColumnPane: View {
    @ObservedObject var state: ColumnBrowserState
    let index: Int
    let directory: URL
    let onActivate: (FileItem) -> Void

    var body: some View {
        let items = state.items(in: directory)

        Group {
            if let message = state.error(for: directory) {
                VStack(spacing: 8) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.isLoading(directory), items.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 行にタップジェスチャを付けると List 本来の選択処理を奪ってしまうので、
                // 選択もダブルクリックも List 標準の仕組みに任せる。
                List(items, selection: selectionBinding) { item in
                    let isSelected = state.selectionSet(in: directory).contains(item.id)
                    HStack(spacing: 6) {
                        Image(systemName: item.kind.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.white : tint(for: item.kind))
                            .frame(width: 14)
                        Text(item.name)
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        if item.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                        }
                    }
                    // 選択の色は自前で塗る。システム任せだとフォーカスの無い列がグレーになるため。
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .padding(.horizontal, 4)
                    )
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: FileItem.ID.self) { ids in
                    if !ids.isEmpty { FileContextMenu(urls: Array(ids)) }
                } primaryAction: { ids in
                    guard let id = ids.first, let item = items.first(where: { $0.id == id }) else { return }
                    onActivate(item)
                }
            }
        }
    }

    /// 複数選択に対応させる（⌘クリックで追加、⇧クリックで範囲）
    private var selectionBinding: Binding<Set<FileItem.ID>> {
        Binding(
            get: { state.selectionSet(in: directory) },
            set: { newValue in
                // 新しく増えた 1 件を主選択とする。減ったときは残りの先頭。
                let previous = state.selectionSet(in: directory)
                let added = newValue.subtracting(previous).first
                state.select(ids: newValue, primary: added ?? newValue.first, inColumnAt: index)
            }
        )
    }

    private func tint(for kind: MediaKind) -> Color {
        switch kind {
        case .folder: return Color(red: 0.35, green: 0.62, blue: 0.95)
        case .video:  return Color(red: 1.00, green: 0.72, blue: 0.20)
        case .image:  return Color(red: 0.45, green: 0.82, blue: 0.55)
        case .audio:  return Color(red: 0.42, green: 0.82, blue: 1.00)
        case .other:  return .secondary
        }
    }
}

/// 最終列のプレビュー（Finder のカラム表示と同じく、選択したファイルの概要を出す）
private struct ColumnPreviewPane: View {
    let item: FileItem
    let onActivate: (FileItem) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ThumbnailImage(item: item, size: 192)
                .frame(width: 192, height: 192)

            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(3).truncationMode(.middle)

            VStack(spacing: 3) {
                infoRow("種類", item.typeLabel)
                infoRow("サイズ", Fmt.bytes(item.displaySize))
                infoRow("変更日", Fmt.date(item.modified))
                infoRow("作成日", Fmt.date(item.created))
            }

            Button("プレビュー（Space）") { onActivate(item) }
                .controlSize(.small)

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 10, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
