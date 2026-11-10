import AppKit
import Foundation
import SwiftUI

@MainActor
final class PreviewModel: ObservableObject {

    @Published private(set) var isOpen = false
    @Published private(set) var item: FileItem?
    /// 前後送りの対象。プレビューを開いたときの「同じフォルダの中身」を保持する。
    /// カラム表示だと一覧と別階層になることがあるので、開いた時点の並びを覚えておく。
    @Published private(set) var siblings: [FileItem] = []
    @Published private(set) var unsupportedReason: String?
    @Published private(set) var isExporting = false
    @Published var isFullScreen = false
    /// 波形の表示範囲（ズーム / パン）
    @Published var waveformViewport = WaveformViewport()
    /// 波形ビューの実表示幅。パン量をピクセルから秒へ換算するのに使う。
    var waveformViewWidth: CGFloat = 1
    /// 書き出し時だけ適用する色味調整。元ファイルには書き込まない。
    @Published var colorAdjustments = ColorAdjustments.neutral
    /// 書き出しパネルの表示状態
    @Published var isExportPanelOpen = false

    let playback = PlaybackController()
    let waveform = WaveformLoader()

    private unowned let settings: AppSettings
    private unowned let toasts: ToastCenter

    init(settings: AppSettings, toasts: ToastCenter) {
        self.settings = settings
        self.toasts = toasts
    }

    // MARK: - 波形のズーム

    func syncWaveformViewport(duration: Double) {
        guard abs(waveformViewport.duration - duration) > 0.0001 else { return }
        waveformViewport.reset(duration: duration)
    }

    func zoomWaveform(in zoomIn: Bool) {
        guard playback.duration > 0 else { return }
        if zoomIn {
            waveformViewport.zoomIn(around: playback.currentTime)
        } else {
            waveformViewport.zoomOut(around: playback.currentTime)
        }
    }

    func magnifyWaveform(_ amount: CGFloat) {
        guard playback.duration > 0, abs(amount) > 0.0005 else { return }
        waveformViewport.zoom(by: 1 + Double(amount), around: playback.currentTime)
    }

    func resetWaveformZoom() {
        waveformViewport.reset(duration: playback.duration)
    }

    func panWaveform(byPixels pixels: CGFloat) {
        guard waveformViewport.isZoomed, waveformViewWidth > 0 else { return }
        let seconds = -Double(pixels / waveformViewWidth) * waveformViewport.visibleDuration
        waveformViewport.pan(by: seconds)
    }

    /// Space を再生 / 一時停止に使ってよいか。
    /// 動画と音声が読み込めているときだけ true。それ以外は Space で閉じる。
    var canPlayback: Bool {
        guard unsupportedReason == nil, playback.loadError == nil, playback.isReady else { return false }
        guard let kind = item?.kind else { return false }
        return kind == .video || kind == .audio
    }

    var showWaveform: Bool {
        get { settings.showWaveform }
        set { settings.showWaveform = newValue }
    }

    // MARK: - 開閉

    func open(_ item: FileItem, siblings: [FileItem] = []) {
        self.item = item
        self.siblings = siblings.isEmpty ? [item] : siblings
        isOpen = true
        show(item)
    }

    /// プレビューを開いたまま別ファイルへ切り替える
    func replace(with item: FileItem, siblings: [FileItem]? = nil) {
        guard isOpen else { return }
        if let siblings, !siblings.isEmpty { self.siblings = siblings }
        self.item = item
        show(item)
    }

    /// 同じフォルダの中だけで前後に送る。
    /// 一覧側の選択に頼ると、カラム表示で別階層のファイルに飛んでしまう。
    @discardableResult
    func step(by offset: Int) -> FileItem? {
        guard !siblings.isEmpty else { return nil }
        let currentIndex = item.flatMap { current in siblings.firstIndex { $0.id == current.id } } ?? -1
        let next: Int
        if currentIndex >= 0 {
            next = max(0, min(siblings.count - 1, currentIndex + offset))
        } else {
            next = offset > 0 ? 0 : siblings.count - 1
        }
        guard next != currentIndex else { return nil }
        let target = siblings[next]
        self.item = target
        show(target)
        return target
    }

    private func show(_ item: FileItem) {
        playback.unload()
        waveform.reset()
        waveformViewport = WaveformViewport()
        unsupportedReason = nil

        guard MediaSupport.isPreviewable(item.kind, url: item.url) else {
            unsupportedReason = MediaSupport.unsupportedReason(for: item.url)
            Log.media.notice("プレビュー非対応: \(item.name, privacy: .public)")
            return
        }

        switch item.kind {
        case .video, .audio:
            playback.load(url: item.url)
            waveform.load(url: item.url)
            if settings.autoPlay { playback.play() }
        case .image:
            break
        case .folder, .other:
            unsupportedReason = MediaSupport.unsupportedReason(for: item.url)
        }
    }

    func close() {
        isOpen = false
        isFullScreen = false
        playback.unload()
        waveform.reset()
        item = nil
        siblings = []
        unsupportedReason = nil
    }

    func toggle(_ item: FileItem?, siblings: [FileItem] = []) {
        if isOpen { close() } else if let item { open(item, siblings: siblings) }
    }

    // MARK: - フレーム書き出し

    /// S キー: 設定済みの保存先へダイアログなしで即保存する
    func exportFrameQuick() {
        guard let item else { return }
        export(to: settings.exportDestination(for: item.url))
    }

    /// ⌥S: 色味を調整しながら書き出すパネルを開く
    func openExportPanel() {
        guard let item, item.kind == .video, playback.isReady else {
            toasts.show(ToastMessage(text: "動画を表示しているときだけ使えます", style: .failure))
            return
        }
        playback.pause()
        isExportPanelOpen = true
    }

    /// ⌘S: 保存先をその場で選ぶ
    func exportFrameWithDialog() {
        guard let item, item.kind == .video else {
            toasts.show(ToastMessage(text: "動画を表示しているときだけ書き出せます", style: .failure))
            return
        }
        let panel = NSSavePanel()
        panel.title = "フレームを書き出し"
        panel.canCreateDirectories = true
        let base = FilenameTemplate.resolve(settings.exportTemplate,
                                            sourceName: item.url.deletingPathExtension().lastPathComponent,
                                            seconds: playback.currentTime,
                                            frameRate: playback.frameRate,
                                            sequence: nil,
                                            size: playback.naturalSize)
        panel.nameFieldStringValue = "\(base).\(settings.exportFormat.fileExtension)"
        panel.directoryURL = settings.exportDestination(for: item.url)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url.deletingLastPathComponent(), fixedName: url.deletingPathExtension().lastPathComponent)
    }

    private func export(to destination: URL, fixedName: String? = nil) {
        guard let item, item.kind == .video else {
            toasts.show(ToastMessage(text: "動画を表示しているときだけ書き出せます", style: .failure))
            return
        }
        guard playback.isReady else {
            toasts.show(ToastMessage(text: "読み込みが終わるまで待ってください", style: .failure))
            return
        }

        isExporting = true
        let seconds = playback.currentTime
        let frameRate = playback.frameRate
        var options = settings.exportOptions(color: colorAdjustments)
        if let fixedName { options.template = fixedName }

        Task {
            do {
                let result = try await FrameExporter.exportFrame(
                    assetURL: item.url,
                    at: seconds,
                    frameRate: frameRate,
                    destination: destination,
                    options: options
                )
                isExporting = false
                let size = "\(Int(result.pixelSize.width))x\(Int(result.pixelSize.height))"
                toasts.show(ToastMessage(
                    text: "フレームを書き出しました（\(size)）",
                    detail: result.url.lastPathComponent,
                    style: .success,
                    revealURL: result.url
                ))
            } catch {
                isExporting = false
                toasts.show(ToastMessage(text: "書き出しに失敗しました",
                                         detail: error.localizedDescription,
                                         style: .failure))
                Log.export.error("書き出し失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
