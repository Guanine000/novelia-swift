import Combine
import Foundation

@MainActor
final class ReadingHistoryStore: ObservableObject {
    @Published private(set) var items: [NoveliaCloudReadingHistoryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private var activeAccount: String?
    private var refreshGeneration = 0
    private var nextPage = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func refresh(account: String?) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        activeAccount = account
        errorMessage = nil

        guard let account, !account.isEmpty else {
            items = []
            isLoading = false
            isLoadingMore = false
            canLoadMore = false
            nextPage = 0
            return
        }

        items = cachedItems(for: account)
        isLoadingMore = false
        canLoadMore = false
        nextPage = 0
        isLoading = true
        defer {
            if generation == refreshGeneration { isLoading = false }
        }

        do {
            let api = try apiClient(for: account)
            let fetched = try await api.cloudReadingHistory(page: 0)
            guard generation == refreshGeneration, activeAccount == account else { return }
            items = deduplicated(fetched)
            nextPage = 1
            canLoadMore = fetched.count == 20
            saveCache(items, for: account)
        } catch {
            guard generation == refreshGeneration, activeAccount == account else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(account: String?, retry: Bool = false) async {
        guard let account, account == activeAccount, canLoadMore, !isLoading, !isLoadingMore else { return }
        guard errorMessage == nil || retry else { return }
        let generation = refreshGeneration
        let page = nextPage
        isLoadingMore = true
        errorMessage = nil
        defer {
            if generation == refreshGeneration { isLoadingMore = false }
        }

        do {
            let fetched = try await apiClient(for: account).cloudReadingHistory(page: page)
            guard generation == refreshGeneration, activeAccount == account else { return }
            isLoadingMore = false
            items = deduplicated(items + fetched)
            nextPage += 1
            canLoadMore = fetched.count == 20
            saveCache(items, for: account)
        } catch {
            guard generation == refreshGeneration, activeAccount == account else { return }
            errorMessage = error.localizedDescription
        }
    }

    func recordRead(novel: Novel, chapterId: String, account: String?) async {
        guard let account, !account.isEmpty,
              let providerId = novel.providerId, let novelId = novel.novelId,
              !chapterId.isEmpty else { return }

        do {
            try await apiClient(for: account).updateWebReadingHistory(
                providerId: providerId,
                novelId: novelId,
                chapterId: chapterId
            )
            let item = NoveliaCloudReadingHistoryItem(
                novel: novel,
                lastReadAt: Int64(Date().timeIntervalSince1970)
            )
            let updatedItems = deduplicated([item] + cachedItems(for: account))
            saveCache(updatedItems, for: account)
            if activeAccount == account { items = updatedItems }
        } catch {
            guard activeAccount == account else { return }
            errorMessage = error.localizedDescription
        }
    }

    func continuation(for item: NoveliaCloudReadingHistoryItem, account: String) async throws -> CloudReadingContinuation {
        guard let providerId = item.novel.providerId, let novelId = item.novel.novelId else {
            throw NoveliaReadingHistoryError.unsupportedNovel
        }
        let detail = try await apiClient(for: account).novelForContinuation(providerId: providerId, novelId: novelId)
        guard !detail.novel.chapters.isEmpty else { throw NoveliaReadingHistoryError.noChapters }
        let chapterIndex = detail.lastReadChapterID.flatMap { chapterID in
            detail.novel.chapters.firstIndex { $0.id == chapterID }
        }
        return CloudReadingContinuation(
            novel: detail.novel,
            chapterIndex: chapterIndex ?? 0,
            didResolveCloudPosition: chapterIndex != nil
        )
    }

    private func apiClient(for account: String) throws -> NoveliaAPIClient {
        guard let token = NoveliaSessionTokenVault.read(), NoveliaSessionRenewal.claims(token)?.subject == account else {
            throw NoveliaReadingHistoryError.loginRequired
        }
        return NoveliaAPIClient()
    }

    private func cacheKey(for account: String) -> String { "cloudReadingHistory.v1.\(account)" }

    private func cachedItems(for account: String) -> [NoveliaCloudReadingHistoryItem] {
        guard let data = defaults.data(forKey: cacheKey(for: account)),
              let saved = try? JSONDecoder().decode([NoveliaCloudReadingHistoryItem].self, from: data) else { return [] }
        return saved
    }

    private func saveCache(_ items: [NoveliaCloudReadingHistoryItem], for account: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: cacheKey(for: account))
    }

    private func deduplicated(_ items: [NoveliaCloudReadingHistoryItem]) -> [NoveliaCloudReadingHistoryItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func username(from token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              let expiration = object["exp"] as? NSNumber,
              expiration.doubleValue > Date().timeIntervalSince1970 else { return nil }
        return subject
    }
}

struct CloudReadingContinuation: Identifiable, Hashable {
    let novel: Novel
    let chapterIndex: Int
    let didResolveCloudPosition: Bool
    var id: String { novel.id }
}

private enum NoveliaReadingHistoryError: LocalizedError {
    case loginRequired
    case unsupportedNovel
    case noChapters

    var errorDescription: String? {
        switch self {
        case .loginRequired: "请重新登录 Novelia 账号后再获取网页阅读历史。"
        case .unsupportedNovel: "无法识别这条阅读记录对应的网页作品。"
        case .noChapters: "网页端没有返回这部作品的章节目录，暂时无法继续阅读。"
        }
    }
}
