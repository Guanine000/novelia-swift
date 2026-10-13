import Combine
import Foundation

@MainActor
final class DiscoverStore: ObservableObject {
    @Published private(set) var novels: [Novel] = []
    @Published private(set) var wenkuNovels: [WenkuNovelOutline] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 当前页码，从 1 开始；与网页端一样按页浏览。
    @Published private(set) var page = 1
    @Published private(set) var pageCount = 1

    private let api = NoveliaAPIClient()
    private var activeQuery: String?
    private var activeExactTag = false
    private var requestGeneration = 0
    /// 最近一次成功加载的查询；从详情页返回时 `.task` 会重新触发，命中则不清空列表，保留滚动位置。
    private var loadedKey: String?

    /// 供 `.task` 调用：同一查询已经成功加载过时直接返回，否则从第 1 页开始搜索。
    func searchIfNeeded(query: String, exactTag: Bool = false) async {
        guard loadedKey != Self.key(query, exactTag) else { return }
        await search(query: query, exactTag: exactTag)
    }

    func search(query: String, exactTag: Bool = false) async {
        await load(query: query, exactTag: exactTag, page: 1)
    }

    /// 翻到当前查询的指定页；出错后重试也走这里。
    func goTo(page target: Int) async {
        await load(query: activeQuery ?? "", exactTag: activeExactTag, page: target)
    }

    private static func key(_ query: String, _ exactTag: Bool) -> String {
        "\(exactTag ? 1 : 0)|\(query)"
    }

    private func load(query: String, exactTag: Bool, page target: Int) async {
        requestGeneration += 1
        let generation = requestGeneration
        // 只有输入搜索词时防抖；翻页立即请求。
        let debounce = query != activeQuery || exactTag != activeExactTag
        loadedKey = nil
        activeQuery = query
        activeExactTag = exactTag
        page = max(1, target)
        if debounce { pageCount = 1 }
        novels = []
        wenkuNovels = []
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration { isLoading = false }
        }

        do {
            if debounce {
                try await Task.sleep(nanoseconds: 350_000_000)
                try Task.checkCancellation()
            }
            let result = try await api.searchNovels(query: query, page: page, exactTag: exactTag)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            novels = result.novels
            pageCount = max(1, result.pageCount)
            loadedKey = Self.key(query, exactTag)
            if page == 1, result.novels.isEmpty,
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
}

@MainActor
final class RankingStore: ObservableObject {
    @Published private(set) var novels: [Novel] = []
    @Published private(set) var pageCount = 1
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = NoveliaAPIClient()
    private var requestGeneration = 0
    private var loadedPage: Int?

    /// 供 `.task` 调用：从详情页返回时不重新加载已显示的同一页。
    func loadIfNeeded(page: Int) async {
        guard loadedPage != page else { return }
        await load(page: page)
    }

    func load(page: Int) async {
        requestGeneration += 1
        loadedPage = nil
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
            loadedPage = page
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }
}
