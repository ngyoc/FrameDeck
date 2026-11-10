import AppKit
import SwiftUI

struct BrowserView: View {
    @ObservedObject var store: DirectoryStore
    @ObservedObject var preview: PreviewModel
    @ObservedObject var columns: ColumnBrowserState
    @ObservedObject var folderSize: FolderSizeCalculator

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            pathBar
        }
        .navigationTitle(store.url.lastPathComponent)
        .toolbar { toolbarContent }
        .task { store.load() }
        .onChange(of: store.selectedIDs) { _, _ in
            // 走査は重いので自動では動かさない。選択が変わったら前の結果だけ捨てる。
            let single = store.selectedItems.count == 1 ? store.selectedItems.first : nil
            folderSize.invalidate(unless: single?.isDirectory == true ? single?.url : nil)

            // プレビューを開いたまま一覧の選択を変えたら、そのまま追従させる。
            // Table の更新サイクル内で再入しないよう、次のループへ逃がす。
            guard preview.isOpen, let item = store.selectedItem else { return }
            Task { @MainActor in preview.replace(with: item, siblings: siblings) }
        }
        .overlay(alignment: .top) {
            if let message = store.errorMessage {
                Text(message)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.viewMode {
        case .icon:    IconGridView(store: store, onActivate: activate)
        case .list:    FileListView(store: store, onActivate: activate)
        case .column:  ColumnBrowserView(store: store, state: columns, onActivate: activate)
        case .gallery: GalleryView(store: store, onActivate: activate)
        }
    }

    private func activate(_ item: FileItem) {
        if !store.open(item) {
            preview.open(item, siblings: siblings)
        }
    }

    /// プレビュー中の前後送りの対象。表示形式によって「同じ階層」の意味が変わる。
    private var siblings: [FileItem] {
        store.viewMode == .column ? columns.activeItems : store.visibleItems
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!store.canGoBack)
                .help("戻る（⌘[）")
            Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!store.canGoForward)
                .help("進む（⌘]）")
            Button { store.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(!store.canGoUp)
                .help("親フォルダへ（⌘↑）")
        }

        ToolbarItem(placement: .principal) {
            Picker("", selection: $store.viewMode) {
                ForEach(BrowserViewMode.allCases) { mode in
                    Image(systemName: mode.symbol)
                        .help(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
            .help("表示形式（⌘1 - ⌘4）")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if store.isLoading { ProgressView().controlSize(.small) }

            if store.viewMode == .icon {
                Slider(value: $store.iconSize, in: 48...384)
                    .frame(width: 90)
                    .help("アイコンの大きさ")
            }

            sortMenu

            Button {
                if let item = store.selectedItem { preview.toggle(item, siblings: siblings) }
            } label: {
                Image(systemName: "eye")
            }
            .disabled(store.selectedItem == nil)
            .help("プレビュー（Space / ⌘Y）")

            Button {
                let target = store.selectedItem?.url ?? store.url
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Finder で表示（⌘R）")
        }
    }

    private var sortMenu: some View {
        Menu {
            Section("並べ替え") {
                ForEach(SortField.allCases) { field in
                    Button {
                        store.applySort(field)
                    } label: {
                        HStack {
                            Text(field.label)
                            if store.sortField == field {
                                Image(systemName: store.sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            }
            Divider()
            Toggle("フォルダを常に上部に表示", isOn: $store.foldersFirst)
            Toggle("隠しファイルを表示", isOn: $store.showsHiddenFiles)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("並べ替え: \(store.sortField.label)（\(store.sortAscending ? "昇順" : "降順")）")
    }

    // MARK: - パスバー

    private var pathBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(displayPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            sizeReadout
            Text("\(store.sortField.label) \(store.sortAscending ? "↑" : "↓")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("\(store.visibleItems.count) 項目")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// 容量の表示。
    /// ここに出す数字は一覧を読んだ時点で分かっているものだけにして、
    /// フォルダの中身の走査は頼まれたときにだけ動かす（外付けやクラウドで固まらないように）。
    @ViewBuilder
    private var sizeReadout: some View {
        if store.selectedItems.count >= 2 {
            Text("\(store.selectedItems.count) 項目を選択 / \(Fmt.bytes(store.selectedFilesTotalBytes))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)

        } else if let folder = selectedFolder {
            folderSizeReadout(folder)

        } else if let file = store.selectedItems.first, let size = file.displaySize {
            Text("選択 \(Fmt.bytes(size))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)

        } else {
            Text("このフォルダのファイル \(Fmt.bytes(store.visibleFilesTotalBytes))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var selectedFolder: FileItem? {
        guard store.selectedItems.count == 1, let item = store.selectedItems.first,
              item.isDirectory else { return nil }
        return item
    }

    @ViewBuilder
    private func folderSizeReadout(_ folder: FileItem) -> some View {
        if folderSize.target == folder.url, let progress = folderSize.progress {
            HStack(spacing: 5) {
                if folderSize.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                }
                Text(progress.isComplete
                     ? "\(progress.fileCount) ファイル / \(Fmt.bytes(progress.totalBytes))\(progress.truncated ? "（上限で打ち切り）" : "")"
                     : "計測中 \(progress.fileCount) ファイル / \(Fmt.bytes(progress.totalBytes))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                if folderSize.isRunning {
                    Button("中止") { folderSize.cancel() }
                        .buttonStyle(.link).font(.system(size: 10))
                }
            }
        } else {
            Button {
                folderSize.start(folder.url)
            } label: {
                Label("フォルダの容量を計算", systemImage: "sum")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            .help("中身を走査して合計サイズを出します。外付けやクラウド上のフォルダでは時間がかかることがあります")
        }
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return store.url.path.hasPrefix(home)
            ? "~" + store.url.path.dropFirst(home.count)
            : store.url.path
    }
}
