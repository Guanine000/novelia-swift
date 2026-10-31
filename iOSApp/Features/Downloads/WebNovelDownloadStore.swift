import Combine
import Foundation

struct WebNovelDownloadProgress: Equatable {
    let completed: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

enum WebNovelEPUBUpdateError: LocalizedError {
    case unavailable, busy, changed, configurationRequired
    var errorDescription: String? {
        switch self {
        case .unavailable: "这本书不是可更新的网络小说 EPUB。"
        case .configurationRequired: "下载设置不完整，请先选择语言模式和译源。"
        case .busy: "这本小说正在下载，请稍后重试。"
        case .changed: "更新期间书籍已被删除、移动或替换，未覆盖当前书库，请重新操作。"
        }
    }
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
    /// App 集成层校验新 EPUB 并尝试承接阅读状态；默认无操作，供独立存储验证使用。
    private let prepareEPUBUpdate: (DownloadedWebNovel, URL, URL) async throws -> Void
    private var hasLoaded = false
    var isReady: Bool { hasLoaded }
    @Published private(set) var isLoading = true
    @Published private(set) var storageError: String?

    init(api: any NovelDownloadService, fileManager: FileManager = .default, directory: URL? = nil,
         indexWriter: LocalLibraryIndexWriter = LocalLibraryIndexWriter(),
         fileCopier: LocalLibraryFileCopier = LocalLibraryFileCopier(),
         prepareEPUBUpdate: @escaping (DownloadedWebNovel, URL, URL) async throws -> Void = { _, _, _ in }) {
        self.api = api
        self.fileManager = fileManager
        self.syncFileCopier = fileCopier
        self.prepareEPUBUpdate = prepareEPUBUpdate
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

    /// 手动更新同一下载记录：完整重新生成，沿用语言/译源；内容相同不改变文件或同步时间。
    /// 提交时复核旧记录，防止网络等待期间的删除或移动被重新添加；失败仅清理新临时文件。
    @discardableResult
    func updateEPUB(_ book: DownloadedWebNovel, configuration: WebNovelEPUBUpdateConfiguration? = nil) async throws -> Bool {
        guard book.novel.isRemote, book.resolvedFileFormat == .epub,
              let provider = book.novel.providerId, let novel = book.novel.novelId else {
            throw WebNovelEPUBUpdateError.unavailable
        }
        guard let selected = configuration ?? book.epubUpdateConfiguration, selected.isValid else {
            throw WebNovelEPUBUpdateError.configurationRequired
        }
        guard progress[book.id] == nil else { throw WebNovelEPUBUpdateError.busy }
        try await loadIfNeeded()
        guard books.first(where: { $0.id == book.id }) == book else { throw WebNovelEPUBUpdateError.changed }
        progress[book.id] = .init(completed: 0, total: 1)
        errors[book.id] = nil
        defer { progress[book.id] = nil }
        let source = selected.effectiveSource
        let destination = uniqueDestination(for: Self.websiteDownloadFilename(title: book.novel.title,
                                         mode: selected.mode, translationSource: source))
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: destination) } }
        do {
            try Task.checkCancellation()
            try await api.downloadWebNovelEPUB(to: destination, providerId: provider, novelId: novel,
                                             title: book.novel.title, translationSource: source, mode: selected.mode)
            try Task.checkCancellation()
            let oldURL = fileURL(for: book)
            let same = try await Task.detached(priority: .utility) {
                try FileContentHash.sha256(oldURL) == FileContentHash.sha256(destination)
            }.value
            guard books.first(where: { $0.id == book.id }) == book else { throw WebNovelEPUBUpdateError.changed }
            try Task.checkCancellation()
            if same {
                if book.downloadMode != selected.mode || book.translationSource != source {
                    try await commit { records in
                        guard let index = records.firstIndex(where: { $0.id == book.id }), records[index] == book else { throw WebNovelEPUBUpdateError.changed }
                        records[index] = DownloadedWebNovel(novel: book.novel, fileFilename: book.fileFilename,
                            downloadedAt: book.downloadedAt, translationSource: source, downloadMode: selected.mode, fileFormat: book.fileFormat)
                    }
                }
                return false
            }
            try await prepareEPUBUpdate(book, oldURL, destination)
            try Task.checkCancellation()
            let updated = DownloadedWebNovel(novel: book.novel, fileFilename: destination.lastPathComponent,
                                            downloadedAt: Date(), translationSource: source,
                                            downloadMode: selected.mode, fileFormat: .epub)
            try await commit { records in
                guard let index = records.firstIndex(where: { $0.id == book.id }), records[index] == book else {
                    throw WebNovelEPUBUpdateError.changed
                }
                records[index] = updated
            }
            committed = true
            await syncFileCopier.remove([oldURL])
            return true
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if !(error is CancellationError) { errors[book.id] = error.localizedDescription }
            throw error
        }
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
        guard book.downloadedAt >= old.downloadedAt else { throw WebNovelEPUBUpdateError.changed }
        let destination = directory.appendingPathComponent("sync-\(UUID().uuidString).\(book.resolvedFileFormat.fileExtension)")
        try await syncFileCopier.copy(from: source, to: destination)
        let replacement = DownloadedWebNovel(novel: book.novel, fileFilename: destination.lastPathComponent,
            downloadedAt: book.downloadedAt, translationSource: book.translationSource,
            downloadMode: book.downloadMode, fileFormat: book.fileFormat)
        do {
            if old.novel.isRemote, old.resolvedFileFormat == .epub, book.resolvedFileFormat == .epub {
                try await prepareEPUBUpdate(old, fileURL(for: old), destination)
            }
            try Task.checkCancellation()
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
