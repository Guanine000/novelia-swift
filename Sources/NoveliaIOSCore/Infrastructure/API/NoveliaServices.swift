// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension NoveliaAPIClient: NovelCatalogService, NovelContentService,
    WenkuCatalogService, FavoritesService, ReadingHistoryService,
    NovelDownloadService, BookCommentsService {}
extension ForumAPIClient: ForumService {}

extension APIServiceCollection {
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
