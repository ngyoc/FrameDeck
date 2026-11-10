import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let contentType: UTType?
    let kind: MediaKind

    var id: URL { url }

    var typeLabel: String {
        if isDirectory { return "フォルダ" }
        return contentType?.localizedDescription ?? url.pathExtension.uppercased()
    }

    /// フォルダはサイズ列を「--」にする（Finder と同じ挙動）
    var displaySize: Int64? { isDirectory ? nil : size }

    /// Table の並べ替えは非オプショナルな値を要求するので、ソート専用のキーを用意する
    var sortSize: Int64 { displaySize ?? -1 }
    var sortModified: Date { modified ?? .distantPast }
    var sortCreated: Date { created ?? .distantPast }

    static let resourceKeys: Set<URLResourceKey> = [
        .nameKey, .isDirectoryKey, .fileSizeKey, .totalFileSizeKey,
        .contentModificationDateKey, .creationDateKey, .contentTypeKey, .isPackageKey, .isHiddenKey
    ]

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: FileItem.resourceKeys) else {
            Log.browser.warning("リソース値を取得できませんでした: \(url.path, privacy: .public)")
            return nil
        }
        // パッケージ（.app など）はフォルダではなくファイルとして扱う
        let isPackage = values.isPackage ?? false
        let isDir = (values.isDirectory ?? false) && !isPackage

        self.url = url
        self.name = values.name ?? url.lastPathComponent
        self.isDirectory = isDir
        self.size = (values.totalFileSize ?? values.fileSize).map(Int64.init)
        self.modified = values.contentModificationDate
        self.created = values.creationDate
        self.contentType = values.contentType
        self.kind = MediaSupport.kind(for: url, contentType: values.contentType, isDirectory: isDir)
    }
}
