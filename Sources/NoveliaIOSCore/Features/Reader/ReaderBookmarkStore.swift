import Combine
import Foundation

/// LocalAppServices 持有、经 `ReaderSettings.bookmarks` 交给各阅读器的书签存储；同步通过 App 适配访问同一实例。
/// 保存在 Application Support/Bookmarks/bookmarks.json，键为书签 ID。书签很少变化，修改时直接原子写入。
/// `directory` 为 nil 时只在内存中保存（测试与未注入的组装使用）。
@MainActor
final class ReaderBookmarkStore: ObservableObject {
    @Published private(set) var records: [String: ReaderBookmark] = [:]
    private let fileURL: URL?

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bookmarks", isDirectory: true)
    }

    init(directory: URL? = nil) {
        fileURL = directory?.appendingPathComponent("bookmarks.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: ReaderBookmark].self, from: data) {
            records = saved.filter { $0.key == $0.value.id.uuidString && $0.value.isValid }
        }
    }

    /// 一本书未删除的书签，按章节与章内位置排序。
    func bookmarks(for bookKey: String) -> [ReaderBookmark] {
        records.values.filter { $0.bookKey == bookKey && !$0.isDeleted }.sorted {
            ($0.chapterIndex, $0.chapterProgression, $0.createdAt) < ($1.chapterIndex, $1.chapterProgression, $1.createdAt)
        }
    }

    /// 当前页范围内（同一章，章内比例在 `range` 中）的书签。
    func bookmarks(for bookKey: String, chapter: Int, in range: Range<Double>) -> [ReaderBookmark] {
        bookmarks(for: bookKey).filter {
            $0.chapterIndex == chapter && (range.contains($0.chapterProgression) || $0.chapterProgression == range.lowerBound)
        }
    }

    @discardableResult
    func add(bookKey: String, chapterIndex: Int, progression: Double, chapterTitle: String?, snippet: String,
             now: Date = Date()) -> ReaderBookmark {
        let cleaned = snippet.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = ReaderBookmark(
            id: UUID(), bookKey: bookKey, chapterIndex: max(0, chapterIndex),
            chapterProgression: progression.isFinite ? min(1, max(0, progression)) : 0,
            chapterTitle: chapterTitle.map { String($0.prefix(200)) },
            snippet: String(cleaned.prefix(ReaderBookmark.maxSnippetLength)), createdAt: now, updatedAt: now)
        var next = records
        next[bookmark.id.uuidString] = bookmark
        save(next)
        return bookmark
    }

    /// 删除保留为墓碑，使其他设备同步后也删除。
    func remove(_ id: UUID, now: Date = Date()) {
        guard var bookmark = records[id.uuidString], !bookmark.isDeleted else { return }
        bookmark.deleted = true
        bookmark.updatedAt = now
        var next = records
        next[id.uuidString] = bookmark
        save(next)
    }

    /// WebDAV 合并后的书签。
    func applySynced(_ remote: [String: ReaderBookmark]) {
        save(ReaderBookmark.merged(records, remote))
    }

    private func save(_ next: [String: ReaderBookmark]) {
        guard next != records else { return }
        records = next
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(next) { try? data.write(to: fileURL, options: .atomic) }
    }
}
