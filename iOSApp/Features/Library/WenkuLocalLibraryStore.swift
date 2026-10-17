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
    private let indexWriter = LocalLibraryIndexWriter()
    private var isRefreshingMetadata = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = applicationSupport.appendingPathComponent("WenkuEPUB", isDirectory: true)
        indexURL = directory.appendingPathComponent("library.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([LocalWenkuEPUB].self, from: data) {
            books = LibraryOrganizer.uniqueRecords(
                saved.filter { fileManager.fileExists(atPath: directory.appendingPathComponent($0.filename).path) },
                id: { $0.id }, date: { $0.addedAt })
        }
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

    func restoreFromSync(_ book: LocalWenkuEPUB, files: [String: URL]) throws {
        guard !books.contains(where: { $0.id == book.id }) else { return }
        guard let source = files[book.filename] else { throw CocoaError(.fileReadNoSuchFile) }
        let destination = uniqueDestination(for: Self.safeFilename(book.filename))
        try fileManager.copyItem(at: source, to: destination)
        var restored = LocalWenkuEPUB(id: book.id, title: book.title,
                                  filename: destination.lastPathComponent, addedAt: book.addedAt,
                                  lastLocatorJSON: book.lastLocatorJSON,
                                  bookDescription: book.bookDescription, author: book.author,
                                  coverFilename: nil, metadataLoaded: book.metadataLoaded,
                                  fileFormat: book.fileFormat, sourceWebNovel: book.sourceWebNovel,
                                  metadataUpdatedAt: book.metadataUpdatedAt)
        do {
            if let coverName = book.coverFilename, let coverSource = files[coverName] {
                let coverDestination = directory.appendingPathComponent("cover-\(UUID().uuidString).jpg")
                try fileManager.copyItem(at: coverSource, to: coverDestination)
                restored.coverFilename = coverDestination.lastPathComponent
            }
            books.insert(restored, at: 0)
            try persistIndex()
        } catch {
            books.removeAll { $0.id == book.id }
            try? fileManager.removeItem(at: destination)
            if let cover = restored.coverFilename { try? fileManager.removeItem(at: directory.appendingPathComponent(cover)) }
            throw error
        }
    }

    func replaceFromSync(_ book: LocalWenkuEPUB, files: [String: URL]) throws {
        let previousBooks = books
        guard let old = previousBooks.first(where: { $0.id == book.id }),
              let source = files[book.filename] else { throw CocoaError(.fileReadNoSuchFile) }
        let destination = uniqueDestination(for: Self.safeFilename(book.filename))
        try fileManager.copyItem(at: source, to: destination)
        var replacement = LocalWenkuEPUB(id: book.id, title: book.title,
            filename: destination.lastPathComponent, addedAt: book.addedAt,
            lastLocatorJSON: book.lastLocatorJSON, bookDescription: book.bookDescription,
            author: book.author, coverFilename: nil, metadataLoaded: book.metadataLoaded,
            fileFormat: book.fileFormat, sourceWebNovel: book.sourceWebNovel,
            metadataUpdatedAt: book.metadataUpdatedAt)
        do {
            if let coverName = book.coverFilename, let coverSource = files[coverName] {
                let coverDestination = directory.appendingPathComponent("cover-\(UUID().uuidString).jpg")
                try fileManager.copyItem(at: coverSource, to: coverDestination)
                replacement.coverFilename = coverDestination.lastPathComponent
            }
            guard let index = books.firstIndex(where: { $0.id == book.id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            books[index] = replacement
            try persistIndex()
            try? fileManager.removeItem(at: fileURL(for: old))
            if let oldCover = coverURL(for: old) { try? fileManager.removeItem(at: oldCover) }
        } catch {
            books = previousBooks
            try? fileManager.removeItem(at: destination)
            if let cover = replacement.coverFilename { try? fileManager.removeItem(at: directory.appendingPathComponent(cover)) }
            throw error
        }
    }

    enum CoverChange {
        case keep, remove
        case replace(UIImage)
    }

    /// 修改书库显示的书名、作者、简介与封面。只改索引记录与封面文件，不改书籍文件，
    /// 内容哈希不变，阅读进度、书签与统计不受影响；修改时间随书籍同步给其他设备。
    func updateMetadata(id: UUID, title: String, author: String?, description: String?,
                        cover: CoverChange, now: Date = Date()) throws {
        guard let index = books.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let previous = books
        var book = books[index]
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { book.title = String(cleanTitle.prefix(200)) }
        book.author = Self.cleaned(author)
        book.bookDescription = Self.cleaned(description)
        book.metadataLoaded = true
        book.metadataUpdatedAt = now
        var newCover: String?
        switch cover {
        case .keep: break
        case .remove: book.coverFilename = nil
        case .replace(let image):
            newCover = try saveCover(image, id: UUID())
            book.coverFilename = newCover
        }
        books[index] = book
        do { try persistIndex() } catch {
            books = previous
            if let newCover { try? fileManager.removeItem(at: directory.appendingPathComponent(newCover)) }
            throw error
        }
        if book.coverFilename != previous[index].coverFilename, let old = previous[index].coverFilename {
            try? fileManager.removeItem(at: directory.appendingPathComponent(old))
        }
    }

    /// 其他设备修改过同一文件版本的信息（较新）：套用书名、作者、简介与封面。`cover` 为下载好的封面临时文件。
    func applySyncedMetadata(_ remote: LocalWenkuEPUB, cover: URL?) throws {
        guard let index = books.firstIndex(where: { $0.id == remote.id }) else { return }
        let previous = books
        var book = books[index]
        book.title = remote.title
        book.author = remote.author
        book.bookDescription = remote.bookDescription
        book.metadataLoaded = true
        book.metadataUpdatedAt = remote.metadataUpdatedAt
        var newCover: String?
        if remote.coverFilename == nil {
            book.coverFilename = nil
        } else if let cover {
            let name = "cover-\(UUID().uuidString).jpg"
            try fileManager.copyItem(at: cover, to: directory.appendingPathComponent(name))
            newCover = name
            book.coverFilename = name
        }
        books[index] = book
        do { try persistIndex() } catch {
            books = previous
            if let newCover { try? fileManager.removeItem(at: directory.appendingPathComponent(newCover)) }
            throw error
        }
        if book.coverFilename != previous[index].coverFilename, let old = previous[index].coverFilename {
            try? fileManager.removeItem(at: directory.appendingPathComponent(old))
        }
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
            books.insert(book, at: 0)
            do {
                try persistIndex()
            } catch {
                books.removeAll { $0.id == book.id }
                try? fileManager.removeItem(at: fileURL)
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
        let coverFilename = try? saveCover(metadata.cover, id: id)
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
        books.insert(book, at: 0)
        do {
            try persistIndex()
        } catch {
            books.removeAll { $0.id == book.id }
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }

    func importForMove(from source: URL, sourceBook: DownloadedWebNovel) async throws -> LocalWenkuEPUB {
        let format: WebNovelFileFormat = source.pathExtension.lowercased() == "txt" ? .txt : .epub
        let destination = uniqueDestination(for: Self.safeFilename(source.lastPathComponent, format: format))
        try fileManager.copyItem(at: source, to: destination)
        let metadata = format == .epub ? await Self.metadata(for: destination) : (title: nil, description: nil, author: nil, cover: nil)
        let id = UUID()
        let coverFilename = try? saveCover(metadata.cover, id: id)
        // 沿用原下载时间，使书库“导入时间”排序不因移动而改变。
        let book = LocalWenkuEPUB(id: id, title: metadata.title ?? sourceBook.novel.title,
            filename: destination.lastPathComponent, addedAt: sourceBook.downloadedAt,
            bookDescription: metadata.description, author: metadata.author ?? sourceBook.novel.author,
            coverFilename: coverFilename, metadataLoaded: true, fileFormat: format,
            sourceWebNovel: sourceBook)
        books.insert(book, at: 0)
        do { try persistIndex() } catch {
            books.removeAll { $0.id == id }
            try? fileManager.removeItem(at: destination)
            if let coverFilename { try? fileManager.removeItem(at: directory.appendingPathComponent(coverFilename)) }
            throw error
        }
        return book
    }

    func removeForMove(_ book: LocalWenkuEPUB) throws {
        let previous = books
        books.removeAll { $0.id == book.id }
        do { try persistIndex() } catch { books = previous; throw error }
        try? fileManager.removeItem(at: fileURL(for: book))
        if let cover = coverURL(for: book) { try? fileManager.removeItem(at: cover) }
    }

    /// 删除书籍文件、封面与索引记录。阅读位置按内容哈希保存，不在此删除，重新导入同一本书时可接着读。
    func remove(_ book: LocalWenkuEPUB) {
        try? fileManager.removeItem(at: fileURL(for: book))
        if let cover = coverFileURL(for: book) { try? fileManager.removeItem(at: cover) }
        books.removeAll { $0.id == book.id }
        try? persistIndex()
    }

    func refreshMissingMetadata() async {
        guard !isRefreshingMetadata else { return }
        let pending = books.filter { $0.metadataLoaded != true }
        // 打开元数据完整的书库时，不应编码或重写整个索引。
        guard !pending.isEmpty else { return }
        isRefreshingMetadata = true
        defer { isRefreshingMetadata = false }
        var changed = false
        for book in pending {
            if Task.isCancelled { break }
            let metadata = await Self.metadata(for: fileURL(for: book))
            if Task.isCancelled { break }
            let coverFilename = try? await saveCoverInBackground(metadata.cover, id: book.id)
            guard let currentIndex = books.firstIndex(where: { $0.id == book.id }),
                  books[currentIndex].metadataLoaded != true else { continue }
            var updated = books[currentIndex]
            if let title = metadata.title { updated.title = title }
            updated.bookDescription = metadata.description
            updated.author = metadata.author
            updated.coverFilename = coverFilename
            updated.metadataLoaded = true
            books[currentIndex] = updated
            changed = true
        }
        if changed { try? await persistIndexInBackground() }
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

    private func persistIndex() throws {
        try indexWriter.writeSync(books, to: indexURL)
    }

    private func persistIndexInBackground() async throws {
        try await indexWriter.write(books, to: indexURL)
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

    private func saveCover(_ image: UIImage?, id: UUID) throws -> String? {
        guard let image, let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        let filename = "cover-\(id.uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
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

