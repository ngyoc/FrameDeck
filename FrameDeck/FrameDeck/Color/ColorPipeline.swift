import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 色味調整を CoreImage のフィルタ列として組み立てる。
/// 適用順は Premiere の基本補正に合わせた（ホワイトバランス → 露光 → ハイライト/シャドウ →
/// コントラスト/彩度 → レベル・カーブ）。
enum ColorPipeline {

    /// 白レベル・黒レベル・各カーブをまとめて 1 本の 1D LUT に焼き込む段数
    private static let lutSize = 256

    static func apply(_ adjustments: ColorAdjustments, to image: CIImage) -> CIImage {
        guard !adjustments.isNeutral else { return image }
        var output = image

        output = applyWhiteBalance(adjustments, to: output)
        output = applyExposure(adjustments, to: output)
        output = applyHighlightShadow(adjustments, to: output)
        output = applyContrastSaturation(adjustments, to: output)
        output = applyLevelsAndCurves(adjustments, to: output)

        // フィルタで範囲外に飛んだ値を 0-1 に戻す（書き出し時の色化けを防ぐ）
        return output.clampedToExtent().cropped(to: image.extent)
    }

    // MARK: - ホワイトバランス

    private static func applyWhiteBalance(_ a: ColorAdjustments, to image: CIImage) -> CIImage {
        guard a.temperature != 0 || a.tint != 0 else { return image }
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        // 基準 6500K。正で暖色（色温度を下げた光源として扱う）、負で寒色。
        filter.neutral = CIVector(x: 6500 - a.temperature * 25, y: -a.tint * 0.5)
        filter.targetNeutral = CIVector(x: 6500, y: 0)
        return filter.outputImage ?? image
    }

    // MARK: - 露光量

    private static func applyExposure(_ a: ColorAdjustments, to image: CIImage) -> CIImage {
        guard a.exposure != 0 else { return image }
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = Float(a.exposure)
        return filter.outputImage ?? image
    }

    // MARK: - ハイライト / シャドウ

    private static func applyHighlightShadow(_ a: ColorAdjustments, to image: CIImage) -> CIImage {
        guard a.highlights != 0 || a.shadows != 0 else { return image }
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        // CIHighlightShadowAdjust は highlightAmount 1.0 が無調整、下げるとハイライトが落ちる。
        filter.highlightAmount = Float(1.0 + a.highlights / 200.0)
        // shadowAmount は 0 が無調整、正で持ち上げ、負で沈める。
        filter.shadowAmount = Float(a.shadows / 100.0)
        filter.radius = 12
        return filter.outputImage ?? image
    }

    // MARK: - コントラスト / 彩度

    private static func applyContrastSaturation(_ a: ColorAdjustments, to image: CIImage) -> CIImage {
        guard a.contrast != 0 || a.saturation != 100 else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = Float(1.0 + a.contrast / 100.0)
        filter.saturation = Float(a.saturation / 100.0)
        filter.brightness = 0
        return filter.outputImage ?? image
    }

    // MARK: - 白レベル / 黒レベル / カーブ

    private static func applyLevelsAndCurves(_ a: ColorAdjustments, to image: CIImage) -> CIImage {
        guard a.whites != 0 || a.blacks != 0 || a.hasCurveEdits else { return image }
        guard let curves = CIFilter(name: "CIColorCurves") else {
            Log.export.error("CIColorCurves を作成できないためレベルとカーブを適用しません")
            return image
        }
        curves.setValue(image, forKey: kCIInputImageKey)
        curves.setValue(makeLUT(a), forKey: "inputCurvesData")
        curves.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        // kCIInputColorSpaceKey は macOS 26 以降なので、下限 14.0 に合わせて文字列キーを使う
        curves.setValue(CGColorSpaceCreateDeviceRGB(), forKey: "inputColorSpace")
        return curves.outputImage ?? image
    }

    /// 白レベル・黒レベル・明るさカーブ・RGB カーブを 1 本の LUT にまとめる。
    /// フィルタを重ねるより誤差が乗りにくく、処理も 1 パスで済む。
    private static func makeLUT(_ a: ColorAdjustments) -> Data {
        var values = [Float](repeating: 0, count: lutSize * 3)

        // 白レベル / 黒レベルは入力レンジの伸縮として扱う
        let blackPoint = -a.blacks / 100.0 * 0.25      // 正で持ち上げ、負で締める
        let whitePoint = 1.0 - a.whites / 100.0 * 0.25 // 正で伸ばす、負で抑える
        let span = max(0.05, whitePoint - blackPoint)

        for i in 0..<lutSize {
            let x = Double(i) / Double(lutSize - 1)
            var v = (x - blackPoint) / span
            v = min(1, max(0, v))
            v = a.lumaCurve.evaluate(v)
            values[i * 3 + 0] = Float(a.redCurve.evaluate(v))
            values[i * 3 + 1] = Float(a.greenCurve.evaluate(v))
            values[i * 3 + 2] = Float(a.blueCurve.evaluate(v))
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
