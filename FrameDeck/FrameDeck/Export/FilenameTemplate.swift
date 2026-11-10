import CoreGraphics
import Foundation

enum FilenameTemplate {

    static let `default` = "{name}_{tc}"

    static let variables: [(token: String, description: String)] = [
        ("{name}",  "元ファイル名（拡張子なし）"),
        ("{tc}",    "タイムコード HHMMSSFF"),
        ("{time}",  "実時間 HHMMSSmmm"),
        ("{frame}", "フレーム番号"),
        ("{seq}",   "書き出し連番"),
        ("{date}",  "書き出し日 YYYYMMDD"),
        ("{w}",     "出力幅"),
        ("{h}",     "出力高さ")
    ]

    static func resolve(_ template: String,
                        sourceName: String,
                        seconds: Double,
                        frameRate: Double,
                        sequence: Int?,
                        size: CGSize) -> String {
        let tc = Fmt.timecode(seconds, frameRate: frameRate)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        let time = Fmt.time(seconds)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        let frame = frameRate > 0 ? Int((seconds * frameRate).rounded()) : Int(seconds * 1000)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"

        var out = template
        out = out.replacingOccurrences(of: "{name}", with: sourceName)
        out = out.replacingOccurrences(of: "{tc}", with: tc)
        out = out.replacingOccurrences(of: "{time}", with: time)
        out = out.replacingOccurrences(of: "{frame}", with: String(format: "%06d", frame))
        out = out.replacingOccurrences(of: "{seq}", with: sequence.map { String(format: "%03d", $0) } ?? "")
        out = out.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: Date()))
        out = out.replacingOccurrences(of: "{w}", with: String(Int(size.width)))
        out = out.replacingOccurrences(of: "{h}", with: String(Int(size.height)))

        return sanitize(out)
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "frame" : cleaned
    }

    /// 同名ファイルがあれば連番を付ける。既存ファイルは上書きしない。
    static func uniqueURL(directory: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(index).\(ext)")
            index += 1
        }
        return candidate
    }
}
