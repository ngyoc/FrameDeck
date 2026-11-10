import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff, heic
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tif"
        case .heic: return "heic"
        }
    }

    var label: String {
        switch self {
        case .png: return "PNG（可逆）"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        }
    }
}

struct ExportOptions {
    var format: ImageFormat = .png
    var jpegQuality: Double = 0.92
    /// nil なら原寸。指定時は長辺をこの値に収める。
    var longestEdge: Int?
    var template: String = FilenameTemplate.default
    /// 書き出し時だけ適用する色味調整。元ファイルは書き換えない。
    var color: ColorAdjustments = .neutral
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case generationFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:            return "映像トラックがないためフレームを書き出せません"
        case .generationFailed(let m): return "フレームの取得に失敗しました: \(m)"
        case .writeFailed(let m):      return "書き出しに失敗しました: \(m)"
        }
    }
}

struct ExportResult {
    let url: URL
    let pixelSize: CGSize
    let requestedTime: Double
    let actualTime: Double
}

/// 表示中のバッファではなく AVAssetImageGenerator で元素材から再抽出する（要件 4.6.5）。
/// 許容誤差ゼロなので、指定したフレームにそのまま着地する。
enum FrameExporter {

    private static let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
        .cacheIntermediates: false
    ])

    static func exportFrame(assetURL: URL,
                            at seconds: Double,
                            frameRate: Double,
                            destination: URL,
                            options: ExportOptions,
                            sequence: Int? = nil) async throws -> ExportResult {

        let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw ExportError.noVideoTrack }

        let timescale = try await track.load(.naturalTimeScale)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let longest = options.longestEdge {
            generator.maximumSize = CGSize(width: longest, height: longest)
        }

        let time = CMTime(seconds: seconds, preferredTimescale: timescale != 0 ? timescale : 600)
        let cgImage: CGImage
        let actualTime: CMTime
        do {
            (cgImage, actualTime) = try await generator.image(at: time)
        } catch {
            throw ExportError.generationFailed(error.localizedDescription)
        }

        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let baseName = FilenameTemplate.resolve(
            options.template,
            sourceName: assetURL.deletingPathExtension().lastPathComponent,
            seconds: seconds,
            frameRate: frameRate,
            sequence: sequence,
            size: pixelSize
        )
        let outURL = FilenameTemplate.uniqueURL(directory: destination,
                                                base: baseName,
                                                ext: options.format.fileExtension)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try write(cgImage: cgImage, to: outURL, options: options)

        Log.export.info("フレーム書き出し: \(outURL.lastPathComponent, privacy: .public) (\(Int(pixelSize.width))x\(Int(pixelSize.height)))")

        return ExportResult(url: outURL,
                            pixelSize: pixelSize,
                            requestedTime: seconds,
                            actualTime: actualTime.seconds)
    }

    /// 現在のフレームを色味調整込みで取得する（書き出しパネルのプレビュー用）。
    static func makeFrameImage(assetURL: URL, at seconds: Double, maximumSize: CGSize? = nil) async throws -> CGImage {
        let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw ExportError.noVideoTrack }
        let timescale = try await track.load(.naturalTimeScale)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maximumSize { generator.maximumSize = maximumSize }

        let time = CMTime(seconds: seconds, preferredTimescale: timescale != 0 ? timescale : 600)
        do {
            let (image, _) = try await generator.image(at: time)
            return image
        } catch {
            throw ExportError.generationFailed(error.localizedDescription)
        }
    }

    /// カーブエディタの背景に敷く輝度ヒストグラム（0-1 に正規化）。
    static func luminanceHistogram(_ cgImage: CGImage, bins: Int = 128) -> [Float] {
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.areaHistogram()
        filter.inputImage = input
        filter.extent = input.extent
        filter.count = bins
        filter.scale = 1
        guard let output = filter.outputImage else { return [] }

        var buffer = [Float](repeating: 0, count: bins * 4)
        buffer.withUnsafeMutableBytes { raw in
            ciContext.render(output,
                             toBitmap: raw.baseAddress!,
                             rowBytes: bins * 4 * MemoryLayout<Float>.size,
                             bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                             format: .RGBAf,
                             colorSpace: nil)
        }

        var values = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            let r = buffer[i * 4 + 0], g = buffer[i * 4 + 1], b = buffer[i * 4 + 2]
            values[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let peak = values.max() ?? 0
        guard peak > 0 else { return values }
        // 最暗部に大きな山があると他が潰れて見えないので、表示用に平方根スケールを掛ける
        return values.map { ($0 / peak).squareRoot() }
    }

    /// 色味調整を適用した CGImage を作る（プレビュー表示用）。
    static func adjusted(_ cgImage: CGImage, with color: ColorAdjustments) -> CGImage? {
        guard !color.isNeutral else { return cgImage }
        let input = CIImage(cgImage: cgImage)
        let output = ColorPipeline.apply(color, to: input)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return cgImage }
        return ciContext.createCGImage(output, from: output.extent,
                                       format: .RGBA8, colorSpace: srgb)
    }

    /// HDR 素材も含めて sRGB に落として書き出す。表示用の縮小画像は使わない。
    private static func write(cgImage: CGImage, to url: URL, options: ExportOptions) throws {
        let image = ColorPipeline.apply(options.color, to: CIImage(cgImage: cgImage))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ExportError.writeFailed("sRGB の色空間を作成できません")
        }
        do {
            switch options.format {
            case .png:
                try ciContext.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: srgb)
            case .jpeg:
                try ciContext.writeJPEGRepresentation(
                    of: image, to: url, colorSpace: srgb,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                                options.jpegQuality])
            case .tiff:
                try ciContext.writeTIFFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: srgb)
            case .heic:
                try ciContext.writeHEIFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: srgb)
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }
}
