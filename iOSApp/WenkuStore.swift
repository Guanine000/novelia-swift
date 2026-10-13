import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class WenkuStore: ObservableObject {
    @Published private(set) var novels: [WenkuNovelOutline] = []
    @Published private(set) var favorites: [WenkuNovelOutline] = []
    @Published private(set) var folders: [NoveliaCloudFolder] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var favoriteErrorMessage: String?

    private let api = NoveliaAPIClient()
    private let pageSize = 24
    private var nextPage = 0
    private var pageCount = 0
    private var query = ""
    private var searchGeneration = 0
    private var favoriteGeneration = 0

    func search(_ value: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        nextPage = 0
        pageCount = 0
        novels = []
        hasMore = false
        errorMessage = nil
        isLoading = true
        defer { if generation == searchGeneration { isLoading = false } }

        do {
            let result = try await api.searchWenku(query: query, page: 0, pageSize: pageSize)
            guard generation == searchGeneration else { return }
            novels = result.novels
            pageCount = result.pageCount
            nextPage = 1
            hasMore = nextPage < pageCount && !result.novels.isEmpty
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let generation = searchGeneration
        let page = nextPage
        isLoadingMore = true
        defer { if generation == searchGeneration { isLoadingMore = false } }
        do {
            let result = try await api.searchWenku(query: query, page: page, pageSize: pageSize)
            guard generation == searchGeneration else { return }
            let known = Set(novels.map(\.id))
            novels.append(contentsOf: result.novels.filter { !known.contains($0.id) })
            pageCount = result.pageCount
            nextPage = page + 1
            hasMore = nextPage < pageCount && !result.novels.isEmpty
            errorMessage = nil
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshFavorites(account: String?) async {
        favoriteGeneration += 1
        let generation = favoriteGeneration
        guard let account, !account.isEmpty else {
            folders = []
            favorites = []
            favoriteErrorMessage = nil
            return
        }
        favoriteErrorMessage = nil
        do {
            let availableFolders = try await api.cloudWenkuFavoriteFolders()
            var fetched: [WenkuNovelOutline] = []
            let folderIDs = availableFolders.count > 1 ? ["all"] : availableFolders.map(\.id)
            for folderID in folderIDs {
                for page in 0...100 {
                    let result = try await api.cloudWenkuFavorites(folderId: folderID, page: page, pageSize: pageSize)
                    fetched.append(contentsOf: result.novels)
                    if result.novels.count < pageSize { break }
                }
            }
            guard generation == favoriteGeneration else { return }
            folders = availableFolders
            var seen = Set<String>()
            favorites = fetched.filter { seen.insert($0.id).inserted }
        } catch {
            guard generation == favoriteGeneration else { return }
            favoriteErrorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(_ novel: WenkuNovelOutline, account: String) async throws {
        if novel.favored != nil || favorites.contains(where: { $0.id == novel.id }) {
            guard let folderID = novel.favored ?? favorites.first(where: { $0.id == novel.id })?.favored else {
                throw WenkuStoreError.favoriteFolderUnavailable
            }
            try await api.removeCloudWenkuFavorite(novelId: novel.id, folderId: folderID)
            favorites.removeAll { $0.id == novel.id }
        } else {
            guard let folder = folders.first else { throw WenkuStoreError.noFavoriteFolder }
            try await api.addCloudWenkuFavorite(novelId: novel.id, folderId: folder.id)
            favorites.insert(
                WenkuNovelOutline(id: novel.id, title: novel.title, titleZh: novel.titleZh, cover: novel.cover, favored: folder.id),
                at: 0
            )
        }
        novels = novels.map { item in
            guard item.id == novel.id else { return item }
            let folder = favorites.first(where: { $0.id == item.id })?.favored
            return WenkuNovelOutline(id: item.id, title: item.title, titleZh: item.titleZh, cover: item.cover, favored: folder)
        }
    }
}

private enum WenkuStoreError: LocalizedError {
    case favoriteFolderUnavailable
    case noFavoriteFolder

    var errorDescription: String? {
        switch self {
        case .favoriteFolderUnavailable: "找不到这本文库小说所在的收藏夹，请刷新后重试。"
        case .noFavoriteFolder: "账号没有可用的文库收藏夹。"
        }
    }
}

struct LocalWenkuEPUB: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let filename: String
    let addedAt: Date
    var lastLocatorJSON: String? = nil
    var bookDescription: String? = nil
    var author: String? = nil
    var coverFilename: String? = nil
    var metadataLoaded: Bool? = nil
    var fileFormat: WebNovelFileFormat? = nil
    var sourceWebNovel: DownloadedWebNovel? = nil
    var resolvedFileFormat: WebNovelFileFormat {
        fileFormat ?? (filename.lowercased().hasSuffix(".txt") ? .txt : .epub)
    }
}

@MainActor
final class WenkuLocalLibraryStore: ObservableObject {
    @Published private(set) var books: [LocalWenkuEPUB] = []
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = applicationSupport.appendingPathComponent("WenkuEPUB", isDirectory: true)
        indexURL = directory.appendingPathComponent("library.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([LocalWenkuEPUB].self, from: data) {
            books = saved.filter { fileManager.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
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
                                  coverFilename: nil, metadataLoaded: book.metadataLoaded)
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
            fileFormat: book.fileFormat, sourceWebNovel: book.sourceWebNovel)
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

    func coverURL(for book: LocalWenkuEPUB) -> URL? {
        guard let coverFilename = book.coverFilename else { return nil }
        let url = directory.appendingPathComponent(coverFilename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func downloadDestination(for filename: String) -> URL {
        uniqueDestination(for: Self.safeFilename(filename))
    }

    /// A library TXT with the same content, compared by SHA-256 (memoised per file).
    private func existingTXT(withContentHash hash: String, excluding newFile: URL) async -> LocalWenkuEPUB? {
        for book in books where book.resolvedFileFormat == .txt {
            let url = directory.appendingPathComponent(book.filename)
            guard url.standardizedFileURL != newFile.standardizedFileURL,
                  fileManager.fileExists(atPath: url.path),
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
            // Decoded once here; the cached text makes the first open parse-only.
            let newHash: String
            do {
                newHash = try await TXTBookCache.shared.validateDecodable(at: fileURL, source: source, trace: trace)
            } catch {
                try? fileManager.removeItem(at: fileURL)
                throw WenkuLocalLibraryError.invalidTXT
            }
            if let existing = await existingTXT(withContentHash: newHash, excluding: fileURL) {
                try? fileManager.removeItem(at: fileURL)
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

        let metadata = await Self.metadata(for: fileURL)
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
        let book = LocalWenkuEPUB(id: id, title: metadata.title ?? sourceBook.novel.title,
            filename: destination.lastPathComponent, addedAt: Date(),
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

    func save(data: Data, title: String, filename: String) async throws {
        guard data.starts(with: [0x50, 0x4b]) else { throw WenkuLocalLibraryError.invalidEPUB }
        let safeName = Self.safeFilename(filename)
        let destination = uniqueDestination(for: safeName)
        try data.write(to: destination, options: .atomic)
        let metadata = await Self.metadata(for: destination)
        let id = UUID()
        let coverFilename = try? saveCover(metadata.cover, id: id)
        books.insert(
            LocalWenkuEPUB(
                id: id,
                title: metadata.title ?? title,
                filename: destination.lastPathComponent,
                addedAt: Date(),
                bookDescription: metadata.description,
                author: metadata.author,
                coverFilename: coverFilename,
                metadataLoaded: true
            ), at: 0
        )
        do { try persistIndex() } catch {
            books.removeAll { $0.id == id }
            try? fileManager.removeItem(at: destination)
            if let coverFilename { try? fileManager.removeItem(at: directory.appendingPathComponent(coverFilename)) }
            throw error
        }
    }

    func remove(_ book: LocalWenkuEPUB) {
        try? fileManager.removeItem(at: fileURL(for: book))
        books.removeAll { $0.id == book.id }
        try? persistIndex()
    }

    func refreshMissingMetadata() async {
        for index in books.indices where books[index].metadataLoaded != true {
            let bookID = books[index].id
            let url = fileURL(for: books[index])
            let metadata = await Self.metadata(for: url)
            guard let currentIndex = books.firstIndex(where: { $0.id == bookID }) else { continue }
            if let title = metadata.title { books[currentIndex].title = title }
            books[currentIndex].bookDescription = metadata.description
            books[currentIndex].author = metadata.author
            books[currentIndex].coverFilename = try? saveCover(metadata.cover, id: bookID)
            books[currentIndex].metadataLoaded = true
        }
        try? persistIndex()
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
        let data = try JSONEncoder().encode(books)
        try data.write(to: indexURL, options: .atomic)
    }

    private func saveCover(_ image: UIImage?, id: UUID) throws -> String? {
        guard let image, let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        let filename = "cover-\(id.uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    private static func metadata(for url: URL) async -> (title: String?, description: String?, author: String?, cover: UIImage?) {
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

    private static func safeFilename(_ filename: String, format: WebNovelFileFormat? = nil) -> String {
        let resolvedFormat = format ?? (URL(fileURLWithPath: filename).pathExtension.lowercased() == "txt" ? .txt : .epub)
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "wenku" : cleaned).\(resolvedFormat.fileExtension)"
    }
}

/// The imported TXT has the same content as a book already in the library; the new copy is removed.
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

struct WebNovelDownloadProgress: Equatable {
    let completed: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

enum WebNovelFileFormat: String, Codable, CaseIterable, Identifiable {
    case epub
    case txt

    var id: String { rawValue }
    var title: String { self == .epub ? "EPUB" : "TXT" }
    var fileExtension: String { rawValue }
}

struct DownloadedWebNovel: Codable, Identifiable, Hashable {
    let novel: Novel
    let fileFilename: String
    let downloadedAt: Date
    let translationSource: NovelTranslationSource?
    /// Optional so indexes created before language-mode selection remain readable.
    let downloadMode: WebNovelDownloadMode?
    /// Optional so the library index created by earlier app versions remains readable.
    let fileFormat: WebNovelFileFormat?

    var id: String { novel.id }
    var resolvedFileFormat: WebNovelFileFormat {
        fileFormat ?? (fileFilename.lowercased().hasSuffix(".txt") ? .txt : .epub)
    }
    var resolvedDownloadMode: WebNovelDownloadMode {
        downloadMode ?? (translationSource == nil ? .original : .translated)
    }
}

@MainActor
final class WebNovelDownloadStore: ObservableObject {
    @Published private(set) var books: [DownloadedWebNovel] = []
    @Published private(set) var progress: [String: WebNovelDownloadProgress] = [:]
    @Published private(set) var errors: [String: String] = [:]

    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL
    private let api = NoveliaAPIClient()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = applicationSupport.appendingPathComponent("WebNovelDownloads", isDirectory: true)
        indexURL = directory.appendingPathComponent("library.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([DownloadedWebNovel].self, from: data) {
            books = saved.filter { fileManager.fileExists(atPath: directory.appendingPathComponent($0.fileFilename).path) }
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
        let destination = uniqueDestination(for: source.lastPathComponent)
        try fileManager.copyItem(at: source, to: destination)
        let novel = book.sourceWebNovel?.novel ?? Novel(id: "local-\(book.id.uuidString)", title: book.title,
            author: book.author ?? "", summary: book.bookDescription ?? "",
            genres: [], chapters: [], accent: .plum)
        let record = DownloadedWebNovel(novel: novel,
            fileFilename: destination.lastPathComponent, downloadedAt: book.sourceWebNovel?.downloadedAt ?? Date(),
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

    func restoreFromSync(_ book: DownloadedWebNovel, files: [String: URL]) throws {
        guard !books.contains(where: { $0.id == book.id }) else { return }
        guard let source = files[book.fileFilename] else { throw CocoaError(.fileReadNoSuchFile) }
        var copied: [URL] = []
        do {
            let destination = uniqueDestination(for: book.fileFilename)
            try fileManager.copyItem(at: source, to: destination)
            copied.append(destination)
            let restored = DownloadedWebNovel(
                novel: book.novel,
                fileFilename: destination.lastPathComponent,
                downloadedAt: book.downloadedAt,
                translationSource: book.translationSource,
                downloadMode: book.downloadMode,
                fileFormat: book.fileFormat
            )
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

    func replaceFromSync(_ book: DownloadedWebNovel, files: [String: URL]) throws {
        let previousBooks = books
        guard let old = previousBooks.first(where: { $0.id == book.id }),
              let source = files[book.fileFilename] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var copied: [URL] = []
        do {
            let destination = uniqueDestination(for: book.fileFilename)
            try fileManager.copyItem(at: source, to: destination)
            copied.append(destination)
            let replacement = DownloadedWebNovel(novel: book.novel,
                fileFilename: destination.lastPathComponent, downloadedAt: book.downloadedAt,
                translationSource: book.translationSource, downloadMode: book.downloadMode,
                fileFormat: book.fileFormat)
            guard let index = books.firstIndex(where: { $0.id == book.id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            books[index] = replacement
            try persistIndex()
            removeStoredFile(for: old)
        } catch {
            books = previousBooks
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
