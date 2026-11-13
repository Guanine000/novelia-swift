import XCTest
@testable import NoveliaIOSCore

final class ReadingPreferencesTests: XCTestCase {
    func testReplacementIsLongestFirstAndNeverRecursive() {
        var projection = ReadingTextProjection()
        projection.replacements = ["小明": "王小明", "王小明": "新名字", "王": "X"]
        XCTAssertEqual(projection.apply("小明和王小明"), "王小明和新名字")
        projection.enabled = false
        XCTAssertEqual(projection.apply("小明"), "小明")
    }
    func testReplacementLongestMatchAndDeletion() {
        var projection = ReadingTextProjection()
        projection.replacements = ["ABC": "2", "AB": "1", "BC": "3", "bad": ""]
        XCTAssertEqual(projection.apply("ABCBC"), "23")
        XCTAssertEqual(projection.apply("a bad word"), "a  word")
        XCTAssertEqual(projection.apply("AB"), "1")
        XCTAssertEqual(projection.apply(""), "")
    }
    func testReplacementCacheFollowsRuleContent() {
        var projection = ReadingTextProjection()
        projection.replacements = ["旧名": "甲"]
        XCTAssertEqual(projection.apply("旧名"), "甲")
        XCTAssertEqual(projection.apply("旧名旧名"), "甲甲")
        projection.replacements = ["旧名": "乙"]
        XCTAssertEqual(projection.apply("旧名"), "乙")
        projection.chinese = .traditional
        XCTAssertEqual(projection.apply("旧名"), "舊名")
        projection.chinese = .simplified
        XCTAssertEqual(projection.apply("舊名"), "乙")
    }
    func testTraditionalConversionCorrectsAmbiguousWords() {
        var projection = ReadingTextProjection(); projection.chinese = .traditional
        XCTAssertEqual(projection.apply("一干二净"), "一乾二淨")
        XCTAssertEqual(projection.apply("你干嘛呢"), "你幹嘛呢")
        XCTAssertEqual(projection.apply("诗云"), "詩云")
        XCTAssertEqual(projection.apply("头发很长"), "頭髮很長")
        // 不引入 OpenCC 的古体用字，保持现有 ICU 用字习惯。
        XCTAssertEqual(projection.apply("吃饭"), "吃飯")
        XCTAssertEqual(projection.apply("刚才"), "剛才")
        XCTAssertEqual(projection.apply("面条"), "麵條")
        XCTAssertEqual(projection.apply("台湾"), "台灣")
        // 繁体默认采用台湾常用词，但只限脱离软件语境也成立的词。
        XCTAssertEqual(projection.apply("软件"), "軟體")
        XCTAssertEqual(projection.apply("网络"), "網路")
        XCTAssertEqual(projection.apply("信息"), "資訊")
        XCTAssertEqual(projection.apply("法律程序"), "法律程序")
    }
    func testSimplifiedConversionIgnoresTraditionalTable() {
        var projection = ReadingTextProjection(); projection.chinese = .simplified
        XCTAssertEqual(projection.apply("頭髮與麵條"), "头发与面条")
    }
    func testChineseAndHTMLPreserveAttributesResourcesAndAnnotation() {
        var projection = ReadingTextProjection(); projection.chinese = .simplified
        XCTAssertEqual(projection.apply("閱讀書籍"), "阅读书籍")
        projection.replacements = ["阅读": "<书&名>"]
        let result = projection.applyHTML("<a href='閱讀.xhtml'>閱讀&amp;書籍</a><script>閱讀</script><style>.閱讀{}</style>")
        XCTAssertTrue(result.contains("href='閱讀.xhtml'"))
        XCTAssertTrue(result.contains("&lt;书&amp;名&gt;"))
        XCTAssertTrue(result.contains("<script>閱讀</script>"))
        XCTAssertTrue(result.contains("<style>.閱讀{}</style>"))
    }
    func testReverseDragRestoresOriginalSelectionAndCancelDirection() {
        let keys = ["a", "b", "c", "d", "e"]
        let selecting = LibraryRangeSelection(original: ["e"], anchor: 1, selects: true)
        XCTAssertEqual(selecting.selection(through: 3, orderedKeys: keys), ["b", "c", "d", "e"])
        XCTAssertEqual(selecting.selection(through: 1, orderedKeys: keys), ["b", "e"])
        let clearing = LibraryRangeSelection(original: ["a", "b", "c", "e"], anchor: 2, selects: false)
        XCTAssertEqual(clearing.selection(through: 0, orderedKeys: keys), ["e"])
        XCTAssertEqual(clearing.selection(through: 2, orderedKeys: keys), ["a", "b", "e"])
    }
    @MainActor func testSingleBookPreferencesNeverOverwriteGlobalAndPersist() {
        let name = "preferences-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(22.0, forKey: SettingsKey.readerFontSize)
        let settings = ReaderSettings(defaults: defaults)
        settings.activateBook("book-a"); settings.setBookPreferencesEnabled(true); settings.fontSize = 30
        XCTAssertEqual(defaults.double(forKey: SettingsKey.readerFontSize), 22)
        settings.activateBook("book-b"); XCTAssertEqual(settings.fontSize, 22)
        settings.activateBook("book-a"); XCTAssertEqual(settings.fontSize, 30)
        let restored = ReaderSettings(defaults: defaults); restored.activateBook("book-a"); XCTAssertEqual(restored.fontSize, 30)
        restored.setBookPreferencesEnabled(false); XCTAssertEqual(restored.fontSize, 22)
    }
    @MainActor func testTextRulesRemainIndependentFromStyleScope() {
        let name = "text-style-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(22.0, forKey: SettingsKey.readerFontSize)
        let settings = ReaderSettings(defaults: defaults); settings.activateBook("a")
        var rules = ReadingTextProjection(); rules.replacements = ["旧名": "新名"]
        settings.setProjection(rules)
        XCTAssertFalse(settings.usesBookPreferences); XCTAssertEqual(settings.fontSize, 22)
        settings.setBookPreferencesEnabled(true); settings.fontSize = 30
        settings.setBookPreferencesEnabled(false)
        XCTAssertFalse(settings.usesBookPreferences); XCTAssertEqual(settings.fontSize, 22)
        XCTAssertEqual(settings.projection.apply("旧名"), "新名")
        let reopened = ReaderSettings(defaults: defaults); reopened.activateBook("a")
        XCTAssertFalse(reopened.usesBookPreferences); XCTAssertEqual(reopened.projection, rules)
        reopened.activateBook("b"); XCTAssertEqual(reopened.projection, .init())
    }
    @MainActor func testLegacyBookPreferencesStillEnableStyle() throws {
        let name = "legacy-style-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let old: [String: Any] = ["a": ["fontSize": 28, "appearance": "system", "paged": true,
                                     "projection": ["chinese": "original", "enabled": true, "replacements": [:]]]]
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "reader.bookPreferences.v1")
        let settings = ReaderSettings(defaults: defaults); settings.activateBook("a")
        XCTAssertTrue(settings.usesBookPreferences); XCTAssertEqual(settings.fontSize, 28); XCTAssertTrue(settings.pagedTextReading)
    }
    func testOldLocalRecordWithoutVolumeMetadataStillDecodes() throws {
        let old = LocalWenkuEPUB(id: UUID(), title: "旧书", filename: "book.epub", addedAt: Date())
        let decoded = try JSONDecoder().decode(LocalWenkuEPUB.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.parentWenkuID); XCTAssertEqual(decoded.title, old.title)
    }
}

private actor OfflineFixture: NovelContentService {
    var count = 0
    func chapter(providerId: String, novelId: String, chapterId: String) async throws -> NovelChapter {
        count += 1
        return NovelChapter(id: chapterId, title: "测试章", originalText: "原文", translatedText: "译文")
    }
    func requests() -> Int { count }
}
final class OfflineChapterTests: XCTestCase {
    func testClearAllRemovesEveryBookOnlyForSelectedAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OnlineChapterOfflineStore(directory: directory)
        let service = OfflineFixture()
        let chapter = NovelChapter(id: "chapter", title: "章", originalText: "", translatedText: "")
        for bookID in ["first", "second"] {
            let book = Novel(id: bookID, title: bookID, author: "", summary: "", genres: [], chapters: [chapter], accent: .ocean, providerId: "source", novelId: bookID)
            for account in ["a", "b"] {
                _ = try await store.chapter(chapter, book: book, account: account, service: service)
            }
        }
        try await store.remove(account: "a")
        let removed = try await store.entries(account: "a")
        let preserved = try await store.entries(account: "b")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(Set(preserved.map(\.bookID)), ["first", "second"])
        try await store.remove(account: "a")
        let stillPreserved = try await store.entries(account: "b")
        XCTAssertEqual(stillPreserved.count, 2)
    }

    func testDiskCacheReopenAccountIsolationAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OnlineChapterOfflineStore(directory: directory), fixture = OfflineFixture()
        let listed = NovelChapter(id: "../chapter", title: "章", originalText: "", translatedText: "")
        let novel = Novel(id: "book", title: "书", author: "", summary: "", genres: [], chapters: [listed], accent: .ocean, providerId: "source", novelId: "book")
        _ = try await store.chapter(listed, book: novel, account: "a", service: fixture)
        let reopened = OnlineChapterOfflineStore(directory: directory)
        let cached = await reopened.cached(book: novel, chapter: listed.id, account: "a")
        XCTAssertEqual(cached?.translatedText, "译文")
        let other = await reopened.cached(book: novel, chapter: listed.id, account: "b")
        XCTAssertNil(other)
        _ = try await reopened.chapter(listed, book: novel, account: "a", service: fixture)
        let count = await fixture.requests(); XCTAssertEqual(count, 1)
        try await reopened.remove(account: "a", bookID: novel.id)
        let cleared = await reopened.cached(book: novel, chapter: listed.id, account: "a"); XCTAssertNil(cleared)
    }
}
