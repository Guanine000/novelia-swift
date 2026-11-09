// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// TXT 目录变更时的状态承接，使用 App 注入的原进度/书签实例；不新建存储或改写源文件。
@MainActor
enum TXTAdjustmentMigration {
    struct State: Sendable {
        var position: SyncedReadingPosition?
        var bookmarks: [String: ReaderBookmark]
    }

    static func prepare(oldBook: TXTParsedBook, next: TXTAdjustmentDocument, settings: ReaderSettings) async throws -> State {
        let key = "txt:" + oldBook.contentHash
        let saved = settings.positions.all()[key]
        let oldPosition = settings.positions.txtPosition(hash: oldBook.contentHash)
        let bookmarks = settings.bookmarks.bookmarks(for: key)
        let projection = settings.projection
        return try await Task.detached(priority: .userInitiated) {
            let oldMap = try TXTAdjustmentCoordinates(text: next.text, chapters: oldBook.chapters, projection: projection)
            let newMap = try TXTAdjustmentCoordinates(text: next.text, chapters: next.chapters(), projection: projection, boundaries: next.boundaries)
            var migrated: SyncedReadingPosition?
            let now = Date()
            if let oldPosition {
                let unit = oldPosition.unit.flatMap { oldPosition.unitCount == oldMap.units.count && oldMap.units.indices.contains($0) ? $0 : nil }
                    ?? oldMap.units.firstIndex(where: { $0.chapter == oldPosition.chapter })
                guard let unit, let raw = oldMap.rawOffset(unit: unit, offset: oldPosition.unit == unit ? oldPosition.offset ?? 0 : 0),
                      let target = newMap.location(rawOffset: raw) else { throw TXTAdjustmentError.invalidDirectory }
                migrated = saved ?? SyncedReadingPosition(chapterIndex: nil, fraction: nil, updatedAt: now)
                migrated?.chapterIndex = newMap.units[target.unit].chapter
                migrated?.unit = target.unit; migrated?.unitCount = newMap.units.count
                migrated?.chapterOffset = target.offset; migrated?.updatedAt = now
            }
            var copies: [String: ReaderBookmark] = [:]
            for var bookmark in bookmarks {
                guard oldMap.units.indices.contains(bookmark.chapterIndex) else { throw TXTAdjustmentError.invalidDirectory }
                let unit = oldMap.units[bookmark.chapterIndex]
                let offset = Int(bookmark.chapterProgression * Double(unit.length))
                guard let raw = oldMap.rawOffset(unit: bookmark.chapterIndex, offset: offset),
                      let target = newMap.location(rawOffset: raw) else { throw TXTAdjustmentError.invalidDirectory }
                bookmark.chapterIndex = target.unit
                bookmark.chapterProgression = Double(target.offset) / Double(max(1, newMap.units[target.unit].length))
                bookmark.chapterTitle = next.boundaries[newMap.units[target.unit].chapter].title
                bookmark.updatedAt = now
                copies[bookmark.id.uuidString] = bookmark
            }
            return State(position: migrated, bookmarks: copies)
        }.value
    }
}

@MainActor
extension ReaderSettings {
    func applyTXTAdjustment(_ state: TXTAdjustmentMigration.State, hash: String) throws {
        try bookmarks.applySynced(state.bookmarks)
        if let position = state.position { positions.mergePosition(key: "txt:" + hash, position: position) }
    }

    func txtBook(url: URL, rules: TXTChapterRuleConfiguration, trace: String) async throws -> TXTParsedBook {
        let base = try await TXTBookCache.shared.book(at: url, rules: rules, source: .open, trace: trace)
        let (book, snapshot) = try await txtAdjustments.readingBook(base, url: url)
        if let saved = snapshot {
            try applyTXTAdjustment(.init(position: saved.position, bookmarks: saved.bookmarks), hash: base.contentHash)
            let appliedKey = "txt.adjustmentAppliedRevision.v1." + base.contentHash
            if defaults.string(forKey: appliedKey) != saved.revision {
                SpeechResumeStore(defaults: defaults).clear(bookKey: "txt:" + base.contentHash)
                defaults.set(saved.revision, forKey: appliedKey)
            }
        }
        registerTXTBook(book)
        return book
    }
}
