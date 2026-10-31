import Foundation

enum WebDAVEPUBUpdateError: LocalizedError {
    case disabled, busy, missingBook, localNewer, incompatible
    var errorDescription: String? {
        switch self {
        case .disabled: "请先开启 WebDAV 同步和书籍同步，并填写服务器凭据。"
        case .busy: "正在同步或下载，请完成后重试。"
        case .missingBook: "WebDAV 中没有这本书的有效书目，请先在持有新版的设备上同步。"
        case .localNewer: "本机 EPUB 的下载时间更新，未使用云端旧版覆盖。请先核对并同步本机版本。"
        case .incompatible: "云端记录不是可更新的网络小说 EPUB，未替换本机文件。"
        }
    }
}

/// 手动取回 WebDAV 同一本小说的新文件版本，仅执行读取；不重新生成 EPUB，也不写源清单。
/// 本地替换负责承接旧版状态，随后正常同步按新文件哈希合并双方进度与书签。
@MainActor
enum WebDAVEPUBUpdater {
    enum Result { case updated, alreadyCurrent }

    static func run(book: DownloadedWebNovel, remote: any WebDAVRemote,
                    library: any SyncBookLibrary<DownloadedWebNovel>, local: any WebDAVSyncLocalState,
                    onProgress: (String) -> Void = { _ in }) async throws -> Result {
        try await library.prepareForSync()
        guard book.novel.isRemote, book.resolvedFileFormat == .epub else { throw WebDAVEPUBUpdateError.incompatible }
        guard library.books.first(where: { $0.id == book.id }) == book else { throw WebDAVSyncError.concurrentChange }
        onProgress("读取 WebDAV 最新书目…")
        let (manifest, _, exists) = try await remote.fetchManifest()
        guard exists else { throw WebDAVEPUBUpdateError.missingBook }
        let target = try selected(book.id, in: manifest)
        guard let asset = target.mainAsset, WebDAVAsset.isValidHash(asset.hash),
              WebDAVAsset.isSafeFilename(asset.filename), target.assets.count == 1 else {
            throw WebDAVSyncError.invalidAsset
        }
        let originalFile = library.syncFiles(for: book)[book.fileFilename]
        let hash = try await Task.detached(priority: .utility) {
            try originalFile.map { try FileContentHash.sha256($0) }
        }.value
        let sameFile = hash == asset.hash
        if !sameFile {
            guard target.record.downloadedAt > book.downloadedAt else {
                if target.record.downloadedAt < book.downloadedAt { throw WebDAVEPUBUpdateError.localNewer }
                throw WebDAVSyncError.concurrentChange
            }
        }
        var files: [String: URL] = [:]
        defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
        if !sameFile {
            onProgress("下载并校验云端 EPUB…")
            files = try await WebDAVCloudBookDownloader.download(target.assets, from: remote)
            guard let file = files[asset.filename] else { throw WebDAVSyncError.invalidAsset }
            let actual = try await Task.detached(priority: .utility) { try FileContentHash.sha256(file) }.value
            guard actual == asset.hash else { throw WebDAVSyncError.invalidAsset }
        }
        try Task.checkCancellation()
        // 下载过程中允许云端进度变化，但不能把已经被替换/删除的文件版本提交到本机。
        onProgress("复核云端版本并合并阅读状态…")
        let (latest, _, stillExists) = try await remote.fetchManifest()
        guard stillExists, try selected(book.id, in: latest) == target,
              library.books.first(where: { $0.id == book.id }) == book else { throw WebDAVSyncError.concurrentChange }
        let key = "epub:\(asset.hash)"
        // 先合并目标哈希的远端状态，替换钩子再承接本机旧版，双方均按各自更新时间归并。
        // 替换失败时这些状态仍与旧文件分离，旧文件和旧哈希记录不受影响。
        let bookmarks = (latest.bookmarks ?? [:]).filter { $0.value.bookKey == key }
        try local.applyBookmarks(ReaderBookmark.merged(local.bookmarks, bookmarks))
        local.mergeReadingPositions(latest.positions.filter { $0.key == key || $0.key == "web:\(book.id)" }, webBooks: library.books)
        try Task.checkCancellation()
        guard !sameFile else { return .alreadyCurrent }
        onProgress("承接本机阅读状态并替换 EPUB…")
        try await library.replaceFromSync(target.record, files: files)
        return .updated
    }

    private static func selected(_ id: String, in manifest: WebDAVManifest) throws -> WebDAVBook<DownloadedWebNovel> {
        guard manifest.version == 1 else { throw WebDAVSyncError.unsupportedManifest }
        guard let target = WebDAVSyncPlanner.uniqueBooks(manifest.webBooks).first(where: { $0.record.id == id }),
              target.record.downloadedAt > (manifest.deletedBooks?[target.record.syncKey] ?? .distantPast) else {
            throw WebDAVEPUBUpdateError.missingBook
        }
        guard target.record.novel.isRemote, target.record.resolvedFileFormat == .epub else { throw WebDAVEPUBUpdateError.incompatible }
        return target
    }
}
