// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// 具体客户端在基础设施层适配业务协议，Domain 和功能消费方不反向依赖客户端。
extension NoveliaAPIClient: NovelCatalogService, NovelContentService,
    WenkuCatalogService, FavoritesService, ReadingHistoryService,
    NovelDownloadService, BookCommentsService {}
extension ForumAPIClient: ForumService {}

extension APIServiceCollection {
    /// App 调用的生产服务工厂；同一小说客户端提供七类能力，论坛使用独立客户端和会话。
    /// 书籍评论使用配置的论坛来源和小说令牌；不要按域名误换为论坛令牌。
    public static func novelia(configuration: APIConfiguration, session: URLSession = .shared,
                               novelToken: @escaping @Sendable () -> String?,
                               forumToken: @escaping @Sendable () -> String?) -> Self {
        let novel = NoveliaAPIClient(baseURL: configuration.novelAPI, session: session,
                                    tokenProvider: novelToken,
                                    bookCommentsBaseURL: configuration.bookCommentsOrigin)
        let forum = ForumAPIClient(baseURL: configuration.forumAPI, session: session,
                                   tokenProvider: forumToken)
        return Self(catalog: novel, content: novel, wenku: novel, favorites: novel,
                    history: novel, downloads: novel, bookComments: novel, forum: forum)
    }
}
