import AVFoundation
import Combine
import SwiftUI

@MainActor
final class PlaybackController: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var frameRate: Double = 0
    @Published private(set) var isVariableFrameRate = false
    @Published private(set) var naturalSize: CGSize = .zero
    @Published private(set) var hasVideo = false
    @Published private(set) var hasAudio = false
    @Published private(set) var isReady = false
    @Published var loadError: String?

    @Published var rate: Double = 1.0 { didSet { applyRate() } }
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }
    @Published var volume: Double = 1.0 { didSet { player.volume = Float(volume) } }
    @Published var loops = false

    /// スクラブ中とシーク完了待ちの間は、時刻の監視で currentTime を上書きしない。
    /// 上書きすると再生ヘッドが要求位置と実位置の間で往復して見える。
    @Published private(set) var isScrubbing = false
    private var seekGeneration = 0
    private var isSeeking = false

    /// フレーム精度のシークに使う。素材のタイムスケールに合わせる。
    private var timescale: CMTimeScale = 600
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private(set) var url: URL?

    static let speedPresets: [Double] = [0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0, 8.0]

    init() {
        player.actionAtItemEnd = .pause
    }

    // MARK: - 読み込み

    func load(url: URL) {
        unload()
        self.url = url
        loadTask = Task { await self.performLoad(url: url) }
    }

    private func performLoad(url: URL) async {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let (playable, assetDuration) = try await asset.load(.isPlayable, .duration)
            guard self.url == url else { return }
            guard playable else {
                loadError = MediaSupport.unsupportedReason(for: url)
                Log.media.notice("再生不可の素材: \(url.lastPathComponent, privacy: .public)")
                return
            }
            duration = assetDuration.seconds.isFinite ? assetDuration.seconds : 0

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            hasVideo = !videoTracks.isEmpty
            hasAudio = !audioTracks.isEmpty

            if let track = videoTracks.first {
                let (fps, size, transform, scale, minDuration) = try await track.load(
                    .nominalFrameRate, .naturalSize, .preferredTransform,
                    .naturalTimeScale, .minFrameDuration)
                frameRate = Double(fps)
                timescale = scale != 0 ? scale : 600
                let transformed = size.applying(transform)
                naturalSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))

                // minFrameDuration と nominalFrameRate が食い違う素材は VFR の可能性が高い
                if minDuration.isValid, minDuration.seconds > 0, fps > 0 {
                    let impliedFPS = 1.0 / minDuration.seconds
                    isVariableFrameRate = abs(impliedFPS - Double(fps)) > 0.5
                }
                if isVariableFrameRate {
                    Log.media.notice("VFR の可能性がある素材: \(url.lastPathComponent, privacy: .public)")
                }
            } else if audioTracks.first != nil {
                timescale = 44_100
            }

            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain
            player.replaceCurrentItem(with: item)
            player.isMuted = isMuted
            player.volume = Float(volume)

            addObservers(for: item)
            isReady = true
            currentTime = 0
        } catch {
            guard self.url == url else { return }
            loadError = "読み込みに失敗しました: \(error.localizedDescription)"
            Log.media.error("読み込み失敗 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        isScrubbing = false
        isSeeking = false
        seekGeneration += 1
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        url = nil
        duration = 0
        currentTime = 0
        frameRate = 0
        isVariableFrameRate = false
        naturalSize = .zero
        hasVideo = false
        hasAudio = false
        isPlaying = false
        isReady = false
        loadError = nil
    }

    // MARK: - 監視

    private func addObservers(for item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = self.player.rate != 0
                // スクラブ中とシーク待ちの間は要求位置を保つ
                guard !self.isScrubbing, !self.isSeeking else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.loops {
                    self.seek(to: 0, precise: false)
                    self.play()
                } else {
                    self.isPlaying = false
                }
            }
        }
    }

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    // MARK: - 再生制御

    func play() {
        guard isReady else { return }
        if currentTime >= duration - 0.001 { seek(to: 0, precise: false) }
        applyRate(forcePlay: true)
        isPlaying = true
    }

    func pause() {
        player.rate = 0
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    private func applyRate(forcePlay: Bool = false) {
        // 4 倍以上は音声が判別できないのでミュートする（要件 4.3.4）
        player.volume = rate > 2.0 ? 0 : Float(volume)
        guard isPlaying || forcePlay else { return }
        player.rate = Float(rate)
    }

    func stepSpeed(_ direction: Int) {
        let presets = PlaybackController.speedPresets
        let index = presets.firstIndex(of: rate) ?? presets.firstIndex(of: 1.0)!
        rate = presets[max(0, min(presets.count - 1, index + direction))]
    }

    // MARK: - シーク

    func seek(to seconds: Double, precise: Bool = true) {
        guard isReady, duration > 0 else { return }
        let target = min(duration, max(0, seconds))
        currentTime = target   // UI を先に動かして待ち時間を感じさせない

        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true

        let time = CMTime(seconds: target, preferredTimescale: timescale)
        let before: CMTime = precise ? .zero : CMTime(seconds: 0.25, preferredTimescale: timescale)
        let after = before

        player.seek(to: time, toleranceBefore: before, toleranceAfter: after) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
                // スクラブ中でなければ実位置に合わせ直す
                if !self.isScrubbing {
                    let actual = self.player.currentTime().seconds
                    if actual.isFinite { self.currentTime = actual }
                }
            }
        }
    }

    // MARK: - スクラブ（波形やシークバーのドラッグ）

    func beginScrub() {
        guard isReady else { return }
        isScrubbing = true
    }

    /// ドラッグ中。追従を優先して許容誤差を持たせる。
    func scrub(to seconds: Double) {
        guard isReady, duration > 0 else { return }
        isScrubbing = true
        seek(to: seconds, precise: false)
    }

    /// 指を離した時点。ここで初めて誤差ゼロのシークをして位置を確定させる。
    func endScrub(to seconds: Double) {
        guard isReady, duration > 0 else {
            isScrubbing = false
            return
        }
        let target = min(duration, max(0, seconds))
        currentTime = target

        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true

        let time = CMTime(seconds: target, preferredTimescale: timescale)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
                self.isScrubbing = false
                let actual = self.player.currentTime().seconds
                if actual.isFinite { self.currentTime = actual }
            }
        }
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// フレーム単位の送り戻し。step(byCount:) が使えない素材では時間シークに落とす（理由はログに残す）。
    func step(frames: Int) {
        guard let item = player.currentItem, isReady else { return }
        pause()
        let canStep = frames > 0 ? item.canStepForward : item.canStepBackward
        if canStep {
            item.step(byCount: frames)
            currentTime = player.currentTime().seconds
        } else {
            let fps = frameRate > 0 ? frameRate : 30
            Log.media.notice("step(byCount:) が使えないため 1/\(fps, format: .fixed(precision: 2)) 秒のシークにフォールバックします")
            seek(to: currentTime + Double(frames) / fps)
        }
    }

    // MARK: - 表示用

    var currentFrame: Int {
        frameRate > 0 ? Int((currentTime * frameRate).rounded()) : 0
    }

    var totalFrames: Int {
        frameRate > 0 ? Int((duration * frameRate).rounded()) : 0
    }

    var timecodeText: String { Fmt.timecode(currentTime, frameRate: frameRate) }
    var durationTimecodeText: String { Fmt.timecode(duration, frameRate: frameRate) }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}
