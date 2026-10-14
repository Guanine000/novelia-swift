import Combine
import Foundation

/// Root 持有的远端文库查询与收藏状态，依赖文库和收藏服务，不管理本地文件。
/// 保留界面从 1 开始、API 从 0 开始的页码转换，以及过期搜索结果丢弃规则。
@MainActor
final class WenkuStore: ObservableObject {
    @Published private(set) var novels: [WenkuNovelOutline] = []
    @Published private(set) var favorites: [WenkuNovelOutline] = []
    @Published private(set) var folders: [NoveliaCloudFolder] = []
    @Published private(set) var isLoading = false
    /// 当前页码，从 1 开始（API 从 0 开始）；与网页端一样按页浏览。
    @Published private(set) var page = 1
    @Published private(set) var pageCount = 1
    @Published private(set) var errorMessage: String?
    @Published private(set) var favoriteErrorMessage: String?

    private let api: any WenkuCatalogService
    private let favoritesAPI: any FavoritesService

    init(api: any WenkuCatalogService, favorites: any FavoritesService) {
        self.api = api
        self.favoritesAPI = favorites
    }
    private let pageSize = 24
    private var query = ""
    private var searchGeneration = 0
    private var favoriteGeneration = 0
    /// 最近一次成功加载的查询；从详情页返回时 `.task` 会重新触发，命中则不清空列表，保留滚动位置。
    private var loadedQuery: String?

    func hasLoaded(_ value: String) -> Bool {
        loadedQuery == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != query { pageCount = 1 }
        query = trimmed
        await goTo(page: 1)
    }

    /// 翻到当前查询的指定页；出错后重试也走这里。
    func goTo(page target: Int) async {
        searchGeneration += 1
        let generation = searchGeneration
        loadedQuery = nil
        page = max(1, target)
        novels = []
        errorMessage = nil
        isLoading = true
        defer { if generation == searchGeneration { isLoading = false } }

        do {
            let result = try await api.searchWenku(query: query, page: page - 1, pageSize: pageSize, level: 0)
            guard generation == searchGeneration else { return }
            novels = result.novels
            pageCount = max(1, result.pageCount)
            loadedQuery = query
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
            let availableFolders = try await favoritesAPI.cloudWenkuFavoriteFolders()
            var fetched: [WenkuNovelOutline] = []
            let folderIDs = availableFolders.count > 1 ? ["all"] : availableFolders.map(\.id)
            for folderID in folderIDs {
                for page in 0...100 {
                    let result = try await favoritesAPI.cloudWenkuFavorites(folderId: folderID, page: page, pageSize: pageSize)
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
            try await favoritesAPI.removeCloudWenkuFavorite(novelId: novel.id, folderId: folderID)
            favorites.removeAll { $0.id == novel.id }
        } else {
            guard let folder = folders.first else { throw WenkuStoreError.noFavoriteFolder }
            try await favoritesAPI.addCloudWenkuFavorite(novelId: novel.id, folderId: folder.id)
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

