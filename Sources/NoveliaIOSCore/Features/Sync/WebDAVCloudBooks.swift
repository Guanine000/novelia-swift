import Foundation

// 只在云端有文件的书（“云端书籍”）。为节省 WebDAV 流量，同步只取回书籍记录和 EPUB 封面，
// 书籍文件在用户打开时才下载。清单格式不变，旧版应用照常读取。

/// 同步引擎记录云端书籍的接口；引擎只通过它读写，不关心本机如何保存。
@MainActor
protocol SyncCloudCatalog: AnyObject {
    /// 当前云端书籍的书库键（`web:<id>`、`wenku:<UUID>`），与 `LibraryBook.key` 相同。
    var cloudBookKeys: Set<String> { get }
    /// 已缓存的封面文件；没有缓存时返回 nil，引擎会下载一次。
    func cachedCover(hash: String) -> URL?
    /// 以本次同步的结果整体替换云端书籍：只含本机没有的书。`covers` 为本次新下载的封面临时文件，键为哈希。
    func replaceCloudBooks(web: [WebDAVBook<DownloadedWebNovel>], wenku: [WebDAVBook<LocalWenkuEPUB>],
                           covers: [String: URL]) throws
}

/// 云端书籍的本机记录与封面缓存，由 `LocalAppServices` 持有，书库与同步共用同一实例。
/// 保存在 Application Support/WebDAVCloudBooks：`index.json` 为记录，`covers/<哈希>` 为封面。
/// 这些都是可重建的缓存：删除后下次同步会重新取回记录与封面。
@MainActor
final class CloudBookStore: ObservableObject, SyncCloudCatalog {
    private struct Index: Codable {
        var web: [WebDAVBook<DownloadedWebNovel>] = []
        var wenku: [WebDAVBook<LocalWenkuEPUB>] = []
    }

    @Published private(set) var webBooks: [WebDAVBook<DownloadedWebNovel>] = []
    @Published private(set) var wenkuBooks: [WebDAVBook<LocalWenkuEPUB>] = []
    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebDAVCloudBooks", isDirectory: true)
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            webBooks = index.web
            wenkuBooks = index.wenku
        }
    }

    var cloudBookKeys: Set<String> {
        Set(webBooks.map { "web:\($0.record.id)" } + wenkuBooks.map { "wenku:\($0.record.id.uuidString)" })
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var coversDirectory: URL { directory.appendingPathComponent("covers", isDirectory: true) }

    private func coverFile(hash: String) -> URL { coversDirectory.appendingPathComponent(hash) }

    func cachedCover(hash: String) -> URL? {
        guard WebDAVAsset.isValidHash(hash) else { return nil }
        let url = coverFile(hash: hash)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// 文库或导入书的封面；TXT 与没有封面的 EPUB 返回 nil。
    func coverURL(for book: WebDAVBook<LocalWenkuEPUB>) -> URL? {
        Self.coverAsset(of: book).flatMap { cachedCover(hash: $0.hash) }
    }

    static func coverAsset(of book: WebDAVBook<LocalWenkuEPUB>) -> WebDAVAsset? {
        guard let name = book.record.coverFilename else { return nil }
        return book.assets.first { $0.filename == name }
    }

    func replaceCloudBooks(web: [WebDAVBook<DownloadedWebNovel>], wenku: [WebDAVBook<LocalWenkuEPUB>],
                           covers: [String: URL]) throws {
        try fileManager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        for (hash, file) in covers where WebDAVAsset.isValidHash(hash) && cachedCover(hash: hash) == nil {
            try fileManager.copyItem(at: file, to: coverFile(hash: hash))
        }
        try save(web: web, wenku: wenku)
        removeUnusedCovers()
    }

    /// 按书库键移除云端记录（从云端删除后调用）。
    func remove(keys: Set<String>) {
        try? save(web: webBooks.filter { !keys.contains("web:\($0.record.id)") },
                  wenku: wenkuBooks.filter { !keys.contains("wenku:\($0.record.id.uuidString)") })
        removeUnusedCovers()
    }

    /// 书已下载到本机后移除对应的云端记录。
    func remove(webID: String) {
        try? save(web: webBooks.filter { $0.record.id != webID }, wenku: wenkuBooks)
    }

    func remove(wenkuID: UUID) {
        try? save(web: webBooks, wenku: wenkuBooks.filter { $0.record.id != wenkuID })
        removeUnusedCovers()
    }

    private func save(web: [WebDAVBook<DownloadedWebNovel>], wenku: [WebDAVBook<LocalWenkuEPUB>]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Index(web: web, wenku: wenku)).write(to: indexURL, options: .atomic)
        if webBooks != web { webBooks = web }
        if wenkuBooks != wenku { wenkuBooks = wenku }
    }

    private func removeUnusedCovers() {
        let used = Set(wenkuBooks.compactMap { Self.coverAsset(of: $0)?.hash })
        guard let files = try? fileManager.contentsOfDirectory(atPath: coversDirectory.path) else { return }
        for name in files where !used.contains(name) {
            try? fileManager.removeItem(at: coverFile(hash: name))
        }
    }
}

/// 从云端删除书籍：从清单移除并记下删除时间，清单写入成功后再删除不再被引用的文件。
/// 清单写入遇到并发修改时重新读取后重试，最多三次。返回实际从清单中移除的书数。
enum WebDAVCloudBookDeleter {
    static func delete(_ keys: Set<String>, from remote: any WebDAVRemote, at date: Date = Date()) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (fetched, etag, existed) = try await remote.fetchManifest()
            guard existed else { return 0 }
            var manifest = fetched
            let before = manifest.webBooks.count + manifest.wenkuBooks.count
            let unused = WebDAVDeletedBooks.remove(keys, from: &manifest, at: date)
            do {
                try await remote.putManifest(manifest, etag: etag, existed: true)
            } catch WebDAVSyncError.concurrentChange where attempt < 2 {
                continue
            }
            // 清单已不引用这些文件；个别删除失败只会留下无用文件，不影响同步。
            for hash in unused.sorted() { try? await remote.deleteBlob(hash) }
            return before - manifest.webBooks.count - manifest.wenkuBooks.count
        }
        throw WebDAVSyncError.concurrentChange
    }
}

/// 打开云端书籍时下载它的全部文件。与同步引擎相同：只接受单级文件名，blob 下载时校验哈希，
/// 任何一个文件失败都删除已下载的临时文件。返回的临时文件由调用方在导入书库后删除。
enum WebDAVCloudBookDownloader {
    static func download(_ assets: [WebDAVAsset], from remote: any WebDAVRemote,
                         onProgress: (Int, Int) -> Void = { _, _ in }) async throws -> [String: URL] {
        var files: [String: URL] = [:]
        do {
            for (index, asset) in assets.enumerated() {
                try Task.checkCancellation()
                guard WebDAVAsset.isSafeFilename(asset.filename), files[asset.filename] == nil else {
                    throw WebDAVSyncError.invalidAsset
                }
                files[asset.filename] = try await remote.downloadBlob(asset.hash)
                onProgress(index + 1, assets.count)
            }
            return files
        } catch {
            files.values.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }
}
