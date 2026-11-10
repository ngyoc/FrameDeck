import Foundation
import SwiftUI

/// カラム表示の状態。ビューの @State に置くとキー操作から触れないので、
/// 階層・選択・読み込み結果をここにまとめて持つ。
@MainActor
final class ColumnBrowserState: ObservableObject {

    /// 左から順に表示しているフォルダ
    @Published private(set) var chain: [URL] = []
    /// 列ごとの主選択（右の列を開く対象）
    @Published private(set) var selections: [URL: FileItem.ID] = [:]
    /// 列ごとの選択集合（⌘/⇧ クリックでの複数選択）
    @Published private(set) var selectionSets: [URL: Set<FileItem.ID>] = [:]
    /// 列ごとの一覧
    @Published private(set) var items: [URL: [FileItem]] = [:]
    @Published private(set) var loading: Set<URL> = []
    @Published private(set) var errors: [URL: String] = [:]
    /// いま操作している列。フォルダを選ぶと右に列が増えるが、
    /// キー操作の対象は選んだ側の列に留める（Finder と同じ挙動）。
    @Published private(set) var focusedIndex = 0

    /// 列ごとの幅。ファイル名が長いときに広げられるようにする。
    @Published var widths: [URL: CGFloat] = [:]

    static let defaultWidth: CGFloat = 230
    static let minimumWidth: CGFloat = 140
    static let maximumWidth: CGFloat = 900
    private static let widthsKey = "column.widths"

    func width(for url: URL) -> CGFloat {
        widths[url] ?? ColumnBrowserState.defaultWidth
    }

    func setWidth(_ value: CGFloat, for url: URL) {
        widths[url] = min(ColumnBrowserState.maximumWidth,
                          max(ColumnBrowserState.minimumWidth, value))
        persistWidths()
    }

    /// すべての列を同じ幅に揃える
    func applyWidthToAll(_ value: CGFloat) {
        let clamped = min(ColumnBrowserState.maximumWidth,
                          max(ColumnBrowserState.minimumWidth, value))
        for url in chain { widths[url] = clamped }
        UserDefaults.standard.set(Double(clamped), forKey: ColumnBrowserState.widthsKey + ".default")
        persistWidths()
    }

    private func persistWidths() {
        // パスは開き直すたびに変わるので、代表値だけ覚えておく
        if let last = chain.last, let value = widths[last] {
            UserDefaults.standard.set(Double(value), forKey: ColumnBrowserState.widthsKey + ".default")
        }
    }

    private var savedDefaultWidth: CGFloat {
        let stored = UserDefaults.standard.double(forKey: ColumnBrowserState.widthsKey + ".default")
        return stored >= ColumnBrowserState.minimumWidth ? CGFloat(stored) : ColumnBrowserState.defaultWidth
    }

    private var loadTasks: [URL: Task<Void, Never>] = [:]
    private unowned let store: DirectoryStore

    init(store: DirectoryStore) {
        self.store = store
    }

    // MARK: - 参照

    /// 操作対象の列
    var activeColumn: URL? {
        chain.indices.contains(focusedIndex) ? chain[focusedIndex] : chain.last
    }

    var activeItems: [FileItem] {
        guard let activeColumn else { return [] }
        return items[activeColumn] ?? []
    }

    var activeSelection: FileItem.ID? {
        guard let activeColumn else { return nil }
        return selections[activeColumn]
    }

    var activeItem: FileItem? {
        guard let id = activeSelection else { return nil }
        return activeItems.first { $0.id == id }
    }

    func items(in url: URL) -> [FileItem] { items[url] ?? [] }
    func isLoading(_ url: URL) -> Bool { loading.contains(url) }
    func error(for url: URL) -> String? { errors[url] }

    func selection(in url: URL) -> FileItem.ID? { selections[url] }
    func selectionSet(in url: URL) -> Set<FileItem.ID> {
        selectionSets[url] ?? selections[url].map { [$0] } ?? []
    }

    // MARK: - 階層の組み立て

    func reset(to root: URL) {
        guard chain.first != root || chain.isEmpty else { return }
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        chain = [root]
        focusedIndex = 0
        widths = [root: savedDefaultWidth]
        selections.removeAll()
        selectionSets.removeAll()
        items.removeAll()
        errors.removeAll()
        load(root)
    }

    /// 並べ替えの設定が変わったら全列を並べ直す
    func reapplySort() {
        for url in chain { load(url) }
    }

    private func load(_ url: URL) {
        loadTasks[url]?.cancel()
        loading.insert(url)
        loadTasks[url] = Task { [weak self] in
            let result = await FileSorter.read(url)
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let list):
                self.items[url] = FileSorter.arrange(list,
                                                     field: self.store.sortField,
                                                     ascending: self.store.sortAscending,
                                                     foldersFirst: self.store.foldersFirst,
                                                     showsHidden: self.store.showsHiddenFiles)
                self.errors[url] = nil
            case .failure(let error):
                self.items[url] = []
                self.errors[url] = "開けません\n\(error.localizedDescription)"
                Log.browser.error("カラム表示の読み込み失敗 \(url.path, privacy: .public)")
            }
            self.loading.remove(url)
        }
    }

    // MARK: - 選択

    /// 指定した列で選択を変える。フォルダなら右に列を足し、それより右は畳む。
    func select(_ id: FileItem.ID?, inColumnAt index: Int) {
        select(ids: id.map { [$0] } ?? [], primary: id, inColumnAt: index)
    }

    /// 複数選択に対応した本体。primary は右の列を開く対象（1 件だけ選ばれているときのみ開く）。
    func select(ids: Set<FileItem.ID>, primary: FileItem.ID?, inColumnAt index: Int) {
        guard chain.indices.contains(index) else { return }
        let column = chain[index]
        let list = items(in: column)

        selectionSets[column] = ids
        let resolvedPrimary = primary ?? (ids.count == 1 ? ids.first : nil)
        selections[column] = resolvedPrimary
        focusedIndex = index

        if chain.count > index + 1 {
            let removed = Array(chain[(index + 1)...])
            removed.forEach {
                selections[$0] = nil
                selectionSets[$0] = nil
                items[$0] = nil
                loadTasks[$0]?.cancel()
                loadTasks[$0] = nil
            }
            chain.removeSubrange((index + 1)...)
        }

        let chosen = list.filter { ids.contains($0.id) }
        let primaryItem = resolvedPrimary.flatMap { pid in list.first { $0.id == pid } }
        store.setSelection(items: chosen, primary: primaryItem)

        // 右の列を開くのは 1 件だけ選ばれているときに限る
        guard ids.count == 1, let item = primaryItem, item.isDirectory else { return }
        chain.append(item.url)
        if widths[item.url] == nil { widths[item.url] = savedDefaultWidth }
        load(item.url)
    }

    /// 操作中の列の中で選択を上下に動かす。
    /// フォルダを選ぶと右に列が増えるが、操作対象はこの列のまま。
    func moveSelection(by offset: Int) {
        recoverFocusIfStuck()
        let index = chain.indices.contains(focusedIndex) ? focusedIndex : chain.count - 1
        guard chain.indices.contains(index) else { return }
        let column = chain[index]
        let list = items(in: column)
        guard !list.isEmpty else { return }

        let next: Int
        if let current = list.firstIndex(where: { $0.id == selections[column] }) {
            next = max(0, min(list.count - 1, current + offset))
        } else {
            // 未選択なら端から始める
            next = offset > 0 ? 0 : list.count - 1
        }
        select(list[next].id, inColumnAt: index)
    }

    /// 選択中がフォルダなら右の列へ移る（選択したときに列は既に足されている）。
    /// 中身が空、または読み込みがまだ終わっていない列にはフォーカスを移さない。
    /// 移してしまうと、その列では上下も左右も反応しなくなって「固まった」ように見えるため。
    @discardableResult
    func enterSelected() -> Bool {
        guard let item = activeItem, item.isDirectory else { return false }
        guard let newIndex = chain.firstIndex(of: item.url) else { return false }
        if isLoading(item.url) { return false }
        guard let first = items(in: item.url).first else { return false }
        select(first.id, inColumnAt: newIndex)
        return true
    }

    /// 操作中の列が空になっていたら、中身のある親の列へ戻す（固まるのを防ぐ保険）
    func recoverFocusIfStuck() {
        guard chain.indices.contains(focusedIndex) else {
            focusedIndex = max(0, chain.count - 1)
            return
        }
        guard items(in: chain[focusedIndex]).isEmpty, !isLoading(chain[focusedIndex]) else { return }
        var index = focusedIndex
        while index > 0 {
            index -= 1
            if !items(in: chain[index]).isEmpty {
                focusedIndex = index
                return
            }
        }
        focusedIndex = 0
    }

    /// 左の列（親）へ戻る
    @discardableResult
    func exitColumn() -> Bool {
        let index = chain.indices.contains(focusedIndex) ? focusedIndex : chain.count - 1
        guard index > 0 else { return false }
        let parentIndex = index - 1
        let parent = chain[parentIndex]
        select(selections[parent], inColumnAt: parentIndex)
        return true
    }
}
