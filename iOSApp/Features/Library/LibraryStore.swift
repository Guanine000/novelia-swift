import Foundation
import SwiftUI

/// 书库中的一本书：网络小说下载或文库书（包括导入的 TXT/EPUB 和文库下载）。
/// 显示与排序所需的字段在创建时取出一次；相等性只比较这些字段，
/// 不逐项比较原始记录（网络小说记录含完整章节列表，比较代价很高）。
struct LibraryBook: Identifiable, Hashable {
    enum Origin {
        case webNovel(DownloadedWebNovel)
        case wenku(LocalWenkuEPUB)
    }

    let origin: Origin
    let fileURL: URL
    let coverURL: URL?
    /// 系列归属与“最近打开”使用的标识。
    let key: String
    let title: String
    let author: String
    let format: WebNovelFileFormat
    /// 排序用的导入时间：导入的书为导入时间，下载的书为下载完成时间。
    let importedAt: Date
    /// 云端书籍：文件只在 WebDAV 上，打开前需下载。值为主文件的内容哈希（与阅读位置键一致）。
    let cloudFileHash: String?
    var isCloudOnly: Bool { cloudFileHash != nil }
    /// 云端书籍全部文件的大小；清单中有文件缺少大小时为 nil。
    let cloudDownloadSize: Int64?
    /// 云端书籍的文件已不在服务器上（手动同步核对或下载时发现），无法下载。
    let cloudFileMissing: Bool

    init(origin: Origin, fileURL: URL, coverURL: URL?, cloudFileHash: String? = nil, cloudDownloadSize: Int64? = nil,
         cloudFileMissing: Bool = false) {
        self.origin = origin
        self.cloudFileMissing = cloudFileMissing
        self.fileURL = fileURL
        self.coverURL = coverURL
        self.cloudFileHash = cloudFileHash
        self.cloudDownloadSize = cloudDownloadSize
        switch origin {
        case .webNovel(let book):
            key = "web:\(book.id)"
            title = book.novel.title
            author = book.novel.author
            format = book.resolvedFileFormat
            importedAt = book.downloadedAt
        case .wenku(let book):
            key = "wenku:\(book.id.uuidString)"
            title = book.title
            author = book.author ?? ""
            format = book.resolvedFileFormat
            importedAt = book.addedAt
        }
    }

    var id: String { key }

    var isWenku: Bool {
        if case .wenku = origin { return true }
        return false
    }

    var categoryTitle: String {
        switch origin {
        case .webNovel: "网络小说"
        case .wenku: "文库"
        }
    }

    /// 阅读位置以文件内容哈希为键；该前缀与阅读器写入时一致。
    var positionPrefix: String { format == .txt ? "txt:" : "epub:" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.title == rhs.title && lhs.author == rhs.author
            && lhs.format == rhs.format && lhs.importedAt == rhs.importedAt
            && lhs.fileURL == rhs.fileURL && lhs.coverURL == rhs.coverURL
            && lhs.cloudFileHash == rhs.cloudFileHash && lhs.cloudDownloadSize == rhs.cloudDownloadSize
            && lhs.cloudFileMissing == rhs.cloudFileMissing
    }

    /// 例如“2.3 MB”；大小未知时为 nil。
    var cloudDownloadSizeText: String? {
        cloudDownloadSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// 全部文件都有大小时返回总和。
    static func totalSize(_ assets: [WebDAVAsset]) -> Int64? {
        assets.reduce(Int64(0) as Int64?) { total, asset in
            guard let total, let size = asset.size else { return nil }
            return total + size
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

struct LibraryReadingStatus: Equatable {
    var lastReadAt: Date?
    /// 例如“读到 42%”“第 3 章”“已打开”“未读”。
    var detail: String
    var fraction: Double?
    var isUnread: Bool { lastReadAt == nil }
}

/// 书库的系列归属、排序设置、最近打开时间与文件哈希缓存。
/// 书籍文件和阅读进度仍由原有下载库与阅读器保存，这里只保存附加信息。
/// LocalAppServices 持有的书库组织与展示状态，通过进度接口关联最近阅读。
/// 文件记录由下载/导入 Store 管理；保留系列、书籍归属和已保存设置的兼容。
@MainActor
final class LibraryStateStore: ObservableObject, LibrarySeriesManaging {

    @Published private(set) var series: LibrarySeriesState
    @Published private(set) var positions: [String: SyncedReadingPosition] = [:]
    @Published private(set) var lastOpened: [String: Date]
    /// 书籍标识 → 文件内容哈希，由 `refreshHashes` 更新。
    @Published private(set) var hashByBook: [String: String] = [:]
    /// 文件身份（标识、文件名、大小、修改时间）→ 哈希的持久缓存。
    private var hashes: [String: String]

    private let readingPositions: any ReadingPositionProviding
    private let defaults: UserDefaults
    private let seriesURL: URL
    private var hashRefreshGeneration = 0

    private enum Key {
        static let hashes = "library.fileHashes.v1"
        static let lastOpened = "library.lastOpened.v1"
        static let sort = "library.sort.v1"
    }

    init(positions: any ReadingPositionProviding, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.readingPositions = positions
        self.defaults = defaults
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("Library", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        seriesURL = directory.appendingPathComponent("series.json")
        series = (try? Data(contentsOf: seriesURL)).flatMap { try? JSONDecoder().decode(LibrarySeriesState.self, from: $0) } ?? LibrarySeriesState()
        hashes = defaults.dictionary(forKey: Key.hashes) as? [String: String] ?? [:]
        lastOpened = (defaults.data(forKey: Key.lastOpened)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        self.positions = readingPositions.all()
    }

    // MARK: 书籍

    /// 本机书籍加上本机还没有的云端书籍（同一本书本机已有时只显示本机那条）。
    func books(web: WebNovelDownloadStore, wenku: WenkuLocalLibraryStore, cloud: CloudBookStore) -> [LibraryBook] {
        let local = web.books.map { LibraryBook(origin: .webNovel($0), fileURL: web.fileURL(for: $0), coverURL: nil) }
            + wenku.books.map { LibraryBook(origin: .wenku($0), fileURL: wenku.fileURL(for: $0), coverURL: wenku.coverFileURL(for: $0)) }
        let localKeys = Set(local.map(\.key))
        // 云端书籍没有本机文件；占位路径不存在，不会被当作书籍文件读取。
        let placeholder = FileManager.default.temporaryDirectory.appendingPathComponent("novelia-cloud-book", isDirectory: true)
        let cloudWeb = cloud.webBooks.compactMap { book -> LibraryBook? in
            guard let hash = book.assets.first(where: { $0.filename == book.record.fileFilename })?.hash else { return nil }
            return LibraryBook(origin: .webNovel(book.record), fileURL: placeholder.appendingPathComponent(book.record.fileFilename),
                               coverURL: nil, cloudFileHash: hash, cloudDownloadSize: LibraryBook.totalSize(book.assets),
                               cloudFileMissing: cloud.missingFileKeys.contains(book.libraryKey))
        }
        let cloudWenku = cloud.wenkuBooks.compactMap { book -> LibraryBook? in
            guard let hash = book.assets.first(where: { $0.filename == book.record.filename })?.hash else { return nil }
            return LibraryBook(origin: .wenku(book.record), fileURL: placeholder.appendingPathComponent(book.record.filename),
                               coverURL: cloud.coverURL(for: book), cloudFileHash: hash,
                               cloudDownloadSize: LibraryBook.totalSize(book.assets),
                               cloudFileMissing: cloud.missingFileKeys.contains(book.libraryKey))
        }
        return local + (cloudWeb + cloudWenku).filter { !localKeys.contains($0.key) }
    }

    /// 相同来源、系列和文件内容只显示一条；保留所有文件和原始记录。
    /// 哈希未就绪时仍按持久标识显示，避免把同名但内容不同的书合并。
    func displayBooks(from books: [LibraryBook]) -> [LibraryBook] {
        LibraryOrganizer.uniqueRecords(books, id: { book in
            guard let hash = hashByBook[book.key] ?? book.cloudFileHash else { return book.key }
            return "\(book.categoryTitle)|\(series.seriesID(forBook: book.key) ?? "")|\(book.positionPrefix)\(hash)"
        }, date: { $0.importedAt })
    }

    func status(for book: LibraryBook) -> LibraryReadingStatus {
        let status = readingStatus(for: book)
        guard book.isCloudOnly else { return status }
        let label = book.cloudFileMissing ? "云端文件缺失" : "未下载"
        return LibraryReadingStatus(lastReadAt: status.lastReadAt, detail: "\(label) · \(status.detail)", fraction: status.fraction)
    }

    private func readingStatus(for book: LibraryBook) -> LibraryReadingStatus {
        let position = hash(for: book).flatMap { positions[book.positionPrefix + $0] }
        let opened = lastOpened[book.key]
        let lastReadAt = [position?.updatedAt, opened].compactMap { $0 }.filter { $0 > .distantPast }.max()
        if let position {
            if book.format == .epub, let fraction = position.fraction {
                return LibraryReadingStatus(lastReadAt: lastReadAt, detail: "读到 \(Int((fraction * 100).rounded()))%", fraction: fraction)
            }
            if let chapter = position.chapterIndex {
                return LibraryReadingStatus(lastReadAt: lastReadAt, detail: "第 \(chapter + 1) 章", fraction: nil)
            }
        }
        return LibraryReadingStatus(lastReadAt: lastReadAt, detail: lastReadAt == nil ? "未读" : "已打开", fraction: nil)
    }

    func sortItem(for book: LibraryBook) -> LibrarySortItem {
        LibrarySortItem(key: book.key, title: book.title, author: book.author,
                        importedAt: book.importedAt, lastReadAt: status(for: book).lastReadAt)
    }

    func markOpened(_ book: LibraryBook) {
        lastOpened[book.key] = Date()
        persistLastOpened()
    }

    /// 阅读器关闭或同步之后重新读取阅读位置。
    func reloadPositions() {
        let latest = readingPositions.all()
        if latest != positions { positions = latest }
    }

    // MARK: 文件哈希

    /// 文件身份：标识、文件名、大小与修改时间；任一变化即重新计算哈希。
    nonisolated private static func identity(key: String, url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(key)|\(url.lastPathComponent)|\(size)|\(Int(modified))"
    }

    private func hash(for book: LibraryBook) -> String? {
        hashByBook[book.key] ?? book.cloudFileHash
    }

    /// 文件身份、哈希及缓存清理都在后台完成；只在批次结束时发布一次。
    /// 取消旧批次时不提交部分结果，避免新增/删除书籍后旧任务覆盖新书库。
    func refreshHashes(for books: [LibraryBook], librariesReady: Bool = true) async {
        hashRefreshGeneration += 1
        guard librariesReady else { return }
        let generation = hashRefreshGeneration
        let targets = books.filter { !$0.isCloudOnly }.map { (key: $0.key, url: $0.fileURL) }
        let cached = hashes
        let worker = Task.detached(priority: .utility) { () -> (cache: [String: String], byBook: [String: String])? in
            var cache: [String: String] = [:]
            var byBook: [String: String] = [:]
            for target in targets {
                guard !Task.isCancelled else { return nil }
                guard let identity = Self.identity(key: target.key, url: target.url),
                      let hash = cached[identity] ?? (try? FileContentHash.sha256(target.url)) else { continue }
                cache[identity] = hash
                byBook[target.key] = hash
            }
            return (cache, byBook)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, generation == hashRefreshGeneration, let result else { return }
        if result.byBook != hashByBook { hashByBook = result.byBook }
        if result.cache != hashes {
            hashes = result.cache
            defaults.set(hashes, forKey: Key.hashes)
        }
        // 只有每本本机书都算出哈希时才清理，避免把暂时读不到的书当作已删除。
        if result.byBook.count == targets.count {
            pruneOrphanedState(books: books, keepingHashes: Set(result.byBook.values).union(books.compactMap(\.cloudFileHash)))
        }
    }

    // MARK: 排序设置（仅保存在本机）

    /// `scope` 为 `nil` 表示全部书籍，否则为系列 ID。
    func sortOptions(scope: String?) -> LibrarySortOptions {
        allSortOptions()[scope ?? "all"] ?? LibrarySortOptions()
    }

    func setSortOptions(_ options: LibrarySortOptions, scope: String?) {
        var all = allSortOptions()
        all[scope ?? "all"] = options
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Key.sort) }
        sortOptionsCache = all
        objectWillChange.send()
    }

    /// 排序在列表重算时频繁读取；只从偏好解码一次，之后由 `setSortOptions` 维护。
    private var sortOptionsCache: [String: LibrarySortOptions]?

    private func allSortOptions() -> [String: LibrarySortOptions] {
        if let sortOptionsCache { return sortOptionsCache }
        let loaded = defaults.data(forKey: Key.sort)
            .flatMap { try? JSONDecoder().decode([String: LibrarySortOptions].self, from: $0) } ?? [:]
        sortOptionsCache = loaded
        return loaded
    }

    // MARK: 系列

    func seriesName(for book: LibraryBook) -> String? {
        series.seriesID(forBook: book.key).flatMap { series.series[$0]?.name }
    }

    @discardableResult
    func createSeries(named name: String) -> String {
        var state = series
        let id = state.createSeries(named: name).id
        save(state)
        return id
    }

    func renameSeries(_ id: String, to name: String) {
        var state = series
        state.renameSeries(id, to: name)
        save(state)
    }

    func deleteSeries(_ id: String) {
        var state = series
        state.deleteSeries(id)
        save(state)
    }

    func assign(_ book: LibraryBook, to seriesID: String?) {
        var state = series
        state.assign(book: book.key, to: seriesID)
        save(state)
    }

    /// 书籍在“网络小说/文库”之间移动后，系列归属与最近打开时间随新标识转移。
    func transfer(from oldKey: String, to newKey: String) {
        var state = series
        state.transfer(from: oldKey, to: newKey)
        save(state)
        if let opened = lastOpened.removeValue(forKey: oldKey) {
            lastOpened[newKey] = opened
            persistLastOpened()
        }
    }

    /// 书籍已从本机和云端一并删除：移出系列（移出记录带时间，随同步传播）并清除最近打开时间。
    /// 只删除本机文件时不调用：同一本书之后可能作为云端书籍显示或被重新下载，应保留原归属。
    func forget(keys: Set<String>) {
        var state = series
        for key in keys { state.assign(book: key, to: nil) }
        save(state)
        let opened = lastOpened.filter { !keys.contains($0.key) }
        if opened.count != lastOpened.count {
            lastOpened = opened
            persistLastOpened()
        }
    }

    /// WebDAV 合并后的系列状态。
    func applySynced(_ state: LibrarySeriesState) {
        save(LibrarySeriesState.merged(series, state))
    }

    // MARK: 已删除书籍的残留

    /// 共享阅读位置保留期：书删除后重新导入同一本仍可续读，超过此时间未更新才清理。
    static let orphanedPositionAge: TimeInterval = 180 * 24 * 60 * 60
    private var lastPrunedHashes: Set<String>?

    /// 书已不在书库（本机与云端）时清理：最近打开时间立即清理；Readium 精确位置立即清理
    /// （共享位置仍可近似恢复）；共享阅读位置超过保留期未更新才清理。书库为空时不清理。
    private func pruneOrphanedState(books: [LibraryBook], keepingHashes: Set<String>) {
        guard !books.isEmpty, keepingHashes != lastPrunedHashes else { return }
        lastPrunedHashes = keepingHashes
        let keys = Set(books.map(\.key))
        let opened = lastOpened.filter { keys.contains($0.key) }
        if opened.count != lastOpened.count {
            lastOpened = opened
            persistLastOpened()
        }
        for key in ReadiumLocatorKeys.orphanedKeys(defaults.dictionaryRepresentation().keys, keepingHashes: keepingHashes) {
            defaults.removeObject(forKey: key)
        }
        if readingPositions.pruneFilePositions(keepingHashes: keepingHashes,
                                               olderThan: Date().addingTimeInterval(-Self.orphanedPositionAge)) > 0 {
            reloadPositions()
        }
    }

    private func save(_ state: LibrarySeriesState) {
        guard state != series else { return }
        series = state
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: seriesURL, options: .atomic)
        }
    }

    private func persistLastOpened() {
        if let data = try? JSONEncoder().encode(lastOpened) { defaults.set(data, forKey: Key.lastOpened) }
    }
}
