import SwiftUI

/// アプリ全体で共有する状態の持ち主。
/// 個々のビューは必要なサブオブジェクトを @ObservedObject で受け取る。
@MainActor
final class AppEnvironment: ObservableObject {
    let settings = AppSettings()
    let toasts = ToastCenter()
    let store = DirectoryStore()
    let router = EventRouter()
    let colorPresets = ColorPresetStore()
    let folderSize = FolderSizeCalculator()
    let preview: PreviewModel
    let columns: ColumnBrowserState

    init() {
        preview = PreviewModel(settings: settings, toasts: toasts)
        columns = ColumnBrowserState(store: store)
    }
}
