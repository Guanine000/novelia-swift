import Foundation

/// 统一书库中的来源筛选，不改变书籍原有归属。
enum LibrarySourceFilter: String, CaseIterable, Identifiable {
    case all, wenku, webNovel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .wenku: "文库"
        case .webNovel: "网络小说"
        }
    }
    func includes(isWenku: Bool) -> Bool {
        switch self {
        case .all: true
        case .wenku: isWenku
        case .webNovel: !isWenku
        }
    }
}

/// 书库排序字段。
enum LibrarySortField: String, Codable, CaseIterable, Identifiable, Sendable {
    case importedAt
    case lastRead
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importedAt: "导入时间"
        case .lastRead: "最近阅读"
        case .title: "书名"
        }
    }
}

/// 书库排序方式；`ascending` 为 `false` 时倒序（最新、最近或 Z→A 在前）。
struct LibrarySortOptions: Codable, Equatable, Sendable {
    var field: LibrarySortField = .lastRead
    var ascending = false

    var summary: String {
        "\(field.title) · \(ascending ? "正序" : "倒序")"
    }
}

/// 参与搜索与排序的书籍信息。导入时间：导入的书为导入时间，下载的书为下载完成时间。
struct LibrarySortItem: Equatable, Sendable {
    var key: String
    var title: String
    var author: String
    var importedAt: Date
    /// 从未阅读时为 `nil`。
    var lastReadAt: Date?
}

enum LibraryOrganizer {
    /// 忽略大小写、全角/半角和变音符号，并去掉首尾空白。
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// 关键词出现在书名或作者中即匹配；空关键词匹配所有书。
    /// 也比较去掉空白后的文字，使“ze ta”（拼音输入法输入中的英文）能匹配“Zeta”。
    static func matches(title: String, author: String, query: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        let compactNeedle = needle.filter { !$0.isWhitespace }
        return [title, author].contains { field in
            let haystack = normalized(field)
            return haystack.contains(needle) || haystack.filter { !$0.isWhitespace }.contains(compactNeedle)
        }
    }

    /// 同一持久标识只能对应一条记录；保留最新记录，时间相同时保留索引中第一条。
    /// 按标识而非书名处理，避免合并同名的不同卷或不同来源书籍。
    static func uniqueRecords<Element, ID: Hashable>(_ records: [Element],
                                                    id: (Element) -> ID,
                                                    date: (Element) -> Date) -> [Element] {
        var indices: [ID: Int] = [:]
        var result: [Element] = []
        for record in records {
            let key = id(record)
            if let index = indices[key] {
                if date(record) > date(result[index]) { result[index] = record }
            } else {
                indices[key] = result.count
                result.append(record)
            }
        }
        return result
    }

    /// 排序规则：
    /// - 导入时间、书名按所选方向排序，相同值依次按导入时间（新在前）、书名、标识排序，结果稳定。
    /// - 最近阅读：已读的书按最后阅读时间、未读的书按导入时间参与排序，让新导入的书及时出现在前面。
    static func sorted<Element>(_ elements: [Element], options: LibrarySortOptions,
                                item: (Element) -> LibrarySortItem) -> [Element] {
        let pairs = elements.map { (element: $0, item: item($0)) }
        return pairs.sorted { lhs, rhs in
            precedes(lhs.item, rhs.item, options: options)
        }.map(\.element)
    }

    static func precedes(_ lhs: LibrarySortItem, _ rhs: LibrarySortItem, options: LibrarySortOptions) -> Bool {
        switch options.field {
        case .importedAt:
            if lhs.importedAt != rhs.importedAt {
                return options.ascending ? lhs.importedAt < rhs.importedAt : lhs.importedAt > rhs.importedAt
            }
        case .title:
            let order = compareTitles(lhs.title, rhs.title)
            if order != .orderedSame {
                return options.ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .lastRead:
            let left = lhs.lastReadAt ?? lhs.importedAt
            let right = rhs.lastReadAt ?? rhs.importedAt
            if left != right {
                return options.ascending ? left < right : left > right
            }
        }
        return tieBreak(lhs, rhs)
    }

    private static func tieBreak(_ lhs: LibrarySortItem, _ rhs: LibrarySortItem) -> Bool {
        if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
        let order = compareTitles(lhs.title, rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.key < rhs.key
    }

    /// 中文按拼音、数字按数值比较（“第2卷”在“第10卷”之前）。
    static func compareTitles(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .numeric, .widthInsensitive],
                    range: nil, locale: Locale(identifier: "zh_Hans"))
    }
}

// MARK: - 系列

/// 一个系列。删除时保留墓碑（`deleted`），以便 WebDAV 合并时传播删除。
struct LibrarySeries: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var deleted = false
}

/// 一本书所属的系列；`seriesID` 为 `nil` 表示已移出系列。
struct LibrarySeriesMembership: Codable, Equatable, Sendable {
    var seriesID: String?
    var updatedAt: Date
}

/// 系列与书籍归属。书籍以 `web:<作品 ID>` 或 `wenku:<UUID>` 标识，
/// 归属与书籍文件、阅读进度分开保存，移入移出不影响书籍本身。
struct LibrarySeriesState: Codable, Equatable, Sendable {
    var series: [String: LibrarySeries] = [:]
    var memberships: [String: LibrarySeriesMembership] = [:]

    /// 未删除的系列，按名称排序。
    var activeSeries: [LibrarySeries] {
        series.values.filter { !$0.deleted }.sorted {
            let order = LibraryOrganizer.compareTitles($0.name, $1.name)
            return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
        }
    }

    /// 书籍当前所属的有效系列；系列已删除时视为不在系列中。
    func seriesID(forBook key: String) -> String? {
        guard let id = memberships[key]?.seriesID, let item = series[id], !item.deleted else { return nil }
        return id
    }

    func bookKeys(inSeries id: String) -> Set<String> {
        guard let item = series[id], !item.deleted else { return [] }
        return Set(memberships.compactMap { $0.value.seriesID == id ? $0.key : nil })
    }

    @discardableResult
    mutating func createSeries(named name: String, now: Date = Date(), id: String = UUID().uuidString) -> LibrarySeries {
        let item = LibrarySeries(id: id, name: Self.cleanName(name), createdAt: now, updatedAt: now)
        series[id] = item
        return item
    }

    mutating func renameSeries(_ id: String, to name: String, now: Date = Date()) {
        guard var item = series[id], !item.deleted else { return }
        item.name = Self.cleanName(name)
        item.updatedAt = now
        series[id] = item
    }

    /// 解散系列：系列标记删除，其中的书全部移出；书籍与阅读进度不受影响。
    mutating func deleteSeries(_ id: String, now: Date = Date()) {
        guard var item = series[id], !item.deleted else { return }
        item.deleted = true
        item.updatedAt = now
        series[id] = item
        for (key, membership) in memberships where membership.seriesID == id {
            memberships[key] = LibrarySeriesMembership(seriesID: nil, updatedAt: now)
        }
    }

    /// 移入（`seriesID` 非空）或移出（`nil`）系列。
    mutating func assign(book key: String, to seriesID: String?, now: Date = Date()) {
        if let seriesID, series[seriesID]?.deleted != false { return }
        guard self.seriesID(forBook: key) != seriesID else { return }
        memberships[key] = LibrarySeriesMembership(seriesID: seriesID, updatedAt: now)
    }

    /// 书籍在“网络小说/文库”之间移动后标识改变，归属随之转移。
    mutating func transfer(from oldKey: String, to newKey: String, now: Date = Date()) {
        guard oldKey != newKey, let id = seriesID(forBook: oldKey) else { return }
        memberships[oldKey] = LibrarySeriesMembership(seriesID: nil, updatedAt: now)
        memberships[newKey] = LibrarySeriesMembership(seriesID: id, updatedAt: now)
    }

    /// 系列与归属各自按键比较更新时间，较新的一方胜出；时间相同时保留本地。
    static func merged(_ local: Self, _ remote: Self) -> Self {
        var result = local
        for (id, item) in remote.series where item.updatedAt > (result.series[id]?.updatedAt ?? .distantPast) {
            result.series[id] = item
        }
        for (key, item) in remote.memberships where item.updatedAt > (result.memberships[key]?.updatedAt ?? .distantPast) {
            result.memberships[key] = item
        }
        return result
    }

    private static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名系列" : String(trimmed.prefix(60))
    }
}

// MARK: - Bangumi 风格阅读状态分类

/// 单书在书库封面框内的缩放方式；默认裁切填满以保持网格整齐，方图或画集可按书切为完整显示。
enum LibraryBookCoverFitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill
    case fit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "裁切填满（默认）"
        case .fit: "完整显示"
        }
    }
}

/// 书库书籍的阅读状态分类；未显式设置或新导入的书默认归入「在读」。
enum LibraryBookStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case reading
    case wantToRead
    case completed
    case onHold
    case dropped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reading: "在读"
        case .wantToRead: "想读"
        case .completed: "读过"
        case .onHold: "搁置"
        case .dropped: "抛弃"
        }
    }

    var systemImage: String {
        switch self {
        case .reading: "book"
        case .wantToRead: "bookmark"
        case .completed: "checkmark.circle"
        case .onHold: "pause.circle"
        case .dropped: "xmark.circle"
        }
    }
}

/// 书库顶部的阅读状态筛选，包含「全部」与五种具体状态。
enum LibraryBookStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case reading
    case wantToRead
    case completed
    case onHold
    case dropped

    var id: String { rawValue }

    var title: String {
        status?.title ?? "全部"
    }

    var status: LibraryBookStatus? {
        switch self {
        case .all: nil
        case .reading: .reading
        case .wantToRead: .wantToRead
        case .completed: .completed
        case .onHold: .onHold
        case .dropped: .dropped
        }
    }

    func includes(_ value: LibraryBookStatus) -> Bool {
        guard let status else { return true }
        return status == value
    }
}

/// 单本书的阅读状态记录；带更新时间以便 WebDAV 多设备按较新时间合并。
struct LibraryBookStatusEntry: Codable, Equatable, Sendable {
    var status: LibraryBookStatus
    var updatedAt: Date
}

/// 书库书籍阅读状态表，按键（`web:<作品 ID>` 或 `wenku:<UUID>`）保存；未记录的书默认视为「在读」。
struct LibraryBookStatusState: Codable, Equatable, Sendable {
    var statuses: [String: LibraryBookStatusEntry] = [:]

    func status(forBook key: String) -> LibraryBookStatus {
        statuses[key]?.status ?? .reading
    }

    /// 设置书籍阅读状态；即使切回默认的「在读」也写入时间戳，确保多设备同步时能覆盖远端旧状态。
    mutating func setStatus(_ status: LibraryBookStatus, forBook key: String, now: Date = Date()) {
        if let existing = statuses[key], existing.status == status { return }
        statuses[key] = LibraryBookStatusEntry(status: status, updatedAt: now)
    }

    /// 书籍在“网络小说/文库”之间移动后标识改变，阅读状态随之转移。
    mutating func transfer(from oldKey: String, to newKey: String, now: Date = Date()) {
        guard oldKey != newKey, let entry = statuses.removeValue(forKey: oldKey) else { return }
        statuses[newKey] = LibraryBookStatusEntry(status: entry.status, updatedAt: max(entry.updatedAt, now))
    }

    /// 书籍已从本机和云端一并删除时清理本地状态记录。
    mutating func remove(keys: Set<String>) {
        for key in keys { statuses.removeValue(forKey: key) }
    }

    /// 按键比较更新时间，较新的一方胜出；时间相同时保留本地。
    static func merged(_ local: Self, _ remote: Self) -> Self {
        var result = local
        for (key, item) in remote.statuses where item.updatedAt > (result.statuses[key]?.updatedAt ?? .distantPast) {
            result.statuses[key] = item
        }
        return result
    }
}

/// 书库阅读状态自动识别配置（仅存本机，不改变 WebDAV 同步格式）。
struct LibraryAutoStatusConfig: Equatable, Sendable {
    var enabled: Bool = false
    /// EPUB 读到此比例及以上自动视为「读过」，避开书末版权页/后记导致卡在 98%–99% 的情况。
    var completionThreshold: Double = 0.98
    /// 在读书籍连续未阅读达到该天数时自动转为「搁置」；0 表示关闭自动搁置。
    var onHoldDays: Int = 30
}

/// 书库阅读状态的纯逻辑自动识别与流转规则；
/// 复用现有 `LibraryBookStatusState`，手动设为「抛弃」的书永不自动覆盖。
enum LibraryBookStatusAutoClassifier {
    struct BookProgressSnapshot: Equatable, Sendable {
        let key: String
        let fraction: Double?
        let hasProgress: Bool
        let isAtLastChapter: Bool
        let lastReadAt: Date?
    }

    static func isCompleted(fraction: Double?, isAtLastChapter: Bool, threshold: Double = 0.98) -> Bool {
        if let fraction, fraction >= threshold { return true }
        return isAtLastChapter
    }

    /// 打开书籍阅读时的状态流转：未设置、想读或搁置转为在读；读过与抛弃保持不变。
    static func transitionOnOpen(current: LibraryBookStatus?) -> LibraryBookStatus? {
        switch current {
        case nil, .wantToRead, .onHold: .reading
        case .reading, .completed, .dropped: nil
        }
    }

    /// 书籍进度实际推进时的状态流转：抛弃永不覆盖；达到完成阈值转为读过；有进度且为想读/搁置转为在读。
    static func transitionOnProgress(
        current: LibraryBookStatus?,
        isCompleted: Bool,
        hasProgress: Bool
    ) -> LibraryBookStatus? {
        if current == .dropped { return nil }
        if isCompleted { return current == .completed ? nil : .completed }
        if hasProgress {
            switch current {
            case nil, .wantToRead, .onHold: return .reading
            case .reading, .completed, .dropped: return nil
            }
        }
        return nil
    }

    /// 新导入/下载且尚未记录状态的未读书籍，自动归入「想读」。
    static func transitionOnNewBook(
        current: LibraryBookStatus?,
        hasProgress: Bool,
        lastReadAt: Date?
    ) -> LibraryBookStatus? {
        guard current == nil, !hasProgress, lastReadAt == nil else { return nil }
        return .wantToRead
    }

    /// 在读书籍久未阅读时自动转为「搁置」；以最近阅读时间与最近状态修改时间的较晚者为准，
    /// 避免用户刚手动改回「在读」又立即被改回「搁置」。
    static func autoOnHoldTransition(
        entry: LibraryBookStatusEntry?,
        lastReadAt: Date?,
        now: Date,
        onHoldDays: Int
    ) -> LibraryBookStatus? {
        guard onHoldDays > 0, let lastReadAt else { return nil }
        let effective = entry?.status ?? .reading
        guard effective == .reading else { return nil }
        let lastActive = max(lastReadAt, entry?.updatedAt ?? .distantPast)
        guard now.timeIntervalSince(lastActive) >= TimeInterval(onHoldDays) * 86_400 else { return nil }
        return .onHold
    }

    /// 存量书籍按当前阅读进度一键整理：计算所有需要变更的 `(bookKey -> targetStatus)`。
    /// 手动标为「抛弃」的书保持不变。
    static func batchReorganizeChanges(
        snapshots: [BookProgressSnapshot],
        existing: LibraryBookStatusState,
        now: Date,
        config: LibraryAutoStatusConfig
    ) -> [String: LibraryBookStatus] {
        var changes: [String: LibraryBookStatus] = [:]
        for snapshot in snapshots {
            let existingEntry = existing.statuses[snapshot.key]
            if existingEntry?.status == .dropped { continue }
            let target: LibraryBookStatus
            if isCompleted(fraction: snapshot.fraction, isAtLastChapter: snapshot.isAtLastChapter,
                           threshold: config.completionThreshold) {
                target = .completed
            } else if !snapshot.hasProgress, snapshot.lastReadAt == nil {
                target = .wantToRead
            } else if config.onHoldDays > 0,
                      let lastReadAt = snapshot.lastReadAt,
                      now.timeIntervalSince(lastReadAt) >= TimeInterval(config.onHoldDays) * 86_400 {
                target = .onHold
            } else {
                target = .reading
            }
            if existing.status(forBook: snapshot.key) != target {
                changes[snapshot.key] = target
            }
        }
        return changes
    }
}

// MARK: - 书架更新检查聚合模型

/// 单本网络小说检查更新的命中结果。
struct ShelfUpdateBookResult: Identifiable, Equatable, Sendable {
    let bookID: String
    let title: String
    let newChapterCount: Int
    let latestChapterTitle: String?
    var id: String { bookID }
}

/// 单本网络小说检查更新失败记录。
struct ShelfUpdateFailure: Identifiable, Equatable, Sendable {
    let bookID: String
    let title: String
    let message: String
    var id: String { bookID }
}

/// 书架批量检查更新的聚合状态（总本数、已完成数、更新列表、失败列表与最近检查时间）。
struct ShelfUpdateSummary: Equatable, Sendable {
    var totalCount: Int = 0
    var completedCount: Int = 0
    var updatedBooks: [ShelfUpdateBookResult] = []
    var failedBooks: [ShelfUpdateFailure] = []
    var checkedAt: Date? = nil

    var hasResults: Bool { totalCount > 0 || checkedAt != nil }

    /// 比较本地已下载网络小说与远端目录；仅当远端章节比本地多出新章节 ID 或总章数增加时视为有更新。
    static func diff(local: DownloadedWebNovel, remote: Novel) -> ShelfUpdateBookResult? {
        guard let provider = local.novel.providerId, let novelID = local.novel.novelId,
              remote.providerId == provider, remote.novelId == novelID else { return nil }
        let localIDs = Set(local.novel.chapters.map(\.id))
        let newChapters = remote.chapters.filter { !localIDs.contains($0.id) }
        let count = max(newChapters.count, remote.chapters.count - local.novel.chapters.count)
        guard count > 0 else { return nil }
        let latestTitle = newChapters.last?.title ?? remote.chapters.last?.title
        return ShelfUpdateBookResult(
            bookID: local.id,
            title: local.novel.title,
            newChapterCount: count,
            latestChapterTitle: latestTitle
        )
    }
}

// MARK: - 跨书库全局搜索（摘录、笔记与书签）

/// 在本地书库的全部摘录、笔记与书签中按关键词检索，按最近更新时间倒序返回。
enum LibraryGlobalSearch {
    struct AnnotationHit: Identifiable, Equatable, Sendable {
        let id: UUID
        let bookKey: String
        let bookTitle: String
        let chapterIndex: Int
        let quote: String
        let note: String
        let color: ReaderAnnotation.Color
        let updatedAt: Date
    }

    struct BookmarkHit: Identifiable, Equatable, Sendable {
        let id: UUID
        let bookKey: String
        let bookTitle: String
        let chapterIndex: Int
        let chapterTitle: String?
        let snippet: String
        let updatedAt: Date
    }

    static func searchAnnotations(
        query: String,
        annotations: [ReaderAnnotation],
        bookTitlesByKey: [String: String],
        limit: Int = 50
    ) -> [AnnotationHit] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return annotations
            .compactMap { item -> AnnotationHit? in
                guard !item.isDeleted, let title = bookTitlesByKey[item.bookKey] else { return nil }
                let matchesQuote = item.quote.localizedCaseInsensitiveContains(keyword)
                let matchesNote = !item.note.isEmpty && item.note.localizedCaseInsensitiveContains(keyword)
                guard matchesQuote || matchesNote else { return nil }
                return AnnotationHit(
                    id: item.id,
                    bookKey: item.bookKey,
                    bookTitle: title,
                    chapterIndex: item.chapterIndex,
                    quote: item.quote,
                    note: item.note,
                    color: item.color,
                    updatedAt: item.updatedAt
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    static func searchBookmarks(
        query: String,
        bookmarks: [ReaderBookmark],
        bookTitlesByKey: [String: String],
        limit: Int = 50
    ) -> [BookmarkHit] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return bookmarks
            .compactMap { item -> BookmarkHit? in
                guard !item.isDeleted, let title = bookTitlesByKey[item.bookKey] else { return nil }
                let matchesSnippet = item.snippet.localizedCaseInsensitiveContains(keyword)
                let matchesChapter = item.chapterTitle?.localizedCaseInsensitiveContains(keyword) == true
                guard matchesSnippet || matchesChapter else { return nil }
                return BookmarkHit(
                    id: item.id,
                    bookKey: item.bookKey,
                    bookTitle: title,
                    chapterIndex: item.chapterIndex,
                    chapterTitle: item.chapterTitle,
                    snippet: item.snippet,
                    updatedAt: item.updatedAt
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - 系列上一卷定位

/// 解析系列卷序与上一卷：优先使用用户已确认的系列卷序，未确认时按自然数字书名升序推断。
enum LibrarySeriesVolumeResolver {
    struct Member: Equatable, Sendable {
        let key: String
        let title: String
    }

    static func orderedKeys(confirmedOrder: [String], members: [Member]) -> [String] {
        let memberMap = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0) })
        var ordered: [String] = []
        var seen = Set<String>()
        for key in confirmedOrder where memberMap[key] != nil && seen.insert(key).inserted {
            ordered.append(key)
        }
        let remaining = members
            .filter { !seen.contains($0.key) }
            .sorted { lhs, rhs in
                let cmp = lhs.title.localizedStandardCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.key < rhs.key
            }
        ordered.append(contentsOf: remaining.map(\.key))
        return ordered
    }

    static func previousBookKey(for bookKey: String, confirmedOrder: [String], members: [Member]) -> String? {
        let keys = orderedKeys(confirmedOrder: confirmedOrder, members: members)
        guard let index = keys.firstIndex(of: bookKey), index > 0 else { return nil }
        return keys[index - 1]
    }
}
