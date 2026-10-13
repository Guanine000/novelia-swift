import Foundation

// WebDAV 同步的决策规则：比较本地与远端清单，得出要下载、上传和写回的内容。
// 这里只做纯计算，不访问网络与本地存储；执行由 WebDAVSyncStore 负责。

/// 可参与 WebDAV 书籍同步的本地记录；按 `syncTimestamp` 判断哪一端较新。
protocol SyncableBook: Codable, Identifiable {
    var syncTimestamp: Date { get }
    /// 进度提示中显示的书名。
    var syncTitle: String { get }
    /// 上传前确认本机文件齐全。
    func hasRequiredSyncFiles(_ files: [String: URL]) -> Bool
}

extension DownloadedWebNovel: SyncableBook {
    var syncTimestamp: Date { downloadedAt }
    var syncTitle: String { novel.title }
    /// 网络小说只有一个正文文件；文件缺失时书库返回空表。
    func hasRequiredSyncFiles(_ files: [String: URL]) -> Bool { files.count == 1 }
}

extension LocalWenkuEPUB: SyncableBook {
    var syncTimestamp: Date { addedAt }
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

extension Array {
    /// 以本地上传后的记录替换清单中同 id 的旧记录。
    mutating func upsert<Record: SyncableBook>(_ book: WebDAVBook<Record>) where Element == WebDAVBook<Record> {
        removeAll { $0.record.id == book.record.id }
        append(book)
    }
}
