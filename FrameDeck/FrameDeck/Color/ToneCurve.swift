import CoreGraphics
import Foundation

/// カラーカーブ 1 本ぶん。制御点を単調三次補間でつなぐ。
/// 単調補間にしているのは、点の間で値が行き過ぎて色が反転するのを防ぐため。
struct ToneCurve: Codable, Equatable {

    struct Point: Codable, Equatable, Identifiable, Hashable {
        var x: Double
        var y: Double
        var id: String { "\(x)-\(y)" }
    }

    var points: [Point]

    static let identity = ToneCurve(points: [Point(x: 0, y: 0), Point(x: 1, y: 1)])

    var isIdentity: Bool {
        points.count == 2 &&
        abs(points[0].x) < 0.0001 && abs(points[0].y) < 0.0001 &&
        abs(points[1].x - 1) < 0.0001 && abs(points[1].y - 1) < 0.0001
    }

    private var sorted: [Point] { points.sorted { $0.x < $1.x } }

    mutating func addPoint(x: Double, y: Double) {
        points.append(Point(x: min(1, max(0, x)), y: min(1, max(0, y))))
        points.sort { $0.x < $1.x }
    }

    mutating func removePoint(at index: Int) {
        // 両端は消せないようにする（カーブが定義できなくなるため）
        guard points.count > 2, index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
    }

    mutating func movePoint(at index: Int, to newValue: Point) {
        guard points.indices.contains(index) else { return }
        var clamped = Point(x: min(1, max(0, newValue.x)), y: min(1, max(0, newValue.y)))
        // 端点は横方向に動かさない
        if index == 0 { clamped.x = 0 }
        if index == points.count - 1 { clamped.x = 1 }
        points[index] = clamped
        points.sort { $0.x < $1.x }
    }

    /// 単調三次エルミート補間（Fritsch-Carlson）。行き過ぎを起こさない。
    func evaluate(_ x: Double) -> Double {
        let pts = sorted
        guard pts.count >= 2 else { return x }
        let t = min(1, max(0, x))
        if t <= pts.first!.x { return min(1, max(0, pts.first!.y)) }
        if t >= pts.last!.x { return min(1, max(0, pts.last!.y)) }

        let n = pts.count
        var slopes = [Double](repeating: 0, count: n - 1)
        var tangents = [Double](repeating: 0, count: n)

        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            slopes[i] = dx > 0 ? (pts[i + 1].y - pts[i].y) / dx : 0
        }
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            if slopes[i - 1] * slopes[i] <= 0 {
                tangents[i] = 0
            } else {
                tangents[i] = (slopes[i - 1] + slopes[i]) / 2
            }
        }
        // 単調性を保つための補正
        for i in 0..<(n - 1) where slopes[i] != 0 {
            let a = tangents[i] / slopes[i]
            let b = tangents[i + 1] / slopes[i]
            let h = (a * a + b * b).squareRoot()
            if h > 3 {
                tangents[i] = 3 * a / h * slopes[i]
                tangents[i + 1] = 3 * b / h * slopes[i]
            }
        }

        var segment = 0
        for i in 0..<(n - 1) where t >= pts[i].x && t <= pts[i + 1].x {
            segment = i
            break
        }
        let p0 = pts[segment], p1 = pts[segment + 1]
        let h = p1.x - p0.x
        guard h > 0 else { return p0.y }
        let s = (t - p0.x) / h
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        let h11 = s3 - s2
        let value = h00 * p0.y + h10 * h * tangents[segment] + h01 * p1.y + h11 * h * tangents[segment + 1]
        return min(1, max(0, value))
    }
}
