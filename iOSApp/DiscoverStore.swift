import Combine
import Foundation

@MainActor
final class DiscoverStore: ObservableObject {
    @Published private(set) var novels: [Novel] = []
    @Published private(set) var wenkuNovels: [WenkuNovelOutline] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadMoreError: String?

    private let api = NoveliaAPIClient()
    private let pageSize = 20
    private var nextPage = 1
    private var activeQuery = ""
    private var activeExactTag = false
    private var requestGeneration = 0

    func search(query: String, exactTag: Bool = false) async {
        requestGeneration += 1
        let generation = requestGeneration
        activeQuery = query
        activeExactTag = exactTag
        nextPage = 1
        novels = []
        wenkuNovels = []
        hasMore = false
        isLoadingMore = false
        loadMoreError = nil
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration { isLoading = false }
        }

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            try Task.checkCancellation()
            let fetched = try await api.searchNovels(query: query, page: 1, exactTag: exactTag)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            novels = fetched
            nextPage = 2
            hasMore = fetched.count == pageSize
            if fetched.isEmpty,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 网络小说书源只按片段匹配标题/关键词，整本书名或中文译名常常搜不到；
                // 此时再查一次文库（中文译本）作为兜底，用户可以从文库详情页跳回网络小说。
                let wenkuPage = try? await api.searchWenku(query: query, page: 0, pageSize: 12, level: 0)
                guard generation == requestGeneration else { return }
                wenkuNovels = wenkuPage?.novels ?? []
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            novels = []
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore,
              !isLoading,
              !isLoadingMore else { return }

        let generation = requestGeneration
        let page = nextPage
        isLoadingMore = true
        loadMoreError = nil
        defer {
            if generation == requestGeneration { isLoadingMore = false }
        }

        do {
            let fetched = try await api.searchNovels(query: activeQuery, page: page, exactTag: activeExactTag)
            guard generation == requestGeneration else { return }
            let knownIDs = Set(novels.map(\.id))
            novels.append(contentsOf: fetched.filter { !knownIDs.contains($0.id) })
            nextPage = page + 1
            hasMore = fetched.count == pageSize
        } catch {
            guard generation == requestGeneration else { return }
            loadMoreError = error.localizedDescription
        }
    }
}

@MainActor
final class RankingStore: ObservableObject {
    @Published private(set) var novels: [Novel] = []
    @Published private(set) var pageCount = 1
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = NoveliaAPIClient()
    private var requestGeneration = 0

    func load(page: Int) async {
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil
        novels = []
        defer {
            if generation == requestGeneration { isLoading = false }
        }

        do {
            let result = try await api.siteRankedNovels(page: page)
            guard generation == requestGeneration else { return }
            novels = result.novels
            pageCount = result.pageCount
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }
}
