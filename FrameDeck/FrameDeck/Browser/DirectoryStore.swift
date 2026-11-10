import Foundation
import SwiftUI

@MainActor
final class DirectoryStore: ObservableObject {

    @Published private(set) var url: URL
    /// 生の読み込み結果。View は visibleItems だけを見るので通知は出さない。
    private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// 複数選択に対応する（容量の合計を見たい用途があるため）
    @Published var selectedIDs: Set<FileItem.ID> = [] {
        didSet {
            // 一覧に無い階層の選択が残らないようにする
            externalSelections.removeAll { !selectedIDs.contains($0.id) }
        }
    }

    /// 主に操作している 1 件。キー移動やプレビューの対象になる。
    var selection: FileItem.ID? {
        get { primaryID ?? selectedIDs.first }
        set {
            primaryID = newValue
            selectedIDs = newValue.map { [$0] } ?? []
        }
    }

    private var primaryID: FileItem.ID?

    /// カラム表示の 2 列目以降など、この階層の一覧には含まれない場所で選ばれた項目。
    /// selectedItem / selectedItems をここからも引けるようにしないと、
    /// Space やメニュー、容量の合計が効かなくなる。
    private var externalSelections: [FileItem] = []

    @Published var viewMode: BrowserViewMode = .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: DirectoryStore.viewModeKey) }
    }
    @Published var sortField: SortField = .name { didSet { persistSort(); scheduleRebuild() } }
    @Published var sortAscending = true { didSet { persistSort(); scheduleRebuild() } }
    /// Finder の「フォルダを常に上部に表示」に相当（既定はオン）
    @Published var foldersFirst = true { didSet { persistSort(); scheduleRebuild() } }
    @Published var showsHiddenFiles = false { didSet { scheduleRebuild() } }
    /// アイコン表示のサムネイル一辺（px）
    @Published var iconSize: Double = 128 {
        didSet { UserDefaults.standard.set(iconSize, forKey: DirectoryStore.iconSizeKey) }
    }
    /// アイコン表示の 1 行あたりの列数。矢印キーでの上下移動に使う。
    var iconColumnsPerRow: Int = 1

    /// Table の描画中に毎回並べ替えると再入エラーになるので、結果を保持しておく
    @Published private(set) var visibleItems: [FileItem] = []

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var loadTask: Task<Void, Never>?

    private static let lastDirectoryKey = "browser.lastDirectory"
    private static let viewModeKey = "browser.viewMode"
    private static let sortFieldKey = "browser.sortField"
    private static let sortAscendingKey = "browser.sortAscending"
    private static let foldersFirstKey = "browser.foldersFirst"
    private static let iconSizeKey = "browser.iconSize"

    init() {
        let defaults = UserDefaults.standard
        self.url = DirectoryStore.initialDirectory()
        if let raw = defaults.string(forKey: DirectoryStore.viewModeKey),
           let mode = BrowserViewMode(rawValue: raw) {
            self.viewMode = mode
        }
        if let raw = defaults.string(forKey: DirectoryStore.sortFieldKey),
           let field = SortField(rawValue: raw) {
            self.sortField = field
        }
        if defaults.object(forKey: DirectoryStore.sortAscendingKey) != nil {
            self.sortAscending = defaults.bool(forKey: DirectoryStore.sortAscendingKey)
        }
        if defaults.object(forKey: DirectoryStore.foldersFirstKey) != nil {
            self.foldersFirst = defaults.bool(forKey: DirectoryStore.foldersFirstKey)
        }
        let savedIconSize = defaults.double(forKey: DirectoryStore.iconSizeKey)
        if savedIconSize >= 48 { self.iconSize = savedIconSize }
    }

    private func persistSort() {
        let defaults = UserDefaults.standard
        defaults.set(sortField.rawValue, forKey: DirectoryStore.sortFieldKey)
        defaults.set(sortAscending, forKey: DirectoryStore.sortAscendingKey)
        defaults.set(foldersFirst, forKey: DirectoryStore.foldersFirstKey)
    }

    /// 並び替えの基準を切り替える。同じ基準を選び直したら昇順降順を反転する（Finder と同じ）。
    func applySort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field.defaultAscending
        }
    }

    /// Table の列ヘッダと双方向でつなぐための橋渡し
    var tableSortOrder: [KeyPathComparator<FileItem>] {
        get {
            let order: SortOrder = sortAscending ? .forward : .reverse
            switch sortField {
            case .name:     return [KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)]
            case .kind:     return [KeyPathComparator(\FileItem.typeLabel, comparator: .localizedStandard, order: order)]
            case .size:     return [KeyPathComparator(\FileItem.sortSize, order: order)]
            case .modified: return [KeyPathComparator(\FileItem.sortModified, order: order)]
            case .created:  return [KeyPathComparator(\FileItem.sortCreated, order: order)]
            }
        }
        set {
            guard let first = newValue.first,
                  let field = SortField.field(for: first.keyPath) else { return }
            let ascending = first.order == .forward
            guard field != sortField || ascending != sortAscending else { return }
            sortField = field
            sortAscending = ascending
        }
    }

    private static func initialDirectory() -> URL {
        let fm = FileManager.default
        if let saved = UserDefaults.standard.string(forKey: lastDirectoryKey) {
            let candidate = URL(fileURLWithPath: saved)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            Log.browser.notice("前回のフォルダが存在しないためホームに戻ります: \(saved, privacy: .public)")
        }
        // ~/Movies は TCC の保護対象外なので、初回起動で権限ダイアログが出ない
        let movies = fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return fm.fileExists(atPath: movies.path) ? movies : fm.homeDirectoryForCurrentUser
    }

    // MARK: - 並び替え / 絞り込み

    /// 表示用に整えた一覧。フォルダを先頭にまとめるのは Finder と同じ挙動。
    /// 並べ替えの変更は Table 自身の更新中に飛んでくる。
    /// その場で visibleItems を書き換えると再入になるので次のループへ逃がす。
    private var rebuildScheduled = false

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor in
            self.rebuildScheduled = false
            self.rebuildVisibleItems()
        }
    }

    private func rebuildVisibleItems() {
        visibleItems = FileSorter.arrange(items,
                                          field: sortField,
                                          ascending: sortAscending,
                                          foldersFirst: foldersFirst,
                                          showsHidden: showsHiddenFiles)
    }

    var selectedItem: FileItem? {
        guard let selection else { return nil }
        if let match = items.first(where: { $0.id == selection }) { return match }
        return externalSelections.first { $0.id == selection }
    }

    /// 選択されている項目すべて（この階層のものと、カラム表示の別階層のものを合わせる）
    var selectedItems: [FileItem] {
        var seen = Set<FileItem.ID>()
        var result: [FileItem] = []
        for item in items where selectedIDs.contains(item.id) {
            if seen.insert(item.id).inserted { result.append(item) }
        }
        for item in externalSelections where selectedIDs.contains(item.id) {
            if seen.insert(item.id).inserted { result.append(item) }
        }
        return result
    }

    /// 選択したファイルの合計サイズ（フォルダは中身を数えないので除く）
    var selectedFilesTotalBytes: Int64 {
        selectedItems.compactMap(\.displaySize).reduce(0, +)
    }

    /// いま開いているフォルダの直下にあるファイルの合計サイズ
    var visibleFilesTotalBytes: Int64 {
        visibleItems.compactMap(\.displaySize).reduce(0, +)
    }

    /// 一覧に無い階層の項目を選択状態にする（カラム表示から呼ぶ）
    func setSelection(_ item: FileItem?) {
        setSelection(items: item.map { [$0] } ?? [], primary: item)
    }

    /// 一覧に無い階層の複数選択（カラム表示から呼ぶ）
    func setSelection(items newItems: [FileItem], primary: FileItem?) {
        externalSelections = newItems
        primaryID = primary?.id
        selectedIDs = Set(newItems.map(\.id))
    }

    // MARK: - ナビゲーション

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.pathComponents.count > 1 }

    func go(to newURL: URL, recordHistory: Bool = true) {
        guard newURL != url else { return }
        if recordHistory {
            backStack.append(url)
            forwardStack.removeAll()
        }
        url = newURL
        UserDefaults.standard.set(newURL.path, forKey: DirectoryStore.lastDirectoryKey)
        externalSelections = []
        primaryID = nil
        selectedIDs = []
        load()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        go(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        go(to: next, recordHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        go(to: url.deletingLastPathComponent())
    }

    /// フォルダなら移動、ファイルなら false を返す（呼び出し側でプレビューを開く）
    @discardableResult
    func open(_ item: FileItem) -> Bool {
        if item.isDirectory {
            go(to: item.url)
            return true
        }
        return false
    }

    // MARK: - 選択の移動（プレビュー表示中に使う）

    @discardableResult
    func moveSelection(by offset: Int) -> FileItem? {
        let list = visibleItems
        guard !list.isEmpty else { return nil }
        let next: Int
        if let current = list.firstIndex(where: { $0.id == selection }) {
            next = max(0, min(list.count - 1, current + offset))
        } else {
            // 未選択のときは移動量に関係なく端から始める
            next = offset > 0 ? 0 : list.count - 1
        }
        selection = list[next].id
        return list[next]
    }

    /// アイコン表示での上下移動（1 行ぶんまとめて動かす）
    @discardableResult
    func moveSelectionByRow(_ direction: Int) -> FileItem? {
        moveSelection(by: direction * max(1, iconColumnsPerRow))
    }

    func select(_ item: FileItem, extending: Bool = false) {
        if extending {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
                if primaryID == item.id { primaryID = selectedIDs.first }
            } else {
                selectedIDs.insert(item.id)
                primaryID = item.id
            }
        } else {
            selection = item.id
        }
    }

    // MARK: - 読み込み

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let target = url

        loadTask = Task { [weak self] in
            let result = await DirectoryStore.read(directory: target)
            guard let self, !Task.isCancelled, self.url == target else { return }
            switch result {
            case .success(let list):
                self.items = list
                self.errorMessage = nil
            case .failure(let error):
                self.items = []
                self.errorMessage = "フォルダを読み込めません: \(error.localizedDescription)"
                Log.browser.error("読み込み失敗 \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            self.isLoading = false
            self.rebuildVisibleItems()
        }
    }

    private nonisolated static func read(directory: URL) async -> Result<[FileItem], Error> {
        await FileSorter.read(directory)
    }
}
