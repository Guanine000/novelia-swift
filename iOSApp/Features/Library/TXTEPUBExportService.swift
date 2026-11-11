// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 已生成的导出文件；分享面板关闭后删除临时目录。
struct LibraryFileShare: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let cleanupDirectory: URL?
}

/// 把 TXT 按当前手工目录导出为 EPUB。只读取源文件、书库和阅读设置，不写回进度、书签或源文件。
@MainActor
enum TXTEPUBExportService {
    static func makeEPUB(book: LibraryBook, settings: ReaderSettings) async throws -> LibraryFileShare {
        guard book.format == .txt else { throw TXTEPUBExportError.notTXT }
        guard FileManager.default.fileExists(atPath: book.fileURL.path) else { throw TXTEPUBExportError.missingFile }

        // session 优先使用按内容哈希保存的手工边界；没有快照或文件已变化时回退到自动分章。
        let session = try await settings.txtAdjustments.session(
            url: book.fileURL,
            rules: TXTChapterRuleStore.shared.configuration
        )
        let bookID = "txt:" + session.baseBook.contentHash
        let projection = settings.bookPreferences[bookID]?.projection ?? .init()
        let chapters = session.document.chapters().map {
            TXTEPUBChapter(title: $0.title, volumeTitle: $0.volumeTitle, body: $0.body)
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoveliaExport", isDirectory: true)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(LibraryArchiveExporter.sanitized(book.title) + ".epub")
        let title = book.title
        let author = book.author
        do {
            // 章节 XHTML 与打包可能耗时，放到后台执行，避免大书导出时卡住界面。
            try await Task.detached(priority: .userInitiated) {
                try await TXTEPUBExporter.export(title: title, author: author, chapters: chapters,
                                                 projection: projection, destination: destination)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return LibraryFileShare(url: destination, title: book.title, cleanupDirectory: directory)
    }
}
