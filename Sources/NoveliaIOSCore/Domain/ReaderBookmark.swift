import Foundation

/// 阅读器书签。`bookKey` 与阅读位置身份一致：网络小说 `webepub:<小说身份>`，文库 `epub:<文件哈希>`、`txt:<文件哈希>`，
/// 同一本书在不同设备、不同文件名下仍对应同一组书签。位置用章节（EPUB spine 项／TXT 分页单元）
/// 与章内比例表示，两种阅读引擎都能近似跳回。删除保留为墓碑（`deleted`），WebDAV 合并时传播删除。
struct ReaderBookmark: Codable, Equatable, Identifiable, Sendable {
    static let maxSnippetLength = 120

    let id: UUID
    let bookKey: String
    var chapterIndex: Int
    /// 章内比例 0–1。
    var chapterProgression: Double
    var chapterTitle: String?
    /// 书签所在页开头的一段正文，用于列表显示。
    var snippet: String
    let createdAt: Date
    var updatedAt: Date
    /// 可选字段：为 true 时为删除墓碑。
    var deleted: Bool?

    var chapterID: String? = nil

    var isDeleted: Bool { deleted == true }

    /// 来自远端的记录先校验，防止异常数据导致越界跳转或超长文本。
    var isValid: Bool {
        (bookKey.hasPrefix("epub:") || bookKey.hasPrefix("txt:") || (bookKey.hasPrefix("webepub:") && chapterID?.isEmpty == false)) && bookKey.count <= 200 && (chapterID?.count ?? 0) <= 1000
            && chapterIndex >= 0 && chapterProgression.isFinite && (0...1).contains(chapterProgression)
            && snippet.count <= Self.maxSnippetLength * 2 && (chapterTitle?.count ?? 0) <= 200
            && createdAt.timeIntervalSince1970.isFinite && updatedAt.timeIntervalSince1970.isFinite
    }

    /// 按书签 ID 合并，较新的 `updatedAt` 胜出（含删除墓碑）；时间相同时保留本机。远端无效记录忽略。
    static func merged(_ local: [String: ReaderBookmark], _ remote: [String: ReaderBookmark]) -> [String: ReaderBookmark] {
        var result = local
        for (key, item) in remote where key == item.id.uuidString && item.isValid {
            if item.updatedAt > (result[key]?.updatedAt ?? .distantPast) { result[key] = item }
        }
        return result
    }
}
