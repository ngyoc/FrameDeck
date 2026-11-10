import AppKit
import SwiftUI

/// Space やフレーム送りのキーは SwiftUI の Table と取り合いになるため、
/// ウィンドウ手前でイベントを受けて自前で振り分ける。
/// テキスト入力中は必ず素通しする（検索欄などを壊さないため）。
@MainActor
final class EventRouter: ObservableObject {

    /// true を返したらイベントを消費する
    var onKeyDown: ((NSEvent) -> Bool)?
    /// 縦スクロール。引数は「1 ノッチあたりの符号」（上方向で +1）
    var onScroll: ((CGFloat, NSEvent.ModifierFlags) -> Bool)?
    /// 横スクロール。生のデルタをそのまま渡す（滑らかにパンさせたいので刻まない）
    var onHorizontalScroll: ((CGFloat) -> Bool)?
    /// ピンチ。倍率の変化量
    var onMagnify: ((CGFloat) -> Bool)?

    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var magnifyMonitor: Any?

    /// トラックパッドの慣性で一気に飛ばないよう、一定量ごとに 1 ノッチへ正規化する
    private var scrollAccumulator: CGFloat = 0
    private let scrollThreshold: CGFloat = 8

    func install() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isTextEditing else { return event }
            return (self.onKeyDown?(event) ?? false) ? nil : event
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            var consumed = false

            // 横方向は波形のパンに使うので刻まずそのまま渡す
            let deltaX = event.scrollingDeltaX
            if abs(deltaX) > abs(event.scrollingDeltaY), abs(deltaX) > 0.01,
               let panHandler = self.onHorizontalScroll {
                if panHandler(event.hasPreciseScrollingDeltas ? deltaX : deltaX * 12) { consumed = true }
                return consumed ? nil : event
            }

            guard let handler = self.onScroll else { return event }
            let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            self.scrollAccumulator += raw

            while abs(self.scrollAccumulator) >= self.scrollThreshold {
                let sign: CGFloat = self.scrollAccumulator > 0 ? 1 : -1
                if handler(sign, event.modifierFlags) { consumed = true }
                self.scrollAccumulator -= sign * self.scrollThreshold
            }
            if event.phase == .ended || event.momentumPhase == .ended { self.scrollAccumulator = 0 }
            return consumed ? nil : event
        }

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, let handler = self.onMagnify else { return event }
            return handler(event.magnification) ? nil : event
        }
    }

    func uninstall() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
        magnifyMonitor = nil
    }

    private var isTextEditing: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }
}

extension NSEvent {
    /// 文字キー（修飾なしのショートカット判定用）
    var plainCharacter: Character? {
        guard let chars = charactersIgnoringModifiers, let first = chars.first else { return nil }
        return Character(first.lowercased())
    }

    var isCommandDown: Bool { modifierFlags.contains(.command) }
    var isShiftDown: Bool { modifierFlags.contains(.shift) }
    var isOptionDown: Bool { modifierFlags.contains(.option) }
}

enum KeyCode {
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let home: UInt16 = 115
    static let end: UInt16 = 119
}
