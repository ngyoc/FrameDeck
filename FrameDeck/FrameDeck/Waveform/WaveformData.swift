import Foundation

/// 時間軸をバケットに分割し、各バケットの最小値 / 最大値 / RMS を保持する。
/// 全サンプルはメモリに載せない（要件 4.4.4）。
struct WaveformData: Sendable {
    var duration: Double
    var bucketsPerSecond: Double
    var minValues: [Float]
    var maxValues: [Float]
    var rmsValues: [Float]
    /// 解析が完了したバケット数。途中経過の描画に使う。
    var filledBuckets: Int

    var bucketCount: Int { maxValues.count }
    var progress: Double {
        bucketCount > 0 ? min(1, Double(filledBuckets) / Double(bucketCount)) : 0
    }
    var isComplete: Bool { filledBuckets >= bucketCount }

    static let empty = WaveformData(duration: 0, bucketsPerSecond: 0,
                                    minValues: [], maxValues: [], rmsValues: [], filledBuckets: 0)
}

// MARK: - バイナリ形式（キャッシュ用）

extension WaveformData {

    private static let magic: UInt32 = 0x46445746 // "FDWF"
    private static let formatVersion: UInt32 = 1

    func encoded() -> Data {
        var data = Data()
        var magic = WaveformData.magic
        var version = WaveformData.formatVersion
        var dur = duration
        var bps = bucketsPerSecond
        var count = UInt32(bucketCount)

        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dur) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &bps) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for array in [minValues, maxValues, rmsValues] {
            array.withUnsafeBufferPointer { buf in
                data.append(UnsafeRawBufferPointer(buf).bindMemory(to: UInt8.self))
            }
        }
        return data
    }

    init?(decoding data: Data) {
        let headerSize = 4 + 4 + 8 + 8 + 4
        guard data.count >= headerSize else { return nil }

        let header: (UInt32, UInt32, Double, Double, UInt32) = data.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
             raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
             raw.loadUnaligned(fromByteOffset: 8, as: Double.self),
             raw.loadUnaligned(fromByteOffset: 16, as: Double.self),
             raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
        }
        guard header.0 == WaveformData.magic, header.1 == WaveformData.formatVersion else { return nil }

        let count = Int(header.4)
        let bytesPerArray = count * MemoryLayout<Float>.size
        guard data.count == headerSize + bytesPerArray * 3 else { return nil }

        func readArray(at offset: Int) -> [Float] {
            data.withUnsafeBytes { raw -> [Float] in
                var out = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    out[i] = raw.loadUnaligned(fromByteOffset: offset + i * MemoryLayout<Float>.size, as: Float.self)
                }
                return out
            }
        }

        self.duration = header.2
        self.bucketsPerSecond = header.3
        self.minValues = readArray(at: headerSize)
        self.maxValues = readArray(at: headerSize + bytesPerArray)
        self.rmsValues = readArray(at: headerSize + bytesPerArray * 2)
        self.filledBuckets = count
    }
}
