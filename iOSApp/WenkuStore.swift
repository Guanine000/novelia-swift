import Combine
import Foundation
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
    let title: String
    let filename: String
    let addedAt: Date
    var lastLocatorJSON: String? = nil
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

    func downloadDestination(for filename: String) -> URL {
        uniqueDestination(for: Self.safeFilename(filename))
    }

    func registerDownloadedFile(at fileURL: URL, title: String) throws {
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

        let book = LocalWenkuEPUB(
            id: UUID(),
            title: title,
            filename: fileURL.lastPathComponent,
            addedAt: Date()
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

    func save(data: Data, title: String, filename: String) throws {
        guard data.starts(with: [0x50, 0x4b]) else { throw WenkuLocalLibraryError.invalidEPUB }
        let safeName = Self.safeFilename(filename)
        let destination = uniqueDestination(for: safeName)
        try data.write(to: destination, options: .atomic)
        books.insert(LocalWenkuEPUB(id: UUID(), title: title, filename: destination.lastPathComponent, addedAt: Date()), at: 0)
        try persistIndex()
    }

    func importEPUB(from source: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "epub" else { throw WenkuLocalLibraryError.unsupportedFile }
        let data = try Data(contentsOf: source)
        let title = source.deletingPathExtension().lastPathComponent
        try save(data: data, title: title, filename: source.lastPathComponent)
    }

    func remove(_ book: LocalWenkuEPUB) {
        try? fileManager.removeItem(at: fileURL(for: book))
        books.removeAll { $0.id == book.id }
        try? persistIndex()
    }

    func updateReadingLocation(bookID: UUID, locatorJSON: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].lastLocatorJSON = locatorJSON
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
