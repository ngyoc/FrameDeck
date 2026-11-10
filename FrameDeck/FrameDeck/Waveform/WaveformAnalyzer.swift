import AVFoundation
import Foundation

enum WaveformError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:          return "音声トラックがありません"
        case .readerFailed(let msg): return "音声の読み込みに失敗しました: \(msg)"
        }
    }
}

/// 音声を先頭から流し読みしながらバケット単位で集計する。
/// actor 上で動くのでメインスレッドを塞がない。
actor WaveformAnalyzer {

    /// 1 秒あたりのバケット数。50 あれば 1 フレーム単位までズームしても形が見える。
    static let bucketsPerSecond: Double = 50
    /// 解析用にダウンサンプルする周波数。エンベロープの取得には十分で、読み出し量を半分以下に抑えられる。
    static let analysisSampleRate: Double = 22_050

    static let shared = WaveformAnalyzer()

    func analyze(url: URL, onProgress: @Sendable (WaveformData) -> Void) async throws -> WaveformData {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw WaveformError.noAudioTrack }
        guard duration.isFinite, duration > 0 else { throw WaveformError.readerFailed("長さを取得できません") }

        let bps = WaveformAnalyzer.bucketsPerSecond
        let bucketCount = max(1, Int((duration * bps).rounded(.up)))
        let samplesPerBucket = max(1, Int((WaveformAnalyzer.analysisSampleRate / bps).rounded()))

        var minValues = [Float](repeating: 0, count: bucketCount)
        var maxValues = [Float](repeating: 0, count: bucketCount)
        var rmsValues = [Float](repeating: 0, count: bucketCount)

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: WaveformAnalyzer.analysisSampleRate
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WaveformError.readerFailed("出力を追加できません") }
        reader.add(output)
        guard reader.startReading() else {
            throw WaveformError.readerFailed(reader.error?.localizedDescription ?? "不明")
        }

        var bucketIndex = 0
        var samplesInBucket = 0
        var bucketMin: Float = 0
        var bucketMax: Float = 0
        var bucketSumSquares: Double = 0
        var lastProgressReport = Date.distantPast
        var scratch = [Float]()

        func closeBucket() {
            guard bucketIndex < bucketCount else { return }
            minValues[bucketIndex] = bucketMin
            maxValues[bucketIndex] = bucketMax
            rmsValues[bucketIndex] = samplesInBucket > 0
                ? Float((bucketSumSquares / Double(samplesInBucket)).squareRoot())
                : 0
            bucketIndex += 1
            samplesInBucket = 0
            bucketMin = 0
            bucketMax = 0
            bucketSumSquares = 0
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                CMSampleBufferInvalidate(sampleBuffer)
                throw CancellationError()
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            let byteLength = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = byteLength / MemoryLayout<Float>.size
            if scratch.count < floatCount { scratch = [Float](repeating: 0, count: floatCount) }

            let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteLength,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else {
                Log.waveform.error("サンプルのコピーに失敗しました（status=\(status)）。以降のバケットは 0 になります")
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            for i in 0..<floatCount {
                let v = scratch[i]
                if v < bucketMin { bucketMin = v }
                if v > bucketMax { bucketMax = v }
                bucketSumSquares += Double(v) * Double(v)
                samplesInBucket += 1
                if samplesInBucket >= samplesPerBucket {
                    closeBucket()
                    if bucketIndex >= bucketCount { break }
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)

            let now = Date()
            if now.timeIntervalSince(lastProgressReport) > 0.15 {
                lastProgressReport = now
                onProgress(WaveformData(duration: duration, bucketsPerSecond: bps,
                                        minValues: minValues, maxValues: maxValues,
                                        rmsValues: rmsValues, filledBuckets: bucketIndex))
            }
            if bucketIndex >= bucketCount { break }
        }

        if samplesInBucket > 0 { closeBucket() }

        if reader.status == .failed {
            throw WaveformError.readerFailed(reader.error?.localizedDescription ?? "不明")
        }
        reader.cancelReading()

        return WaveformData(duration: duration, bucketsPerSecond: bps,
                            minValues: minValues, maxValues: maxValues,
                            rmsValues: rmsValues, filledBuckets: bucketCount)
    }
}
