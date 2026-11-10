import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var preview: PreviewModel
    @ObservedObject private var toasts: ToastCenter

    init(env: AppEnvironment) {
        self.env = env
        self.preview = env.preview
        self.toasts = env.toasts
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: env.store)
        } detail: {
            BrowserView(store: env.store, preview: preview,
                        columns: env.columns, folderSize: env.folderSize)
        }
        .frame(minWidth: 900, minHeight: 560)
        .overlay {
            if preview.isOpen {
                PreviewOverlay(model: preview) { preview.close() }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = toasts.message {
                ToastView(message: message) { toasts.dismiss() }
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: preview.isExportPanelOpen) { _, isOpen in
            if isOpen {
                openWindow(id: FrameDeckApp.exportWindowID)
            } else {
                dismissWindow(id: FrameDeckApp.exportWindowID)
            }
        }
        .animation(.easeOut(duration: 0.16), value: preview.isOpen)
        .animation(.easeOut(duration: 0.2), value: toasts.message)
        .onAppear {
            let bindings = KeyBindings(env: env)
            env.router.onKeyDown = { bindings.handle($0) }
            env.router.onScroll = { bindings.handleScroll(sign: $0, modifiers: $1) }
            env.router.onHorizontalScroll = { bindings.handleHorizontalScroll(delta: $0) }
            env.router.onMagnify = { bindings.handleMagnify($0) }
            env.router.install()
            applyDemoArgumentIfNeeded()
        }
    }

    static func syntheticKey(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero,
                         modifierFlags: [.function, .numericPad],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: keyCode)!
    }

    /// `--demo <ファイルパス>` で起動したとき、そのファイルを選択してプレビューまで開く。
    /// 画面確認とスクリーンショット取得を手動操作なしで再現するための開発用の口。
    private func applyDemoArgumentIfNeeded() {
        let args = CommandLine.arguments
        if let modeIndex = args.firstIndex(of: "--view-mode"), args.count > modeIndex + 1,
           let mode = BrowserViewMode(rawValue: args[modeIndex + 1]) {
            env.store.viewMode = mode
        }
        if let dirIndex = args.firstIndex(of: "--folder"), args.count > dirIndex + 1 {
            env.store.go(to: URL(fileURLWithPath: args[dirIndex + 1]))
        }
        if let n = args.firstIndex(of: "--press-down"), args.count > n + 1,
           let times = Int(args[n + 1]) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                for _ in 0..<times {
                    _ = KeyBindings(env: env).handle(ContentView.syntheticKey(KeyCode.down))
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if args.contains("--press-right") {
                    _ = KeyBindings(env: env).handle(ContentView.syntheticKey(KeyCode.right))
                    try? await Task.sleep(for: .milliseconds(800))
                    _ = KeyBindings(env: env).handle(ContentView.syntheticKey(KeyCode.down))
                }
            }
        }
        if ClickTest.isRequested() {
            Task { @MainActor in await ClickTest.run(env: env) }
            return
        }
        guard let index = args.firstIndex(of: "--demo"), args.count > index + 1 else { return }
        let target = URL(fileURLWithPath: args[index + 1])
        guard FileManager.default.fileExists(atPath: target.path) else {
            Log.app.notice("--demo で指定されたファイルが見つかりません: \(target.path, privacy: .public)")
            return
        }
        env.store.go(to: target.deletingLastPathComponent())
        Task { @MainActor in
            // ファイルシステムは NFD、コマンドライン引数は NFC で返ってくることがあるので、
            // 日本語のファイル名でも一致するよう正規化して比べる
            let wanted = target.path.precomposedStringWithCanonicalMapping
            func match(_ item: FileItem) -> Bool {
                item.url.path.precomposedStringWithCanonicalMapping == wanted
            }

            // 一覧の読み込みが終わってから選択する
            for _ in 0..<40 {
                if env.store.items.contains(where: match) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let item = env.store.items.first(where: match) else {
                FileHandle.standardOutput.write(Data("demo: 対象が見つかりません \(target.lastPathComponent)\n".utf8))
                return
            }
            env.store.selection = item.id
            env.preview.open(item)

            // 検証用: 波形を N 回ズームし、指定秒へ寄せた状態にする
            if let z = args.firstIndex(of: "--wave-zoom"), args.count > z + 1,
               let times = Int(args[z + 1]) {
                for _ in 0..<60 {
                    if env.preview.playback.isReady { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let at = args.firstIndex(of: "--seek").flatMap {
                    args.count > $0 + 1 ? Double(args[$0 + 1]) : nil
                } ?? env.preview.playback.duration / 3
                env.preview.playback.seek(to: at)
                try? await Task.sleep(for: .milliseconds(600))
                for _ in 0..<times {
                    env.preview.zoomWaveform(in: true)
                    try? await Task.sleep(for: .milliseconds(120))
                }
                env.preview.waveformViewport.center(on: at)
            }

            if args.contains("--export-panel") {
                // 読み込みとフレーム取得が終わるのを待ってから開く
                for _ in 0..<60 {
                    if env.preview.playback.isReady { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                env.preview.playback.seek(to: env.preview.playback.duration / 3)
                try? await Task.sleep(for: .milliseconds(400))
                env.preview.openExportPanel()
            }
        }
    }
}
