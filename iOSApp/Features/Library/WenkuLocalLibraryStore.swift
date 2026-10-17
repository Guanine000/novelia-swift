import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Root 持有的文库/导入文件 Store，负责 WenkuEPUB 目录、索引、封面和元数据。
/// 远端文库查询由 WenkuStore 负责；保留 LocalWenkuEPUB 记录与文件恢复/同步约定。
@MainActor
final class WenkuLocalLibraryStore: ObservableObject {
    @Published private(set) var books: [LocalWenkuEPUB] = []
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL
    private let repository: LocalLibraryRepository<LocalWenkuEPUB>
    private var hasLoaded = false
    var isReady: Bool { hasLoaded }
    @Published private(set) var isLoading = true
    @Published private(set) var storageError: String?
    private let fileCopier: LocalLibraryFileCopier
    private var isRefreshingMetadata = false
    private let importGate = SerialAsyncGate()

    init(fileManager: FileManager = .default, directory: URL? = nil,
         indexWriter: LocalLibraryIndexWriter = LocalLibraryIndexWriter(),
         fileCopier: LocalLibraryFileCopier = LocalLibraryFileCopier()) {
        self.fileManager = fileManager
        self.fileCopier = fileCopier
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = directory ?? support.appendingPathComponent("WenkuEPUB", isDirectory: true)
        self.directory = directory
        indexURL = directory.appendingPathComponent("library.json")
        repository = LocalLibraryRepository(url: indexURL, writer: indexWriter) { saved in
            LibraryOrganizer.uniqueRecords(
                saved.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) },
                id: { $0.id }, date: { $0.addedAt })
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
            if !(error is CancellationError) { storageError = "书库索引读取失败，原文件已保留。请重试或导出日志排查。" }
            throw error
        }
    }

    @discardableResult
    private func commit<Value>(_ change: (inout [LocalWenkuEPUB]) throws -> Value) async throws -> Value {
        try await loadIfNeeded()
        return try await repository.update(change) { if books != $0 { books = $0 } }
    }

    func fileURL(for book: LocalWenkuEPUB) -> URL {
        directory.appendingPathComponent(book.filename)
    }

    func syncFiles(for book: LocalWenkuEPUB) -> [String: URL] {
        var files = [book.filename: fileURL(for: book)]
        if let coverFilename = book.coverFilename, let coverURL = coverURL(for: book) {
            files[coverFilename] = coverURL
        }
        return files
    }

    func restoreFromSync(_ book: LocalWenkuEPUB, files: [String: URL]) async throws {
        try await loadIfNeeded()
        guard !books.contains(where: { $0.id == book.id }) else { return }
        guard let source = files[book.filename] else { throw CocoaError(.fileReadNoSuchFile) }
        let destination = directory.appendingPathComponent("sync-\(UUID().uuidString).\(book.resolvedFileFormat.fileExtension)")
        var copied: [URL] = []
        var restored = book
        // 文件名属于本机，不改变书籍 ID、版本时间及内容身份。
        restored = LocalWenkuEPUB(id: book.id, title: book.title, filename: destination.lastPathComponent,
            addedAt: book.addedAt, lastLocatorJSON: book.lastLocatorJSON, bookDescription: book.bookDescription,
            author: book.author, coverFilename: nil, metadataLoaded: book.metadataLoaded,
            fileFormat: book.fileFormat, sourceWebNovel: book.sourceWebNovel, metadataUpdatedAt: book.metadataUpdatedAt)
        do {
            try await fileCopier.copy(from: source, to: destination)
            copied.append(destination)
            if let name = book.coverFilename, let source = files[name] {
                let cover = directory.appendingPathComponent("cover-\(UUID().uuidString).jpg")
                try await fileCopier.copy(from: source, to: cover)
                copied.append(cover)
                restored.coverFilename = cover.lastPathComponent
            }
            try await commit { records in
                guard !records.contains(where: { $0.id == book.id }) else { throw CocoaError(.fileWriteFileExists) }
                records.insert(restored, at: 0)
            }
        } catch { await fileCopier.remove(copied); throw error }
    }

    func replaceFromSync(_ book: LocalWenkuEPUB, files: [String: URL]) async throws {
        try await loadIfNeeded()
        guard let old = books.first(where: { $0.id == book.id }), let source = files[book.filename] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let destination = directory.appendingPathComponent("sync-\(UUID().uuidString).\(book.resolvedFileFormat.fileExtension)")
        var copied: [URL] = []
        var replacement = LocalWenkuEPUB(id: book.id, title: book.title, filename: destination.lastPathComponent,
            addedAt: book.addedAt, lastLocatorJSON: book.lastLocatorJSON, bookDescription: book.bookDescription,
            author: book.author, coverFilename: nil, metadataLoaded: book.metadataLoaded,
            fileFormat: book.fileFormat, sourceWebNovel: book.sourceWebNovel, metadataUpdatedAt: book.metadataUpdatedAt)
        do {
            try await fileCopier.copy(from: source, to: destination)
            copied.append(destination)
            if let name = book.coverFilename, let source = files[name] {
                let cover = directory.appendingPathComponent("cover-\(UUID().uuidString).jpg")
                try await fileCopier.copy(from: source, to: cover)
                copied.append(cover)
                replacement.coverFilename = cover.lastPathComponent
            }
            try await commit { records in
                guard let index = records.firstIndex(where: { $0.id == book.id }), records[index] == old else {
                    throw CocoaError(.fileWriteUnknown)
                }
                records[index] = replacement
            }
        } catch { await fileCopier.remove(copied); throw error }
        await fileCopier.remove([fileURL(for: old)] + [coverFileURL(for: old)].compactMap { $0 })
    }

    enum CoverChange {
        case keep, remove
        case replace(UIImage)
    }

    /// 修改书库显示的书名、作者、简介与封面。只改索引记录与封面文件，不改书籍文件，
    /// 内容哈希不变，阅读进度、书签与统计不受影响；修改时间随书籍同步给其他设备。
    func updateMetadata(id: UUID, title: String, author: String?, description: String?,
                        cover: CoverChange, now: Date = Date()) async throws {
        try await loadIfNeeded()
        guard let old = books.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        var book = old
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { book.title = String(cleanTitle.prefix(200)) }
        book.author = Self.cleaned(author)
        book.bookDescription = Self.cleaned(description)
        book.metadataLoaded = true
        book.metadataUpdatedAt = now
        var newCover: String?
        do {
            switch cover {
            case .keep: break
            case .remove: book.coverFilename = nil
            case .replace(let image):
                newCover = try await saveCoverInBackground(image, id: UUID())
                book.coverFilename = newCover
            }
            try await commit { records in
                guard let index = records.firstIndex(where: { $0.id == id }), records[index] == old else {
                    throw CocoaError(.fileWriteUnknown)
                }
                records[index] = book
            }
        } catch {
            await fileCopier.remove(newCover.map { [directory.appendingPathComponent($0)] } ?? [])
            throw error
        }
        if book.coverFilename != old.coverFilename { await fileCopier.remove([coverFileURL(for: old)].compactMap { $0 }) }
    }

    /// 网络等待期间可能已有本机编辑或文件版本替换，应用前重新比较版本与修改时间。
    /// 复制封面期间再次编辑／删除时仍拒绝旧快照提交，由调用方重试合并。
    func applySyncedMetadata(_ remote: LocalWenkuEPUB, cover: URL?) async throws {
        try await loadIfNeeded()
        guard let old = books.first(where: { $0.id == remote.id }),
              old.addedAt == remote.addedAt,
              (remote.metadataUpdatedAt ?? .distantPast) > (old.metadataUpdatedAt ?? .distantPast) else { return }
        var book = old
        book.title = remote.title
        book.author = remote.author
        book.bookDescription = remote.bookDescription
        book.metadataLoaded = true
        book.metadataUpdatedAt = remote.metadataUpdatedAt
        var copied: [URL] = []
        do {
            if remote.coverFilename == nil { book.coverFilename = nil }
            else if let cover {
                let target = directory.appendingPathComponent("cover-\(UUID().uuidString).jpg")
                try await fileCopier.copy(from: cover, to: target)
                copied.append(target)
                book.coverFilename = target.lastPathComponent
            }
            try await commit { records in
                guard let index = records.firstIndex(where: { $0.id == remote.id }), records[index] == old else {
                    throw CocoaError(.fileWriteUnknown)
                }
                records[index] = book
            }
        } catch { await fileCopier.remove(copied); throw error }
        if book.coverFilename != old.coverFilename { await fileCopier.remove([coverFileURL(for: old)].compactMap { $0 }) }
    }

    private static func cleaned(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : String(value.prefix(4000))
    }

    func coverURL(for book: LocalWenkuEPUB) -> URL? {
        guard let url = coverFileURL(for: book) else { return nil }
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// 供列表行使用的低成本 URL；加载器在主线程之外检查文件是否存在并解码图片。
    func coverFileURL(for book: LocalWenkuEPUB) -> URL? {
        book.coverFilename.map { directory.appendingPathComponent($0) }
    }

    func downloadDestination(for filename: String) -> URL {
        uniqueDestination(for: Self.safeFilename(filename))
    }

    /// 内容相同的本地书籍，通过 SHA-256 比较（按文件缓存哈希）。
    /// 大小不同的文件内容必然不同，先比较大小，只为大小相同的书计算哈希，避免大书库每次导入都读全部文件。
    private func existingBook(withContentHash hash: String, format: WebNovelFileFormat, size: Int?) async -> LocalWenkuEPUB? {
        for book in books where book.resolvedFileFormat == format {
            let url = directory.appendingPathComponent(book.filename)
            if let size, let existingSize = Self.fileSize(url), existingSize != size { continue }
            guard fileManager.fileExists(atPath: url.path),
                  let existing = try? await TXTBookCache.shared.contentHash(of: url) else { continue }
            if existing == hash { return book }
        }
        return nil
    }

    func registerDownloadedFile(at fileURL: URL, title: String, source: TXTLoadSource = .download,
                                trace: String = DiagnosticContext.newTraceID()) async throws {
        try await loadIfNeeded()
        guard fileURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw WenkuLocalLibraryError.invalidEPUB
        }
        let format: WebNovelFileFormat
        switch fileURL.pathExtension.lowercased() {
        case "epub": format = .epub
        case "txt": format = .txt
        default:
            try? fileManager.removeItem(at: fileURL)
            throw WenkuLocalLibraryError.unsupportedFile
        }

        if format == .txt {
            // 此处只解码一次；缓存的文本使首次打开只需解析。
            let newHash: String
            do {
                newHash = try await TXTBookCache.shared.validateDecodable(at: fileURL, source: source, trace: trace)
            } catch {
                try? fileManager.removeItem(at: fileURL)
                throw WenkuLocalLibraryError.invalidTXT
            }
            if let existing = await existingBook(withContentHash: newHash, format: .txt, size: Self.fileSize(fileURL)) {
                if existing.filename != fileURL.lastPathComponent { try? fileManager.removeItem(at: fileURL) }
                throw LocalLibraryDuplicateError(existingTitle: existing.title, contentHash: newHash)
            }
            let book = LocalWenkuEPUB(
                id: UUID(), title: title, filename: fileURL.lastPathComponent,
                addedAt: Date(), metadataLoaded: true, fileFormat: .txt
            )
            do { try await insertImported(book, hash: newHash) }
            catch {
                if !books.contains(where: { $0.filename == fileURL.lastPathComponent }) { await fileCopier.remove([fileURL]) }
                throw error
            }
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            try? fileManager.removeItem(at: fileURL)
            throw WenkuLocalLibraryError.invalidEPUB
        }
        let signature = try? handle.read(upToCount: 2)
        try? handle.close()
        guard signature == Data([0x50, 0x4b]) else {
            try? fileManager.removeItem(at: fileURL)
            throw WenkuLocalLibraryError.invalidEPUB
        }

        let newHash = try await TXTBookCache.shared.contentHash(of: fileURL)
        let metadata = await Self.metadata(for: fileURL)
        // 在元数据读取后检查，覆盖同一本 EPUB 被重复导入或下载的情况。
        if let existing = await existingBook(withContentHash: newHash, format: .epub, size: Self.fileSize(fileURL)) {
            if existing.filename != fileURL.lastPathComponent { try? fileManager.removeItem(at: fileURL) }
            throw LocalLibraryDuplicateError(existingTitle: existing.title, contentHash: newHash)
        }
        let id = UUID()
        let coverFilename = try? await saveCoverInBackground(metadata.cover, id: id)
        let book = LocalWenkuEPUB(
            id: id,
            title: metadata.title ?? title,
            filename: fileURL.lastPathComponent,
            addedAt: Date(),
            bookDescription: metadata.description,
            author: metadata.author,
            coverFilename: coverFilename,
            metadataLoaded: true,
            fileFormat: .epub
        )
        do { try await insertImported(book, hash: newHash) }
        catch {
            if !books.contains(where: { $0.filename == fileURL.lastPathComponent }) { await fileCopier.remove([fileURL]) }
            await fileCopier.remove(coverFilename.map { [directory.appendingPathComponent($0)] } ?? [])
            throw error
        }
    }

    /// 重复内容检查与提交共用串行入口；检查读取的始终是前一笔成功提交的书库。
    private func insertImported(_ book: LocalWenkuEPUB, hash: String) async throws {
        try await importGate.run {
            if let existing = await existingBook(withContentHash: hash, format: book.resolvedFileFormat,
                                                  size: Self.fileSize(fileURL(for: book))) {
                throw LocalLibraryDuplicateError(existingTitle: existing.title, contentHash: hash)
            }
            try await commit { $0.insert(book, at: 0) }
        }
    }

    func importForMove(from source: URL, sourceBook: DownloadedWebNovel) async throws -> LocalWenkuEPUB {
        try await loadIfNeeded()
        let format: WebNovelFileFormat = source.pathExtension.lowercased() == "txt" ? .txt : .epub
        let destination = directory.appendingPathComponent("move-\(UUID().uuidString).\(format.fileExtension)")
        var copied: [URL] = []
        do {
            try await fileCopier.copy(from: source, to: destination)
            copied.append(destination)
            let metadata = format == .epub ? await Self.metadata(for: destination) : (title: nil, description: nil, author: nil, cover: nil)
            let id = UUID()
            let coverFilename = try await saveCoverInBackground(metadata.cover, id: id)
            if let coverFilename { copied.append(directory.appendingPathComponent(coverFilename)) }
            let book = LocalWenkuEPUB(id: id, title: metadata.title ?? sourceBook.novel.title,
                filename: destination.lastPathComponent, addedAt: sourceBook.downloadedAt,
                bookDescription: metadata.description, author: metadata.author ?? sourceBook.novel.author,
                coverFilename: coverFilename, metadataLoaded: true, fileFormat: format, sourceWebNovel: sourceBook)
            try await commit { $0.insert(book, at: 0) }
            return book
        } catch { await fileCopier.remove(copied); throw error }
    }

    func removeForMove(_ book: LocalWenkuEPUB) async throws {
        try await commit { records in
            guard let current = records.first(where: { $0.id == book.id }), current == book else {
                throw CocoaError(.fileWriteUnknown)
            }
            records.removeAll { $0.id == book.id }
        }
        await fileCopier.remove([fileURL(for: book)] + [coverFileURL(for: book)].compactMap { $0 })
    }

    /// 先提交索引，再清理文件；写盘失败时书目和原文件保持可用。
    func remove(_ book: LocalWenkuEPUB) async throws {
        let removed = try await commit { records -> LocalWenkuEPUB? in
            let current = records.first { $0.id == book.id }
            records.removeAll { $0.id == book.id }
            return current
        }
        if let removed { await fileCopier.remove([fileURL(for: removed)] + [coverFileURL(for: removed)].compactMap { $0 }) }
    }

    func refreshMissingMetadata() async {
        guard !isRefreshingMetadata else { return }
        isRefreshingMetadata = true
        defer { isRefreshingMetadata = false }
        do {
            try await loadIfNeeded()
            storageError = nil
            let pending = books.filter { $0.metadataLoaded != true }
            let originals = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
            guard !pending.isEmpty else { return }
            var patches: [LocalWenkuEPUB] = []
            var newCovers: [URL] = []
            do {
                for old in pending {
                    try Task.checkCancellation()
                    let metadata = await Self.metadata(for: fileURL(for: old))
                    let cover = try await saveCoverInBackground(metadata.cover, id: UUID())
                    if let cover { newCovers.append(directory.appendingPathComponent(cover)) }
                    var book = old
                    if let title = metadata.title { book.title = title }
                    book.bookDescription = metadata.description
                    book.author = metadata.author
                    book.coverFilename = cover
                    book.metadataLoaded = true
                    patches.append(book)
                }
                try await commit { records in
                    for book in patches {
                        guard let index = records.firstIndex(where: { $0.id == book.id }), records[index] == originals[book.id] else { continue }
                        records[index] = book
                    }
                }
                let used = Set(books.compactMap(\.coverFilename))
                await fileCopier.remove(newCovers.filter { !used.contains($0.lastPathComponent) })
            } catch { await fileCopier.remove(newCovers); throw error }
        } catch {
            if !(error is CancellationError) { storageError = "书籍信息保存失败，请重试。" }
        }
    }

    private func uniqueDestination(for filename: String) -> URL {
        var candidate = directory.appendingPathComponent(filename)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(URL(fileURLWithPath: filename).pathExtension)")
            suffix += 1
        }
        return candidate
    }

    private func saveCoverInBackground(_ image: UIImage?, id: UUID) async throws -> String? {
        guard let image else { return nil }
        let filename = "cover-\(id.uuidString).jpg"
        let url = directory.appendingPathComponent(filename)
        return try await Task.detached(priority: .utility) {
            guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
            try data.write(to: url, options: .atomic)
            return filename
        }.value
    }

    nonisolated private static func metadata(for url: URL) async -> (title: String?, description: String?, author: String?, cover: UIImage?) {
        guard let metadata = await EPUBContainer.metadata(
            fileURL: url, coverMaxSize: CGSize(width: 240, height: 320)
        ) else { return (nil, nil, nil, nil) }
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = metadata.description?
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = metadata.authors.joined(separator: ", ")
        return (title?.isEmpty == false ? title : nil, description?.isEmpty == false ? description : nil, author.isEmpty ? nil : author, metadata.cover)
    }

    nonisolated private static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private static func safeFilename(_ filename: String, format: WebNovelFileFormat? = nil) -> String {
        let resolvedFormat = format ?? (URL(fileURLWithPath: filename).pathExtension.lowercased() == "txt" ? .txt : .epub)
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "wenku" : cleaned).\(resolvedFormat.fileExtension)"
    }
}

/// 导入的 TXT 与书库中已有书籍内容相同，因此移除新副本。
struct LocalLibraryDuplicateError: LocalizedError {
    let existingTitle: String
    let contentHash: String

    var errorDescription: String? {
        "书库中已存在相同内容的《\(existingTitle)》，未重复导入。"
    }
}

private enum WenkuLocalLibraryError: LocalizedError {
    case invalidEPUB
    case invalidTXT
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .invalidEPUB: "该文件不是有效的 EPUB 压缩包。"
        case .invalidTXT: "TXT 文件为空或编码无法识别，暂时无法导入。"
        case .unsupportedFile: "目前只支持导入 .epub 或 .txt 文件。"
        }
    }
}

