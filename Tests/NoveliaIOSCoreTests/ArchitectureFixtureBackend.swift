// SPDX-License-Identifier: GPL-3.0-only
// Core 测试与独立 Debug App 共用的合成实现；整个文件受 DEBUG 条件保护。
#if DEBUG
import Foundation
#if canImport(NoveliaIOSCore)
@testable import NoveliaIOSCore
#endif

/// 测试认证组装持有的内存凭据；仅生成合成声明，不访问 Keychain。
/// 锁保护全部读写以满足跨任务使用，不能用此实现保存生产凭据。
final class FixtureTokenStore: SessionTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(username: String) {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": username, "exp": 4_102_444_800])
        token = "fixture." + payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
    }
    func read() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func save(_ value: String) { lock.lock(); defer { lock.unlock() }; token = value }
    func clear() { lock.lock(); defer { lock.unlock() }; token = nil }
}

/// 测试/Debug 组装持有的完整替代后台，actor 隔离收藏、评论、帖子及调用计数。
/// 下载文件由注入闭包提供；保留状态变化和失败注入，不能作为生产回退。
actor ArchitectureFixtureBackend: NovelCatalogService, NovelContentService, WenkuCatalogService,
    FavoritesService, ReadingHistoryService, NovelDownloadService, BookCommentsService, ForumService {
    static let username = "architecture-user"
    private var calls: [String: Int] = [:]
    private var favorite = false
    private var wenkuFavorite = false
    private var postFavorite = false
    private var postTitle = "架构验证帖子"
    private var postContent = "这是替代服务提供的帖子正文。"
    private var bookComments: [NoveliaComment] = []
    private var forumComments: [ForumComment] = []
    private var failure: String?
    private let sampleFile: @Sendable () async throws -> URL

    private let directorySize: Int?
    private let ambiguousChapters: Bool
    private let onCall: @Sendable (String) -> Void
    private let updatedSampleFile: (@Sendable () async throws -> URL)?
    init(initialFailure: String? = nil, sampleFile: @escaping @Sendable () async throws -> URL, updatedSampleFile: (@Sendable () async throws -> URL)? = nil, ambiguousChapters: Bool = false, directorySize: Int? = nil, onCall: @escaping @Sendable (String) -> Void = { _ in }) {
        self.failure = initialFailure; self.sampleFile = sampleFile; self.updatedSampleFile = updatedSampleFile; self.onCall = onCall; self.ambiguousChapters = ambiguousChapters; self.directorySize = directorySize
    }
    func failNext(_ name: String) { failure = name }
    func callCounts() -> [String: Int] { calls }
    private func mark(_ name: String) throws {
        calls[name, default: 0] += 1
        onCall(name)
        if failure == name { failure = nil; throw URLError(.notConnectedToInternet) }
    }
    private func decode<T: Decodable>(_ object: Any, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func novel() -> Novel {
        Novel(id: "remote/fixture/one", title: "架构验证小说", author: "合成作者", summary: "本书来自内存替代服务。",
            genres: ["验证"], chapters: (directorySize.map { (1...$0).map { "验证章节 \($0)" } } ?? (ambiguousChapters ? ["幕间", "幕间", "幕间"] : ["第一章", "第二章"])).enumerated().map {
                NovelChapter(id: String($0.offset + 1), title: $0.element, originalText: "", translatedText: "")
            }, accent: .ocean, providerId: "fixture", novelId: "one",
            cloudFavoriteFolderID: favorite ? "folder" : nil,
            translationChapterCounts: [.gpt: 2])
    }
    private func postModel(id: Int64 = 42) throws -> ForumPost {
        try decode(["id": id, "categoryId": 1, "title": postTitle, "content": postContent,
                    "authorUsername": Self.username, "favorited": postFavorite,
                    "commentsCount": forumComments.count], as: ForumPost.self)
    }
    // 服务集合只保存当前 actor 的引用、不读取可变状态，因此可在组装时同步创建。
    nonisolated func services() -> APIServiceCollection {
        APIServiceCollection(catalog: self, content: self, wenku: self, favorites: self,
                             history: self, downloads: self, bookComments: self, forum: self)
    }
    func searchNovels(query: String, page: Int, exactTag: Bool) async throws -> NoveliaRankPage {
        try mark("searchNovels"); return NoveliaRankPage(novels: page == 1 ? [novel()] : [], pageCount: 2)
    }
    func siteRankedNovels(page: Int) async throws -> NoveliaRankPage {
        try mark("siteRankedNovels"); return NoveliaRankPage(novels: [novel()], pageCount: 1)
    }
    func novel(providerId: String, novelId: String) async throws -> Novel { try mark("novel"); return novel() }
    func chapter(providerId: String, novelId: String, chapterId: String) async throws -> NovelChapter {
        try mark("chapter")
        let text = String(repeating: "这是替代服务提供的阅读正文，章节获取不经过真实服务器。\n\n", count: 50)
        return NovelChapter(id: chapterId, title: chapterId == "1" ? "第一章" : "第二章",
                            originalText: text, translatedText: text, translationsBySource: [.gpt: [text]])
    }
    func searchWenku(query: String, page: Int, pageSize: Int, level: Int) async throws -> WenkuNovelPage {
        try mark("searchWenku")
        return WenkuNovelPage(novels: [WenkuNovelOutline(id: "wenku-one", title: "架构验证文库",
                              favored: wenkuFavorite ? "folder" : nil)], pageCount: 1)
    }
    func wenkuNovel(id: String) async throws -> WenkuNovelDetail {
        try mark("wenkuNovel")
        let availability: WenkuVolumeAvailability = try decode(["volumeId": "volume-one.epub", "total": 2,
            "baidu": 0, "youdao": 0, "gpt": 2, "sakura": 0], as: WenkuVolumeAvailability.self)
        return WenkuNovelDetail(id: id, title: "架构验证文库", titleZh: "", cover: nil,
            authors: ["合成作者"], artists: [], keywords: [], publisher: nil, imprint: nil,
            latestPublishAt: nil, level: "0", introduction: "替代服务提供的文库详情。",
            webIds: [], volumes: [], glossary: [:], visited: 1, favored: wenkuFavorite ? "folder" : nil,
            volumeZh: [], volumeJp: [availability])
    }
    func cloudFavoriteFolders() async throws -> [NoveliaCloudFolder] { try mark("cloudFavoriteFolders"); return [NoveliaCloudFolder(id: "folder", title: "验证收藏夹")] }
    func cloudWenkuFavoriteFolders() async throws -> [NoveliaCloudFolder] { try mark("cloudWenkuFavoriteFolders"); return [NoveliaCloudFolder(id: "folder", title: "验证收藏夹")] }
    func cloudFavorites(folderId: String, page: Int) async throws -> [Novel] { try mark("cloudFavorites"); return favorite ? [novel()] : [] }
    func cloudWenkuFavorites(folderId: String, page: Int, pageSize: Int) async throws -> WenkuNovelPage {
        try mark("cloudWenkuFavorites")
        return WenkuNovelPage(novels: wenkuFavorite ? [WenkuNovelOutline(id: "wenku-one", title: "架构验证文库", favored: "folder")] : [], pageCount: 1)
    }
    func addCloudFavorite(providerId: String, novelId: String, folderId: String) async throws { try mark("addCloudFavorite"); favorite = true }
    func removeCloudFavorite(providerId: String, novelId: String, folderId: String) async throws { try mark("removeCloudFavorite"); favorite = false }
    func addCloudWenkuFavorite(novelId: String, folderId: String) async throws { try mark("addCloudWenkuFavorite"); wenkuFavorite = true }
    func removeCloudWenkuFavorite(novelId: String, folderId: String) async throws { try mark("removeCloudWenkuFavorite"); wenkuFavorite = false }
    func cloudReadingHistory(page: Int) async throws -> [NoveliaCloudReadingHistoryItem] { try mark("cloudReadingHistory"); return [NoveliaCloudReadingHistoryItem(novel: novel(), lastReadAt: 1)] }
    func updateWebReadingHistory(providerId: String, novelId: String, chapterId: String) async throws { try mark("updateWebReadingHistory") }
    func novelForContinuation(providerId: String, novelId: String) async throws -> NoveliaCloudNovelDetail { try mark("novelForContinuation"); return NoveliaCloudNovelDetail(novel: novel(), lastReadChapterID: "1") }
    func downloadWebNovelEPUB(to destinationURL: URL, providerId: String, novelId: String, title: String,
                             translationSource: NovelTranslationSource?, mode: WebNovelDownloadMode) async throws {
        try mark("downloadWebNovelEPUB")
        let file: URL
        if (calls["downloadWebNovelEPUB"] ?? 0) > 1, let updatedSampleFile { file = try await updatedSampleFile() }
        else { file = try await sampleFile() }
        try FileManager.default.copyItem(at: file, to: destinationURL)
    }
    func downloadWenkuEPUB(to destinationURL: URL, novelId: String, volumeId: String, mode: WenkuEPUBMode,
                          translator: WenkuTranslator, filenameTranslators: [WenkuTranslator]?,
                          filenameAuthors: [String], translationsMode: WenkuTranslationsMode) async throws {
        try mark("downloadWenkuEPUB"); let file = try await sampleFile()
        try FileManager.default.copyItem(at: file, to: destinationURL)
    }
    func novelComments(subjectKey: String, page: Int, pageSize: Int) async throws -> NoveliaCommentPage { try mark("novelComments"); return NoveliaCommentPage(total: bookComments.count, items: bookComments) }
    func novelCommentReplies(subjectKey: String, rootID: Int, page: Int, pageSize: Int) async throws -> NoveliaCommentPage { try mark("novelCommentReplies"); return NoveliaCommentPage(total: 0, items: []) }
    func postNovelComment(subjectKey: String, content: String, rootID: Int?) async throws -> NoveliaComment {
        try mark("postNovelComment")
        let comment = NoveliaComment(id: bookComments.count + 1, subjectKey: subjectKey, rootId: rootID,
            content: content, authorId: 1, authorUsername: Self.username, status: 0,
            createdAt: "2026-10-14T00:00:00Z", updatedAt: "2026-10-14T00:00:00Z", replyCount: 0)
        bookComments.append(comment); return comment
    }
    func categories() async throws -> [ForumCategory] { try mark("categories"); return try decode([["id": 1, "slug": "novel", "tags": []]], as: [ForumCategory].self) }
    func posts(page: Int, pageSize: Int, category: String, query: String, sort: ForumSort,
               tagID: Int64?, source: ForumFeedSource) async throws -> ForumPage<ForumPost> { try mark("posts"); return ForumPage(total: 1, items: [try postModel()]) }
    func post(id: Int64) async throws -> ForumPost { try mark("post"); return try postModel(id: id) }
    func comments(postID: Int64, page: Int, pageSize: Int) async throws -> ForumPage<ForumComment> { try mark("comments"); return ForumPage(total: Int64(forumComments.count), items: forumComments) }
    func replies(postID: Int64, rootID: Int64, page: Int, pageSize: Int) async throws -> ForumPage<ForumComment> { try mark("replies"); return ForumPage(total: 0, items: []) }
    func createComment(postID: Int64, content: String, rootID: Int64?) async throws -> ForumComment {
        try mark("createComment")
        let comment: ForumComment = try decode(["id": forumComments.count + 1, "postId": postID,
            "content": content, "authorUsername": Self.username], as: ForumComment.self)
        forumComments.append(comment); return comment
    }
    func updateComment(postID: Int64, commentID: Int64, content: String) async throws -> ForumComment {
        try mark("updateComment")
        let comment: ForumComment = try decode(["id": commentID, "postId": postID, "content": content,
            "authorUsername": Self.username], as: ForumComment.self)
        forumComments.removeAll { $0.id == commentID }; forumComments.append(comment); return comment
    }
    func createPost(categoryID: Int64, title: String, content: String, tagIDs: [Int64]) async throws -> ForumPost { try mark("createPost"); postTitle = title; postContent = content; return try postModel() }
    func updatePost(id: Int64, categoryID: Int64, title: String, content: String, tagIDs: [Int64]) async throws -> ForumPost { try mark("updatePost"); postTitle = title; postContent = content; return try postModel(id: id) }
    func setFavorite(postID: Int64, isFavorite: Bool) async throws { try mark("setFavorite"); postFavorite = isFavorite }
}
#endif
