import Foundation

/// フォルダの中身の合計サイズを数える。
///
/// ネットワークボリューム・外付け HDD・クラウド同期フォルダでは走査が重くなるため、
/// **選択しただけでは動かさず、明示的に頼まれたときだけ**実行する。
/// 途中経過を出しながら進み、いつでも止められる。
@MainActor
final class FolderSizeCalculator: ObservableObject {

    struct Progress: Equatable {
        var totalBytes: Int64
        var fileCount: Int
        var isComplete: Bool
        /// 上限に達して打ち切った
        var truncated: Bool
    }

    /// 走査を打ち切るファイル数の上限。これを超えたら概算として途中で止める。
    nonisolated static let fileLimit = 200_000

    @Published private(set) var target: URL?
    @Published private(set) var progress: Progress?
    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?

    var isMeasuring: Bool { isRunning }

    /// 明示的に頼まれたときだけ呼ぶ
    func start(_ url: URL) {
        cancel()
        target = url
        progress = Progress(totalBytes: 0, fileCount: 0, isComplete: false, truncated: false)
        isRunning = true

        task = Task { [weak self] in
            let stream = FolderSizeCalculator.scan(url)
            for await update in stream {
                guard let self, !Task.isCancelled, self.target == url else { return }
                self.progress = update
                if update.isComplete { self.isRunning = false }
            }
            guard let self, self.target == url else { return }
            self.isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func clear() {
        cancel()
        target = nil
        progress = nil
    }

    /// 選択が変わったら結果を捨てる（別のフォルダの数字が残らないように）
    func invalidate(unless url: URL?) {
        guard target != url else { return }
        clear()
    }

    private nonisolated static func scan(_ url: URL) -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var total: Int64 = 0
                var count = 0
                var truncated = false
                let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]

                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsPackageDescendants, .skipsHiddenFiles]
                ) else {
                    continuation.yield(Progress(totalBytes: 0, fileCount: 0, isComplete: true, truncated: false))
                    continuation.finish()
                    return
                }

                var lastReport = 0
                while let next = enumerator.nextObject() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    guard let fileURL = next as? URL,
                          let values = try? fileURL.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { continue }
                    total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    count += 1

                    if count >= FolderSizeCalculator.fileLimit {
                        truncated = true
                        break
                    }
                    // 進み具合をときどき知らせる
                    if count - lastReport >= 500 {
                        lastReport = count
                        continuation.yield(Progress(totalBytes: total, fileCount: count,
                                                    isComplete: false, truncated: false))
                    }
                }
                continuation.yield(Progress(totalBytes: total, fileCount: count,
                                            isComplete: true, truncated: truncated))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
