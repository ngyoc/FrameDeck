import AppKit
import SwiftUI

/// 詳細一覧（リスト表示）。アイコン / カラム / ギャラリー表示は M2 で追加する。
struct FileListView: View {
    @ObservedObject var store: DirectoryStore
    let onActivate: (FileItem) -> Void

    var body: some View {
        Table(store.visibleItems,
              selection: $store.selectedIDs,
              sortOrder: Binding(get: { store.tableSortOrder },
                                 set: { store.tableSortOrder = $0 })) {
            TableColumn("名前", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 7) {
                    Image(systemName: item.kind.symbolName)
                        .foregroundStyle(tint(for: item.kind))
                        .frame(width: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 220, ideal: 360)

            TableColumn("種類") { item in
                Text(item.typeLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150)

            TableColumn("サイズ", value: \.sortSize) { item in
                Text(Fmt.bytes(item.displaySize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn("変更日", value: \.sortModified) { item in
                Text(Fmt.date(item.modified))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 110, ideal: 140)

            TableColumn("作成日", value: \.sortCreated) { item in
                Text(Fmt.date(item.created))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 110, ideal: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let item = store.items.first(where: { $0.id == id }) {
                onActivate(item)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<FileItem.ID>) -> some View {
        if !ids.isEmpty {
            FileContextMenu(urls: Array(ids))
        }
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
