import Foundation
import UniformTypeIdentifiers

enum MediaKind: String {
    case folder
    case video
    case image
    case audio
    case other

    var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .video:  return "film"
        case .image:  return "photo"
        case .audio:  return "waveform"
        case .other:  return "doc"
        }
    }
}

/// AVFoundation / ImageIO がそのまま扱える形式かどうかの判定。
/// ffmpeg を同梱しない方針のため、扱えないものは「非対応」と明示する（黙って失敗させない）。
enum MediaSupport {

    /// AVFoundation で再生できる動画コンテナ。
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "qt"]

    /// AVFoundation で再生できる音声コンテナ。
    static let audioExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "adts", "caf", "flac", "au"
    ]

    /// 一覧では表示するがプレビューはできない形式。理由の提示に使う。
    static let knownUnsupportedExtensions: Set<String> = [
        "mkv", "webm", "ogv", "ogg", "flv", "wmv", "avi", "mxf", "r3d", "braw", "ari", "mts", "m2ts", "ts", "vob", "rm", "asf"
    ]

    static func kind(for url: URL, contentType: UTType?, isDirectory: Bool) -> MediaKind {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()

        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }

        if let type = contentType {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .other
    }

    /// プレビューを試みる価値があるか。false の場合は理由メッセージを出す。
    static func isPreviewable(_ kind: MediaKind, url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if knownUnsupportedExtensions.contains(ext) { return false }
        switch kind {
        case .video, .audio, .image: return true
        case .folder, .other: return false
        }
    }

    static func unsupportedReason(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if knownUnsupportedExtensions.contains(ext) {
            return "\(ext.uppercased()) は AVFoundation が対応していないため再生できません。\n（FrameDeck は ffmpeg を同梱しない方針です）"
        }
        return "この形式のプレビューには対応していません。"
    }
}
