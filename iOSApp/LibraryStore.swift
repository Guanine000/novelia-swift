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

    init(origin: Origin, fileURL: URL, coverURL: URL?) {
        self.origin = origin
        self.fileURL = fileURL
        self.coverURL = coverURL
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
@MainActor
final class LibraryStateStore: ObservableObject {
    static let shared = LibraryStateStore()

    @Published private(set) var series: LibrarySeriesState
    @Published private(set) var positions: [String: SyncedReadingPosition] = [:]
    @Published private(set) var lastOpened: [String: Date]
    /// 书籍标识 → 文件内容哈希，由 `refreshHashes` 更新。
    @Published private(set) var hashByBook: [String: String] = [:]
    /// 文件身份（标识、文件名、大小、修改时间）→ 哈希的持久缓存。
    private var hashes: [String: String]

    private let defaults: UserDefaults
    private let seriesURL: URL
    private var isRefreshingHashes = false

    private enum Key {
        static let hashes = "library.fileHashes.v1"
        static let lastOpened = "library.lastOpened.v1"
        static let sort = "library.sort.v1"
    }

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("Library", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        seriesURL = directory.appendingPathComponent("series.json")
        series = (try? Data(contentsOf: seriesURL)).flatMap { try? JSONDecoder().decode(LibrarySeriesState.self, from: $0) } ?? LibrarySeriesState()
        hashes = defaults.dictionary(forKey: Key.hashes) as? [String: String] ?? [:]
        lastOpened = (defaults.data(forKey: Key.lastOpened)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        positions = ReadingPositionSync.all()
    }

    // MARK: 书籍

    func books(web: WebNovelDownloadStore, wenku: WenkuLocalLibraryStore) -> [LibraryBook] {
        web.books.map { LibraryBook(origin: .webNovel($0), fileURL: web.fileURL(for: $0), coverURL: nil) }
            + wenku.books.map { LibraryBook(origin: .wenku($0), fileURL: wenku.fileURL(for: $0), coverURL: wenku.coverFileURL(for: $0)) }
    }

    func status(for book: LibraryBook) -> LibraryReadingStatus {
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
        let latest = ReadingPositionSync.all()
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
        hashByBook[book.key]
    }

    /// 在后台计算缺少的文件哈希（只计算一次并缓存），用于对应阅读进度。
    /// 首次打开大量书籍时，界面每秒最多刷新一次，避免每算完一本就重排整个书库导致滚动卡顿。
    func refreshHashes(for books: [LibraryBook]) async {
        guard !isRefreshingHashes else { return }
        isRefreshingHashes = true
        defer { isRefreshingHashes = false }
        let targets = books.map { (key: $0.key, url: $0.fileURL) }
        let identities = await Task.detached(priority: .utility) {
            targets.map { Self.identity(key: $0.key, url: $0.url) }
        }.value
        var valid = Set<String>()
        var changed = false
        var byBook: [String: String] = [:]
        var lastPublish = ContinuousClock.now
        for (target, identity) in zip(targets, identities) {
            guard let identity else { continue }
            valid.insert(identity)
            if let hash = hashes[identity] {
                byBook[target.key] = hash
                continue
            }
            let url = target.url
            guard let hash = try? await Task.detached(priority: .utility, operation: { try WebDAVFileHash.sha256(url) }).value else { continue }
            hashes[identity] = hash
            byBook[target.key] = hash
            changed = true
            if ContinuousClock.now - lastPublish > .seconds(1) {
                hashByBook.merge(byBook) { $1 }
                lastPublish = .now
            }
        }
        if byBook != hashByBook { hashByBook = byBook }
        let stale = hashes.keys.filter { !valid.contains($0) }
        if !stale.isEmpty {
            stale.forEach { hashes[$0] = nil }
            changed = true
        }
        if changed { defaults.set(hashes, forKey: Key.hashes) }
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
        objectWillChange.send()
    }

    private func allSortOptions() -> [String: LibrarySortOptions] {
        defaults.data(forKey: Key.sort).flatMap { try? JSONDecoder().decode([String: LibrarySortOptions].self, from: $0) } ?? [:]
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

    /// WebDAV 合并后的系列状态。
    func applySynced(_ state: LibrarySeriesState) {
        save(LibrarySeriesState.merged(series, state))
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
