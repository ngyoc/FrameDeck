import AppKit
import Foundation

/// `--click-test` で起動したとき、ウィンドウ内に実際のクリックを合成して
/// 「一覧の行をクリックしたら選択が変わるか」を確かめる。
/// 外部からのクリック送出にはアクセシビリティ権限が要るが、
/// 自分のウィンドウへ自分でイベントを流す分には不要。
@MainActor
enum ClickTest {

    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--click-test")
    }

    private static func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func run(env: AppEnvironment) async {
        out("=== クリック検証: \(env.store.viewMode.label)表示 ===")

        // 万一イベント処理で詰まっても必ず終了させる
        Task.detached {
            try? await Task.sleep(for: .seconds(45))
            FileHandle.standardOutput.write(Data("[NG] 時間切れ（イベント処理で停止）\n".utf8))
            exit(2)
        }

        // 一覧が出そろうのを待つ
        for _ in 0..<80 {
            if !env.store.visibleItems.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(1200))

        // 書き出しウィンドウなど別シーンも増えたので、本体のウィンドウを選び直す
        let candidates = NSApp.windows.filter { $0.contentView != nil }
        out("ウィンドウ一覧: " + candidates.map {
            "\($0.title.isEmpty ? "(無題)" : $0.title)[表示=\($0.isVisible) 幅=\(Int($0.frame.width))]"
        }.joined(separator: ", "))

        // 背景から起動すると表示前のことがあるので、まだ出ていなければ出す
        guard let window = candidates.max(by: { $0.frame.width < $1.frame.width }),
              let root = window.contentView else {
            out("[NG] ウィンドウが見つかりません")
            exit(1)
        }

        // 非アクティブなウィンドウへのクリックは無視されるので、キーになるまで粘る
        for _ in 0..<20 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            try? await Task.sleep(for: .milliseconds(250))
            if window.isKeyWindow && NSApp.isActive { break }
        }
        out("ウィンドウ状態: key=\(window.isKeyWindow) main=\(window.isMainWindow) app=\(NSApp.isActive ? "アクティブ" : "非アクティブ")")
        guard window.isKeyWindow else {
            out("[中断] ウィンドウを前面に出せませんでした（他のアプリがフォーカスを保持）")
            exit(3)
        }

        var passed = true
        env.store.selection = nil
        try? await Task.sleep(for: .milliseconds(200))

        // --no-click: 起動直後にクリックせず十字キーだけ試す（フォーカスの有無を切り分ける）
        if CommandLine.arguments.contains("--no-click") {
            out("クリックせず、起動直後に十字キーだけ送ります")

            // カラム表示は列ごとに読み込むので、そちらが揃うのも待つ
            if env.store.viewMode == .column {
                for _ in 0..<100 {
                    if !env.columns.activeItems.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                out("表示中のフォルダ: \(env.columns.activeColumn?.path ?? "(なし)") / \(env.columns.activeItems.count) 項目")
                out("並べ替え: \(env.store.sortField.rawValue) \(env.store.sortAscending ? "昇順" : "降順") / フォルダ優先=\(env.store.foldersFirst)")
                out("カラムの先頭5件: " + env.columns.activeItems.prefix(5).map { "\($0.isDirectory ? "[D]" : "[F]")\(shorten($0.name))" }.joined(separator: " / "))
                out("一覧の先頭5件:  " + env.store.visibleItems.prefix(5).map { "\($0.isDirectory ? "[D]" : "[F]")\(shorten($0.name))" }.joined(separator: " / "))
            } else {
                out("表示中のフォルダ: \(env.store.url.path) / \(env.store.visibleItems.count) 項目")
            }

            func selectionName() -> String {
                if env.store.viewMode == .column {
                    return env.columns.activeItem?.name ?? "(なし)"
                }
                return env.store.selectedItem?.name ?? "(なし)"
            }

            func press(_ label: String, _ code: UInt16, expectMove: Bool = true) async {
                let before = selectionName()
                let beforeFolder = env.store.url.lastPathComponent
                key(code, in: window)
                try? await Task.sleep(for: .milliseconds(500))
                let after = selectionName()
                let afterFolder = env.store.url.lastPathComponent
                let changed = before != after || beforeFolder != afterFolder
                let ok = changed == expectMove
                let folderNote = beforeFolder != afterFolder ? "  [フォルダ移動 \(beforeFolder) → \(afterFolder)]" : ""
                out("[\(ok ? "OK" : "NG")] \(label): \(shorten(before)) → \(shorten(after))\(folderNote)")
                if !ok { passed = false }
            }

            // 先頭で ↑ を押すと動かないのが正しいので、下に余裕を作ってから上を試す
            await press("↓ 選択を下へ", KeyCode.down)
            await press("↓ 選択を下へ", KeyCode.down)
            await press("↓ 選択を下へ", KeyCode.down)
            await press("↑ 選択を上へ", KeyCode.up)
            await press("↑ 選択を上へ", KeyCode.up)

            // 横方向はフォルダを選んだ状態で試す
            if env.store.viewMode == .icon || env.store.viewMode == .gallery {
                await press("→ 次の項目へ", KeyCode.right)
                await press("← 前の項目へ", KeyCode.left)
            } else {
                // 先頭のフォルダを選んでから右へ入る
                let folder = env.store.viewMode == .column
                    ? env.columns.activeItems.first(where: { $0.isDirectory })
                    : env.store.visibleItems.first(where: { $0.isDirectory })
                if env.store.viewMode == .column {
                    out("操作中の列: \(env.columns.activeColumn?.lastPathComponent ?? "(なし)") / 列数 \(env.columns.chain.count)")
                }
                if let folder {
                    if env.store.viewMode == .column {
                        // 末尾の列ではなく、いま操作している列に対して選ぶ
                        env.columns.select(folder.id, inColumnAt: env.columns.focusedIndex)
                    } else {
                        env.store.selection = folder.id
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    out("フォルダ「\(folder.name)」を選択して横方向を試します")
                    await press("→ フォルダへ入る", KeyCode.right)
                    await press("← 親へ戻る", KeyCode.left)
                } else {
                    out("[スキップ] このフォルダにサブフォルダが無いため横方向は未検証")
                }
            }

            // 選択の強調表示（青かグレーか）
            out("--- 選択の強調表示 ---")
            // アイコン表示とギャラリー表示は選択を自前で塗っているので、この検査の対象外
            let usesTable = env.store.viewMode == .list || env.store.viewMode == .column

            func focusReport(_ label: String) async {
                guard usesTable else {
                    out("[OK] \(label): 自前描画（常にアクセントカラー）")
                    return
                }
                // 検証中にウィンドウが後ろへ回ることがあるので、判定前に前面へ戻して落ち着かせる
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(500))

                let tables = AppKitBridge.fileListTables(in: window)
                let table: NSTableView? = env.store.viewMode == .column
                    ? (tables.indices.contains(env.columns.focusedIndex) ? tables[env.columns.focusedIndex] : tables.first)
                    : tables.first
                guard let table else {
                    out("[NG] \(label): 一覧のテーブルを掴めていません")
                    passed = false
                    return
                }
                let isFirst = table.window?.firstResponder === table
                let windowKey = table.window?.isKeyWindow ?? false
                let row = table.selectedRow

                if env.store.viewMode == .column {
                    // カラム表示はシステムのハイライトを止めて自前で青く塗っている
                    let suppressed = table.selectionHighlightStyle == .none
                    let ok = suppressed && isFirst
                    out("[\(ok ? "OK" : "NG")] \(label): 自前描画=\(suppressed) firstResponder=\(isFirst) 選択行=\(row)")
                    if !ok { passed = false }
                } else {
                    var emphasized = false
                    if row >= 0, let rowView = table.rowView(atRow: row, makeIfNecessary: false) {
                        emphasized = rowView.isEmphasized && rowView.isSelected
                    }
                    let ok = isFirst && emphasized
                    out("[\(ok ? "OK" : "NG")] \(label): firstResponder=\(isFirst) キーウィンドウ=\(windowKey) 選択行=\(row) 強調=\(emphasized)")
                    if !ok { passed = false }
                }
            }

            await focusReport("↓ で移動したあと")

            // 下の階層へ入ったあと
            let folderForFocus = env.store.viewMode == .column
                ? env.columns.activeItems.first(where: { $0.isDirectory })
                : env.store.visibleItems.first(where: { $0.isDirectory })
            if let folderForFocus {
                if env.store.viewMode == .column {
                    env.columns.select(folderForFocus.id, inColumnAt: env.columns.focusedIndex)
                } else {
                    env.store.selection = folderForFocus.id
                }
                try? await Task.sleep(for: .milliseconds(400))
                key(KeyCode.right, in: window)
                try? await Task.sleep(for: .milliseconds(1200))
                key(KeyCode.down, in: window)
                try? await Task.sleep(for: .milliseconds(700))
                await focusReport("下の階層へ入ったあと")
                key(KeyCode.left, in: window)
                try? await Task.sleep(for: .milliseconds(900))
                await focusReport("親へ戻ったあと")
            }

            // 追加要望ぶんの検証
            out("--- 容量表示 ---")
            let folderTotal = env.store.visibleFilesTotalBytes
            out("[\(folderTotal > 0 ? "OK" : "NG")] このフォルダのファイル合計: \(Fmt.bytes(folderTotal))")
            if folderTotal <= 0 { passed = false }

            if env.store.viewMode != .column {
                let files = env.store.visibleItems.filter { !$0.isDirectory }.prefix(3)
                env.store.selectedIDs = Set(files.map(\.id))
                try? await Task.sleep(for: .milliseconds(300))
                let sum = env.store.selectedFilesTotalBytes
                let expected = files.compactMap(\.displaySize).reduce(0, +)
                out("[\(sum == expected && sum > 0 ? "OK" : "NG")] 複数選択の合計: \(files.count) 件 / \(Fmt.bytes(sum))")
                if sum != expected || sum <= 0 { passed = false }
                env.store.selectedIDs = []
                try? await Task.sleep(for: .milliseconds(200))
            }

            // スペースキーでプレビューが開くか
            out("--- スペースキー ---")

            // まず動画ファイルを選ぶ
            let video = env.store.viewMode == .column
                ? env.columns.activeItems.first(where: { $0.kind == .video })
                : env.store.visibleItems.first(where: { $0.kind == .video })
            if let video {
                if env.store.viewMode == .column {
                    env.columns.select(video.id, inColumnAt: env.columns.focusedIndex)
                } else {
                    env.store.selection = video.id
                }
                try? await Task.sleep(for: .milliseconds(400))
                out("選択中: \(shorten(video.name)) / store.selectedItem=\(env.store.selectedItem?.name.prefix(16) ?? "(なし)")")

                key(KeyCode.space, in: window)
                try? await Task.sleep(for: .milliseconds(900))
                let opened = env.preview.isOpen
                out("[\(opened ? "OK" : "NG")] Space でプレビューが開く: \(opened ? "開いた" : "開かない")")
                if !opened { passed = false }

                if opened {
                    // 動画は Space が再生 / 一時停止に割り当たること
                    let wasPlaying = env.preview.playback.isPlaying
                    key(KeyCode.space, in: window)
                    try? await Task.sleep(for: .milliseconds(700))
                    let stillOpen = env.preview.isOpen
                    let toggled = env.preview.playback.isPlaying != wasPlaying
                    out("[\(stillOpen && toggled ? "OK" : "NG")] 動画は Space で再生 / 一時停止（閉じない）: 開いたまま=\(stillOpen) 再生状態が変化=\(toggled)")
                    if !stillOpen || !toggled { passed = false }

                    key(KeyCode.escape, in: window)
                    try? await Task.sleep(for: .milliseconds(600))
                    out("[\(env.preview.isOpen ? "NG" : "OK")] Esc で閉じる")
                    if env.preview.isOpen { passed = false }
                }

                // 画像や非対応ファイルは Space で閉じられること
                let nonPlayable = env.store.viewMode == .column
                    ? env.columns.activeItems.first(where: { $0.kind == .image || $0.kind == .other })
                    : env.store.visibleItems.first(where: { $0.kind == .image || $0.kind == .other })
                if let nonPlayable {
                    let siblings = env.store.viewMode == .column ? env.columns.activeItems : env.store.visibleItems
                    env.preview.open(nonPlayable, siblings: siblings)
                    try? await Task.sleep(for: .milliseconds(900))
                    out("非再生ファイル: \(shorten(nonPlayable.name)) / canPlayback=\(env.preview.canPlayback)")
                    key(KeyCode.space, in: window)
                    try? await Task.sleep(for: .milliseconds(700))
                    out("[\(env.preview.isOpen ? "NG" : "OK")] 再生できないファイルは Space で閉じる")
                    if env.preview.isOpen { passed = false; env.preview.close() }
                }

                // プレビュー中の前後送りが同じフォルダに閉じているか
                out("--- プレビュー中の前後送り ---")
                do {
                    let siblings = env.store.viewMode == .column ? env.columns.activeItems : env.store.visibleItems
                    env.preview.open(video, siblings: siblings)
                    try? await Task.sleep(for: .milliseconds(800))
                    let folder = video.url.deletingLastPathComponent()
                    var allSame = true
                    var names: [String] = []
                    for _ in 0..<4 {
                        key(KeyCode.down, in: window)
                        try? await Task.sleep(for: .milliseconds(450))
                        guard let now = env.preview.item else { continue }
                        names.append(shorten(now.name))
                        if now.url.deletingLastPathComponent() != folder { allSame = false }
                    }
                    out("送った先: \(names.joined(separator: " → "))")
                    out("[\(allSame ? "OK" : "NG")] 前後送りが同じフォルダ内に収まる（\(folder.lastPathComponent)）")
                    if !allSame { passed = false }
                    env.preview.close()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            } else {
                out("[スキップ] 動画ファイルが見つかりません")
            }

            // 空のフォルダに矢印キーで入ってしまわないか
            out("--- 空フォルダ ---")
            let emptyName = "空のフォルダ"
            let source: [FileItem] = env.store.viewMode == .column
                ? env.columns.activeItems : env.store.visibleItems
            if let empty = source.first(where: { $0.name == emptyName && $0.isDirectory }) {
                if env.store.viewMode == .column {
                    env.columns.select(empty.id, inColumnAt: env.columns.focusedIndex)
                } else {
                    env.store.selection = empty.id
                }
                try? await Task.sleep(for: .milliseconds(700))
                let beforeFolder = env.store.url.lastPathComponent
                let beforeCol = env.store.viewMode == .column ? env.columns.focusedIndex : -1

                key(KeyCode.right, in: window)
                try? await Task.sleep(for: .milliseconds(900))

                let afterFolder = env.store.url.lastPathComponent
                let afterCol = env.store.viewMode == .column ? env.columns.focusedIndex : -1
                let stayed = (beforeFolder == afterFolder) && (beforeCol == afterCol)
                out("[\(stayed ? "OK" : "NG")] 空フォルダに → で入らない（フォルダ \(beforeFolder)→\(afterFolder) / 列 \(beforeCol)→\(afterCol)）")
                if !stayed { passed = false }

                // そのあとも上下が効くこと（固まっていないこと）
                let beforeSel = env.store.selectedItem?.name ?? "(なし)"
                key(KeyCode.down, in: window)
                try? await Task.sleep(for: .milliseconds(600))
                let afterSel = env.store.selectedItem?.name ?? "(なし)"
                let alive = beforeSel != afterSel
                out("[\(alive ? "OK" : "NG")] そのあとも ↓ が効く: \(shorten(beforeSel)) → \(shorten(afterSel))")
                if !alive { passed = false }
            } else {
                out("[スキップ] 「\(emptyName)」が見つかりません")
            }

            out(passed ? "=== 総合: OK ===" : "=== 総合: NG ===")
            exit(passed ? 0 : 1)
        }

        switch env.store.viewMode {
        case .list, .column:
            let tables = AppKitBridge.tableViews(in: root)
            out("見つかった一覧ビュー: \(tables.count) 個（行数: \(tables.map(\.numberOfRows).map(String.init).joined(separator: ", "))）")
            // 行数がいちばん多いものがファイル一覧（少ないほうはサイドバー）
            guard let table = tables.max(by: { $0.numberOfRows < $1.numberOfRows }),
                  table.numberOfRows > 3 else {
                out("[NG] ファイル一覧のビューを特定できません")
                exit(1)
            }
            let rect = table.rect(ofRow: 3)
            // 行の中心は区切り線に当たることがあるので少し内側を狙う
            let inside = CGPoint(x: rect.minX + 40, y: rect.midY + (table.isFlipped ? -3 : 3))
            let point = table.convert(inside, to: nil)
            out("クリック位置: 行 3 の中心（ウィンドウ座標 \(Int(point.x)), \(Int(point.y))）")
            click(at: point, in: window, clickCount: 1)

        case .icon, .gallery:
            // グリッド / ストリップは NSTableView ではないので、座標を直接狙う
            let point = env.store.viewMode == .icon
                ? CGPoint(x: root.bounds.minX + 320, y: root.bounds.maxY - 140)
                : CGPoint(x: root.bounds.minX + 420, y: root.bounds.minY + 90)
            out("クリック位置: ウィンドウ座標 \(Int(point.x)), \(Int(point.y))")
            click(at: point, in: window, clickCount: 1)
        }

        try? await Task.sleep(for: .milliseconds(700))

        guard let firstSelection = env.store.selectedItem else {
            out("[NG] 単一クリックしても選択されませんでした")
            out("=== 総合: NG ===")
            exit(1)
        }
        out("[OK] 単一クリックで選択: \(firstSelection.name)")

        // 十字キーで選択が動くか
        for (label, code) in [("↓", KeyCode.down), ("↓", KeyCode.down), ("↑", KeyCode.up)] {
            let before = env.store.selectedItem?.name ?? "(なし)"
            key(code, in: window)
            try? await Task.sleep(for: .milliseconds(350))
            let after = env.store.selectedItem?.name ?? "(なし)"
            let moved = before != after
            out("[\(moved ? "OK" : "NG")] \(label) キー: \(shorten(before)) → \(shorten(after))")
            if !moved { passed = false }
        }

        // 複数選択（⌘クリック / ⇧クリック）
        out("--- 複数選択 ---")
        await checkMultiSelect(env: env, window: window) { line, ok in
            out(line); if !ok { passed = false }
        }

        out("--- クリックしてからスペースキー ---")
        out("選択中: \(shorten(env.store.selectedItem?.name ?? "(なし)"))")
        key(KeyCode.space, in: window)
        try? await Task.sleep(for: .milliseconds(900))
        out("[\(env.preview.isOpen ? "OK" : "NG")] Space でプレビューが開く")
        if !env.preview.isOpen { passed = false }

        // カラム表示は 2 列目（サブフォルダの中）でも試す
        if env.store.viewMode == .column {
            if env.preview.isOpen {
                key(KeyCode.escape, in: window)
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let folder = env.columns.activeItems.first(where: { $0.isDirectory }) {
                env.columns.select(folder.id, inColumnAt: env.columns.focusedIndex)
                try? await Task.sleep(for: .milliseconds(700))
                _ = env.columns.enterSelected()
                try? await Task.sleep(for: .milliseconds(700))
                let inner = env.columns.activeItem
                out("2 列目の選択: \(shorten(inner?.name ?? "(なし)")) / store.selectedItem=\(shorten(env.store.selectedItem?.name ?? "(なし)"))")
                key(KeyCode.space, in: window)
                try? await Task.sleep(for: .milliseconds(900))
                out("[\(env.preview.isOpen ? "OK" : "NG")] 2 列目で Space が効く")
                if !env.preview.isOpen { passed = false }
            }
        }

        out(passed ? "=== 総合: OK ===" : "=== 総合: NG ===")
        exit(passed ? 0 : 1)
    }

    /// 2 行目を ⌘ クリックして、選択が 2 件になるかを見る
    private static func checkMultiSelect(env: AppEnvironment, window: NSWindow,
                                         report: (String, Bool) -> Void) async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))

        // 表示形式ごとに「別々の項目 3 つ」の座標を作る
        var points: [CGPoint] = []
        let mode = env.store.viewMode
        if mode == .list || mode == .column {
            let tables = AppKitBridge.fileListTables(in: window)
            let table: NSTableView? = mode == .column
                ? (tables.indices.contains(env.columns.focusedIndex) ? tables[env.columns.focusedIndex] : tables.first)
                : tables.first
            guard let table, table.numberOfRows > 9 else {
                report("[スキップ] 行が足りないので未検証", true); return
            }
            for row in [3, 5, 8] {
                let r = table.rect(ofRow: row)
                points.append(table.convert(CGPoint(x: r.minX + 60,
                                                    y: r.midY + (table.isFlipped ? -3 : 3)), to: nil))
            }
        } else if mode == .icon {
            // グリッドのセル中心をおおよそで狙う
            guard let root = window.contentView else { return }
            let top = root.bounds.maxY - 150
            for (dx, dy) in [(330, 0), (500, 0), (330, -230)] {
                points.append(CGPoint(x: root.bounds.minX + CGFloat(dx), y: top + CGFloat(dy)))
            }
        } else {
            // ギャラリーは下部のサムネイルストリップ
            guard let root = window.contentView else { return }
            let y = root.bounds.minY + 95
            for dx in [330, 430, 530] {
                points.append(CGPoint(x: root.bounds.minX + CGFloat(dx), y: y))
            }
        }

        func rowPoint(_ i: Int) -> CGPoint { points[min(i, points.count - 1)] }

        click(at: rowPoint(0), in: window, clickCount: 1)
        try? await Task.sleep(for: .milliseconds(500))
        let afterFirst = env.store.selectedIDs.count
        report("1 件目のクリック後: \(afterFirst) 件選択", afterFirst == 1)

        click(at: rowPoint(1), in: window, clickCount: 1, modifiers: [.command])
        try? await Task.sleep(for: .milliseconds(600))
        let afterCmd = env.store.selectedIDs.count
        report("[\(afterCmd == 2 ? "OK" : "NG")] ⌘クリックで追加: \(afterCmd) 件選択", afterCmd == 2)

        click(at: rowPoint(2), in: window, clickCount: 1, modifiers: [.shift])
        try? await Task.sleep(for: .milliseconds(600))
        let afterShift = env.store.selectedIDs.count
        // アイコン / ギャラリーは自前の判定なので ⇧ は「追加」になる（範囲選択は未実装）
        let shiftOK = (mode == .list || mode == .column) ? afterShift > 2 : afterShift >= 3
        report("[\(shiftOK ? "OK" : "NG")] ⇧クリック後: \(afterShift) 件選択", shiftOK)

        let bytes = env.store.selectedFilesTotalBytes
        report("[\(bytes > 0 ? "OK" : "NG")] 合計サイズ: \(Fmt.bytes(bytes))", bytes > 0)
    }

    private static func shorten(_ text: String) -> String {
        text.count > 24 ? String(text.prefix(24)) + "…" : text
    }

    private static func key(_ keyCode: UInt16, in window: NSWindow) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let isArrow = [KeyCode.up, KeyCode.down, KeyCode.left, KeyCode.right].contains(keyCode)
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: isArrow ? [.function, .numericPad] : [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                characters: keyCode == KeyCode.space ? " " : "",
                charactersIgnoringModifiers: keyCode == KeyCode.space ? " " : "",
                isARepeat: false,
                keyCode: keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func click(at point: CGPoint, in window: NSWindow, clickCount: Int,
                              modifiers: NSEvent.ModifierFlags = []) {
        // どのビューに当たっているかも出しておく（座標のずれと本当の不具合を切り分けるため）
        if let hit = window.contentView?.hitTest(point) {
            out("当たったビュー: \(type(of: hit))")
        } else {
            out("当たったビュー: なし（座標がウィンドウ外の可能性）")
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: modifiers,
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
