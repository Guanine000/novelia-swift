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
