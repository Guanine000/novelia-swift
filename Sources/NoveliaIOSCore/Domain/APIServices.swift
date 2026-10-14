// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Consumers depend on these interfaces. Existing models and pagination
// conventions are preserved; request encoding stays in the API adapters.

public protocol NovelCatalogService: Sendable {
    func searchNovels(query: String, page: Int, exactTag: Bool) async throws -> NoveliaRankPage
    func siteRankedNovels(page: Int) async throws -> NoveliaRankPage
    func novel(providerId: String, novelId: String) async throws -> Novel
}

public protocol NovelContentService: Sendable {
    func chapter(providerId: String, novelId: String, chapterId: String) async throws -> NovelChapter
}

public protocol WenkuCatalogService: Sendable {
    func searchWenku(query: String, page: Int, pageSize: Int, level: Int) async throws -> WenkuNovelPage
    func wenkuNovel(id: String) async throws -> WenkuNovelDetail
}

public protocol FavoritesService: Sendable {
    func cloudFavoriteFolders() async throws -> [NoveliaCloudFolder]
    func cloudWenkuFavoriteFolders() async throws -> [NoveliaCloudFolder]
    func cloudWenkuFavorites(folderId: String, page: Int, pageSize: Int) async throws -> WenkuNovelPage
    func addCloudWenkuFavorite(novelId: String, folderId: String) async throws
    func removeCloudWenkuFavorite(novelId: String, folderId: String) async throws
    func cloudFavorites(folderId: String, page: Int) async throws -> [Novel]
    func addCloudFavorite(providerId: String, novelId: String, folderId: String) async throws
    func removeCloudFavorite(providerId: String, novelId: String, folderId: String) async throws
}

public protocol ReadingHistoryService: Sendable {
    func cloudReadingHistory(page: Int) async throws -> [NoveliaCloudReadingHistoryItem]
    func updateWebReadingHistory(providerId: String, novelId: String, chapterId: String) async throws
    func novelForContinuation(providerId: String, novelId: String) async throws -> NoveliaCloudNovelDetail
}

public protocol NovelDownloadService: Sendable {
    func downloadWebNovelEPUB(
        to destinationURL: URL,
        providerId: String,
        novelId: String,
        title: String,
        translationSource: NovelTranslationSource?,
        mode: WebNovelDownloadMode
    ) async throws
    func downloadWenkuEPUB(
        to destinationURL: URL,
        novelId: String,
        volumeId: String,
        mode: WenkuEPUBMode,
        translator: WenkuTranslator,
        filenameTranslators: [WenkuTranslator]?,
        filenameAuthors: [String],
        translationsMode: WenkuTranslationsMode
    ) async throws
}

public protocol BookCommentsService: Sendable {
    func novelComments(subjectKey: String, page: Int, pageSize: Int) async throws -> NoveliaCommentPage
    func novelCommentReplies(subjectKey: String, rootID: Int, page: Int, pageSize: Int) async throws -> NoveliaCommentPage
    func postNovelComment(subjectKey: String, content: String, rootID: Int?) async throws -> NoveliaComment
}

public protocol ForumService: Sendable {
    func categories() async throws -> [ForumCategory]
    func posts(
        page: Int,
        pageSize: Int,
        category: String,
        query: String,
        sort: ForumSort,
        tagID: Int64?,
        source: ForumFeedSource
    ) async throws -> ForumPage<ForumPost>
    func post(id: Int64) async throws -> ForumPost
    func comments(postID: Int64, page: Int, pageSize: Int) async throws -> ForumPage<ForumComment>
    func replies(postID: Int64, rootID: Int64, page: Int, pageSize: Int) async throws -> ForumPage<ForumComment>
    func createComment(postID: Int64, content: String, rootID: Int64?) async throws -> ForumComment
    func updateComment(postID: Int64, commentID: Int64, content: String) async throws -> ForumComment
    func createPost(categoryID: Int64, title: String, content: String, tagIDs: [Int64]) async throws -> ForumPost
    func updatePost(id: Int64, categoryID: Int64, title: String, content: String, tagIDs: [Int64]) async throws -> ForumPost
    func setFavorite(postID: Int64, isFavorite: Bool) async throws
}

/// Observable stores expose account state on the main actor. Token formats and
/// credential storage remain an implementation detail of authentication.
@MainActor
protocol AccountSessionProviding: AnyObject {
    var username: String? { get }
    var isRefreshing: Bool { get }
    func refreshSession() async -> Bool
    func logout()
    func matchesAccount(_ account: String) -> Bool
}

/// An explicit collection: replacement implementations are never silently
/// substituted with the production client when a service is missing.
public struct APIServiceCollection: Sendable {
    public let catalog: any NovelCatalogService
    public let content: any NovelContentService
    public let wenku: any WenkuCatalogService
    public let favorites: any FavoritesService
    public let history: any ReadingHistoryService
    public let downloads: any NovelDownloadService
    public let bookComments: any BookCommentsService
    public let forum: any ForumService

    public init(catalog: any NovelCatalogService, content: any NovelContentService,
                wenku: any WenkuCatalogService, favorites: any FavoritesService,
                history: any ReadingHistoryService, downloads: any NovelDownloadService,
                bookComments: any BookCommentsService, forum: any ForumService) {
        self.catalog = catalog
        self.content = content
        self.wenku = wenku
        self.favorites = favorites
        self.history = history
        self.downloads = downloads
        self.bookComments = bookComments
        self.forum = forum
    }

}
