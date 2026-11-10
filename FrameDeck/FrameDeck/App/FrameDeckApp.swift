import AppKit
import SwiftUI

@main
struct FrameDeckApp: App {
    @StateObject private var env = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(env: env)
        }
        .defaultSize(width: 1240, height: 800)
        .commands { AppCommands(env: env) }

        // 書き出しパネルは独立したウィンドウにする。
        // シートだと大きさを変えられず、映像が見づらいため。
        Window("フレーム書き出し", id: FrameDeckApp.exportWindowID) {
            ExportPanel(model: env.preview,
                        settings: env.settings,
                        presets: env.colorPresets) {
                env.preview.isExportPanelOpen = false
            }
        }
        .defaultSize(width: 1180, height: 860)
        .defaultPosition(.center)
        .keyboardShortcut(nil)
    }

    static let exportWindowID = "export-panel"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // セルフテスト中はウィンドウを隠すので、ここで終了させない
        !SelfTest.isActive && !WindowCapture.isActive
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("FrameDeck 起動")
        if SelfTest.runIfRequested() { return }

        // 検証用の起動引数で動かすときは、先に前面へ出す。
        // 背面のままだと SwiftUI がビューを描画せず onAppear が来ないため、
        // 検証そのものが始まらない。
        let args = CommandLine.arguments
        if args.contains("--click-test") || args.contains("--screenshot") || args.contains("--demo") {
            NSApp.activate(ignoringOtherApps: true)
        }

        WindowCapture.runIfRequested()
    }
}

struct AppCommands: Commands {
    @ObservedObject var env: AppEnvironment

    var body: some Commands {
        // 「新規」系はこのアプリでは使わないので畳む（読み取り専用のため）
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Finder で表示") {
                let target = env.store.selectedItem?.url ?? env.store.url
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("デフォルトのアプリで開く") {
                guard let url = env.store.selectedItem?.url else { return }
                NSWorkspace.shared.open(url)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("フレームを書き出し…") {
                env.preview.exportFrameWithDialog()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!env.preview.isOpen)

            Button("色味を調整して書き出し…") {
                env.preview.openExportPanel()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!env.preview.isOpen)

            Button("パスをコピー") {
                let path = (env.store.selectedItem?.url ?? env.store.url).path
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
        }

        CommandMenu("移動") {
            Button("戻る") { env.store.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!env.store.canGoBack)
            Button("進む") { env.store.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!env.store.canGoForward)
            Button("親フォルダへ") { env.store.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!env.store.canGoUp)
            Button("開く") {
                guard let item = env.store.selectedItem else { return }
                let siblings = env.store.viewMode == .column ? env.columns.activeItems : env.store.visibleItems
                if !env.store.open(item) { env.preview.open(item, siblings: siblings) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(env.store.selectedItem == nil)
        }

        CommandGroup(after: .toolbar) {
            ForEach(BrowserViewMode.allCases) { mode in
                Button("\(mode.label)表示") { env.store.viewMode = mode }
                    .keyboardShortcut(mode.shortcut, modifiers: .command)
            }

            Divider()

            Menu("並べ替え") {
                ForEach(SortField.allCases) { field in
                    Button {
                        env.store.applySort(field)
                    } label: {
                        if env.store.sortField == field {
                            Label(field.label, systemImage: env.store.sortAscending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(field.label)
                        }
                    }
                }
                Divider()
                Toggle("フォルダを常に上部に表示", isOn: Binding(
                    get: { env.store.foldersFirst },
                    set: { env.store.foldersFirst = $0 }
                ))
            }

            Divider()

            Button(env.preview.isOpen ? "プレビューを閉じる" : "プレビュー") {
                let siblings = env.store.viewMode == .column ? env.columns.activeItems : env.store.visibleItems
                env.preview.toggle(env.store.selectedItem, siblings: siblings)
            }
            .keyboardShortcut("y", modifiers: .command)

            Divider()

            Button("波形をズームイン") { env.preview.zoomWaveform(in: true) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!env.preview.isOpen)
            Button("波形をズームアウト") { env.preview.zoomWaveform(in: false) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!env.preview.isOpen)
            Button("波形のズームをリセット") { env.preview.resetWaveformZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!env.preview.isOpen)

            Divider()

            Toggle("隠しファイルを表示", isOn: Binding(
                get: { env.store.showsHiddenFiles },
                set: { env.store.showsHiddenFiles = $0 }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
}
