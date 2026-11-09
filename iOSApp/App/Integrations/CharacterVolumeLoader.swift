// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 连接书库文件与只读章节能力；不下载、不激活单书设置，也不迁移或写入阅读进度。
@MainActor
enum CharacterVolumeLoader {
    struct Volume {
        let source: LocalRecapSource
        let boundary: Int
    }
    static func load(_ book: LibraryBook, settings: ReaderSettings) async throws -> Volume {
        guard !book.isCloudOnly, FileManager.default.fileExists(atPath: book.fileURL.path) else { throw CharacterLexiconError.missing }
        let url = book.fileURL
        let hash = try await Task.detached { try FileContentHash.sha256(url) }.value
        try Task.checkCancellation()
        let projection = settings.bookPreferences[book.positionPrefix + hash]?.projection ?? .init()
        if book.format == .txt {
            let rules = TXTChapterRuleStore(defaults: settings.defaults).configuration
            let base = try await TXTBookCache.shared.book(at: url, rules: rules, source: .open, trace: DiagnosticContext.newTraceID())
            let (parsed, snapshot) = try await settings.txtAdjustments.readingBook(base, url: url)
            let saved = settings.positions.all()["txt:" + hash]
            let position = snapshot?.position.flatMap { (saved?.updatedAt ?? .distantPast) <= $0.updatedAt ? $0 : saved } ?? saved
            let boundary = min(max(0, position?.chapterIndex ?? 0), max(0, parsed.chapters.count - 1))
            return .init(source: .txt(parsed, title: book.title, chapter: parsed.chapters.count, projection: projection, maximumChapterBytes: CharacterExtractionPlan.maximumBytes), boundary: boundary)
        }
        let container = try await EPUBContainer.open(fileURL: url)
        let spine = min(max(0, settings.positions.epubPosition(hash: hash)?.chapterIndex ?? 0), max(0, container.spine.count - 1))
        guard let current = LocalRecapSource.epub(container, hash: hash, currentSpine: spine, projection: projection),
              let full = LocalRecapSource.epub(container, hash: hash, currentSpine: spine, projection: projection, completeVolume: true, maximumChapterBytes: CharacterExtractionPlan.maximumBytes) else { throw CharacterLexiconError.missing }
        return .init(source: full, boundary: current.currentChapter)
    }
}
