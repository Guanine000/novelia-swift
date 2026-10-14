import Combine
import Foundation

/// 社区页面持有的查询状态，依赖注入的 ForumService 管理分类、筛选与分页。
/// 请求代次阻止旧结果覆盖新查询；分类、筛选和页码更新保留现有重载行为。
@MainActor
final class ForumStore: ObservableObject {
    @Published private(set) var categories: [ForumCategory] = []
    @Published private(set) var posts: [ForumPost] = []
    @Published private(set) var total: Int64 = 0
    @Published private(set) var page = 0
    @Published private(set) var isLoadingCategories = false
    @Published private(set) var isLoadingPosts = false
    @Published private(set) var errorMessage: String?
    @Published var selectedCategory = ""
    @Published var query = ""
    @Published var selectedTagID: Int64?

    var filterTags: [ForumTag] {
        guard source == .all, selectedCategory == "novel" else { return [] }
        return categories.first(where: { $0.slug == "novel" })?.tags
            .filter { ["书单", "工具", "教程", "资源"].contains($0.name) }
            .sorted { $0.sortOrder < $1.sortOrder } ?? []
    }
    @Published var sort: ForumSort = .active
    @Published var source: ForumFeedSource = .all

    private let pageSize = 20
    private var requestGeneration = 0
    private let api: any ForumService

    init(api: any ForumService) {
        self.api = api
    }

    func selectCategory(_ slug: String) async {
        selectedTagID = nil
        selectedCategory = slug
        await loadPosts(page: 0)
    }

    func loadCategories() async {
        guard !isLoadingCategories else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }
        do {
            let fetched = try await api.categories().sorted { categoryOrder($0.slug) < categoryOrder($1.slug) }
            categories = fetched
            if !fetched.contains(where: { $0.slug == selectedCategory }) {
                selectedCategory = fetched.first?.slug ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPosts(page requestedPage: Int = 0) async {
        guard requestedPage >= 0 else { return }
        requestGeneration += 1
        let generation = requestGeneration
        isLoadingPosts = true
        errorMessage = nil
        defer { if generation == requestGeneration { isLoadingPosts = false } }
        do {
            let result = try await api.posts(
                page: requestedPage,
                pageSize: pageSize,
                category: selectedCategory,
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                sort: sort,
                tagID: filterTags.contains(where: { $0.id == selectedTagID }) ? selectedTagID : nil,
                source: source
            )
            guard generation == requestGeneration else { return }
            posts = result.items
            total = result.total
            page = requestedPage
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        if categories.isEmpty { await loadCategories() }
        await loadPosts(page: 0)
    }

    func clearError() {
        errorMessage = nil
    }

    func selectSource(_ value: ForumFeedSource) async {
        source = value
        selectedTagID = nil
        await loadPosts(page: 0)
    }

    private func categoryOrder(_ slug: String) -> Int {
        switch slug {
        case "announcements": 0
        case "novel": 1
        case "feedback": 2
        default: 3
        }
    }
}

