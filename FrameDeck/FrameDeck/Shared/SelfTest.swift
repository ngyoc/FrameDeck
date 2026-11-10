import AppKit
import AVFoundation
import Foundation

/// `--selftest <動画パス>` で起動したときだけ走る動作確認。
/// GUI を操作せずに「波形解析」と「フレーム書き出し」が実素材で通ることを確かめる。
/// 読み取り専用の原則どおり、書き込むのは書き出し先の一時フォルダだけ。
enum SelfTest {

    /// 検証中はウィンドウを隠すため、「最後のウィンドウが閉じたら終了」を無効化する必要がある
    private(set) static var isActive = false

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), args.count > index + 1 else { return false }
        let path = args[index + 1]

        isActive = true
        // 検証中にフォアグラウンドを奪わないようにする
        NSApp.setActivationPolicy(.accessory)
        NSApp.windows.forEach { $0.orderOut(nil) }

        Task {
            let ok = await run(path: path)
            exit(ok ? 0 : 1)
        }
        return true
    }

    /// 別スレッドから触る値を安全に持つための小さな入れ物
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ value: Value) { storage = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    private static func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func run(path: String) async -> Bool {
        let url = URL(fileURLWithPath: path)
        out("=== FrameDeck セルフテスト ===")
        out("素材: \(url.lastPathComponent)")

        guard FileManager.default.fileExists(atPath: url.path) else {
            out("[NG] ファイルが存在しません: \(path)")
            return false
        }

        var passed = true

        // 1. メタデータ
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var duration: Double = 0
        var frameRate: Double = 0
        var naturalSize = CGSize.zero
        do {
            duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let track = videoTracks.first {
                let (fps, size, transform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
                frameRate = Double(fps)
                let t = size.applying(transform)
                naturalSize = CGSize(width: abs(t.width), height: abs(t.height))
            }
            out("[OK] メタデータ: \(Fmt.time(duration)) / \(Int(naturalSize.width))x\(Int(naturalSize.height)) / \(String(format: "%.3f", frameRate)) fps / 映像 \(videoTracks.count) 音声 \(audioTracks.count)")
        } catch {
            out("[NG] メタデータ取得: \(error.localizedDescription)")
            return false
        }

        // 2. 波形解析
        let waveStart = Date()
        let progressBox = Locked((count: 0, buckets: 0))
        do {
            let waveform = try await WaveformAnalyzer.shared.analyze(url: url) { partial in
                progressBox.value = (progressBox.value.count + 1, partial.filledBuckets)
            }
            let lastProgress = progressBox.value
            let elapsed = Date().timeIntervalSince(waveStart)
            let nonZero = waveform.maxValues.filter { $0 > 0.001 }.count
            let ratio = waveform.bucketCount > 0 ? Double(nonZero) / Double(waveform.bucketCount) : 0
            let peak = waveform.maxValues.max() ?? 0
            out(String(format: "[OK] 波形解析: %d バケット / %.2f 秒 / 有音率 %.1f%% / ピーク %.3f / 進捗通知 %d 回（最終 %d バケット）",
                       waveform.bucketCount, elapsed, ratio * 100, peak, lastProgress.count, lastProgress.buckets))
            if nonZero == 0 {
                out("[NG] 波形が全て 0 です。解析経路を確認してください")
                passed = false
            }
            if elapsed > max(15.0, duration * 0.05) {
                out(String(format: "[警告] 解析が目標より遅い（%.1f 秒）", elapsed))
            }

            // 3. キャッシュ往復
            WaveformCache.save(waveform, for: url)
            if let cached = WaveformCache.load(for: url, bucketsPerSecond: WaveformAnalyzer.bucketsPerSecond) {
                let same = cached.bucketCount == waveform.bucketCount
                    && cached.maxValues.first == waveform.maxValues.first
                    && cached.maxValues.last == waveform.maxValues.last
                    && abs(cached.duration - waveform.duration) < 0.001
                out(same ? "[OK] キャッシュ往復: 一致" : "[NG] キャッシュ往復: 内容が一致しません")
                passed = passed && same
            } else {
                out("[NG] キャッシュ往復: 読み戻せませんでした")
                passed = false
            }
        } catch {
            out("[NG] 波形解析: \(error.localizedDescription)")
            passed = false
        }

        // 4. フレーム書き出し（原寸 PNG）
        guard naturalSize != .zero else {
            out("[スキップ] 映像トラックが無いためフレーム書き出しは省略")
            out(passed ? "=== 総合: OK ===" : "=== 総合: NG ===")
            return passed
        }
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("framedeck-selftest", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)

        let targetTime = duration / 3
        do {
            let result = try await FrameExporter.exportFrame(
                assetURL: url, at: targetTime, frameRate: frameRate,
                destination: outDir, options: ExportOptions(longestEdge: nil))

            let exists = FileManager.default.fileExists(atPath: result.url.path)
            let bytes = (try? result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeMatches = Int(result.pixelSize.width) == Int(naturalSize.width)
                && Int(result.pixelSize.height) == Int(naturalSize.height)
            let drift = abs(result.actualTime - result.requestedTime)
            let frameInterval = frameRate > 0 ? 1.0 / frameRate : 0.04

            out("[\(exists && bytes > 0 ? "OK" : "NG")] 書き出し: \(result.url.lastPathComponent) (\(bytes) バイト)")
            out("[\(sizeMatches ? "OK" : "NG")] 原寸維持: 出力 \(Int(result.pixelSize.width))x\(Int(result.pixelSize.height)) / 素材 \(Int(naturalSize.width))x\(Int(naturalSize.height))")
            out(String(format: "[%@] フレーム精度: 要求 %.4fs → 実際 %.4fs（誤差 %.4fs / 1 フレーム %.4fs）",
                       drift <= frameInterval + 0.001 ? "OK" : "NG",
                       result.requestedTime, result.actualTime, drift, frameInterval))
            passed = passed && exists && bytes > 0 && sizeMatches && drift <= frameInterval + 0.001

            // 5. 長辺指定（サムネサイズ書き出し）
            let thumb = try await FrameExporter.exportFrame(
                assetURL: url, at: targetTime, frameRate: frameRate,
                destination: outDir, options: ExportOptions(longestEdge: 1280))
            let longest = max(thumb.pixelSize.width, thumb.pixelSize.height)
            out("[\(Int(longest) == 1280 ? "OK" : "NG")] 長辺 1280 指定: \(Int(thumb.pixelSize.width))x\(Int(thumb.pixelSize.height))")
            passed = passed && Int(longest) == 1280

            // 6. 上書き防止
            let again = try await FrameExporter.exportFrame(
                assetURL: url, at: targetTime, frameRate: frameRate,
                destination: outDir, options: ExportOptions(longestEdge: nil))
            let differs = again.url != result.url
            out("[\(differs ? "OK" : "NG")] 上書き防止: \(again.url.lastPathComponent)")
            passed = passed && differs

            // 7. 色味調整つき書き出し
            let color: ColorAdjustments = {
                var c = ColorAdjustments.neutral
                c.exposure = 0.8
                c.contrast = 25
                c.temperature = 20
                c.saturation = 130
                c.highlights = -30
                c.shadows = 40
                c.whites = 15
                c.blacks = -10
                c.lumaCurve.addPoint(x: 0.5, y: 0.58)
                c.redCurve.addPoint(x: 0.5, y: 0.54)
                return c
            }()

            let graded = try await FrameExporter.exportFrame(
                assetURL: url, at: targetTime, frameRate: frameRate,
                destination: outDir,
                options: ExportOptions(template: "{name}_graded_{tc}", color: color))
            let gradedBytes = (try? graded.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sameSize = Int(graded.pixelSize.width) == Int(naturalSize.width)
            out("[\(gradedBytes > 0 && sameSize ? "OK" : "NG")] 色味調整つき書き出し: \(graded.url.lastPathComponent) (\(gradedBytes) バイト / \(Int(graded.pixelSize.width))x\(Int(graded.pixelSize.height)))")
            passed = passed && gradedBytes > 0 && sameSize

            // 調整前後で中身が変わっていること（＝色調整が実際に効いていること）
            let plainData = try? Data(contentsOf: result.url)
            let gradedData = try? Data(contentsOf: graded.url)
            let contentChanged = plainData != nil && gradedData != nil && plainData != gradedData
            out("[\(contentChanged ? "OK" : "NG")] 調整前後で画像が変化: 無調整 \(plainData?.count ?? 0) バイト / 調整後 \(gradedBytes) バイト")
            passed = passed && contentChanged

            // トーンカーブの単調性（点を足しても値が逆転しないこと）
            var mono = true
            var previous = -1.0
            for i in 0...100 {
                let v = color.lumaCurve.evaluate(Double(i) / 100.0)
                if v < previous - 0.0001 { mono = false; break }
                previous = v
            }
            out("[\(mono ? "OK" : "NG")] トーンカーブが単調増加")
            passed = passed && mono

            // プリセットの保存と読み戻し
            let presetOK = await MainActor.run { () -> Bool in
                let store = ColorPresetStore()
                let before = store.presets.count
                store.save(name: "__selftest__", adjustments: color)
                let reloaded = ColorPresetStore()
                let found = reloaded.presets.first { $0.name == "__selftest__" }
                let ok = found?.adjustments == color
                if let found { reloaded.delete(found) }
                _ = before
                return ok
            }
            out("[\(presetOK ? "OK" : "NG")] プリセットの保存と読み戻し")
            passed = passed && presetOK

            // 8. カーブエディタ背景の輝度ヒストグラム
            let frame = try await FrameExporter.makeFrameImage(
                assetURL: url, at: targetTime, maximumSize: CGSize(width: 1024, height: 1024))
            let hist = FrameExporter.luminanceHistogram(frame)
            let nonZeroBins = hist.filter { $0 > 0.001 }.count
            let peakBin = hist.firstIndex(of: hist.max() ?? 0) ?? -1
            out("[\(nonZeroBins > 4 ? "OK" : "NG")] 輝度ヒストグラム: \(hist.count) ビン中 \(nonZeroBins) ビンが非ゼロ / ピーク位置 \(peakBin)")
            passed = passed && nonZeroBins > 4

            // 9. 書き出し先の決め方（既定は「動画と同じ場所に動画名のフォルダ」）
            let destinationOK = await MainActor.run { () -> (Bool, String) in
                let settings = AppSettings()
                let saved = settings.destinationMode
                settings.destinationMode = .alongsideSource
                let dir = settings.exportDestination(for: url)
                settings.destinationMode = saved
                let expectedParent = url.deletingLastPathComponent().path
                let expectedName = url.deletingPathExtension().lastPathComponent
                let ok = dir.deletingLastPathComponent().path == expectedParent
                    && dir.lastPathComponent == FilenameTemplate.sanitize(expectedName)
                return (ok, dir.path)
            }
            out("[\(destinationOK.0 ? "OK" : "NG")] 書き出し先の決定: \(destinationOK.1)")
            passed = passed && destinationOK.0

            out("出力先: \(outDir.path)")
        } catch {
            out("[NG] フレーム書き出し: \(error.localizedDescription)")
            passed = false
        }

        // 10. スクラブ中に再生ヘッドが前後しないか
        let scrubOK = await MainActor.run { () -> Bool in true }
        _ = scrubOK
        await checkScrub(url: url, duration: duration, report: { line, ok in
            out(line)
            if !ok { passed = false }
        })

        out(passed ? "=== 総合: OK ===" : "=== 総合: NG ===")
        return passed
    }

    /// 波形をクリックしたときに再生ヘッドが要求位置から動かないことを確かめる。
    /// 以前は要求位置と実位置の間で往復して、カクついて見えていた。
    @MainActor
    private static func checkScrub(url: URL, duration: Double,
                                   report: @escaping (String, Bool) -> Void) async {
        let controller = PlaybackController()
        controller.load(url: url)
        for _ in 0..<120 {
            if controller.isReady { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard controller.isReady else {
            report("[NG] スクラブ検証: 読み込めませんでした", false)
            return
        }

        // カクつきは再生中に時刻の監視が走っているときに起きるので、再生しながら測る
        controller.play()
        try? await Task.sleep(for: .milliseconds(800))

        // 比較用: 修正前と同じ「押した瞬間に粗いシーク、離した瞬間に精密シーク」だけの流れ
        let oldTarget = duration * 0.41
        controller.seek(to: oldTarget, precise: false)
        var oldSamples: [Double] = []
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(40))
            oldSamples.append(controller.currentTime)
        }
        controller.seek(to: oldTarget, precise: true)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            oldSamples.append(controller.currentTime)
        }
        var oldBackward = 0
        for i in 1..<max(1, oldSamples.count) where oldSamples[i] < oldSamples[i - 1] - 0.05 {
            oldBackward += 1
        }
        let oldDrift = oldSamples.map { abs($0 - oldTarget) }.max() ?? 0
        report(String(format: "（参考）シーク API を直接叩いた場合: 最大ずれ %.4fs / 逆戻り %d 回",
                      oldDrift, oldBackward), true)

        // 波形をクリックしたのと同じ流れ（押した瞬間 → 離した瞬間）
        let target = duration * 0.62
        controller.scrub(to: target)
        var samples: [Double] = []
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(40))
            samples.append(controller.currentTime)
        }
        controller.endScrub(to: target)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            samples.append(controller.currentTime)
            if !controller.isScrubbing { break }
        }

        let drift = samples.map { abs($0 - target) }.max() ?? 0
        // 単調でない動き（前後の往復）を数える
        var reversals = 0
        for i in 2..<max(2, samples.count) {
            let a = samples[i - 2], b = samples[i - 1], c = samples[i]
            if (b - a) * (c - b) < -0.000001 { reversals += 1 }
        }
        // 再生中なので前へは進む。要求位置より手前へ戻る動きだけを数える。
        var backwardJumps = 0
        for i in 1..<max(1, samples.count) where samples[i] < samples[i - 1] - 0.05 {
            backwardJumps += 1
        }
        let ok = drift < 2.0 && backwardJumps == 0
        report(String(format: "[%@] スクラブ中の再生ヘッド（再生しながら）: 要求 %.3fs / 最大ずれ %.4fs / 逆戻り %d 回 / 往復 %d 回",
                      ok ? "OK" : "NG", target, drift, backwardJumps, reversals), ok)
        controller.pause()
        controller.unload()
    }
}
