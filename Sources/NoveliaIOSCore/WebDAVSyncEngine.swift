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
}

/// 书籍以外随同步合并的本机状态：阅读位置、书库系列、屏蔽标签、阅读背景与导入字体。
@MainActor
protocol WebDAVSyncLocalState {
    var readingPositions: [String: SyncedReadingPosition] { get }
    func mergeReadingPositions(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel])
    var librarySeries: LibrarySeriesState { get }
    func applyLibrarySeries(_ series: LibrarySeriesState)
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
    private let onProgress: (WebDAVSyncProgress) -> Void
    private(set) var progress = WebDAVSyncProgress() { didSet { onProgress(progress) } }

    init(remote: any WebDAVRemote, local: any WebDAVSyncLocalState,
         web: any SyncBookLibrary<DownloadedWebNovel>, wenku: any SyncBookLibrary<LocalWenkuEPUB>,
         options: WebDAVSyncOptions, onProgress: @escaping (WebDAVSyncProgress) -> Void) {
        self.remote = remote
        self.local = local
        self.web = web
        self.wenku = wenku
        self.options = options
        self.onProgress = onProgress
    }

    /// 返回从远端新恢复的书籍数。取消或失败时已传输的文件不会回滚；清单只在最后写入，
    /// 标签、系列、背景与字体在清单写入成功后才套用到本机。
    func run() async throws -> Int {
        try await remote.verifyConnection()
        progress.stage = "创建同步目录"
        progress.detail = "正在检查同步目录…"
        try await remote.prepareFolders()
        progress.stage = "读取远端书目"
        progress.detail = "正在读取远端书目…"
        let (fetchedManifest, etag, existed) = try await remote.fetchManifest()
        var manifest = fetchedManifest
        var imported = 0
        if options.books {
            manifest.webBooks = WebDAVSyncPlanner.uniqueBooks(manifest.webBooks)
            manifest.wenkuBooks = WebDAVSyncPlanner.uniqueBooks(manifest.wenkuBooks)
            let webPlan = WebDAVSyncPlanner.planBooks(local: web.books, remote: manifest.webBooks)
            let wenkuPlan = WebDAVSyncPlanner.planBooks(local: wenku.books, remote: manifest.wenkuBooks)
            progress.totalUnits = webPlan.unitCount { web.syncFiles(for: $0).count }
                + wenkuPlan.unitCount { wenku.syncFiles(for: $0).count }
                + 1
            progress.stage = "恢复远端下载"
            imported += try await download(webPlan, into: web)
            imported += try await download(wenkuPlan, into: wenku)
            local.mergeReadingPositions(manifest.positions, webBooks: web.books)
            progress.stage = "上传本地下载"
            try await upload(webPlan, from: web, into: &manifest.webBooks)
            try await upload(wenkuPlan, from: wenku, into: &manifest.wenkuBooks)
            manifest.positions = WebDAVSyncPlanner.positionsToSync(local.readingPositions, in: manifest)
            manifest.librarySeries = LibrarySeriesState.merged(local.librarySeries, manifest.librarySeries ?? LibrarySeriesState())
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
                    for hash in hashes {
                        let file = try await remote.downloadBlob(hash)
                        temporaryFiles.append(file)
                        guard local.isValidBackgroundImage(file) else { throw WebDAVSyncError.invalidAsset }
                        resourceFiles[hash] = file
                    }
                case .useLocal:
                    backgrounds[key] = current
                    for landscape in [false, true] {
                        let file = local.backgroundImageURL(dark: dark, landscape: landscape)
                        if FileManager.default.fileExists(atPath: file.path) {
                            try await remote.uploadBlob(file, hash: contentHash(of: file))
                        }
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
            for hash in plan.uploads {
                if let file = files[hash] { try await remote.uploadBlob(file, hash: hash) }
            }
            for hash in plan.downloads {
                let file = try await remote.downloadBlob(hash); temporaryFiles.append(file); resourceFiles[hash] = file
            }
            manifest.fonts = fonts
        }
        progress.stage = "保存远端书目"
        progress.detail = "正在保存同步清单…"
        try await remote.putManifest(manifest, etag: etag, existed: existed)
        if options.tags { local.applyBlockedTags(manifest.blockedTags ?? [:]) }
        if options.books, let series = manifest.librarySeries { local.applyLibrarySeries(series) }
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
        return imported
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
            try await remote.uploadBlob(url, hash: hash)
            assets.append(WebDAVAsset(filename: filename, hash: hash))
            progress.completedUnits += 1
        }
        return WebDAVBook(record: record, assets: assets)
    }

    /// 在后台读取文件计算哈希，书籍与背景图片可能很大，不能占用主线程。
    private func contentHash(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try WebDAVFileHash.sha256(url)
        }.value
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
