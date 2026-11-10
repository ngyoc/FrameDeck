import AppKit
import SwiftUI

/// カラーカーブの編集。クリックで点を追加、ドラッグで移動、右クリックで削除。
struct ToneCurveEditor: View {

    @Binding var curve: ToneCurve
    let tint: Color
    /// 背後に薄く出す輝度ヒストグラム（0-1 に正規化済み）
    var histogram: [Float] = []

    @State private var draggingIndex: Int?
    /// ⌥ クリックで点を消したあと、指を離すまで移動処理を走らせないための札
    @State private var skipUntilRelease = false

    private let gridDivisions = 4

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, canvasSize in
                    drawHistogram(ctx: &ctx, size: canvasSize)
                    drawGrid(ctx: &ctx, size: canvasSize)
                    drawCurve(ctx: &ctx, size: canvasSize)
                    drawPoints(ctx: &ctx, size: canvasSize)
                }
                .background(Color(red: 0.07, green: 0.07, blue: 0.09))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
            }
            .frame(width: size.width, height: size.height)
        }
    }

    // MARK: - 描画

    private func drawHistogram(ctx: inout GraphicsContext, size: CGSize) {
        guard !histogram.isEmpty else { return }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in histogram.enumerated() {
            let x = CGFloat(index) / CGFloat(max(1, histogram.count - 1)) * size.width
            let y = size.height - CGFloat(value) * size.height * 0.85
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(.white.opacity(0.18)))
    }

    private func drawGrid(ctx: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for i in 0...gridDivisions {
            let t = CGFloat(i) / CGFloat(gridDivisions)
            grid.move(to: CGPoint(x: t * size.width, y: 0))
            grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: t * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 1)

        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        ctx.stroke(diagonal, with: .color(.white.opacity(0.12)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func drawCurve(ctx: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let steps = max(32, Int(size.width))
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            let y = curve.evaluate(x)
            let point = CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * size.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        ctx.stroke(path, with: .color(tint), lineWidth: 1.8)
    }

    private func drawPoints(ctx: inout GraphicsContext, size: CGSize) {
        for (index, point) in curve.points.enumerated() {
            let center = CGPoint(x: CGFloat(point.x) * size.width,
                                 y: (1 - CGFloat(point.y)) * size.height)
            let radius: CGFloat = draggingIndex == index ? 5.5 : 4
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(tint))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    // MARK: - 操作

    /// 点の追加・移動・削除をすべてこのジェスチャで受ける。
    /// DragGesture(minimumDistance: 0) は同じ場所に置いた onTapGesture を先に取ってしまうため、
    /// クリックでの追加もここで処理する。
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingIndex == nil {
                    if let existing = nearestPointIndex(to: value.startLocation, size: size) {
                        // ⌥ クリックは点の削除
                        if NSEvent.modifierFlags.contains(.option) {
                            curve.removePoint(at: existing)
                            draggingIndex = nil
                            skipUntilRelease = true
                            return
                        }
                        draggingIndex = existing
                    } else {
                        // 近くに点が無ければその場に足して、そのまま掴む
                        let x = Double(value.startLocation.x / size.width)
                        let y = Double(1 - value.startLocation.y / size.height)
                        curve.addPoint(x: x, y: y)
                        draggingIndex = curve.points.firstIndex {
                            abs($0.x - min(1, max(0, x))) < 0.0001
                        }
                    }
                }
                guard !skipUntilRelease, let index = draggingIndex else { return }
                let newPoint = ToneCurve.Point(
                    x: Double(value.location.x / size.width),
                    y: Double(1 - value.location.y / size.height))
                curve.movePoint(at: index, to: newPoint)
                // 並べ替えで添字がずれるので追い直す
                draggingIndex = curve.points.firstIndex {
                    abs($0.x - min(1, max(0, newPoint.x))) < 0.0001
                } ?? index
            }
            .onEnded { _ in
                draggingIndex = nil
                skipUntilRelease = false
            }
    }

    private func nearestPointIndex(to location: CGPoint, size: CGSize) -> Int? {
        let threshold: CGFloat = 14
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in curve.points.enumerated() {
            let center = CGPoint(x: CGFloat(point.x) * size.width,
                                 y: (1 - CGFloat(point.y)) * size.height)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance < threshold, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

}
