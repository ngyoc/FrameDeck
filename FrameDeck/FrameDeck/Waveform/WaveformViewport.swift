import Foundation

/// 波形の表示範囲。長尺で発話位置を詰めるためのズームとパンを担う。
struct WaveformViewport: Equatable {

    /// 素材全体の長さ
    var duration: Double = 0
    /// 表示している時間幅
    var visibleDuration: Double = 0
    /// 表示範囲の開始時刻
    var start: Double = 0

    /// 最大でどこまで寄れるか（画面いっぱいに何秒ぶんを出すか）
    static let minimumVisibleDuration: Double = 0.5

    var end: Double { start + visibleDuration }
    var isZoomed: Bool { duration > 0 && visibleDuration < duration - 0.0001 }

    var zoomFactor: Double {
        guard duration > 0, visibleDuration > 0 else { return 1 }
        return duration / visibleDuration
    }

    var zoomLabel: String {
        guard isZoomed else { return "全体" }
        let factor = zoomFactor
        return factor >= 10 ? String(format: "%.0fx", factor) : String(format: "%.1fx", factor)
    }

    mutating func reset(duration: Double) {
        self.duration = duration
        self.visibleDuration = duration
        self.start = 0
    }

    /// 中心時刻を保ったまま拡大縮小する
    mutating func zoom(by factor: Double, around anchor: Double) {
        guard duration > 0 else { return }
        let lowerBound = min(WaveformViewport.minimumVisibleDuration, duration)
        let newVisible = min(duration, max(lowerBound, visibleDuration / factor))
        // アンカーが表示範囲内で同じ相対位置に留まるようにする
        let ratio = visibleDuration > 0 ? (anchor - start) / visibleDuration : 0.5
        visibleDuration = newVisible
        start = anchor - newVisible * ratio
        clamp()
    }

    mutating func zoomIn(around anchor: Double) { zoom(by: 2, around: anchor) }
    mutating func zoomOut(around anchor: Double) { zoom(by: 0.5, around: anchor) }

    mutating func pan(by seconds: Double) {
        start += seconds
        clamp()
    }

    /// 再生ヘッドが表示範囲から出そうなときに追従させる
    mutating func follow(_ time: Double) {
        guard isZoomed else { return }
        let margin = visibleDuration * 0.15
        if time < start + margin {
            start = time - margin
        } else if time > end - margin {
            start = time - visibleDuration + margin
        }
        clamp()
    }

    /// 指定時刻を中央に置く
    mutating func center(on time: Double) {
        guard isZoomed else { return }
        start = time - visibleDuration / 2
        clamp()
    }

    private mutating func clamp() {
        visibleDuration = min(max(visibleDuration, min(WaveformViewport.minimumVisibleDuration, duration)), max(duration, 0.0001))
        start = min(max(0, start), max(0, duration - visibleDuration))
    }

    // MARK: - 座標変換

    func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, visibleDuration > 0 else { return start }
        return min(duration, max(0, start + Double(x / width) * visibleDuration))
    }

    func x(forTime time: Double, width: CGFloat) -> CGFloat {
        guard visibleDuration > 0 else { return 0 }
        return CGFloat((time - start) / visibleDuration) * width
    }
}
