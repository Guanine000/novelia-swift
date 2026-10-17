import Foundation

// 执行一次 WebDAV 同步：按 WebDAVSyncPlanner 的计划传输文件、更新本机书库并写回清单。
// 网络只经过 WebDAVRemote，本机状态只经过 SyncBookLibrary 与 WebDAVSyncLocalState。

/// 可同步的本机书库：网络小说下载，或文库与导入书籍。
@MainActor
protocol SyncBookLibrary<Record>: AnyObject {
    associatedtype Record: SyncableBook
    var books: [Record] { get }
    /// 该书需要上传的文件，键为远端记录中的文件名。
    func syncFiles(for book: Record) -> [String: URL]
    func restoreFromSync(_ book: Record, files: [String: URL]) throws
    func replaceFromSync(_ book: Record, files: [String: URL]) throws
    /// 其他设备已从云端删除这本书：删除本机文件与记录。
    func removeFromSync(_ book: Record)
    /// 其他设备修改过同一文件版本的书库信息（较新）：套用书名、作者、简介与封面（`cover` 为下载好的封面）。
    func applySyncedMetadata(_ book: Record, cover: URL?) throws
}

extension SyncBookLibrary {
    func applySyncedMetadata(_ book: Record, cover: URL?) throws {}
}

/// 书籍以外随同步合并的本机状态：阅读位置、书库系列、屏蔽标签、阅读背景与导入字体。
@MainActor
protocol WebDAVSyncLocalState {
    var readingPositions: [String: SyncedReadingPosition] { get }
    func mergeReadingPositions(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel])
    var librarySeries: LibrarySeriesState { get }
    func applyLibrarySeries(_ series: LibrarySeriesState)
    /// 阅读器书签（含删除墓碑），随书籍同步。
    var bookmarks: [String: ReaderBookmark] { get }
    func applyBookmarks(_ bookmarks: [String: ReaderBookmark])
    var blockedTags: [String: SyncedBlockedTag] { get }
    func applyBlockedTags(_ tags: [String: SyncedBlockedTag])
    func background(dark: Bool) throws -> SyncedReaderBackground
    /// 本机背景图片的保存位置；文件不存在表示该方向没有图片。
    func backgroundImageURL(dark: Bool, landscape: Bool) -> URL
    func isValidBackgroundImage(_ file: URL) -> Bool
    func applyBackground(_ value: SyncedReaderBackground, dark: Bool, files: [String: URL]) throws
    func fonts() throws -> [String: SyncedImportedFont]
    /// 本机导入字体文件，键为内容哈希。
    func fontFiles() throws -> [String: URL]
    func applyFonts(_ records: [String: SyncedImportedFont], files: [String: URL]) throws
}

extension WebDAVSyncLocalState {
    var bookmarks: [String: ReaderBookmark] { [:] }
    func applyBookmarks(_ bookmarks: [String: ReaderBookmark]) {}
}

struct WebDAVSyncOptions: Equatable {
    var books: Bool
    var tags: Bool
    var backgrounds: Bool
    var fonts: Bool
}

/// 同步进度：`stage` 用于失败提示，`detail` 显示在进度浮窗。
struct WebDAVSyncProgress: Equatable {
    var stage = "连接服务器"
    var detail = "正在连接服务器…"
    var completedUnits = 0
    var totalUnits = 1
}

@MainActor
final class WebDAVSyncEngine {
    private let remote: any WebDAVRemote
    private let local: any WebDAVSyncLocalState
    private let web: any SyncBookLibrary<DownloadedWebNovel>
    private let wenku: any SyncBookLibrary<LocalWenkuEPUB>
    private let options: WebDAVSyncOptions
    /// 有值时不下载书籍文件：本机没有的书只记为云端书籍（含 EPUB 封面），打开时再下载；
    /// 本机已有的书也不被远端较新的版本替换。为 nil 时下载全部书籍文件（旧行为）。
    private let cloud: (any SyncCloudCatalog)?
    private let onProgress: (WebDAVSyncProgress) -> Void
    private(set) var progress = WebDAVSyncProgress() { didSet { onProgress(progress) } }
    private let defaults: UserDefaults
    /// 上次同步保存的文件哈希，键为 `WebDAVFileHash.identity`。
    private let cachedHashes: [String: String]
    /// 本次同步用到的文件哈希，结束时写回缓存。
    private var usedHashes: [String: String] = [:]
    /// 远端已有的 blob：清单引用的文件都在写清单之前上传过，不必再询问服务器。
    private var knownBlobs: Set<String> = []
    /// 清单写入成功后才更新的云端书籍及本次下载的封面。
    private var pendingCloud: (web: [WebDAVBook<DownloadedWebNovel>], wenku: [WebDAVBook<LocalWenkuEPUB>], covers: [String: URL])?
    private var temporaryCovers: [URL] = []
    /// 被其他设备从云端删除、清单写入成功后要从本机删除的书。
    private var deletedLocalWeb: [DownloadedWebNovel] = []
    private var deletedLocalWenku: [LocalWenkuEPUB] = []
    /// 本次按云端删除记录从本机删除的书数。
    private(set) var removedLocalCount = 0
    /// 本次套用其他设备修改的书库信息的书数。
    private(set) var updatedMetadataCount = 0
    /// 已恢复到本机的新书数（下载全部文件模式）；清单写入失败也不回滚，重试时据此累计提示数量。
    private(set) var restoredBeforeFailure = 0
    /// 服务器已有清单却没有返回 ETag：写清单无法带条件，多设备同时同步时后写入的会覆盖先写入的。
    private(set) var manifestLacksETag = false
    /// 为 true 时（手动同步）先列出服务器 blobs/，清单引用却已不在服务器上的文件由本机补传。
    private let verifiesBlobs: Bool
    /// 同步开始时清单引用、服务器却没有的文件。
    private var missingBlobs: Set<String> = []
    /// 本次补传的缺失文件。
    private(set) var repairedBlobs: Set<String> = []
    /// 写入的清单仍引用、服务器缺少且本机没有可补传的文件数；需要在仍有这些书的设备上同步。
    private(set) var unrepairedBlobCount = 0
    /// 本次是否成功列出服务器文件；为 false 时不更新云端书籍的缺失标记。
    private var didListBlobs = false
    /// 书籍文件缺失、本机也没有的云端书籍（书名，用于完成提示）。
    private(set) var missingCloudBookTitles: [String] = []

    init(remote: any WebDAVRemote, local: any WebDAVSyncLocalState,
         web: any SyncBookLibrary<DownloadedWebNovel>, wenku: any SyncBookLibrary<LocalWenkuEPUB>,
         options: WebDAVSyncOptions, defaults: UserDefaults = .standard,
         cloud: (any SyncCloudCatalog)? = nil, verifiesBlobs: Bool = false,
         onProgress: @escaping (WebDAVSyncProgress) -> Void) {
        self.remote = remote
        self.verifiesBlobs = verifiesBlobs
        self.cloud = cloud
        self.local = local
        self.web = web
        self.wenku = wenku
        self.options = options
        self.defaults = defaults
        cachedHashes = defaults.dictionary(forKey: SettingsKey.WebDAV.fileHashes) as? [String: String] ?? [:]
        self.onProgress = onProgress
    }

    /// 返回从远端新恢复的书籍数；记录云端书籍时为本次新出现的云端书籍数。取消或失败时已传输的文件不会回滚；清单只在最后写入，
    /// 标签、系列、背景与字体在清单写入成功后才套用到本机。阅读位置例外：在上传前按时间合并进本机，
    /// 以便写入清单的是合并结果；按时间合并可重复执行，清单写入失败也不会产生错误进度。
    func run() async throws -> Int {
        var finished = false
        defer {
            saveHashes(pruning: finished && options.books)
            temporaryCovers.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try await remote.verifyConnection()
        progress.stage = "创建同步目录"
        progress.detail = "正在检查同步目录…"
        try await remote.prepareFolders()
        progress.stage = "读取远端书目"
        progress.detail = "正在读取远端书目…"
        let (fetchedManifest, etag, existed) = try await remote.fetchManifest()
        manifestLacksETag = existed && etag == nil
        var manifest = fetchedManifest
        knownBlobs = WebDAVSyncPlanner.referencedBlobs(in: fetchedManifest)
        if verifiesBlobs, existed {
            progress.detail = "正在核对云端文件…"
            // 列目录失败或服务器不支持时照常同步，只是不补传。
            if let present = try? await remote.listBlobs() {
                didListBlobs = true
                missingBlobs = knownBlobs.subtracting(present)
                knownBlobs.formIntersection(present)
            }
        }
        var imported = 0
        if options.books {
            manifest.webBooks = WebDAVSyncPlanner.uniqueBooks(manifest.webBooks)
            manifest.wenkuBooks = WebDAVSyncPlanner.uniqueBooks(manifest.wenkuBooks)
            // 先套用其他设备较新的书库信息，随后的规划与上传就写回合并后的记录。
            try await mergeEditedMetadata(manifest.wenkuBooks)
            // 云端已删除的书不恢复也不上传；重新下载或导入的更新版本照常同步。
            var deleted = manifest.deletedBooks ?? [:]
            let webBooks = WebDAVDeletedBooks.apply(local: web.books, remote: manifest.webBooks, deleted: &deleted)
            let wenkuBooks = WebDAVDeletedBooks.apply(local: wenku.books, remote: manifest.wenkuBooks, deleted: &deleted)
            manifest.webBooks = webBooks.remote
            manifest.wenkuBooks = wenkuBooks.remote
            // 删除时间及之前的本机副本随云端删除一起移除；之后重新下载或导入的版本不受影响。
            deletedLocalWeb = web.books.filter { book in !webBooks.local.contains { $0.id == book.id } }
            deletedLocalWenku = wenku.books.filter { book in !wenkuBooks.local.contains { $0.id == book.id } }
            if manifest.deletedBooks != nil || !deleted.isEmpty { manifest.deletedBooks = deleted }
            let webPlan = WebDAVSyncPlanner.planBooks(local: webBooks.local, remote: manifest.webBooks)
            let wenkuPlan = WebDAVSyncPlanner.planBooks(local: wenkuBooks.local, remote: manifest.wenkuBooks)
            if let cloud {
                let webCloud = webPlan.downloads.filter { !$0.replacesLocal }.map(\.book)
                let wenkuCloud = wenkuPlan.downloads.filter { !$0.replacesLocal }.map(\.book)
                let coverAssets = wenkuCloud.compactMap(CloudBookStore.coverAsset(of:))
                    .filter { cloud.cachedCover(hash: $0.hash) == nil }
                progress.totalUnits = webPlan.uploads.reduce(0) { $0 + web.syncFiles(for: $1).count }
                    + wenkuPlan.uploads.reduce(0) { $0 + wenku.syncFiles(for: $1).count }
                    + coverAssets.count + 1
                progress.stage = "取回云端书目"
                var covers: [String: URL] = [:]
                for asset in coverAssets where covers[asset.hash] == nil {
                    try Task.checkCancellation()
                    progress.detail = "正在取回封面…"
                    // 封面缺失只影响显示，不让整次同步失败。
                    do {
                        let file = try await remote.downloadBlob(asset.hash)
                        temporaryCovers.append(file)
                        covers[asset.hash] = file
                    } catch WebDAVSyncError.missingBlob {}
                    progress.completedUnits += 1
                }
                pendingCloud = (webCloud, wenkuCloud, covers)
                imported = Self.newCount(webCloud, wenkuCloud, known: cloud)
            } else {
                progress.totalUnits = webPlan.unitCount { web.syncFiles(for: $0).count }
                    + wenkuPlan.unitCount { wenku.syncFiles(for: $0).count }
                    + 1
                progress.stage = "恢复远端下载"
                imported += try await download(webPlan, into: web)
                imported += try await download(wenkuPlan, into: wenku)
            }
            local.mergeReadingPositions(manifest.positions, webBooks: web.books)
            progress.stage = "上传本地下载"
            try await upload(webPlan, from: web, into: &manifest.webBooks)
            try await upload(wenkuPlan, from: wenku, into: &manifest.wenkuBooks)
            progress.detail = "正在整理书目…"
            try await fillMissingSizes(&manifest.webBooks, from: web)
            try await fillMissingSizes(&manifest.wenkuBooks, from: wenku)
            manifest.positions = WebDAVSyncPlanner.positionsToSync(local.readingPositions, in: manifest)
            manifest.librarySeries = LibrarySeriesState.merged(local.librarySeries, manifest.librarySeries ?? LibrarySeriesState())
            let bookmarks = WebDAVSyncPlanner.bookmarksToSync(
                ReaderBookmark.merged(local.bookmarks, manifest.bookmarks ?? [:]), in: manifest)
            if manifest.bookmarks != nil || !bookmarks.isEmpty { manifest.bookmarks = bookmarks }
        }
        if options.tags {
            manifest.blockedTags = BlockedTagsStore.merged(local.blockedTags, manifest.blockedTags ?? [:])
        }
        var resourceFiles: [String: URL] = [:]
        var temporaryFiles: [URL] = []
        defer { temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        if options.backgrounds {
            progress.stage = "同步阅读背景"; progress.detail = "正在同步背景颜色与竖横屏图片…"
            var backgrounds = manifest.backgrounds ?? [:]
            for dark in [false, true] {
                let key = dark ? "dark" : "light"
                let current = try local.background(dark: dark)
                switch WebDAVSyncPlanner.planBackground(local: current, remote: backgrounds[key]) {
                case .useRemote(let hashes):
                    progress.totalUnits += hashes.count
                    for hash in hashes {
                        let file = try await remote.downloadBlob(hash)
                        temporaryFiles.append(file)
                        guard local.isValidBackgroundImage(file) else { throw WebDAVSyncError.invalidAsset }
                        resourceFiles[hash] = file
                        progress.completedUnits += 1
                    }
                case .useLocal:
                    backgrounds[key] = current
                    let images = [false, true].map { local.backgroundImageURL(dark: dark, landscape: $0) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    progress.totalUnits += images.count
                    for file in images {
                        try await uploadIfNeeded(file, hash: contentHash(of: file))
                        progress.completedUnits += 1
                    }
                }
            }
            manifest.backgrounds = backgrounds
        }
        if options.fonts {
            progress.stage = "同步导入字体"; progress.detail = "正在同步导入字体…"
            let fonts = SyncedImportedFont.merged(try local.fonts(), manifest.fonts ?? [:])
            let files = try local.fontFiles()
            let plan = try WebDAVSyncPlanner.planFonts(fonts, localHashes: Set(files.keys))
            progress.totalUnits += plan.uploads.count + plan.downloads.count
            for hash in plan.uploads {
                if let file = files[hash] { try await uploadIfNeeded(file, hash: hash) }
                progress.completedUnits += 1
            }
            // 清单已记录、服务器却缺少的本机字体文件一并补传。
            for (hash, file) in files where missingBlobs.contains(hash) && !knownBlobs.contains(hash) {
                try await uploadIfNeeded(file, hash: hash)
            }
            for hash in plan.downloads {
                let file = try await remote.downloadBlob(hash); temporaryFiles.append(file); resourceFiles[hash] = file
                progress.completedUnits += 1
            }
            manifest.fonts = fonts
        }
        progress.stage = "保存远端书目"
        progress.detail = "正在保存同步清单…"
        if !missingBlobs.isEmpty {
            unrepairedBlobCount = WebDAVSyncPlanner.referencedBlobs(in: manifest).intersection(missingBlobs)
                .subtracting(repairedBlobs).count
        }
        // 清单与读取时完全相同就不再写入：没有改动的同步只需读取一次清单。
        if !existed || !Self.sameContent(manifest, fetchedManifest) {
            try await remote.putManifest(manifest, etag: etag, existed: existed)
        }
        deletedLocalWeb.forEach(web.removeFromSync)
        deletedLocalWenku.forEach(wenku.removeFromSync)
        removedLocalCount = deletedLocalWeb.count + deletedLocalWenku.count
        if let cloud, let pendingCloud {
            try cloud.replaceCloudBooks(web: pendingCloud.web, wenku: pendingCloud.wenku, covers: pendingCloud.covers)
            if didListBlobs {
                // 只看书籍主文件：封面缺失不影响阅读。书目不自动删除，由用户在书库中决定。
                let stillMissing = missingBlobs.subtracting(repairedBlobs)
                let web = pendingCloud.web.filter { $0.mainAsset.map { stillMissing.contains($0.hash) } ?? false }
                let wenku = pendingCloud.wenku.filter { $0.mainAsset.map { stillMissing.contains($0.hash) } ?? false }
                cloud.setMissingFileKeys(Set(web.map(\.libraryKey) + wenku.map(\.libraryKey)))
                missingCloudBookTitles = web.map(\.record.syncTitle) + wenku.map(\.record.syncTitle)
            }
        }
        if options.tags { local.applyBlockedTags(manifest.blockedTags ?? [:]) }
        if options.books, let series = manifest.librarySeries { local.applyLibrarySeries(series) }
        if options.books, let bookmarks = manifest.bookmarks { local.applyBookmarks(bookmarks) }
        if options.backgrounds {
            for dark in [false, true] {
                if let value = manifest.backgrounds?[dark ? "dark" : "light"] {
                    try local.applyBackground(value, dark: dark, files: resourceFiles)
                }
            }
        }
        if options.fonts { try local.applyFonts(manifest.fonts ?? [:], files: resourceFiles) }
        progress.completedUnits += 1
        progress.detail = "同步完成"
        finished = true
        return imported
    }

    /// 同一文件版本（`syncTimestamp` 相同）的书，远端书库信息的修改时间较新时套用到本机。
    /// 与阅读位置一样按时间合并，可重复执行；封面缺失时只更新文字信息。
    private func mergeEditedMetadata(_ remoteBooks: [WebDAVBook<LocalWenkuEPUB>]) async throws {
        for item in remoteBooks {
            guard let localBook = wenku.books.first(where: { $0.id == item.record.id }),
                  localBook.syncTimestamp == item.record.syncTimestamp,
                  (item.record.metadataUpdatedAt ?? .distantPast) > (localBook.metadataUpdatedAt ?? .distantPast) else { continue }
            try Task.checkCancellation()
            var cover: URL?
            if let name = item.record.coverFilename, let asset = item.assets.first(where: { $0.filename == name }) {
                do {
                    let file = try await remote.downloadBlob(asset.hash)
                    temporaryCovers.append(file)
                    cover = file
                } catch WebDAVSyncError.missingBlob {}
            }
            try wenku.applySyncedMetadata(item.record, cover: cover)
            updatedMetadataCount += 1
        }
    }

    /// 旧清单的文件没有大小：本机有同一版本（记录时间相同）且内容哈希一致时补上，之后写回清单。
    /// 只读本机文件属性与已缓存的哈希，不产生网络请求。
    private func fillMissingSizes<Record: SyncableBook>(_ books: inout [WebDAVBook<Record>],
                                          from library: any SyncBookLibrary<Record>) async throws {
        for index in books.indices where books[index].assets.contains(where: { $0.size == nil }) {
            try Task.checkCancellation()
            let book = books[index]
            guard let localBook = library.books.first(where: { $0.id == book.record.id }),
                  localBook.syncTimestamp == book.record.syncTimestamp else { continue }
            let files = library.syncFiles(for: localBook)
            var assets = book.assets
            for assetIndex in assets.indices where assets[assetIndex].size == nil {
                guard let file = files[assets[assetIndex].filename],
                      try await contentHash(of: file) == assets[assetIndex].hash else { continue }
                assets[assetIndex].size = Self.fileSize(file)
            }
            if assets != book.assets { books[index] = WebDAVBook(record: book.record, assets: assets) }
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// 本次新出现（之前不在云端书籍中）的书数，用于完成提示。
    private static func newCount(_ web: [WebDAVBook<DownloadedWebNovel>], _ wenku: [WebDAVBook<LocalWenkuEPUB>],
                                 known cloud: any SyncCloudCatalog) -> Int {
        let known = cloud.cloudBookKeys
        return web.filter { !known.contains("web:\($0.record.id)") }.count
            + wenku.filter { !known.contains("wenku:\($0.record.id.uuidString)") }.count
    }

    private static func sameContent(_ lhs: WebDAVManifest, _ rhs: WebDAVManifest) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    /// 下载远端较新的书并写入本机书库，返回新恢复（而非替换）的书数。
    private func download<Record>(_ plan: BookSyncPlan<Record>, into library: any SyncBookLibrary<Record>) async throws -> Int {
        var restored = 0
        for item in plan.downloads {
            try Task.checkCancellation()
            let record = item.book.record
            let files = try await download(item.book.assets, title: record.syncTitle)
            defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
            if item.replacesLocal {
                try library.replaceFromSync(record, files: files)
            } else {
                try library.restoreFromSync(record, files: files)
                restored += 1
                restoredBeforeFailure += 1
            }
        }
        return restored
    }

    /// 上传本机较新的书，并以新记录替换清单中的旧记录。
    private func upload<Record>(_ plan: BookSyncPlan<Record>, from library: any SyncBookLibrary<Record>,
                                into books: inout [WebDAVBook<Record>]) async throws {
        for book in plan.uploads {
            try Task.checkCancellation()
            let files = library.syncFiles(for: book)
            guard book.hasRequiredSyncFiles(files) else { throw WebDAVSyncError.invalidAsset }
            books.upsert(try await remoteBook(book, files: files))
        }
    }

    private func remoteBook<Record: SyncableBook>(_ record: Record, files: [String: URL]) async throws -> WebDAVBook<Record> {
        var assets: [WebDAVAsset] = []
        for (filename, url) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            progress.detail = "正在上传：\(record.syncTitle) · \(filename)"
            let hash = try await contentHash(of: url)
            try await uploadIfNeeded(url, hash: hash)
            assets.append(WebDAVAsset(filename: filename, hash: hash, size: Self.fileSize(url)))
            progress.completedUnits += 1
        }
        return WebDAVBook(record: record, assets: assets)
    }

    /// 在后台读取文件计算哈希，书籍与背景图片可能很大，不能占用主线程。
    /// 路径、大小与修改时间都未变的文件沿用上次的结果。
    private func contentHash(of url: URL) async throws -> String {
        let cached = cachedHashes
        let (identity, hash) = try await Task.detached(priority: .utility) { () throws -> (String?, String) in
            let identity = WebDAVFileHash.identity(of: url)
            if let identity, let hash = cached[identity] { return (identity, hash) }
            return (identity, try WebDAVFileHash.sha256(url))
        }.value
        if let identity { usedHashes[identity] = hash }
        return hash
    }

    private func uploadIfNeeded(_ file: URL, hash: String) async throws {
        guard !knownBlobs.contains(hash) else { return }
        defer { if missingBlobs.contains(hash), knownBlobs.contains(hash) { repairedBlobs.insert(hash) } }
        try await remote.uploadBlob(file, hash: hash)
        knownBlobs.insert(hash)
    }

    /// 书籍同步完整结束时只保留本次用到的条目，清掉已删除或已修改文件的旧哈希；
    /// 失败或未同步书籍时只追加，避免丢掉尚未处理的书的缓存。
    private func saveHashes(pruning: Bool) {
        let hashes = pruning ? usedHashes : cachedHashes.merging(usedHashes) { $1 }
        guard hashes != cachedHashes else { return }
        defaults.set(hashes, forKey: SettingsKey.WebDAV.fileHashes)
    }

    /// 下载一本书的全部文件到临时位置；任何一个失败都删除已下载的文件。
    private func download(_ assets: [WebDAVAsset], title: String) async throws -> [String: URL] {
        var files: [String: URL] = [:]
        do {
            for asset in assets {
                try Task.checkCancellation()
                guard WebDAVAsset.isSafeFilename(asset.filename), files[asset.filename] == nil else {
                    throw WebDAVSyncError.invalidAsset
                }
                progress.detail = "正在恢复：\(title) · \(asset.filename)"
                files[asset.filename] = try await remote.downloadBlob(asset.hash)
                progress.completedUnits += 1
            }
            return files
        } catch {
            files.values.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }
}

extension WebDAVSyncEngine {
    /// 清单写入因其他设备刚写过而冲突（412）时，重新读取清单并完整再执行一次，最多 `maxAttempts` 次。
    /// 重跑是安全的：清单写入前只向本机追加/替换较新的书并按时间合并进度，重新规划不会重复导入；
    /// 删除本机副本、云端书目、系列、标签、背景与字体都只在清单写入成功后套用。
    /// 返回各次新恢复书数之和（失败那次已恢复到本机的书不会在下一次再计数），以及成功那次的其他结果。
    static func runRetryingConcurrentChange(maxAttempts: Int = 3, make: () -> WebDAVSyncEngine)
        async throws -> WebDAVSyncRunResult {
        var imported = 0
        for attempt in 1...max(1, maxAttempts) {
            let engine = make()
            do {
                imported += try await engine.run()
                return WebDAVSyncRunResult(imported: imported, removedLocal: engine.removedLocalCount,
                                           lacksETag: engine.manifestLacksETag,
                                           repairedBlobs: engine.repairedBlobs.count,
                                           unrepairedBlobs: engine.unrepairedBlobCount,
                                           missingCloudBookTitles: engine.missingCloudBookTitles)
            } catch WebDAVSyncError.concurrentChange where attempt < maxAttempts {
                imported += engine.restoredBeforeFailure
                continue
            }
        }
        throw WebDAVSyncError.concurrentChange
    }
}

/// 一次内容同步的结果，用于完成提示与设置页状态。
struct WebDAVSyncRunResult: Equatable {
    var imported: Int
    var removedLocal: Int
    var lacksETag: Bool
    /// 本次补传的、服务器缺失的文件数（仅手动同步核对）。
    var repairedBlobs = 0
    /// 服务器仍缺少、本机也没有的文件数。
    var unrepairedBlobs = 0
    /// 书籍文件缺失的云端书籍书名，书库中标记为“云端文件缺失”。
    var missingCloudBookTitles: [String] = []
}

/// 串行执行会写入 WebDAV 清单的操作（书籍等内容同步与云端删除），先到先执行。
/// 没有 ETag 的服务器无法用条件写入阻止覆盖，本机至少不让两个操作交错读写清单。
typealias WebDAVManifestWriteGate = SerialAsyncGate
