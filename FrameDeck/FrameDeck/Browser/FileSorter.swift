import Foundation

/// 一覧の絞り込みと並べ替え。フォルダ一覧とカラム表示の各列で同じ規則を使う。
enum FileSorter {

    static func arrange(_ items: [FileItem],
                        field: SortField,
                        ascending: Bool,
                        foldersFirst: Bool,
                        showsHidden: Bool) -> [FileItem] {
        var list = showsHidden ? items : items.filter { !$0.name.hasPrefix(".") }
        let order: SortOrder = ascending ? .forward : .reverse

        switch field {
        case .name:     list.sort(using: KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order))
        case .kind:     list.sort(using: KeyPathComparator(\FileItem.typeLabel, comparator: .localizedStandard, order: order))
        case .size:     list.sort(using: KeyPathComparator(\FileItem.sortSize, order: order))
        case .modified: list.sort(using: KeyPathComparator(\FileItem.sortModified, order: order))
        case .created:  list.sort(using: KeyPathComparator(\FileItem.sortCreated, order: order))
        }

        return foldersFirst
            ? list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
            : list
    }

    /// 中身が無い（見える項目が 1 つも無い）かどうか。
    /// 1 件見つけた時点で打ち切るので、大きなフォルダでも待たされない。
    static func isEffectivelyEmpty(_ directory: URL, showsHidden: Bool) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                return false   // 読めない場合は空扱いにしない（権限の問題と区別できないため）
            }
            for name in names where showsHidden || !name.hasPrefix(".") {
                return false
            }
            return true
        }.value
    }

    static func read(_ directory: URL) async -> Result<[FileItem], Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(FileItem.resourceKeys),
                    options: [])
                return .success(urls.compactMap(FileItem.init(url:)))
            } catch {
                return .failure(error)
            }
        }.value
    }
}
