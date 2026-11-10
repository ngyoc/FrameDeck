import OSLog

/// アプリ全体のログ出力口。
/// サイレントフォールバック禁止のルールに従い、フォールバックが起きた箇所では必ずここに理由を残す。
enum Log {
    private static let subsystem = "com.laorca.framedeck"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let waveform = Logger(subsystem: subsystem, category: "waveform")
    static let export = Logger(subsystem: subsystem, category: "export")
}
