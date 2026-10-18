import Foundation

// WebDAV 同步的决策规则：比较本地与远端清单，得出要下载、上传和写回的内容。
// 这里只做纯计算，不访问网络与本地存储；执行由 WebDAVSyncStore 负责。

/// 可参与 WebDAV 书籍同步的本地记录；按 `syncTimestamp` 判断哪一端较新。
protocol SyncableBook: Codable, Identifiable {
    var syncTimestamp: Date { get }
    /// 跨设备的书籍标识，与书库键相同（`web:<id>`、`wenku:<UUID>`），用于云端删除记录。
    var syncKey: String { get }
    /// 进度提示中显示的书名。
    var syncTitle: String { get }
    /// 上传前确认本机文件齐全。
    func hasRequiredSyncFiles(_ files: [String: URL]) -> Bool
    /// 书库中手动修改信息的时间，同一文件版本按此合并信息；不支持修改的记录为 nil。
    var metadataUpdatedAt: Date? { get }
}

extension DownloadedWebNovel {
    /// 网络小说的信息来自网站，不在书库中修改。
    var metadataUpdatedAt: Date? { nil }
}

extension DownloadedWebNovel: SyncableBook {
    var syncTimestamp: Date { downloadedAt }
    var syncKey: String { "web:\(id)" }
    var syncTitle: String { novel.title }
    /// 网络小说只有一个正文文件；文件缺失时书库返回空表。
    func hasRequiredSyncFiles(_ files: [String: URL]) -> Bool { files.count == 1 }
}

extension LocalWenkuEPUB: SyncableBook {
    var syncTimestamp: Date { addedAt }
    var syncKey: String { "wenku:\(id.uuidString)" }
    var syncTitle: String { title }
    /// 文库与导入书籍必须包含正文，封面等附属文件可选。
    func hasRequiredSyncFiles(_ files: [String: URL]) -> Bool { files[filename] != nil }
}

struct BookSyncPlan<Record: SyncableBook> {
    struct Download {
        let book: WebDAVBook<Record>
        /// 本地已有该书的旧版本，下载后替换；否则作为新书恢复。
        let replacesLocal: Bool
    }

    /// 远端较新或本地没有的书，保持远端清单顺序。
    var downloads: [Download]
    /// 本地较新、只在本地或两端时间相同的书，保持本地顺序。
    var uploads: [Record]

    /// 需要传输的文件数；本地书的文件数由书库提供。
    func unitCount(localFileCount: (Record) -> Int) -> Int {
        downloads.reduce(0) { $0 + $1.book.assets.count } + uploads.reduce(0) { $0 + localFileCount($1) }
    }
}

enum BackgroundSyncDecision: Equatable {
    /// 远端较新：下载这些图片后套用远端设置。
    case useRemote(downloadHashes: [String])
    /// 本地较新或时间相同：上传本地图片并写入清单。
    case useLocal
}

struct FontSyncPlan: Equatable {
    var uploads: [String]
    var downloads: [String]
}

enum WebDAVSyncPlanner {
    /// 远端时间晚于本地才下载；时间相同时以本地为准并重新上传（已存在的 blob 不会重复传输）。
    static func planBooks<Record: SyncableBook>(local: [Record], remote: [WebDAVBook<Record>]) -> BookSyncPlan<Record> {
        let local = LibraryOrganizer.uniqueRecords(local, id: \.id, date: \.syncTimestamp)
        let remote = uniqueBooks(remote)
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.record.id, $0) })
        let downloads = remote.compactMap { item -> BookSyncPlan<Record>.Download? in
            guard let existing = localByID[item.record.id] else { return .init(book: item, replacesLocal: false) }
            return item.record.syncTimestamp > existing.syncTimestamp ? .init(book: item, replacesLocal: true) : nil
        }
        let uploads = local.filter { book in
            guard let item = remoteByID[book.id] else { return true }
            return book.syncTimestamp >= item.record.syncTimestamp
        }
        return BookSyncPlan(downloads: downloads, uploads: uploads)
    }

    /// 同一本书在清单中出现多次时（旧版本或手工编辑造成）只保留时间最新的一条，位置取首次出现处。
    static func uniqueBooks<Record: SyncableBook>(_ books: [WebDAVBook<Record>]) -> [WebDAVBook<Record>] {
        LibraryOrganizer.uniqueRecords(books, id: { $0.record.id }, date: { $0.record.syncTimestamp })
    }

    /// 清单引用的全部 blob：书籍文件、背景图片与未删除的字体。
    static func referencedBlobs(in manifest: WebDAVManifest) -> Set<String> {
        var hashes = Set((manifest.webBooks.flatMap(\.assets) + manifest.wenkuBooks.flatMap(\.assets)).map(\.hash))
        for background in (manifest.backgrounds ?? [:]).values {
            hashes.formUnion([background.portraitHash, background.landscapeHash].compactMap { $0 })
        }
        hashes.formUnion((manifest.fonts ?? [:]).values.filter { !$0.deleted }.map(\.hash))
        return hashes
    }

    /// 只保留清单中仍有书籍的阅读位置：网络小说按 id，EPUB/TXT 按文件哈希。
    static func positionsToSync(_ positions: [String: SyncedReadingPosition],
                                in manifest: WebDAVManifest) -> [String: SyncedReadingPosition] {
        let webKeys = Set(manifest.webBooks.map { "web:\($0.record.id)" })
        let assetHashes = (manifest.webBooks.flatMap(\.assets) + manifest.wenkuBooks.flatMap(\.assets)).map(\.hash)
        let fileKeys = Set(assetHashes.map { "epub:\($0)" } + assetHashes.map { "txt:\($0)" })
        return positions.filter { webKeys.contains($0.key) || fileKeys.contains($0.key) }
    }

    /// 只同步清单中书籍的书签（含墓碑）；本机已删除、也不在云端的书的书签留在本机。
    static func bookmarksToSync(_ bookmarks: [String: ReaderBookmark], in manifest: WebDAVManifest) -> [String: ReaderBookmark] {
        let hashes = (manifest.webBooks.flatMap(\.assets) + manifest.wenkuBooks.flatMap(\.assets)).map(\.hash)
        let keys = Set(hashes.map { "epub:\($0)" } + hashes.map { "txt:\($0)" })
        return bookmarks.filter { keys.contains($0.value.bookKey) }
    }

    /// 浅色、深色背景各自比较：远端严格较新才采用远端。
    static func planBackground(local: SyncedReaderBackground, remote: SyncedReaderBackground?) -> BackgroundSyncDecision {
        guard let remote, remote.updatedAt > local.updatedAt else { return .useLocal }
        return .useRemote(downloadHashes: [remote.portraitHash, remote.landscapeHash].compactMap { $0 })
    }

    /// 合并后的字体记录中，本机有文件的上传，其余下载；已删除的跳过。
    /// 先校验全部记录，任何一项无效都不开始传输。
    static func planFonts(_ fonts: [String: SyncedImportedFont], localHashes: Set<String>) throws -> FontSyncPlan {
        var plan = FontSyncPlan(uploads: [], downloads: [])
        for (hash, record) in fonts.sorted(by: { $0.key < $1.key }) {
            guard hash == record.hash, ["ttf", "otf", "ttc"].contains(record.format) else {
                throw WebDAVSyncError.invalidAsset
            }
            if record.deleted { continue }
            if localHashes.contains(hash) { plan.uploads.append(hash) } else { plan.downloads.append(hash) }
        }
        return plan
    }
}

/// 云端删除记录：书籍从云端删除时记下时间，晚于该时间下载或导入的同一本书才会再次同步。
enum WebDAVDeletedBooks {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    /// 仅保留最近三十天的书籍删除记录；恰好三十天的边界保留。过期后离线旧设备可能重新上传书籍。
    /// 不以此清理正文文件，其他类型（例如书签）的删除记录也不在此裁剪。
    static func prune(_ deleted: [String: Date], at now: Date) -> [String: Date] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return deleted }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        return deleted.filter { $0.value >= cutoff }
    }

    static func prune(in manifest: inout WebDAVManifest, at now: Date) {
        guard let deleted = manifest.deletedBooks else { return }
        manifest.deletedBooks = prune(deleted, at: now)
    }

    /// 去掉已删除的书：远端条目不再恢复，本机副本不再上传。比删除时间更新的书视为重新添加，同时清除删除记录。
    static func apply<Record: SyncableBook>(local: [Record], remote: [WebDAVBook<Record>], deleted: inout [String: Date])
        -> (local: [Record], remote: [WebDAVBook<Record>]) {
        func isDeleted(_ book: Record) -> Bool {
            guard let date = deleted[book.syncKey] else { return false }
            return book.syncTimestamp <= date
        }
        for book in local + remote.map(\.record) where deleted[book.syncKey] != nil && !isDeleted(book) {
            deleted[book.syncKey] = nil
        }
        return (local.filter { !isDeleted($0) }, remote.filter { !isDeleted($0.record) })
    }

    /// 从清单中删除指定书籍并记下删除时间，返回被删除书籍引用、且清单中已不再引用的 blob。
    static func remove(_ keys: Set<String>, from manifest: inout WebDAVManifest, at date: Date) -> Set<String> {
        let removed = manifest.webBooks.filter { keys.contains($0.record.syncKey) }.flatMap(\.assets)
            + manifest.wenkuBooks.filter { keys.contains($0.record.syncKey) }.flatMap(\.assets)
        manifest.webBooks.removeAll { keys.contains($0.record.syncKey) }
        manifest.wenkuBooks.removeAll { keys.contains($0.record.syncKey) }
        var deleted = prune(manifest.deletedBooks ?? [:], at: date)
        for key in keys { deleted[key] = max(deleted[key] ?? .distantPast, date) }
        manifest.deletedBooks = deleted
        manifest.positions = WebDAVSyncPlanner.positionsToSync(manifest.positions, in: manifest)
        return Set(removed.map(\.hash)).subtracting(WebDAVSyncPlanner.referencedBlobs(in: manifest))
    }
}

extension Array {
    /// 以本地上传后的记录替换清单中同 id 的旧记录。
    mutating func upsert<Record: SyncableBook>(_ book: WebDAVBook<Record>) where Element == WebDAVBook<Record> {
        removeAll { $0.record.id == book.record.id }
        append(book)
    }
}
