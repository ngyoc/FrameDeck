import AppKit
import Foundation

/// キー入力の振り分け。プレビューの開閉状態で意味が変わる。
@MainActor
struct KeyBindings {

    let env: AppEnvironment

    private var store: DirectoryStore { env.store }
    private var columns: ColumnBrowserState { env.columns }
    private var preview: PreviewModel { env.preview }
    private var playback: PlaybackController { env.preview.playback }

    /// いま見えている階層の並び。プレビューの前後送りの対象になる。
    private var currentSiblings: [FileItem] {
        store.viewMode == .column ? columns.activeItems : store.visibleItems
    }

    // MARK: - キー入力

    func handle(_ event: NSEvent) -> Bool {
        // 書き出しパネル表示中はパネル側の操作を優先する
        if preview.isExportPanelOpen { return false }
        // ⌘ 付きはメニューのショートカットに任せる（⌘S などが二重に発火しないように）
        if event.isCommandDown { return false }
        return preview.isOpen ? handleInPreview(event) : handleInBrowser(event)
    }

    private func handleInBrowser(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.space:
            guard let item = store.selectedItem else { return false }
            preview.open(item, siblings: currentSiblings)
            return true

        case KeyCode.returnKey, KeyCode.keypadEnter:
            guard let item = store.selectedItem else { return false }
            if !store.open(item) { preview.open(item, siblings: currentSiblings) }
            return true

        case KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down:
            // 修飾キー付き（⌘↑ 親フォルダ など）はメニューに任せる
            guard !event.isCommandDown, !event.isOptionDown else { return false }
            return moveInBrowser(keyCode: event.keyCode)

        default:
            return false
        }
    }

    /// 一覧の十字キー移動。
    /// 縦は選択の上下、横はフォルダの出入り（アイコン / ギャラリーは並びの前後）。
    private func moveInBrowser(keyCode: UInt16) -> Bool {
        switch store.viewMode {

        case .column:
            // 列ごとに選択を持つので ColumnBrowserState 側で動かす
            switch keyCode {
            case KeyCode.up:    columns.moveSelection(by: -1)
            case KeyCode.down:  columns.moveSelection(by: 1)
            case KeyCode.right:
                let moved = columns.enterSelected()
                focusActiveColumn()
                return moved
            default:
                let moved = columns.exitColumn()
                focusActiveColumn()
                return moved
            }
            focusActiveColumn()
            return true

        case .list:
            switch keyCode {
            case KeyCode.up:   store.moveSelection(by: -1)
            case KeyCode.down: store.moveSelection(by: 1)
            case KeyCode.right:
                // フォルダなら中へ入る（Finder のカラム表示と同じ感覚）。
                // 空のフォルダには入らない。入ると何も選べず、止まったように見えるため。
                guard let item = store.selectedItem, item.isDirectory else { return true }
                enterFolderIfNotEmpty(item)
            default:
                guard store.canGoUp else { return true }
                let leaving = store.url
                store.goUp()
                // 戻った先で、いま出てきたフォルダを選んでおく
                Task { @MainActor in
                    for _ in 0..<40 {
                        if let match = store.visibleItems.first(where: { $0.url == leaving }) {
                            store.selection = match.id
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                }
            }
            focusList()
            return true

        case .icon:
            switch keyCode {
            case KeyCode.left:  store.moveSelection(by: -1)
            case KeyCode.right: store.moveSelection(by: 1)
            case KeyCode.up:    store.moveSelectionByRow(-1)
            default:            store.moveSelectionByRow(1)
            }
            return true

        case .gallery:
            store.moveSelection(by: (keyCode == KeyCode.up || keyCode == KeyCode.left) ? -1 : 1)
            return true
        }
    }

    /// 中身のあるフォルダにだけ入る。空なら知らせて留まる。
    private func enterFolderIfNotEmpty(_ item: FileItem) {
        Task { @MainActor in
            let isEmpty = await FileSorter.isEffectivelyEmpty(item.url,
                                                             showsHidden: store.showsHiddenFiles)
            guard !isEmpty else {
                env.toasts.show(ToastMessage(text: "「\(item.name)」は空のフォルダです", style: .info),
                                duration: 2.0)
                return
            }
            store.go(to: item.url)
            focusList()
        }
    }

    /// リスト表示は SwiftUI の Table なので、選択を動かしても
    /// フォーカスもスクロールも自動では追従しない。
    /// フォーカスが無いと選択がグレー表示になるので、ここで明示的に移す。
    private func focusList() {
        // 選択の反映が終わってからテーブルを触る
        Task { @MainActor in
            let row = store.selection.flatMap { id in
                store.visibleItems.firstIndex { $0.id == id }
            }
            ListFocus.focusList(rowCount: store.visibleItems.count, selectedRow: row)
        }
    }

    /// カラム表示は列ごとにテーブルがあるので、操作中の列へフォーカスを移す。
    private func focusActiveColumn() {
        Task { @MainActor in
            let row = columns.activeSelection.flatMap { id in
                columns.activeItems.firstIndex { $0.id == id }
            }
            ListFocus.suppressColumnHighlights()
            ListFocus.focusColumn(index: columns.focusedIndex,
                                  rowCount: columns.activeItems.count,
                                  selectedRow: row)
        }
    }

    private func handleInPreview(_ event: NSEvent) -> Bool {
        let shift = event.isShiftDown
        let option = event.isOptionDown

        switch event.keyCode {
        case KeyCode.space:
            // 再生できるものだけ Space を再生 / 一時停止に使う。
            // それ以外（画像・非対応形式）は Space で閉じられるようにする。
            if preview.canPlayback {
                playback.togglePlay()
            } else {
                preview.close()
            }
            return true

        case KeyCode.escape:
            preview.close()
            return true

        case KeyCode.left, KeyCode.right:
            let forward = event.keyCode == KeyCode.right
            let sign: Double = forward ? 1 : -1
            if shift && option {
                playback.skip(sign * 10)
            } else if option {
                playback.skip(sign * 5)
            } else if shift {
                playback.skip(sign * 1)
            } else {
                playback.step(frames: forward ? 1 : -1)
            }
            return true

        case KeyCode.up, KeyCode.down:
            moveSelection(by: event.keyCode == KeyCode.down ? 1 : -1)
            return true

        case KeyCode.home:
            playback.seek(to: 0)
            return true

        case KeyCode.end:
            playback.seek(to: playback.duration)
            return true

        default:
            break
        }

        guard let key = event.plainCharacter else { return false }
        switch key {
        case "s":
            if option {
                preview.openExportPanel()
            } else {
                preview.exportFrameQuick()
            }
            return true
        case "m":
            playback.isMuted.toggle()
            return true
        case "w":
            preview.showWaveform.toggle()
            return true
        case "f":
            preview.isFullScreen.toggle()
            return true
        case "l":
            // ループは ⇧L（L 単体は M5 でシャトル早送りに割り当てる）
            if shift { playback.loops.toggle(); return true }
            return false
        case "[":
            playback.stepSpeed(-1)
            return true
        case "]":
            playback.stepSpeed(1)
            return true
        case "\\":
            playback.rate = 1.0
            return true
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            guard let digit = key.wholeNumberValue, playback.duration > 0 else { return false }
            playback.seek(to: playback.duration * Double(digit) / 10.0)
            return true
        default:
            return false
        }
    }

    /// プレビュー表示中の前後送り。
    /// 一覧の選択ではなく「開いたときと同じフォルダの並び」の中だけを動く。
    private func moveSelection(by offset: Int) {
        guard let next = preview.step(by: offset) else { return }
        // 一覧側の選択も追従させる
        if store.viewMode == .column {
            if let index = columns.chain.firstIndex(where: { $0 == next.url.deletingLastPathComponent() }) {
                columns.select(next.id, inColumnAt: index)
            } else {
                store.setSelection(next)
            }
        } else if store.visibleItems.contains(where: { $0.id == next.id }) {
            store.selection = next.id
        } else {
            store.setSelection(next)
        }
    }

    // MARK: - スクロール（コマ送り）

    func handleScroll(sign: CGFloat, modifiers: NSEvent.ModifierFlags) -> Bool {
        // 書き出しパネルの中身をスクロールしているときに動画を動かさない
        guard preview.isOpen, !preview.isExportPanelOpen, playback.isReady else { return false }
        // 上方向（+1）で戻る。トラックパッドで自然に感じる向き。
        if modifiers.contains(.option) {
            playback.skip(sign > 0 ? -1 : 1)
        } else if modifiers.contains(.shift) {
            playback.step(frames: sign > 0 ? -10 : 10)
        } else {
            playback.step(frames: sign > 0 ? -1 : 1)
        }
        return true
    }

    /// 横スクロールで波形をパンする
    func handleHorizontalScroll(delta: CGFloat) -> Bool {
        guard preview.isOpen, !preview.isExportPanelOpen,
              preview.waveformViewport.isZoomed else { return false }
        preview.panWaveform(byPixels: delta)
        return true
    }

    /// ピンチで波形をズームする
    func handleMagnify(_ amount: CGFloat) -> Bool {
        guard preview.isOpen, !preview.isExportPanelOpen, playback.duration > 0 else { return false }
        preview.magnifyWaveform(amount)
        return true
    }
}
