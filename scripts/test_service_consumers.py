#!/usr/bin/env python3
"""Exercise production feature stores and chapter cache using injected services.

Uses isolated defaults and synthetic data; no account, library or network access.
"""
from pathlib import Path
import re
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
layout = json.loads((root/'scripts/source_layout.json').read_text())
core = root / 'Sources/NoveliaIOSCore'
app = root / 'iOSApp'
code = '\n'.join((root / layout[name]).read_text() for name in [
    'APIConfiguration.swift', 'Novel.swift', 'WenkuNovel.swift',
    'NoveliaAPIClient.swift', 'ForumAPIClient.swift', 'APIServices.swift', 'NoveliaServices.swift'])
code += '\n' + '\n'.join((root / layout[name]).read_text() for name in [
    'DiscoverStore.swift', 'FavoritesStore.swift', 'ReadingHistoryStore.swift'])
forum = (root / layout['ForumStore.swift']).read_text()
code += '\n' + forum[forum.index('@MainActor\nfinal class ForumStore'):]
wenku = (root / layout['WenkuStore.swift']).read_text()
code += '\n' + wenku[wenku.index('@MainActor\nfinal class WenkuStore'):]
reader = (root / layout['ReaderView.swift']).read_text()
code += '\n' + reader[reader.index('@MainActor\nprivate final class OnlineChapterCache'):]

# Generate the unexercised protocol methods as explicit failures, not production
# fallbacks. The exercised methods below implement synthetic backend behavior.
protocols = (root / layout['APIServices.swift']).read_text().split('@MainActor\nprotocol AccountSessionProviding')[0]
methods = re.findall(r'    func [\s\S]*?(?:async throws(?: -> [^\n]+)?)\n', protocols)
custom = {'searchNovels', 'siteRankedNovels', 'chapter', 'searchWenku',
          'cloudFavoriteFolders', 'cloudWenkuFavoriteFolders', 'cloudFavorites',
          'cloudWenkuFavorites', 'cloudReadingHistory', 'updateWebReadingHistory',
          'novelForContinuation', 'categories', 'posts', 'addCloudFavorite', 'removeCloudFavorite'}
unused = ''
for signature in methods:
    name = re.search(r'func (\w+)', signature)[1]
    if name not in custom:
        unused += signature.rstrip() + ' { throw TestError.unexpectedCall("' + name + '") }\n'
code += r'''
import Combine

enum TestError: Error { case unexpectedCall(String) }
func book(_ name: String = "book") -> Novel {
    Novel(id: name, title: name, author: "Synthetic", summary: "", genres: [],
          chapters: [NovelChapter(id: "one", title: "One", originalText: "", translatedText: "")],
          accent: .ocean, providerId: "synthetic", novelId: name)
}
@MainActor final class TestSession: AccountSessionProviding {
    var username: String? = "alice"
    var isRefreshing = false
    func matchesAccount(_ account: String) -> Bool { username == account }
    func refreshSession() async -> Bool { true }
    func logout() { username = nil }
}
actor Backend: NovelCatalogService, NovelContentService, WenkuCatalogService,
    FavoritesService, ReadingHistoryService, NovelDownloadService, BookCommentsService, ForumService {
    var calls: [String: Int] = [:]
    var slowHistory = false
    func count(_ name: String) -> Int { calls[name, default: 0] }
    func mark(_ name: String) { calls[name, default: 0] += 1 }
    func configureSlowHistory() { slowHistory = true }
    func searchNovels(query: String, page: Int, exactTag: Bool) async throws -> NoveliaRankPage {
        mark("search")
        if query == "slow" { try await Task.sleep(for: .milliseconds(150)) }
        return NoveliaRankPage(novels: query == "fallback" ? [] : [book(query + String(page))], pageCount: 3)
    }
    func siteRankedNovels(page: Int) async throws -> NoveliaRankPage {
        mark("rank")
        return NoveliaRankPage(novels: [book("rank" + String(page))], pageCount: 4)
    }
    func chapter(providerId: String, novelId: String, chapterId: String) async throws -> NovelChapter {
        mark("chapter")
        try await Task.sleep(for: .milliseconds(30))
        return NovelChapter(id: chapterId, title: "Injected", originalText: "Original", translatedText: "译文")
    }
    func searchWenku(query: String, page: Int, pageSize: Int, level: Int) async throws -> WenkuNovelPage {
        mark("wenku")
        precondition(level == 0)
        return WenkuNovelPage(novels: [WenkuNovelOutline(id: query + String(page), title: "Injected Wenku")], pageCount: 4)
    }
    func cloudFavoriteFolders() async throws -> [NoveliaCloudFolder] {
        mark("folders"); return [NoveliaCloudFolder(id: "folder", title: "Folder")]
    }
    func cloudWenkuFavoriteFolders() async throws -> [NoveliaCloudFolder] {
        mark("wenkuFolders"); return [NoveliaCloudFolder(id: "folder", title: "Folder")]
    }
    func cloudFavorites(folderId: String, page: Int) async throws -> [Novel] {
        mark("favorites"); return [book().settingCloudFavoriteFolder(folderId)]
    }
    func cloudWenkuFavorites(folderId: String, page: Int, pageSize: Int) async throws -> WenkuNovelPage {
        mark("wenkuFavorites"); return WenkuNovelPage(novels: [], pageCount: 1)
    }
    func addCloudFavorite(providerId: String, novelId: String, folderId: String) async throws { mark("add") }
    func removeCloudFavorite(providerId: String, novelId: String, folderId: String) async throws { mark("remove") }
    func cloudReadingHistory(page: Int) async throws -> [NoveliaCloudReadingHistoryItem] {
        mark("history")
        if slowHistory { try await Task.sleep(for: .milliseconds(100)) }
        return [NoveliaCloudReadingHistoryItem(novel: book(), lastReadAt: 1)]
    }
    func updateWebReadingHistory(providerId: String, novelId: String, chapterId: String) async throws { mark("record") }
    func novelForContinuation(providerId: String, novelId: String) async throws -> NoveliaCloudNovelDetail {
        mark("continuation"); return NoveliaCloudNovelDetail(novel: book(novelId), lastReadChapterID: "one")
    }
    func categories() async throws -> [ForumCategory] {
        mark("categories")
        return try JSONDecoder().decode([ForumCategory].self, from: Data(#"[{"id":1,"slug":"novel","tags":[]}]"#.utf8))
    }
    func posts(page: Int, pageSize: Int, category: String, query: String, sort: ForumSort,
               tagID: Int64?, source: ForumFeedSource) async throws -> ForumPage<ForumPost> {
        mark("posts"); return ForumPage(total: 0, items: [])
    }
''' + unused + r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        let suite = "novelia-service-consumers-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = Backend()
        let session = TestSession()
        let discover = DiscoverStore(api: backend, wenku: backend)
        await discover.search(query: "fallback")
        precondition(discover.novels.isEmpty && discover.wenkuNovels.first?.id == "fallback0")
        let before = await backend.count("search")
        await discover.searchIfNeeded(query: "fallback")
        let after = await backend.count("search")
        precondition(before == after, "Returning to results must preserve the loaded query")
        await discover.goTo(page: 2)
        precondition(discover.page == 2 && discover.pageCount == 3)
        precondition(discover.wenkuNovels.isEmpty, "Fallback is only for the first page")
        let old = Task { await discover.search(query: "slow") }
        try await Task.sleep(for: .milliseconds(370))
        await discover.search(query: "latest")
        await old.value
        precondition(discover.novels.first?.title == "latest1", "Old results must not overwrite new queries")
        let ranking = RankingStore(api: backend)
        await ranking.loadIfNeeded(page: 2); await ranking.loadIfNeeded(page: 2)
        let rankings = await backend.count("rank")
        precondition(rankings == 1 && ranking.novels.first?.title == "rank2")

        let favorites = FavoritesStore(api: backend, session: session, defaults: defaults)
        await favorites.refresh(account: "alice")
        precondition(favorites.novels.count == 1)
        try await favorites.add(book("added"), to: NoveliaCloudFolder(id: "folder", title: "Folder"), account: "alice")
        precondition(favorites.contains(book("added")))
        try await favorites.remove(book("added"), account: "alice")
        precondition(!favorites.contains(book("added")))
        session.logout()
        await favorites.refresh(account: "alice")
        precondition(favorites.errorMessage != nil)
        let reads = await backend.count("favorites")
        precondition(reads == 1, "Wrong account must not call backend")
        await favorites.refresh(account: nil)
        precondition(favorites.novels.isEmpty)
        session.username = "alice"

        let history = ReadingHistoryStore(api: backend, session: session, defaults: defaults)
        await history.refresh(account: "alice")
        precondition(history.items.count == 1)
        let continuation = try await history.continuation(for: history.items[0], account: "alice")
        precondition(continuation.chapterIndex == 0 && continuation.didResolveCloudPosition)
        await history.recordRead(novel: book(), chapterId: "one", account: "alice")
        let records = await backend.count("record")
        precondition(records == 1)
        await backend.configureSlowHistory()
        let pending = Task { await history.refresh(account: "alice") }
        try await Task.sleep(for: .milliseconds(20))
        session.logout(); await history.refresh(account: nil)
        await pending.value
        precondition(history.items.isEmpty, "Logged-out history must not be restored by an old response")

        let wenku = WenkuStore(api: backend, favorites: backend)
        await wenku.search("test")
        precondition(wenku.novels.first?.id == "test0" && wenku.page == 1)
        await wenku.goTo(page: 2)
        precondition(wenku.novels.first?.id == "test1")
        let forum = ForumStore(api: backend)
        await forum.loadCategories(); await forum.selectCategory("novel")
        precondition(forum.categories.count == 1 && forum.posts.isEmpty)

        let cache = OnlineChapterCache()
        let listed = book().chapters[0]
        async let first = cache.chapter(listed, in: book(), service: backend)
        async let second = cache.chapter(listed, in: book(), service: backend)
        let values = try await (first, second)
        precondition(values.0.title == "Injected" && values.1.translatedText == "译文")
        _ = try await cache.chapter(listed, in: book(), service: backend)
        let chapters = await backend.count("chapter")
        precondition(chapters == 1, "Paged chapter fetching must retain in-flight and completed cache reuse")
        print("Service consumers passed: injected discovery/fallback/paging, stale results, ranking reuse, favorites/session, history/logout/continuation, wenku, forum and chapter cache")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='novelia-service-consumers-') as directory:
    path = Path(directory)
    (path / 'Checks.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'),
                    str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
