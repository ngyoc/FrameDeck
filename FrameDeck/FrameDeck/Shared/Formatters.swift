import Foundation

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "--" }
        return dateFormatter.string(from: value)
    }

    /// HH:MM:SS.mmm 形式。実時間の表示に使う。
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--:--.---" }
        let total = Int(seconds)
        let ms = Int(((seconds - Double(total)) * 1000).rounded())
        // 999.5ms 以上が繰り上がって 1000 になった場合の補正
        let (carry, msFixed) = ms >= 1000 ? (1, 0) : (0, ms)
        let t = total + carry
        return String(format: "%02d:%02d:%02d.%03d", t / 3600, (t % 3600) / 60, t % 60, msFixed)
    }

    /// HH:MM:SS:FF 形式。fps が不明（0）のときは実時間表記にフォールバックする。
    static func timecode(_ seconds: Double, frameRate: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--:--:--" }
        guard frameRate > 0 else { return time(seconds) }
        let fps = frameRate.rounded()
        var frame = Int((seconds * frameRate).rounded())
        let fpsInt = max(1, Int(fps))
        let totalSeconds = frame / fpsInt
        frame %= fpsInt
        return String(format: "%02d:%02d:%02d:%02d",
                      totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60, frame)
    }

    /// 短い長さ表記（一覧の列など）。1 時間未満は M:SS、以上は H:MM:SS。
    static func shortDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--" }
        let t = Int(seconds.rounded())
        if t >= 3600 {
            return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
