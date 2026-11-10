import SwiftUI

/// 波形そのものがシークバーを兼ねる（要件 4.4.1）。
/// 長尺でも発話位置を詰められるよう、時間軸のズームとパンに対応する。
struct WaveformView: View {

    let data: WaveformData?
    let duration: Double
    let currentTime: Double
    let isAnalyzing: Bool
    let errorMessage: String?
    @Binding var viewport: WaveformViewport
    let onScrub: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    @State private var columns: [Column] = []
    @State private var builtKey = BuildKey()
    @State private var isDragging = false
    @State private var hoverTime: Double?

    struct Column {
        var low: Float
        var high: Float
        var rms: Float
        /// 解析がまだ届いていない領域
        var pending: Bool
    }

    /// 再計算が必要かどうかを判定するための鍵
    struct BuildKey: Equatable {
        var width: Int = -1
        var filled: Int = -1
        var start: Double = -1
        var visible: Double = -1
    }

    private let playedColor = Color(red: 0.36, green: 0.78, blue: 1.0)
    private let unplayedColor = Color(red: 0.44, green: 0.50, blue: 0.58)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let playheadX = viewport.x(forTime: currentTime, width: width)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(ctx: &ctx, size: size, playheadX: playheadX)
                }
                topLeftLabels
                if viewport.isZoomed {
                    zoomBadge
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if viewport.isZoomed {
                    minimap(width: width)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: width, height: geo.size.height)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub(viewport.time(atX: value.location.x, width: width))
                    }
                    .onEnded { value in
                        isDragging = false
                        onScrubEnded(viewport.time(atX: value.location.x, width: width))
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverTime = viewport.time(atX: point.x, width: width)
                case .ended: hoverTime = nil
                }
            }
            .onChange(of: currentKey(width: width)) { _, _ in rebuild(width: width) }
            .onAppear { rebuild(width: width, force: true) }
        }
    }

    private func currentKey(width: CGFloat) -> BuildKey {
        BuildKey(width: Int(width.rounded()),
                 filled: data?.filledBuckets ?? -1,
                 start: viewport.start,
                 visible: viewport.visibleDuration)
    }

    // MARK: - 描画

    private func draw(ctx: inout GraphicsContext, size: CGSize, playheadX: CGFloat) {
        let mid = size.height / 2
        let half = size.height / 2 - 4

        var center = Path()
        center.move(to: CGPoint(x: 0, y: mid))
        center.addLine(to: CGPoint(x: size.width, y: mid))
        ctx.stroke(center, with: .color(.white.opacity(0.10)), lineWidth: 1)

        drawTimeRuler(ctx: &ctx, size: size)

        if columns.isEmpty {
            var bar = Path()
            bar.addRect(CGRect(x: 0, y: mid - 2, width: size.width, height: 4))
            ctx.fill(bar, with: .color(unplayedColor.opacity(0.35)))
            var played = Path()
            played.addRect(CGRect(x: 0, y: mid - 2, width: max(0, min(size.width, playheadX)), height: 4))
            ctx.fill(played, with: .color(playedColor))
        } else {
            var peakPlayed = Path(), peakRest = Path(), pending = Path()
            var rmsPlayed = Path(), rmsRest = Path()

            for (index, column) in columns.enumerated() {
                let x = CGFloat(index)
                if column.pending {
                    pending.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
                    continue
                }
                let top = mid - CGFloat(column.high) * half
                let bottom = mid - CGFloat(column.low) * half
                let peakRect = CGRect(x: x, y: min(top, bottom),
                                      width: 1, height: max(1, abs(bottom - top)))
                let rmsHeight = max(1, CGFloat(column.rms) * half * 2)
                let rmsRect = CGRect(x: x, y: mid - rmsHeight / 2, width: 1, height: rmsHeight)

                if x <= playheadX {
                    peakPlayed.addRect(peakRect)
                    rmsPlayed.addRect(rmsRect)
                } else {
                    peakRest.addRect(peakRect)
                    rmsRest.addRect(rmsRect)
                }
            }
            ctx.fill(pending, with: .color(.white.opacity(0.045)))
            ctx.fill(peakRest, with: .color(unplayedColor.opacity(0.45)))
            ctx.fill(rmsRest, with: .color(unplayedColor.opacity(0.95)))
            ctx.fill(peakPlayed, with: .color(playedColor.opacity(0.45)))
            ctx.fill(rmsPlayed, with: .color(playedColor))
        }

        // カーソル位置
        if let hoverTime, !isDragging {
            let hx = viewport.x(forTime: hoverTime, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: hx, y: 0))
            line.addLine(to: CGPoint(x: hx, y: size.height))
            ctx.stroke(line, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }

        // 再生ヘッド
        if playheadX >= -1, playheadX <= size.width + 1 {
            var head = Path()
            head.move(to: CGPoint(x: playheadX, y: 0))
            head.addLine(to: CGPoint(x: playheadX, y: size.height))
            ctx.stroke(head, with: .color(.white.opacity(0.9)), lineWidth: isDragging ? 2 : 1)
        }
    }

    /// ズームすると「今どのあたりを見ているか」が分からなくなるので目盛りを出す
    private func drawTimeRuler(ctx: inout GraphicsContext, size: CGSize) {
        guard viewport.visibleDuration > 0, size.width > 0 else { return }
        let targetSpacing: Double = 90 // px
        let rawStep = viewport.visibleDuration * Double(targetSpacing) / Double(size.width)
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { $0 >= rawStep } ?? 3600

        var tick = (viewport.start / step).rounded(.down) * step
        while tick <= viewport.end {
            if tick >= viewport.start {
                let x = viewport.x(forTime: tick, width: size.width)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: 6))
                ctx.stroke(line, with: .color(.white.opacity(0.22)), lineWidth: 1)
                ctx.draw(Text(Fmt.shortDuration(tick))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35)),
                         at: CGPoint(x: x + 3, y: 11), anchor: .leading)
            }
            tick += step
        }
    }

    // MARK: - 付随表示

    @ViewBuilder
    private var topLeftLabels: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 10).padding(.top, 6)
        } else if isAnalyzing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("波形を解析中 \(Int((data?.progress ?? 0) * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 10).padding(.top, 6)
        }
    }

    private var zoomBadge: some View {
        Text(viewport.zoomLabel)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
            .padding(.trailing, 8).padding(.top, 6)
    }

    /// 全体のどこを見ているかを示す帯
    private func minimap(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.08))
            if duration > 0 {
                Rectangle()
                    .fill(playedColor.opacity(0.6))
                    .frame(width: max(2, width * CGFloat(viewport.visibleDuration / duration)))
                    .offset(x: width * CGFloat(viewport.start / duration))
            }
        }
        .frame(height: 3)
    }

    // MARK: - 表示解像度への畳み込み

    /// バケット列を画面の 1 ピクセル 1 列に畳み込む。
    /// 再生位置の更新ごとに作り直すと重いので、幅・解析量・表示範囲が変わったときだけ計算する。
    private func rebuild(width: CGFloat, force: Bool = false) {
        let key = currentKey(width: width)
        guard key.width > 0 else { return }
        guard force || key != builtKey else { return }
        builtKey = key

        guard let data, data.bucketCount > 0, viewport.visibleDuration > 0 else {
            if !columns.isEmpty { columns = [] }
            return
        }

        let pixelWidth = key.width
        let usable = max(1, data.filledBuckets)
        let bps = data.bucketsPerSecond

        // モノラルへのダウンミックスで L+R が加算されるため、素材によってはピークが 1.0 を超える。
        // 絶対値の dB 表示は将来のピークホールドで扱い、ここでは発話位置が見えることを優先する。
        var peak: Float = 0
        for i in 0..<usable {
            peak = Swift.max(peak, data.maxValues[i], -data.minValues[i])
        }
        let scale = 1.0 / Swift.max(peak, 0.1)

        var result = [Column](repeating: Column(low: 0, high: 0, rms: 0, pending: false), count: pixelWidth)

        for x in 0..<pixelWidth {
            let t0 = viewport.start + viewport.visibleDuration * Double(x) / Double(pixelWidth)
            let t1 = viewport.start + viewport.visibleDuration * Double(x + 1) / Double(pixelWidth)
            let start = Int(t0 * bps)
            let end = Swift.max(start + 1, Int(t1 * bps))

            if start >= usable {
                result[x] = Column(low: 0, high: 0, rms: 0, pending: start < data.bucketCount)
                continue
            }
            var low: Float = 0, high: Float = 0, rms: Float = 0
            for b in start..<Swift.min(end, usable) {
                low = Swift.min(low, data.minValues[b])
                high = Swift.max(high, data.maxValues[b])
                rms = Swift.max(rms, data.rmsValues[b])
            }
            result[x] = Column(low: Swift.max(-1, low * scale),
                               high: Swift.min(1, high * scale),
                               rms: Swift.min(1, rms * scale),
                               pending: false)
        }

        columns = result
    }
}
