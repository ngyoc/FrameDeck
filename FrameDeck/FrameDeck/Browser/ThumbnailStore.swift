import AppKit
import QuickLookThumbnailing
import SwiftUI

/// QuickLook のサムネイル生成をまとめる。
/// Finder と同じ絵が出るうえ、システム側のキャッシュも共有されるので自前のディスクキャッシュは持たない。
/// メモリキャッシュだけ用意して、スクロール中の再生成を抑える。
actor ThumbnailStore {

    static let shared = ThumbnailStore()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 800
        return cache
    }()

    /// 同じ URL とサイズで並行して走るリクエストをまとめる
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func thumbnail(for url: URL, size: CGFloat) -> Task<NSImage?, Never> {
        let bucket = ThumbnailStore.sizeBucket(size)
        let key = "\(url.path)|\(bucket)"

        if let cached = cache.object(forKey: key as NSString) {
            return Task { cached }
        }
        if let existing = inFlight[key] { return existing }

        let task = Task<NSImage?, Never> { [weak self] in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: bucket, height: bucket),
                scale: 2,
                representationTypes: .all)
            do {
                let representation = try await QLThumbnailGenerator.shared
                    .generateBestRepresentation(for: request)
                let image = representation.nsImage
                await self?.store(image, for: key)
                return image
            } catch {
                // 生成できないファイル（壊れている・対応外）はアイコン表示に落とす
                await self?.store(nil, for: key)
                return nil
            }
        }
        inFlight[key] = task
        return task
    }

    private func store(_ image: NSImage?, for key: String) {
        if let image { cache.setObject(image, forKey: key as NSString) }
        inFlight[key] = nil
    }

    /// 少しのサイズ違いで作り直さないよう段階に丸める
    private static func sizeBucket(_ size: CGFloat) -> CGFloat {
        let buckets: [CGFloat] = [48, 64, 96, 128, 192, 256, 384, 512]
        return buckets.first { $0 >= size } ?? 512
    }
}

/// サムネイル 1 枚ぶんの表示。読み込み中はファイル種別のアイコンを出す。
struct ThumbnailImage: View {
    let item: FileItem
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: size * 0.32))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(item.url.path)|\(Int(size))") {
            let task = await ThumbnailStore.shared.thumbnail(for: item.url, size: size)
            let result = await task.value
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
