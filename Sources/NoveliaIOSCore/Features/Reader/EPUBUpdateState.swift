import Foundation

/// 更新 EPUB 后按唯一章节路径承接状态；保留旧文件记录，与新版已有状态按时间合并。
/// 目录路径不再匹配时不猜测章节序号，避免把位置套到无关章节。
@MainActor
enum EPUBUpdateState {
    static func carry(oldHash: String, newHash: String, oldPaths: [String], newPaths: [String],
                      positions: any ReadingPositionSynchronizing, bookmarks: ReaderBookmarkStore) throws {
        guard oldHash != newHash else { return }
        let oldCounts = Dictionary(grouping: oldPaths, by: { $0 }).mapValues(\.count)
        var newIndices: [String: [Int]] = [:]
        for (index, path) in newPaths.enumerated() { newIndices[path, default: []].append(index) }
        var mapping: [Int: Int] = [:]
        for (index, path) in oldPaths.enumerated() {
            if oldCounts[path] == 1, let matches = newIndices[path], matches.count == 1 { mapping[index] = matches[0] }
        }
        let newKey = "epub:\(newHash)"
        var copies: [String: ReaderBookmark] = [:]
        for old in bookmarks.records.values where old.bookKey == "epub:\(oldHash)" {
            guard let chapter = mapping[old.chapterIndex] else { continue }
            // 两台设备更新为同一文件时生成相同 ID，避免同步后出现两份承接书签。
            let seed = FileContentHash.sha256(Data("\(old.id.uuidString)|\(newKey)".utf8))
            let uuid = "\(seed.prefix(8))-\(seed.dropFirst(8).prefix(4))-\(seed.dropFirst(12).prefix(4))-\(seed.dropFirst(16).prefix(4))-\(seed.dropFirst(20).prefix(12))"
            let copied = ReaderBookmark(id: UUID(uuidString: uuid)!, bookKey: newKey, chapterIndex: chapter,
                chapterProgression: old.chapterProgression, chapterTitle: old.chapterTitle,
                snippet: old.snippet, createdAt: old.createdAt, updatedAt: old.updatedAt, deleted: old.deleted)
            copies[copied.id.uuidString] = copied
        }
        try bookmarks.applySynced(copies)
        if var saved = positions.epubPosition(hash: oldHash), let oldChapter = saved.chapterIndex,
           saved.updatedAt > (positions.epubPosition(hash: newHash)?.updatedAt ?? .distantPast),
           let chapter = mapping[oldChapter] {
            saved.chapterIndex = chapter
            saved.fraction = (Double(chapter) + (saved.chapterProgression ?? 0)) / Double(max(1, newPaths.count))
            positions.merge([newKey: saved], webBooks: [])
        }
    }
}
