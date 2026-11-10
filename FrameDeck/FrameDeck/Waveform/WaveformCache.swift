import CryptoKit
import Foundation

/// 解析済み波形のディスクキャッシュ。
/// 同じ素材を何度も開く運用のため、2 回目以降は即時表示できるようにする。
enum WaveformCache {

    static let defaultSizeLimit: Int64 = 2 * 1024 * 1024 * 1024 // 2GB

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.laorca.framedeck", isDirectory: true)
            .appendingPathComponent("waveform", isDirectory: true)
    }

    /// パス・更新日時・サイズ・解析パラメータを混ぜた鍵。素材が差し替わればキャッシュも外れる。
    static func key(for url: URL, bucketsPerSecond: Double) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            Log.waveform.warning("キャッシュ鍵を作れません（属性取得失敗）: \(url.path, privacy: .public)")
            return nil
        }
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        let source = "\(url.path)|\(mtime)|\(size)|\(bucketsPerSecond)|v1"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func load(for url: URL, bucketsPerSecond: Double) -> WaveformData? {
        guard let key = key(for: url, bucketsPerSecond: bucketsPerSecond) else { return nil }
        let file = directory.appendingPathComponent("\(key).fdwf")
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let decoded = WaveformData(decoding: data) else {
            Log.waveform.notice("キャッシュを解釈できないため破棄して再解析します: \(file.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return decoded
    }

    static func save(_ waveform: WaveformData, for url: URL) {
        guard waveform.isComplete else { return }
        guard let key = key(for: url, bucketsPerSecond: waveform.bucketsPerSecond) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try waveform.encoded().write(to: directory.appendingPathComponent("\(key).fdwf"), options: .atomic)
        } catch {
            Log.waveform.error("キャッシュ保存失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func fileSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { return 0 }
        return Int64(size)
    }

    private static func accessDate(of url: URL) -> Date {
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .distantPast }
        return values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
    }

    static func totalSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { $0 + fileSize(of: $1) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        Log.waveform.notice("波形キャッシュを削除しました")
    }

    /// 上限を超えていたら古いものから削除する。
    static func pruneIfNeeded(limit: Int64 = defaultSizeLimit) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }

        var total = files.reduce(Int64(0)) { $0 + fileSize(of: $1) }
        guard total > limit else { return }

        // 最後に使われたのが古いものから落とす（LRU）
        let sorted = files.sorted { accessDate(of: $0) < accessDate(of: $1) }
        for file in sorted where total > limit {
            let size = fileSize(of: file)
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
        Log.waveform.notice("波形キャッシュを整理しました（上限 \(limit) バイト）")
    }
}
