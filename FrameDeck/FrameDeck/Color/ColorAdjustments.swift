import Foundation

/// フレーム書き出し時の色味調整。Premiere の「基本補正」と「カーブ」に相当する。
/// 一時的な設定で、元の動画ファイルには一切書き込まない。
struct ColorAdjustments: Codable, Equatable {

    // カラー
    /// 色温度。負で青寄り、正で暖色寄り（-100 - 100）
    var temperature: Double = 0
    /// 色かぶり補正。負で緑寄り、正でマゼンタ寄り（-100 - 100）
    var tint: Double = 0
    /// 彩度（0 - 200、100 が等倍）
    var saturation: Double = 100

    // ライト
    /// 露光量（EV、-5 - 5）
    var exposure: Double = 0
    /// コントラスト（-100 - 100）
    var contrast: Double = 0
    /// ハイライト（-100 - 100）
    var highlights: Double = 0
    /// シャドウ（-100 - 100）
    var shadows: Double = 0
    /// 白レベル（-100 - 100）
    var whites: Double = 0
    /// 黒レベル（-100 - 100）
    var blacks: Double = 0

    // カーブ
    var lumaCurve: ToneCurve = .identity
    var redCurve: ToneCurve = .identity
    var greenCurve: ToneCurve = .identity
    var blueCurve: ToneCurve = .identity

    static let neutral = ColorAdjustments()

    var isNeutral: Bool { self == ColorAdjustments.neutral }

    var hasCurveEdits: Bool {
        !lumaCurve.isIdentity || !redCurve.isIdentity || !greenCurve.isIdentity || !blueCurve.isIdentity
    }

    mutating func resetBasics() {
        temperature = 0; tint = 0; saturation = 100
        exposure = 0; contrast = 0; highlights = 0; shadows = 0; whites = 0; blacks = 0
    }

    mutating func resetCurves() {
        lumaCurve = .identity; redCurve = .identity; greenCurve = .identity; blueCurve = .identity
    }

    /// 調整項目の定義。UI のスライダーを 1 か所で管理する。
    enum Field: String, CaseIterable, Identifiable {
        case temperature, tint, saturation
        case exposure, contrast, highlights, shadows, whites, blacks

        var id: String { rawValue }

        var label: String {
            switch self {
            case .temperature: return "色温度"
            case .tint:        return "色かぶり補正"
            case .saturation:  return "彩度"
            case .exposure:    return "露光量"
            case .contrast:    return "コントラスト"
            case .highlights:  return "ハイライト"
            case .shadows:     return "シャドウ"
            case .whites:      return "白レベル"
            case .blacks:      return "黒レベル"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .saturation: return 0...200
            case .exposure:   return -5...5
            default:          return -100...100
            }
        }

        var neutralValue: Double {
            switch self {
            case .saturation: return 100
            default:          return 0
            }
        }

        var decimals: Int { self == .exposure ? 2 : 0 }

        var section: Section {
            switch self {
            case .temperature, .tint, .saturation: return .color
            default: return .light
            }
        }

        enum Section: String, CaseIterable, Identifiable {
            case color, light
            var id: String { rawValue }
            var label: String { self == .color ? "カラー" : "ライト" }
        }
    }

    subscript(field: Field) -> Double {
        get {
            switch field {
            case .temperature: return temperature
            case .tint:        return tint
            case .saturation:  return saturation
            case .exposure:    return exposure
            case .contrast:    return contrast
            case .highlights:  return highlights
            case .shadows:     return shadows
            case .whites:      return whites
            case .blacks:      return blacks
            }
        }
        set {
            switch field {
            case .temperature: temperature = newValue
            case .tint:        tint = newValue
            case .saturation:  saturation = newValue
            case .exposure:    exposure = newValue
            case .contrast:    contrast = newValue
            case .highlights:  highlights = newValue
            case .shadows:     shadows = newValue
            case .whites:      whites = newValue
            case .blacks:      blacks = newValue
            }
        }
    }
}
