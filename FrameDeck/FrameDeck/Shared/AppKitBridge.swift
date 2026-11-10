import AppKit
import SwiftUI

/// SwiftUI の List / Table の下地にある AppKit のビューを扱うための橋渡し。
/// SwiftUI から直接できない「キーボードフォーカスの移動」と「行のスクロール」だけに使う。
enum AppKitBridge {

    static func tableViews(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView { found.append(table) }
        view.subviews.forEach { found.append(contentsOf: tableViews(in: $0)) }
        return found
    }

    /// ウィンドウ内の一覧テーブルを左から順に返す。
    /// 先頭はサイドバー、その後ろがファイル一覧（カラム表示なら列の順）になる。
    static func orderedTableViews(in window: NSWindow?) -> [NSTableView] {
        guard let root = window?.contentView else { return [] }
        return tableViews(in: root)
            .map { (table: $0, x: $0.convert($0.bounds, to: nil).minX) }
            .sorted { $0.x < $1.x }
            .map(\.table)
    }

    /// サイドバーを除いたファイル一覧のテーブル群
    static func fileListTables(in window: NSWindow?) -> [NSTableView] {
        let all = orderedTableViews(in: window)
        guard all.count > 1 else { return all }
        // いちばん左はサイドバー
        return Array(all.dropFirst())
    }

    /// 指定の並び順・行数に当てはまるテーブルを選ぶ。
    /// 位置で決められない場合は行数で照合する。
    static func fileListTable(in window: NSWindow?, index: Int, expectedRows: Int?) -> NSTableView? {
        let tables = fileListTables(in: window)
        guard !tables.isEmpty else { return nil }
        if tables.indices.contains(index) {
            let candidate = tables[index]
            if expectedRows == nil || candidate.numberOfRows == expectedRows { return candidate }
        }
        if let expectedRows {
            if let match = tables.first(where: { $0.numberOfRows == expectedRows }) { return match }
        }
        return tables.indices.contains(index) ? tables[index] : tables.last
    }
}

extension NSTableView {
    /// キーボードフォーカスを移して選択を強調表示（青）にする
    @discardableResult
    func takeKeyboardFocus() -> Bool {
        guard let window else { return false }
        if window.firstResponder === self { return true }
        return window.makeFirstResponder(self)
    }
}

/// 十字キー操作のあとにフォーカスとスクロールを整える。
@MainActor
enum ListFocus {

    private static var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
    }

    /// リスト表示（ファイル一覧のテーブルは 1 つだけ）
    @discardableResult
    static func focusList(rowCount: Int, selectedRow: Int?) -> NSTableView? {
        guard let table = AppKitBridge.fileListTable(in: window, index: 0, expectedRows: rowCount) else {
            return nil
        }
        apply(table, row: selectedRow)
        return table
    }

    /// カラム表示（左から index 番目の列）
    @discardableResult
    static func focusColumn(index: Int, rowCount: Int, selectedRow: Int?) -> NSTableView? {
        guard let table = AppKitBridge.fileListTable(in: window, index: index, expectedRows: rowCount) else {
            return nil
        }
        apply(table, row: selectedRow)
        return table
    }

    private static func apply(_ table: NSTableView, row: Int?) {
        table.takeKeyboardFocus()
        if let row, row >= 0, row < table.numberOfRows {
            table.scrollRowToVisible(row)
        }
    }

    /// カラム表示は選択を自前で青く塗るので、システムのハイライトを止める。
    /// 止めないと、フォーカスの無い列にグレーの帯が重なって見える。
    static func suppressColumnHighlights() {
        for table in AppKitBridge.fileListTables(in: window)
        where table.selectionHighlightStyle != .none {
            table.selectionHighlightStyle = .none
        }
    }

    /// 列が増減した直後はテーブルがまだ無いことがあるので、少し置いてからもう一度当てる
    static func suppressColumnHighlightsSoon() {
        suppressColumnHighlights()
        Task { @MainActor in
            for delay in [80, 250, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                suppressColumnHighlights()
            }
        }
    }
}
