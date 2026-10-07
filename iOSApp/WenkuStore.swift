import Combine
import Foundation
import ReadiumShared
import ReadiumStreamer
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

    func coverURL(for book: LocalWenkuEPUB) -> URL? {
        guard let coverFilename = book.coverFilename else { return nil }
        let url = directory.appendingPathComponent(coverFilename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func downloadDestination(for filename: String) -> URL {
        uniqueDestination(for: Self.safeFilename(filename))
    }

    func registerDownloadedFile(at fileURL: URL, title: String) async throws {
        guard fileURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw WenkuLocalLibraryError.invalidEPUB
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
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
            metadataLoaded: true
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
            candidate = directory.appendingPathComponent("\(base)-\(suffix).epub")
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
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(parser: DefaultPublicationParser(httpClient: httpClient, assetRetriever: assetRetriever, pdfFactory: DefaultPDFDocumentFactory()))
        guard let fileURL = FileURL(url: url),
              let asset = try? await assetRetriever.retrieve(url: fileURL).get(),
              let publication = try? await opener.open(asset: asset, allowUserInteraction: false).get(),
              publication.conforms(to: .epub) else { return (nil, nil, nil, nil) }
        let metadata = publication.metadata
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = metadata.description?
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = metadata.authors.compactMap(\.name).joined(separator: ", ")
        let cover = try? await publication.coverFitting(maxSize: CGSize(width: 240, height: 320)).get()
        return (title?.isEmpty == false ? title : nil, description?.isEmpty == false ? description : nil, author.isEmpty ? nil : author, cover ?? nil)
    }

    private static func safeFilename(_ filename: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "wenku" : cleaned).epub"
    }
}

private enum WenkuLocalLibraryError: LocalizedError {
    case invalidEPUB
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .invalidEPUB: "该文件不是有效的 EPUB 压缩包。"
        case .unsupportedFile: "目前只支持导入 .epub 文件。"
        }
    }
}

struct WebNovelDownloadProgress: Equatable {
    let completed: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

struct DownloadedWebNovel: Codable, Identifiable, Hashable {
    let novel: Novel
    /// Kept for migration of chapter-by-chapter downloads created by older app versions.
    let chapterDataFilename: String?
    let fileFilename: String?
    let downloadedAt: Date
    let translationSource: NovelTranslationSource?

    var id: String { novel.id }
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
            books = saved.filter { book in
                [book.chapterDataFilename, book.fileFilename]
                    .compactMap { $0 }
                    .contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
            }
        }
    }

    func isDownloaded(_ novelID: String) -> Bool {
        books.contains { $0.id == novelID }
    }

    func chapters(for book: DownloadedWebNovel) async throws -> [String: NovelChapter] {
        guard let chapterDataFilename = book.chapterDataFilename else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let url = directory.appendingPathComponent(chapterDataFilename)
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            let chapters = try JSONDecoder().decode([NovelChapter].self, from: data)
            return Dictionary(chapters.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        }.value
    }

    func download(_ novel: Novel, translationSource: NovelTranslationSource?) async {
        guard novel.isRemote,
              let providerId = novel.providerId,
              let novelId = novel.novelId,
              progress[novel.id] == nil else { return }

        errors[novel.id] = nil
        progress[novel.id] = WebNovelDownloadProgress(completed: 0, total: 1)

        do {
            try Task.checkCancellation()
            let filename = Self.websiteDownloadFilename(title: novel.title, translationSource: translationSource)
            let dataURL = uniqueDestination(for: filename)
            try await api.downloadWebNovelEPUB(
                to: dataURL,
                providerId: providerId,
                novelId: novelId,
                title: novel.title,
                translationSource: translationSource
            )
            progress[novel.id] = WebNovelDownloadProgress(completed: 1, total: 1)

            let record = DownloadedWebNovel(
                novel: novel,
                chapterDataFilename: nil,
                fileFilename: dataURL.lastPathComponent,
                downloadedAt: Date(),
                translationSource: translationSource
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

    func fileURL(for book: DownloadedWebNovel) -> URL? {
        book.fileFilename.map { directory.appendingPathComponent($0) }
    }

    private func removeStoredFile(for book: DownloadedWebNovel) {
        for filename in [book.chapterDataFilename, book.fileFilename].compactMap({ $0 }) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(filename))
        }
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

    private static func websiteDownloadFilename(title: String, translationSource: NovelTranslationSource?) -> String {
        let safeTitle = title.replacingOccurrences(of: "[\\/|\\\\:*?\"<>]", with: "", options: .regularExpression)
        guard let translationSource else { return "jp.\(safeTitle).epub" }
        return "zh.Y\(translationSource.rawValue.prefix(1)).\(safeTitle).epub"
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(books)
        try data.write(to: indexURL, options: .atomic)
    }

}
