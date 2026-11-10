import Foundation
import SwiftUI

@MainActor
final class WaveformLoader: ObservableObject {

    @Published private(set) var data: WaveformData?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var loadedFromCache = false
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var currentURL: URL?

    func load(url: URL) {
        guard currentURL != url else { return }
        cancel()
        currentURL = url
        data = nil
        errorMessage = nil
        loadedFromCache = false

        if let cached = WaveformCache.load(for: url, bucketsPerSecond: WaveformAnalyzer.bucketsPerSecond) {
            data = cached
            loadedFromCache = true
            Log.waveform.info("キャッシュから波形を読み込みました: \(url.lastPathComponent, privacy: .public)")
            return
        }

        isAnalyzing = true

        // 途中経過は AsyncStream 経由でメインアクターに渡す（コールバック内で self を捕まえないため）
        let (progressStream, continuation) = AsyncStream<WaveformData>.makeStream()

        task = Task { [weak self] in
            let consumer = Task { @MainActor [weak self] in
                for await partial in progressStream {
                    guard let self, self.currentURL == url else { continue }
                    // 到着順が入れ替わっても巻き戻らないようにする
                    if (self.data?.filledBuckets ?? 0) <= partial.filledBuckets {
                        self.data = partial
                    }
                }
            }
            defer { consumer.cancel() }

            do {
                let result = try await WaveformAnalyzer.shared.analyze(url: url) { partial in
                    continuation.yield(partial)
                }
                continuation.finish()
                guard let self, !Task.isCancelled, self.currentURL == url else { return }
                self.data = result
                self.isAnalyzing = false
                WaveformCache.save(result, for: url)
                WaveformCache.pruneIfNeeded()
            } catch is CancellationError {
                continuation.finish()
                // 別ファイルへ切り替えた通常の流れ。ユーザーには何も出さない。
            } catch {
                continuation.finish()
                guard let self, self.currentURL == url else { return }
                self.isAnalyzing = false
                self.errorMessage = error.localizedDescription
                Log.waveform.error("解析失敗 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isAnalyzing = false
    }

    func reset() {
        cancel()
        currentURL = nil
        data = nil
        errorMessage = nil
    }
}
