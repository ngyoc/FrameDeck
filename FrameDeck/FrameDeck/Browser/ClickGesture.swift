import AppKit
import SwiftUI

/// 単一クリックで選択、2 連クリックで開く。
/// onTapGesture を 2 つ重ねると片方しか反応しないことがあるため、
/// 「まず 2 連クリックを試し、外れたら単一クリック」と明示的に組み立てる。
extension View {
    /// - Parameter select: 単一クリック。引数は ⌘ / ⇧ が押されていたか（複数選択の合図）。
    func fileClickGesture(select: @escaping (_ extending: Bool) -> Void,
                          activate: @escaping () -> Void) -> some View {
        gesture(
            TapGesture(count: 2).onEnded { activate() }
                .exclusively(before: TapGesture(count: 1).onEnded {
                    // 静的な NSEvent.modifierFlags ではなく、いま処理中のイベントから読む。
                    // 静的な方はハードウェアの現在状態を返すので、取りこぼすことがある。
                    let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                    select(flags.contains(.command) || flags.contains(.shift))
                })
        )
    }
}
