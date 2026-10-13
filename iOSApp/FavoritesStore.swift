import Combine
import Foundation

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var novels: [Novel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private var activeAccount: String?
    private var refreshGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func contains(_ novel: Novel) -> Bool {
        novels.contains { $0.id == novel.id }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func folderID(for novel: Novel) -> String? {
        novels.first { $0.id == novel.id }?.cloudFavoriteFolderID ?? novel.cloudFavoriteFolderID
    }

    func refresh(account: String?) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        activeAccount = account
        errorMessage = nil

        guard let account, !account.isEmpty else {
            novels = []
            isLoading = false
            return
        }

        novels = cachedNovels(for: account)
        isLoading = true
        defer {
            if generation == refreshGeneration { isLoading = false }
        }

        do {
            let api = try apiClient(for: account)
            var fetched: [Novel] = []
            let folders = try await api.cloudFavoriteFolders()
            // Android 客户端仅在有多个文件夹时开放聚合的“all”路由；
            // 只有一个文件夹的账户使用该文件夹的实际 ID。
            let folderIDs = folders.count > 1 ? ["all"] : folders.map(\.id)
            for folderID in folderIDs {
                for page in 0...100 {
                    let batch = try await api.cloudFavorites(folderId: folderID, page: page)
                    fetched.append(contentsOf: batch)
                    if batch.count < 20 { break }
                }
            }
            guard generation == refreshGeneration, activeAccount == account else { return }
            novels = deduplicated(fetched)
            saveCache(novels, for: account)
        } catch {
            guard generation == refreshGeneration, activeAccount == account else { return }
            errorMessage = error.localizedDescription
        }
    }

    func folders(account: String) async throws -> [NoveliaCloudFolder] {
        try await apiClient(for: account).cloudFavoriteFolders()
    }

    func add(_ novel: Novel, to folder: NoveliaCloudFolder, account: String) async throws {
        guard let providerId = novel.providerId, let novelId = novel.novelId else {
            throw NoveliaFavoritesError.unsupportedNovel
        }
        let api = try apiClient(for: account)
        try await api.addCloudFavorite(providerId: providerId, novelId: novelId, folderId: folder.id)
        guard activeAccount == account else { return }
        let saved = compact(novel, folderID: folder.id)
        novels.removeAll { $0.id == saved.id }
        novels.insert(saved, at: 0)
        saveCache(novels, for: account)
        errorMessage = nil
    }

    func remove(_ novel: Novel, account: String) async throws {
        guard let providerId = novel.providerId,
              let novelId = novel.novelId,
              let folderID = folderID(for: novel) else {
            throw NoveliaFavoritesError.favoriteFolderUnavailable
        }
        let api = try apiClient(for: account)
        try await api.removeCloudFavorite(providerId: providerId, novelId: novelId, folderId: folderID)
        guard activeAccount == account else { return }
        novels.removeAll { $0.id == novel.id }
        saveCache(novels, for: account)
        errorMessage = nil
    }

    /// 应用已登录小说详情返回的账户专属收藏状态。
    func updateStatus(from novel: Novel, account: String?) {
        guard let account, activeAccount == account else { return }
        guard let folderID = novel.cloudFavoriteFolderID else {
            novels.removeAll { $0.id == novel.id }
            saveCache(novels, for: account)
            return
        }
        let saved = compact(novel, folderID: folderID)
        novels.removeAll { $0.id == novel.id }
        novels.insert(saved, at: 0)
        saveCache(novels, for: account)
    }

    private func apiClient(for account: String) throws -> NoveliaAPIClient {
        guard let token = NoveliaSessionTokenVault.read(), NoveliaSessionRenewal.claims(token)?.subject == account else {
            throw NoveliaFavoritesError.loginRequired
        }
        return NoveliaAPIClient()
    }

    private func cacheKey(for account: String) -> String {
        "cloudFavorites.v1.\(account)"
    }

    private func cachedNovels(for account: String) -> [Novel] {
        guard let data = defaults.data(forKey: cacheKey(for: account)),
              let saved = try? JSONDecoder().decode([Novel].self, from: data) else { return [] }
        return saved
    }

    private func saveCache(_ novels: [Novel], for account: String) {
        guard let data = try? JSONEncoder().encode(novels.map {
            compact($0, folderID: $0.cloudFavoriteFolderID ?? "")
        }) else { return }
        defaults.set(data, forKey: cacheKey(for: account))
    }

    private func compact(_ novel: Novel, folderID: String) -> Novel {
        Novel(
            id: novel.id,
            title: novel.title,
            author: novel.author,
            summary: novel.summary,
            genres: novel.genres,
            chapters: novel.chapters.map {
                NovelChapter(id: $0.id, title: $0.title, originalText: "", translatedText: "")
            },
            accent: novel.accent,
            providerId: novel.providerId,
            novelId: novel.novelId,
            cloudFavoriteFolderID: folderID.isEmpty ? nil : folderID,
            translationChapterCounts: novel.translationChapterCounts,
            totalCharacters: novel.totalCharacters
        )
    }

    private func deduplicated(_ novels: [Novel]) -> [Novel] {
        var seen = Set<String>()
        return novels.filter { seen.insert($0.id).inserted }
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

private enum NoveliaFavoritesError: LocalizedError {
    case loginRequired
    case unsupportedNovel
    case favoriteFolderUnavailable

    var errorDescription: String? {
        switch self {
        case .loginRequired: "请先登录 Novelia 账号，再同步网页收藏。"
        case .unsupportedNovel: "该作品不支持加入 Novelia 网页收藏。"
        case .favoriteFolderUnavailable: "缺少云端收藏夹信息，请刷新网页收藏后重试。"
        }
    }
}
