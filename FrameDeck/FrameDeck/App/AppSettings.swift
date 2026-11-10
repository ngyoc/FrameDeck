import Foundation
import SwiftUI

/// フレームの書き出し先の決め方
enum ExportDestinationMode: String, CaseIterable, Identifiable {
    /// 動画と同じ階層に、動画と同じ名前のフォルダを作ってその中へ
    case alongsideSource
    case desktop
    case fixedFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alongsideSource: return "動画と同じ場所に動画名のフォルダを作る"
        case .desktop:         return "デスクトップ"
        case .fixedFolder:     return "指定したフォルダ"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {

    @AppStorage("export.destinationPath") private var destinationPath: String = ""
    @AppStorage("export.destinationMode") private var destinationModeRaw: String = ExportDestinationMode.alongsideSource.rawValue
    @AppStorage("export.format") private var formatRaw: String = ImageFormat.png.rawValue
    @AppStorage("export.template") var exportTemplate: String = FilenameTemplate.default
    @AppStorage("export.jpegQuality") var jpegQuality: Double = 0.92
    @AppStorage("export.longestEdge") var longestEdge: Int = 0   // 0 = 原寸

    @AppStorage("preview.showWaveform") var showWaveform: Bool = true
    @AppStorage("preview.autoPlay") var autoPlay: Bool = false

    var destinationMode: ExportDestinationMode {
        get { ExportDestinationMode(rawValue: destinationModeRaw) ?? .alongsideSource }
        set { destinationModeRaw = newValue.rawValue }
    }

    /// 「指定したフォルダ」を選んだときの保存先
    var fixedDestination: URL {
        get {
            if !destinationPath.isEmpty {
                let url = URL(fileURLWithPath: destinationPath)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
                Log.export.notice("書き出し先が存在しないためデスクトップに戻します: \(self.destinationPath, privacy: .public)")
            }
            return AppSettings.desktopURL
        }
        set { destinationPath = newValue.path }
    }

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// 素材ごとの実際の書き出し先を決める。
    /// 既定は「動画と同じ階層に、拡張子を除いた動画名のフォルダを作ってその中へ」。
    func exportDestination(for sourceURL: URL) -> URL {
        switch destinationMode {
        case .alongsideSource:
            let folderName = FilenameTemplate.sanitize(sourceURL.deletingPathExtension().lastPathComponent)
            return sourceURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        case .desktop:
            return AppSettings.desktopURL
        case .fixedFolder:
            return fixedDestination
        }
    }

    var exportFormat: ImageFormat {
        get { ImageFormat(rawValue: formatRaw) ?? .png }
        set { formatRaw = newValue.rawValue }
    }

    func exportOptions(color: ColorAdjustments = .neutral) -> ExportOptions {
        ExportOptions(format: exportFormat,
                      jpegQuality: jpegQuality,
                      longestEdge: longestEdge > 0 ? longestEdge : nil,
                      template: exportTemplate,
                      color: color)
    }
}
