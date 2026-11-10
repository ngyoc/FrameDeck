import Foundation
import SwiftUI

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case icon, list, column, gallery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon:    return "アイコン"
        case .list:    return "リスト"
        case .column:  return "カラム"
        case .gallery: return "ギャラリー"
        }
    }

    var symbol: String {
        switch self {
        case .icon:    return "square.grid.2x2"
        case .list:    return "list.bullet"
        case .column:  return "rectangle.split.3x1"
        case .gallery: return "square.bottomhalf.filled"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .icon: return "1"
        case .list: return "2"
        case .column: return "3"
        case .gallery: return "4"
        }
    }
}

/// 並び替えの基準。Finder の「表示順序」に合わせている。
enum SortField: String, CaseIterable, Identifiable {
    case name, kind, size, modified, created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name:     return "名前"
        case .kind:     return "種類"
        case .size:     return "サイズ"
        case .modified: return "変更日"
        case .created:  return "作成日"
        }
    }

    /// Table の列と対応付けるためのキーパス
    var keyPath: PartialKeyPath<FileItem> {
        switch self {
        case .name:     return \FileItem.name
        case .kind:     return \FileItem.typeLabel
        case .size:     return \FileItem.sortSize
        case .modified: return \FileItem.sortModified
        case .created:  return \FileItem.sortCreated
        }
    }

    static func field(for keyPath: PartialKeyPath<FileItem>) -> SortField? {
        allCases.first { $0.keyPath == keyPath }
    }

    /// 日付は新しい順、それ以外は昇順が既定（Finder と同じ感覚）
    var defaultAscending: Bool {
        switch self {
        case .modified, .created: return false
        default: return true
        }
    }
}
