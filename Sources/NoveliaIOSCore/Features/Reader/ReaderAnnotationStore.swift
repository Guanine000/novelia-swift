// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// 阅读器标注（摘录/高亮与笔记）。由 ReaderSettings 持有并注入各引擎与标注列表；
/// 同步通过 App 适配读取同一实例。保存在 Application Support/Annotations/annotations.json。
/// `directory` 为 nil 时只在内存中保存（测试与未注入的组装使用）。
@MainActor
final class ReaderAnnotationStore: ObservableObject {
    static let maxPerBook = 1_000
    @Published private(set) var records: [String: ReaderAnnotation] = [:]
    private let fileURL: URL?

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Annotations", isDirectory: true)
    }

    init(directory: URL? = nil) {
        fileURL = directory?.appendingPathComponent("annotations.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: ReaderAnnotation].self, from: data) {
            records = saved.filter { $0.key == $0.value.id.uuidString && $0.value.isValid }
        }
    }

    /// 一本书未删除的标注，按章节与章内起点排序。
    func annotations(for bookKey: String) -> [ReaderAnnotation] {
        records.values.filter { $0.bookKey == bookKey && !$0.isDeleted }.sorted {
            ($0.chapterIndex, $0.startUTF16, $0.createdAt) < ($1.chapterIndex, $1.startUTF16, $1.createdAt)
        }
    }

    func annotations(for bookKey: String, chapter: Int) -> [ReaderAnnotation] {
        annotations(for: bookKey).filter { $0.chapterIndex == chapter }
    }

    func annotation(id: UUID) -> ReaderAnnotation? {
        records[id.uuidString].flatMap { $0.isDeleted ? nil : $0 }
    }

    /// 新建标注。与已有标注范围重叠时，完全相同的范围更新原记录，其他重叠标注按最新操作替换。
    @discardableResult
    func add(bookKey: String, chapterIndex: Int, chapterID: String? = nil, resourceHref: String? = nil,
             progression: Double? = nil, range: NSRange, quote: String, chapterText: String? = nil,
             projectionIdentity: String, color: ReaderAnnotation.Color = .yellow,
             note: String = "", now: Date = Date()) throws -> ReaderAnnotation {
        guard ReaderAnnotation.isValidBookKey(bookKey),
              chapterIndex >= 0, range.location >= 0, range.length > 0,
              !quote.isEmpty, quote.utf16.count <= ReaderAnnotation.maxQuoteLength,
              note.utf16.count <= ReaderAnnotation.maxNoteLength,
              projectionIdentity.utf8.count <= 128
        else { throw ReaderAnnotationError.invalidSelection }
        if let chapterText {
            guard NSMaxRange(range) <= (chapterText as NSString).length else {
                throw ReaderAnnotationError.invalidSelection
            }
        }
        let context: (prefix: String, suffix: String)
        if let chapterText {
            context = ReaderAnnotation.context(in: chapterText, range: range)
        } else {
            context = ("", "")
        }
        let start = range.location
        let end = NSMaxRange(range)
        let candidate = ReaderAnnotation(
            id: UUID(), bookKey: bookKey, chapterIndex: chapterIndex, chapterID: chapterID,
            resourceHref: resourceHref, progression: progression,
            startUTF16: start, endUTF16: end,
            quote: quote, prefix: context.prefix, suffix: context.suffix,
            projectionIdentity: projectionIdentity, color: color, note: note,
            createdAt: now, updatedAt: now
        )
        var next = records
        let existing = annotations(for: bookKey).filter { ReaderAnnotation.overlaps(candidate, $0) }
        if let same = existing.first(where: {
            $0.startUTF16 == candidate.startUTF16 && $0.endUTF16 == candidate.endUTF16
                && $0.chapterID == candidate.chapterID && $0.quote == candidate.quote
        }) {
            var updated = same
            updated.color = color
            updated.note = note
            updated.updatedAt = now
            next[same.id.uuidString] = updated
            try save(next)
            return updated
        }
        for item in existing {
            guard var removed = next[item.id.uuidString] else { continue }
            removed.deleted = true
            removed.updatedAt = now
            next[item.id.uuidString] = removed
        }
        let liveCount = next.values.filter { $0.bookKey == bookKey && !$0.isDeleted }.count
        guard liveCount < Self.maxPerBook else { throw ReaderAnnotationError.tooMany }
        next[candidate.id.uuidString] = candidate
        try save(next)
        return candidate
    }

    func update(_ id: UUID, color: ReaderAnnotation.Color? = nil, note: String? = nil,
                now: Date = Date()) throws {
        guard var annotation = records[id.uuidString], !annotation.isDeleted else { return }
        if let color { annotation.color = color }
        if let note {
            guard note.utf16.count <= ReaderAnnotation.maxNoteLength else { throw ReaderAnnotationError.invalidNote }
            annotation.note = note
        }
        annotation.updatedAt = now
        var next = records
        next[id.uuidString] = annotation
        try save(next)
    }

    func remove(_ id: UUID, now: Date = Date()) throws {
        try remove([id], now: now)
    }

    func remove(_ ids: [UUID], now: Date = Date()) throws {
        var next = records
        for id in ids {
            guard var annotation = next[id.uuidString], !annotation.isDeleted else { continue }
            annotation.deleted = true
            annotation.updatedAt = now
            next[id.uuidString] = annotation
        }
        try save(next)
    }

    func applySynced(_ remote: [String: ReaderAnnotation]) throws {
        try save(ReaderAnnotation.merged(records, remote))
    }

    private func save(_ next: [String: ReaderAnnotation]) throws {
        guard next != records else { return }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        }
        records = next
    }
}

enum ReaderAnnotationError: LocalizedError {
    case invalidSelection, invalidNote, tooMany

    var errorDescription: String? {
        switch self {
        case .invalidSelection: "无法保存这段标注，请重新选择正文。"
        case .invalidNote: "笔记过长，请缩短后重试。"
        case .tooMany: "本书的摘录与笔记数量已达上限。"
        }
    }
}
