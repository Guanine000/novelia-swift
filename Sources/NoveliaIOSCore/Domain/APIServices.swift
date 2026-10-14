// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// 页面、Store 和章节缓存只依赖业务协议；具体实现由 App 组装并持有。
// 保留现有模型与分页语义，请求编码和后端字段转换由 API 适配层负责。

/// 网络小说搜索、排行与详情；消费方无需知道具体客户端或请求地址。
public protocol NovelCatalogService: Sendable {
    func searchNovels(query: String, page: Int, exactTag: Bool) async throws -> NoveliaRankPage
    func siteRankedNovels(page: Int) async throws -> NoveliaRankPage
    func novel(providerId: String, novelId: String) async throws -> Novel
}

/// 在线章节正文；滚动与分页阅读共用此接口，缓存和排版由阅读功能管理。
public protocol NovelContentService: Sendable {
    func chapter(providerId: String, novelId: String, chapterId: String) async throws -> NovelChapter
}

/// 远端文库查询与详情；本地文库文件和书库索引不属于此接口。
public protocol WenkuCatalogService: Sendable {
    func searchWenku(query: String, page: Int, pageSize: Int, level: Int) async throws -> WenkuNovelPage
    func wenkuNovel(id: String) async throws -> WenkuNovelDetail
}

/// 云端收藏与文件夹；账号隔离和界面状态由消费方 Store 管理。
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

/// 云端阅读历史、上报与续读；本地阅读位置通过独立进度接口保存。
public protocol ReadingHistoryService: Sendable {
    func cloudReadingHistory(page: Int) async throws -> [NoveliaCloudReadingHistoryItem]
    func updateWebReadingHistory(providerId: String, novelId: String, chapterId: String) async throws
    func novelForContinuation(providerId: String, novelId: String) async throws -> NoveliaCloudNovelDetail
}

/// 将 EPUB 交付到指定目标；文件入库、索引和下载界面状态由本地 Store 负责。
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

/// 书籍评论与回复；当前后台使用论坛来源和小说会话，由具体适配保证对应关系。
public protocol BookCommentsService: Sendable {
    func novelComments(subjectKey: String, page: Int, pageSize: Int) async throws -> NoveliaCommentPage
    func novelCommentReplies(subjectKey: String, rootID: Int, page: Int, pageSize: Int) async throws -> NoveliaCommentPage
    func postNovelComment(subjectKey: String, content: String, rootID: Int?) async throws -> NoveliaComment
}

/// 论坛查询与写操作；分类筛选、分页状态和导航留在社区功能内。
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

/// 在主执行域提供消费方所需的账号状态与操作；实例由 App 注入。
/// 令牌格式、凭据存储和账号匹配细节留在认证实现，不向业务 Store 暴露。
@MainActor
protocol AccountSessionProviding: AnyObject {
    var username: String? { get }
    var isRefreshing: Bool { get }
    func refreshSession() async -> Bool
    func logout()
    func matchesAccount(_ account: String) -> Bool
}

/// App 持有的完整服务集合；允许显式组合不同实现，不能缺项后悄悄回退到生产客户端。
/// 替换 API 在组装处完成，消费方继续使用对应业务协议。
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
