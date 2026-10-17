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
    private let syncFileCopier: LocalLibraryFileCopier
    private let indexURL: URL
    private let api: any NovelDownloadService
    private let repository: LocalLibraryRepository<DownloadedWebNovel>
    private var hasLoaded = false
    var isReady: Bool { hasLoaded }
    @Published private(set) var isLoading = true
    @Published private(set) var storageError: String?

    init(api: any NovelDownloadService, fileManager: FileManager = .default, directory: URL? = nil,
         indexWriter: LocalLibraryIndexWriter = LocalLibraryIndexWriter(),
         fileCopier: LocalLibraryFileCopier = LocalLibraryFileCopier()) {
        self.api = api
        self.fileManager = fileManager
        self.syncFileCopier = fileCopier
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = directory ?? support.appendingPathComponent("WebNovelDownloads", isDirectory: true)
        self.directory = directory
        indexURL = directory.appendingPathComponent("library.json")
        repository = LocalLibraryRepository(url: indexURL, writer: indexWriter) { saved in
            LibraryOrganizer.uniqueRecords(
                saved.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileFilename).path) },
                id: { $0.id }, date: { $0.downloadedAt })
        }
    }

    func loadIfNeeded() async throws {
        guard !hasLoaded else { return }
        do {
            try await repository.load { if books != $0 { books = $0 } }
            storageError = nil
            isLoading = false
            hasLoaded = true
        } catch {
            isLoading = false
            if !(error is CancellationError) { storageError = "网络小说书库索引读取失败，原文件已保留。请重试或导出日志排查。" }
            throw error
        }
    }

    @discardableResult
    private func commit<Value>(_ change: (inout [DownloadedWebNovel]) throws -> Value) async throws -> Value {
        try await loadIfNeeded()
        return try await repository.update(change) { if books != $0 { books = $0 } }
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
            try await loadIfNeeded()
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
            let old: DownloadedWebNovel?
            do {
                old = try await commit { records in
                    let previous = records.first { $0.id == novel.id }
                    records.removeAll { $0.id == novel.id }
                    records.insert(record, at: 0)
                    return previous
                }
            } catch { await syncFileCopier.remove([dataURL]); throw error }
            if let old { await syncFileCopier.remove([fileURL(for: old)]) }
        } catch {
            errors[novel.id] = error.localizedDescription
        }
        progress[novel.id] = nil
    }

    /// 索引提交失败时保留原文件，用户可以重试删除。
    func remove(_ book: DownloadedWebNovel) async throws {
        let removed = try await commit { records -> DownloadedWebNovel? in
            let current = records.first { $0.id == book.id }
            records.removeAll { $0.id == book.id }
            return current
        }
        if let removed { await syncFileCopier.remove([fileURL(for: removed)]) }
    }

    func importForMove(from source: URL, book: LocalWenkuEPUB) async throws -> DownloadedWebNovel {
        try await loadIfNeeded()
        let format = book.resolvedFileFormat
        let novel = book.sourceWebNovel?.novel ?? Novel(id: "local-\(book.id.uuidString)", title: book.title,
            author: book.author ?? "", summary: book.bookDescription ?? "", genres: [], chapters: [], accent: .plum)
        let destination = directory.appendingPathComponent("move-\(UUID().uuidString).\(format.fileExtension)")
        try await syncFileCopier.copy(from: source, to: destination)
        let record = DownloadedWebNovel(novel: novel, fileFilename: destination.lastPathComponent,
            downloadedAt: book.sourceWebNovel?.downloadedAt ?? book.addedAt,
            translationSource: book.sourceWebNovel?.translationSource,
            downloadMode: book.sourceWebNovel?.downloadMode, fileFormat: format)
        do {
            try await commit { records in
                guard !records.contains(where: { $0.id == novel.id }) else { throw WebNovelMoveError.alreadyExists }
                records.insert(record, at: 0)
            }
        } catch { await syncFileCopier.remove([destination]); throw error }
        return record
    }

    func removeForMove(_ book: DownloadedWebNovel) async throws {
        try await commit { records in
            guard let current = records.first(where: { $0.id == book.id }), current == book else {
                throw CocoaError(.fileWriteUnknown)
            }
            records.removeAll { $0.id == book.id }
        }
        await syncFileCopier.remove([fileURL(for: book)])
    }

    func fileURL(for book: DownloadedWebNovel) -> URL {
        directory.appendingPathComponent(book.fileFilename)
    }

    func syncFiles(for book: DownloadedWebNovel) -> [String: URL] {
        let url = fileURL(for: book)
        return fileManager.fileExists(atPath: url.path) ? [book.fileFilename: url] : [:]
    }

    func restoreFromSync(_ book: DownloadedWebNovel, files: [String: URL]) async throws {
        try await loadIfNeeded()
        guard !books.contains(where: { $0.id == book.id }) else { return }
        guard let source = files[book.fileFilename] else { throw CocoaError(.fileReadNoSuchFile) }
        let destination = directory.appendingPathComponent("sync-\(UUID().uuidString).\(book.resolvedFileFormat.fileExtension)")
        try await syncFileCopier.copy(from: source, to: destination)
        let restored = DownloadedWebNovel(novel: book.novel, fileFilename: destination.lastPathComponent,
            downloadedAt: book.downloadedAt, translationSource: book.translationSource,
            downloadMode: book.downloadMode, fileFormat: book.fileFormat)
        do {
            try await commit { records in
                guard !records.contains(where: { $0.id == book.id }) else { throw CocoaError(.fileWriteFileExists) }
                records.insert(restored, at: 0)
            }
        } catch { await syncFileCopier.remove([destination]); throw error }
    }

    func replaceFromSync(_ book: DownloadedWebNovel, files: [String: URL]) async throws {
        try await loadIfNeeded()
        guard let old = books.first(where: { $0.id == book.id }), let source = files[book.fileFilename] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let destination = directory.appendingPathComponent("sync-\(UUID().uuidString).\(book.resolvedFileFormat.fileExtension)")
        try await syncFileCopier.copy(from: source, to: destination)
        let replacement = DownloadedWebNovel(novel: book.novel, fileFilename: destination.lastPathComponent,
            downloadedAt: book.downloadedAt, translationSource: book.translationSource,
            downloadMode: book.downloadMode, fileFormat: book.fileFormat)
        do {
            try await commit { records in
                guard let index = records.firstIndex(where: { $0.id == book.id }), records[index] == old else {
                    throw CocoaError(.fileWriteUnknown)
                }
                records[index] = replacement
            }
        } catch { await syncFileCopier.remove([destination]); throw error }
        await syncFileCopier.remove([fileURL(for: old)])
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


}

private enum WebNovelMoveError: LocalizedError {
    case alreadyExists
    var errorDescription: String? {
        "网络小说中已经有这本书，请先处理已有书籍后再移动。原书和阅读进度已保留。"
    }
}
