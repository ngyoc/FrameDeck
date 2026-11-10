import SwiftUI

struct SidebarEntry: Identifiable, Hashable {
    let title: String
    let symbol: String
    let url: URL

    /// 識別子は URL に固定する。毎回 UUID を振ると List が更新のたびに全行を作り直す。
    var id: URL { url }
}

struct SidebarView: View {
    @ObservedObject var store: DirectoryStore

    @State private var favorites: [SidebarEntry] = []
    @State private var volumes: [SidebarEntry] = []

    var body: some View {
        List {
            Section("よく使う項目") {
                ForEach(favorites) { row($0) }
            }
            if !volumes.isEmpty {
                Section("場所") {
                    ForEach(volumes) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 300)
        .task {
            favorites = SidebarView.loadFavorites()
            volumes = SidebarView.loadVolumes()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWorkspace.didMountNotification, object: nil)) { _ in
            volumes = SidebarView.loadVolumes()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWorkspace.didUnmountNotification, object: nil)) { _ in
            volumes = SidebarView.loadVolumes()
        }
    }

    private func row(_ entry: SidebarEntry) -> some View {
        Button {
            store.go(to: entry.url)
        } label: {
            Label(entry.title, systemImage: entry.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            store.url == entry.url
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
                : nil
        )
    }

    // MARK: - 一覧の作成（起動時とボリューム着脱時のみ）

    private static func loadFavorites() -> [SidebarEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, String, URL)] = [
            ("ホーム", "house", home),
            ("デスクトップ", "menubar.dock.rectangle", home.appendingPathComponent("Desktop")),
            ("書類", "doc", home.appendingPathComponent("Documents")),
            ("ダウンロード", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            ("ムービー", "film", home.appendingPathComponent("Movies")),
            ("ピクチャ", "photo", home.appendingPathComponent("Pictures")),
            ("ミュージック", "music.note", home.appendingPathComponent("Music"))
        ]
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.2.path) }
            .map { SidebarEntry(title: $0.0, symbol: $0.1, url: $0.2) }
    }

    private static func loadVolumes() -> [SidebarEntry] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return SidebarEntry(title: values?.volumeName ?? url.lastPathComponent,
                                symbol: (values?.volumeIsInternal ?? true) ? "internaldrive" : "externaldrive",
                                url: url)
        }
    }
}
