import Foundation
import XCTest
@testable import NoveliaIOSCore

final class ArchitectureReplacementTests: XCTestCase {
    func testCompleteReplacementCollectionAndStateTransitions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = directory.appendingPathComponent("sample.epub")
        let bytes = Data("Synthetic download payload".utf8)
        try bytes.write(to: sample)
        let backend = ArchitectureFixtureBackend { sample }
        let api = backend.services()
        let found = try await api.catalog.searchNovels(query: "test", page: 1, exactTag: false)
        XCTAssertEqual(found.novels.first?.title, "架构验证小说")
        _ = try await api.catalog.siteRankedNovels(page: 1)
        let detail = try await api.catalog.novel(providerId: "fixture", novelId: "one")
        XCTAssertEqual(detail.chapters.count, 2)
        let chapter = try await api.content.chapter(providerId: "fixture", novelId: "one", chapterId: "1")
        XCTAssertFalse(chapter.translation(for: .gpt)?.isEmpty ?? true)
        _ = try await api.wenku.searchWenku(query: "test", page: 0, pageSize: 24, level: 0)
        let wenku = try await api.wenku.wenkuNovel(id: "wenku-one")
        XCTAssertEqual(wenku.volumeJp.first?.count(for: .gpt), 2)

        _ = try await api.favorites.cloudFavoriteFolders()
        _ = try await api.favorites.cloudWenkuFavoriteFolders()
        try await api.favorites.addCloudFavorite(providerId: "fixture", novelId: "one", folderId: "folder")
        var favorites = try await api.favorites.cloudFavorites(folderId: "folder", page: 0)
        XCTAssertEqual(favorites.count, 1)
        try await api.favorites.removeCloudFavorite(providerId: "fixture", novelId: "one", folderId: "folder")
        favorites = try await api.favorites.cloudFavorites(folderId: "folder", page: 0)
        XCTAssertTrue(favorites.isEmpty)
        try await api.favorites.addCloudWenkuFavorite(novelId: "wenku-one", folderId: "folder")
        var wenkuFavorites = try await api.favorites.cloudWenkuFavorites(folderId: "folder", page: 0, pageSize: 24)
        XCTAssertEqual(wenkuFavorites.novels.count, 1)
        try await api.favorites.removeCloudWenkuFavorite(novelId: "wenku-one", folderId: "folder")
        wenkuFavorites = try await api.favorites.cloudWenkuFavorites(folderId: "folder", page: 0, pageSize: 24)
        XCTAssertTrue(wenkuFavorites.novels.isEmpty)
        _ = try await api.history.cloudReadingHistory(page: 0)
        try await api.history.updateWebReadingHistory(providerId: "fixture", novelId: "one", chapterId: "1")
        let continuation = try await api.history.novelForContinuation(providerId: "fixture", novelId: "one")
        XCTAssertEqual(continuation.lastReadChapterID, "1")

        let webFile = directory.appendingPathComponent("web.epub"), wenkuFile = directory.appendingPathComponent("wenku.epub")
        try await api.downloads.downloadWebNovelEPUB(to: webFile, providerId: "fixture", novelId: "one",
            title: "Book", translationSource: .gpt, mode: .translated)
        try await api.downloads.downloadWenkuEPUB(to: wenkuFile, novelId: "wenku-one", volumeId: "volume-one.epub",
            mode: .translated, translator: .gpt, filenameTranslators: nil, filenameAuthors: [], translationsMode: .priority)
        XCTAssertEqual(try Data(contentsOf: webFile), bytes)
        XCTAssertEqual(try Data(contentsOf: wenkuFile), bytes)
        _ = try await api.bookComments.postNovelComment(subjectKey: "web-fixture-one", content: "验证评论", rootID: nil)
        let bookComments = try await api.bookComments.novelComments(subjectKey: "web-fixture-one", page: 1, pageSize: 10)
        XCTAssertEqual(bookComments.items.first?.content, "验证评论")
        _ = try await api.bookComments.novelCommentReplies(subjectKey: "web-fixture-one", rootID: 1, page: 1, pageSize: 20)

        _ = try await api.forum.categories()
        _ = try await api.forum.posts(page: 0, pageSize: 20, category: "novel", query: "", sort: .active, tagID: nil, source: .all)
        _ = try await api.forum.createPost(categoryID: 1, title: "新帖子", content: "正文", tagIDs: [])
        _ = try await api.forum.updatePost(id: 42, categoryID: 1, title: "已编辑", content: "更新正文", tagIDs: [])
        try await api.forum.setFavorite(postID: 42, isFavorite: true)
        let post = try await api.forum.post(id: 42)
        XCTAssertEqual(post.title, "已编辑")
        XCTAssertTrue(post.favorited)
        let comment = try await api.forum.createComment(postID: 42, content: "回复", rootID: nil)
        _ = try await api.forum.updateComment(postID: 42, commentID: comment.id, content: "编辑回复")
        let comments = try await api.forum.comments(postID: 42, page: 0, pageSize: 20)
        XCTAssertEqual(comments.items.first?.content, "编辑回复")
        _ = try await api.forum.replies(postID: 42, rootID: comment.id, page: 0, pageSize: 20)
        let calls = await backend.callCounts()
        XCTAssertEqual(calls.count, 32, "Every replacement interface operation must be exercised")
    }

    func testReplacementFailurePropagatesAndRetryUsesSameService() async throws {
        let backend = ArchitectureFixtureBackend { throw URLError(.unsupportedURL) }
        let api = backend.services()
        await backend.failNext("chapter")
        do {
            _ = try await api.content.chapter(providerId: "fixture", novelId: "one", chapterId: "1")
            XCTFail("Replacement failure must propagate")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        let chapter = try await api.content.chapter(providerId: "fixture", novelId: "one", chapterId: "1")
        XCTAssertEqual(chapter.title, "第一章")
        let calls = await backend.callCounts()
        XCTAssertEqual(calls["chapter"], 2)
    }

    func testMemoryCredentialsAreIndependentAndClearable() throws {
        let left = FixtureTokenStore(username: "alice"), right = FixtureTokenStore(username: "bob")
        XCTAssertEqual(NoveliaSessionRenewal.claims(left.read()!)?.subject, "alice")
        XCTAssertEqual(NoveliaSessionRenewal.claims(right.read()!)?.subject, "bob")
        left.clear()
        XCTAssertNil(left.read())
        XCTAssertNotNil(right.read())
    }
}
