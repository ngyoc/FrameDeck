import AppKit
import Foundation

/// `--screenshot <出力パス>` で起動したとき、ウィンドウの描画内容を PNG に書き出して終了する。
/// 画面収録の権限に依存せずに UI を確認するための開発用の口。
@MainActor
enum WindowCapture {

    private(set) static var isActive = false

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshot"), args.count > index + 1 else { return }
        let output = URL(fileURLWithPath: args[index + 1])
        let delay = args.firstIndex(of: "--screenshot-delay")
            .flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 5.0
        isActive = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // 非アクティブだと選択の強調表示が描かれないので、撮る前に前面へ出す
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            let ok = capture(to: output)
            FileHandle.standardOutput.write(Data(((ok ? "撮影しました: " : "撮影に失敗しました: ") + output.path + "\n").utf8))
            exit(ok ? 0 : 1)
        }
    }

    private static func diagnose(_ view: NSView) {
        if let host = view as? PlayerHostView {
            let rect = host.videoRect
            let line = "映像レイヤー: 表示準備 \(host.isReadyForDisplay ? "完了" : "未完了") / 描画領域 \(Int(rect.width))x\(Int(rect.height))\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        view.subviews.forEach(diagnose)
    }

    private static func capture(to url: URL) -> Bool {
        // 撮る対象: タイトル指定 > キーウィンドウ > いちばん大きいウィンドウ
        let args = CommandLine.arguments
        let wanted = args.firstIndex(of: "--screenshot-window").flatMap {
            args.count > $0 + 1 ? args[$0 + 1] : nil
        }
        let candidates = NSApp.windows.filter { $0.contentView != nil }
        let base = wanted.flatMap { title in candidates.first { $0.title.contains(title) } }
            ?? NSApp.keyWindow
            ?? candidates.max(by: { $0.frame.width < $1.frame.width })

        guard let base else {
            FileHandle.standardError.write(Data("表示中のウィンドウが見つかりません\n".utf8))
            return false
        }
        // シートが出ていればそちらを撮る
        let window = base.attachedSheet ?? base
        guard let view = window.contentView else { return false }
        // AVPlayerLayer は GPU 合成なのでビットマップキャッシュには写らない。
        // 代わりに「最初のフレームを描画できているか」をここで確認する。
        diagnose(view)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("書き込み失敗: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
