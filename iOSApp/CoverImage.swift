import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// 轻小说封面同时缓存在内存（缩小采样用于显示）和磁盘中，
/// 避免列表滚动时重复下载或闪现占位图。
final class CoverImageLoader: @unchecked Sendable {
    static let shared = CoverImageLoader()

    /// 最大封面显示尺寸为 112 × 154 pt；480 px 足以覆盖 3× 分辨率。
    private static let maxPixelSize: CGFloat = 480
    private static let maxDiskBytes = 150 * 1024 * 1024
    private static let maxDiskAge: TimeInterval = 30 * 24 * 60 * 60

    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoverImages", isDirectory: true),
         session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        memory.totalCostLimit = 48 * 1024 * 1024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task.detached(priority: .background) { Self.prune(directory) }
    }

    /// 同步查询内存缓存，使已缓存的封面在首帧即可显示。
    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[url] { return existing }
            let task = Task.detached(priority: .userInitiated) { [self] in await load(url) }
            inFlight[url] = task
            return task
        }
        let image = await task.value
        lock.withLock { inFlight[url] = nil }
        return image
    }

    private func load(_ url: URL) async -> UIImage? {
        if url.isFileURL {
            guard let image = Self.downsampledFile(url) else { return nil }
            memory.setObject(image, forKey: url as NSURL,
                             cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
            return image
        }
        let file = directory.appendingPathComponent(Self.filename(for: url))
        var data = try? Data(contentsOf: file)
        if data == nil {
            guard let (downloaded, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  !downloaded.isEmpty else { return nil }
            data = downloaded
            try? downloaded.write(to: file, options: .atomic)
        }
        guard let data, let image = Self.downsampled(data) else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        memory.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    private static func filename(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func downsampled(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source)
    }

    private static func downsampledFile(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source)
    }

    private static func thumbnail(_ source: CGImageSource) -> UIImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 先移除超过 30 天的封面，再按从旧到新淘汰，直到文件夹不超过 150 MB。
    private static func prune(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.date < $1.date }
        let cutoff = Date().addingTimeInterval(-maxDiskAge)
        var total = entries.reduce(0) { $0 + $1.size }
        while let oldest = entries.first, oldest.date < cutoff || total > maxDiskBytes {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            entries.removeFirst()
        }
    }
}

/// 从 `CoverImageLoader` 加载封面，加载中或失败时显示 `placeholder`。
struct CoverImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        Group {
            if let image = currentImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, loaded?.url != url else { return }
            if let image = await CoverImageLoader.shared.image(for: url) { loaded = (url, image) }
        }
    }

    private var currentImage: UIImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return CoverImageLoader.shared.cachedImage(for: url)
    }
}
