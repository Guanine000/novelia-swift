import Combine
import Foundation

struct WebNovelDownloadProgress: Equatable {
    let completed: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

/// Root 持有的网络小说下载与本地记录 Store，通过 NovelDownloadService 获取 EPUB。
/// 管理 WebNovelDownloads 文件、library.json 和进度/错误；保留记录身份及同步兼容。
@MainActor
final class WebNovelDownloadStore: ObservableObject {
    @Published private(set) var books: [DownloadedWebNovel] = []
    @Published private(set) var progress: [String: WebNovelDownloadProgress] = [:]
    @Published private(set) var errors: [String: String] = [:]

    private let fileManager: FileManager
    private let directory: URL
    private let syncFileCopier = LocalLibraryFileCopier()
    private let indexURL: URL
    private let api: any NovelDownloadService

    init(api: any NovelDownloadService, fileManager: FileManager = .default) {
        self.api = api
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = applicationSupport.appendingPathComponent("WebNovelDownloads", isDirectory: true)
        indexURL = directory.appendingPathComponent("library.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([DownloadedWebNovel].self, from: data) {
            books = LibraryOrganizer.uniqueRecords(
                saved.filter { fileManager.fileExists(atPath: directory.appendingPathComponent($0.fileFilename).path) },
                id: { $0.id }, date: { $0.downloadedAt })
        }
    }

    func isDownloaded(_ novelID: String) -> Bool {
        books.contains { $0.id == novelID }
    }

    func download(_ novel: Novel, mode: WebNovelDownloadMode, translationSource: NovelTranslationSource?) async {
        guard novel.isRemote,
              let providerId = novel.providerId,
              let novelId = novel.novelId,
              progress[novel.id] == nil else { return }

        errors[novel.id] = nil
        progress[novel.id] = WebNovelDownloadProgress(completed: 0, total: 1)

        do {
            try Task.checkCancellation()
            let effectiveSource = mode == .original ? nil : translationSource
            let filename = Self.websiteDownloadFilename(title: novel.title, mode: mode,
                                                         translationSource: effectiveSource)
            let dataURL = uniqueDestination(for: filename)
            try await api.downloadWebNovelEPUB(
                to: dataURL,
                providerId: providerId,
                novelId: novelId,
                title: novel.title,
                translationSource: effectiveSource,
                mode: mode
            )
            progress[novel.id] = WebNovelDownloadProgress(completed: 1, total: 1)

            let record = DownloadedWebNovel(
                novel: novel,
                fileFilename: dataURL.lastPathComponent,
                downloadedAt: Date(),
                translationSource: effectiveSource,
                downloadMode: mode,
                fileFormat: .epub
            )
            let previousBooks = books
            books.removeAll { $0.id == novel.id }
            books.insert(record, at: 0)
            do {
                try persistIndex()
            } catch {
                books = previousBooks
                try? fileManager.removeItem(at: dataURL)
                throw error
            }
            if let old = previousBooks.first(where: { $0.id == novel.id }) {
                removeStoredFile(for: old)
            }
        } catch {
            errors[novel.id] = error.localizedDescription
        }
        progress[novel.id] = nil
    }

    func remove(_ book: DownloadedWebNovel) {
        removeStoredFile(for: book)
        books.removeAll { $0.id == book.id }
        try? persistIndex()
    }

    func importForMove(from source: URL, book: LocalWenkuEPUB) throws -> DownloadedWebNovel {
        let format = book.resolvedFileFormat
        let novel = book.sourceWebNovel?.novel ?? Novel(id: "local-\(book.id.uuidString)", title: book.title,
            author: book.author ?? "", summary: book.bookDescription ?? "",
            genres: [], chapters: [], accent: .plum)
        guard !books.contains(where: { $0.id == novel.id }) else {
            throw WebNovelMoveError.alreadyExists
        }
        let destination = uniqueDestination(for: source.lastPathComponent)
        try fileManager.copyItem(at: source, to: destination)
        let record = DownloadedWebNovel(novel: novel,
            fileFilename: destination.lastPathComponent, downloadedAt: book.sourceWebNovel?.downloadedAt ?? book.addedAt,
            translationSource: book.sourceWebNovel?.translationSource,
            downloadMode: book.sourceWebNovel?.downloadMode, fileFormat: format)
        books.insert(record, at: 0)
        do { try persistIndex() } catch {
            books.removeAll { $0.id == record.id }
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return record
    }

    func removeForMove(_ book: DownloadedWebNovel) throws {
        let previous = books
        books.removeAll { $0.id == book.id }
        do { try persistIndex() } catch { books = previous; throw error }
        removeStoredFile(for: book)
    }

    func fileURL(for book: DownloadedWebNovel) -> URL {
        directory.appendingPathComponent(book.fileFilename)
    }

    func syncFiles(for book: DownloadedWebNovel) -> [String: URL] {
        let url = fileURL(for: book)
        return fileManager.fileExists(atPath: url.path) ? [book.fileFilename: url] : [:]
    }

    func restoreFromSync(_ book: DownloadedWebNovel, files: [String: URL]) async throws {
        guard !books.contains(where: { $0.id == book.id }) else { return }
        guard let source = files[book.fileFilename] else { throw CocoaError(.fileReadNoSuchFile) }
        var copied: [URL] = []
        do {
            let destination = directory.appendingPathComponent("sync-\(UUID().uuidString).\(book.resolvedFileFormat.fileExtension)")
            try await syncFileCopier.copy(from: source, to: destination)
            copied.append(destination)
            let restored = DownloadedWebNovel(
                novel: book.novel,
                fileFilename: destination.lastPathComponent,
                downloadedAt: book.downloadedAt,
                translationSource: book.translationSource,
                downloadMode: book.downloadMode,
                fileFormat: book.fileFormat
            )
            try Task.checkCancellation()
            guard !books.contains(where: { $0.id == book.id }) else { throw CocoaError(.fileWriteFileExists) }
            books.insert(restored, at: 0)
            do { try persistIndex() } catch {
                books.removeAll { $0.id == book.id }
                throw error
            }
        } catch {
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    func replaceFromSync(_ book: DownloadedWebNovel, files: [String: URL]) async throws {
        guard let old = books.first(where: { $0.id == book.id }),
              let source = files[book.fileFilename] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var copied: [URL] = []
        do {
            let destination = directory.appendingPathComponent("sync-\(UUID().uuidString).\(book.resolvedFileFormat.fileExtension)")
            try await syncFileCopier.copy(from: source, to: destination)
            copied.append(destination)
            let replacement = DownloadedWebNovel(novel: book.novel,
                fileFilename: destination.lastPathComponent, downloadedAt: book.downloadedAt,
                translationSource: book.translationSource, downloadMode: book.downloadMode,
                fileFormat: book.fileFormat)
            try Task.checkCancellation()
            guard let index = books.firstIndex(where: { $0.id == book.id }), books[index] == old else {
                throw CocoaError(.fileNoSuchFile)
            }
            books[index] = replacement
            try persistIndex()
            removeStoredFile(for: old)
        } catch {
            // 复制阶段尚未改变书目；提交后的同步写盘失败在主执行域立即回滚。
            if let index = books.firstIndex(where: { $0.id == book.id }), books[index].fileFilename == copied.first?.lastPathComponent {
                books[index] = old
            }
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    private func removeStoredFile(for book: DownloadedWebNovel) {
        try? fileManager.removeItem(at: fileURL(for: book))
    }

    private func uniqueDestination(for filename: String) -> URL {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    private static func websiteDownloadFilename(title: String, mode: WebNovelDownloadMode,
                                                translationSource: NovelTranslationSource?) -> String {
        let safeTitle = title.replacingOccurrences(of: "[\\/|\\\\:*?\"<>]", with: "", options: .regularExpression)
        let translator = translationSource.map { "Y\($0.rawValue.prefix(1))." } ?? ""
        return "\(mode.apiValue).\(translator)\(safeTitle).epub"
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(books)
        try data.write(to: indexURL, options: .atomic)
    }

}

private enum WebNovelMoveError: LocalizedError {
    case alreadyExists
    var errorDescription: String? {
        "网络小说中已经有这本书，请先处理已有书籍后再移动。原书和阅读进度已保留。"
    }
}
