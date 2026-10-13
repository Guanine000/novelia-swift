import Combine
import Foundation

// 手动 WebDAV 同步共享的记录，以及合并本地和远端副本的规则。

struct SyncedReadingPosition: Codable, Equatable {
    /// 网络小说：章节序号。EPUB：spine 序号（保存偏移量之前的版本没有该字段）。
    /// TXT（`txt:<hash>`）：按阅读器章节规则得到的章节序号。
    var chapterIndex: Int?
    /// EPUB：全书进度，为旧版应用保留。
    var fraction: Double?
    var updatedAt: Date
    /// EPUB：页面首段文字在章节源文本中的 UTF-16 偏移量，
    /// 字体或布局变化后重新分页时仍可用于恢复位置。
    var chapterOffset: Int? = nil
    /// 仅 TXT：分页单元及单元总数；此时 `chapterOffset` 表示该单元内的偏移量。
    /// 旧版应用解码时忽略这两个字段。
    var unit: Int? = nil
    var unitCount: Int? = nil
    /// EPUB：当前位置之前的章节文本比例（0...1）。两个 EPUB 引擎都会写入，
    /// 以便互相恢复章内位置；旧版应用忽略此字段，
    /// 回退到 `fraction`。
    var chapterProgression: Double? = nil

    /// 远端位置的时间不早于本地位置时，替换本地位置。
    static func merged(_ local: [String: Self], _ remote: [String: Self]) -> [String: Self] {
        var result = local
        for (key, value) in remote where value.updatedAt >= (result[key]?.updatedAt ?? .distantPast) {
            result[key] = value
        }
        return result
    }
}

/// 在 YueduCoreText 阅读器（章节文本的 UTF-16 偏移量）与 Readium
/// （章内进度比例）之间转换 EPUB 章内位置。
enum EPUBChapterProgress {
    static func progression(offset: Int, length: Int) -> Double {
        guard length > 0 else { return 0 }
        return min(1, max(0, Double(offset) / Double(length)))
    }

    static func offset(progression: Double, length: Int) -> Int {
        guard length > 0, progression.isFinite else { return 0 }
        return min(length, max(0, Int((Double(length) * progression).rounded(.down))))
    }

    /// YueduCoreText 对章节 XHTML 排版时使用的文本 UTF-16 长度近似值：
    /// 去除标签间空白、head/script/style 内容及所有标签，每个字符实体计数一次。
    /// 仅用于转换引入 `chapterProgression` 之前保存的偏移量。
    static func textLength(html: String) -> Int {
        var text = html
        // 标签间空白仅服务于布局；文本内部的空白保留。
        for pattern in [#">\s+<"#] {
            text = text.replacingOccurrences(of: pattern, with: "><", options: .regularExpression)
        }
        for pattern in [#"(?is)<head\b.*?</head\s*>"#, #"(?is)<(script|style)\b.*?</\1\s*>"#, #"(?s)<!--.*?-->"#, #"<[^>]*>"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);"#, with: "_", options: .regularExpression)
        return text.utf16.count
    }
}

struct SyncedBlockedTag: Codable, Equatable {
    var blocked: Bool
    var updatedAt: Date
}

@MainActor
final class BlockedTagsStore: ObservableObject {
    static let shared = BlockedTagsStore()
    @Published private(set) var tags: [String]
    @Published private(set) var wenkuTags: [String: [String]]
    private let defaults: UserDefaults
    private(set) var syncStates: [String: SyncedBlockedTag]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        syncStates = defaults.data(forKey: "blockedNovelTags.sync.v1")
            .flatMap { try? JSONDecoder().decode([String: SyncedBlockedTag].self, from: $0) } ?? [:]
        for tag in defaults.stringArray(forKey: "blockedNovelTags") ?? [] where syncStates[tag] == nil {
            syncStates[tag] = SyncedBlockedTag(blocked: true, updatedAt: .distantPast)
        }
        tags = syncStates.filter { $0.value.blocked }.map(\.key).sorted()
        wenkuTags = defaults.dictionary(forKey: "knownWenkuTags") as? [String: [String]] ?? [:]
    }
    func contains(_ tag: String) -> Bool { tags.contains(tag.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func add(_ tag: String) {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !tags.contains(value) else { return }
        syncStates[value] = SyncedBlockedTag(blocked: true, updatedAt: Date()); persist()
    }
    func remove(_ tag: String) {
        syncStates[tag] = SyncedBlockedTag(blocked: false, updatedAt: Date()); persist()
    }
    static func merged(_ local: [String: SyncedBlockedTag], _ remote: [String: SyncedBlockedTag]) -> [String: SyncedBlockedTag] {
        var result = local
        for (tag, value) in remote where !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existing = result[tag] {
                if value.updatedAt > existing.updatedAt || (value.updatedAt == existing.updatedAt && !value.blocked) {
                    result[tag] = value
                }
            } else { result[tag] = value }
        }
        return result
    }
    func applySynced(_ remote: [String: SyncedBlockedTag]) {
        syncStates = Self.merged(syncStates, remote); persist()
    }
    private func persist() {
        tags = syncStates.filter { $0.value.blocked }.map(\.key).sorted()
        defaults.set(tags, forKey: "blockedNovelTags")
        if let data = try? JSONEncoder().encode(syncStates) { defaults.set(data, forKey: "blockedNovelTags.sync.v1") }
    }
    func hides(_ genres: [String]) -> Bool { genres.contains(where: contains) }
    func rememberWenku(id: String, tags: [String]) {
        guard wenkuTags[id] != tags else { return }
        wenkuTags[id] = tags; defaults.set(wenkuTags, forKey: "knownWenkuTags")
    }
}

struct SyncedReaderBackground: Codable {
    var mode: String
    var color: String
    var portraitHash: String?
    var landscapeHash: String?
    var updatedAt: Date
}

struct SyncedImportedFont: Codable {
    var hash: String
    var format: String
    var deleted: Bool
    var updatedAt: Date
    static func merged(_ local: [String: Self], _ remote: [String: Self]) -> [String: Self] {
        var result = remote
        for (hash, value) in local {
            if let other = result[hash], other.updatedAt > value.updatedAt || (other.updatedAt == value.updatedAt && other.deleted) { continue }
            result[hash] = value
        }
        return result
    }
}
