import Foundation
import XCTest
@testable import NoveliaIOSCore

final class BookWordCountTests: XCTestCase {
    func testEastAsianCharactersAndPunctuationCountIndividually() {
        XCTAssertEqual(BookWordCount.count(text: "你好，世界！"), 6)
        XCTAssertEqual(BookWordCount.count(text: "「こんにちは」"), 7)
        XCTAssertEqual(BookWordCount.count(text: "“你好”……"), 6, "Chinese quotes and ellipses are counted when they stand alone")
        XCTAssertEqual(BookWordCount.count(text: "艾伦·耶格尔"), 6)
        XCTAssertEqual(BookWordCount.count(text: "ＡＢＣ"), 3, "full-width letters count as East Asian characters")
    }

    func testOtherRunsCountAsWordsAndWhitespaceIsIgnored() {
        XCTAssertEqual(BookWordCount.count(text: "Hello, world!"), 2)
        XCTAssertEqual(BookWordCount.count(text: "don’t stop…"), 2, "curly apostrophes and ellipses attach to the word before them")
        XCTAssertEqual(BookWordCount.count(text: "第2024年 Level 99"), 5)
        XCTAssertEqual(BookWordCount.count(text: " \n\t\u{3000}\u{00A0}"), 0)
        XCTAssertEqual(BookWordCount.count(text: ""), 0)
    }

    func testCombiningMarksAndEmojiSequencesDoNotAddWords() {
        XCTAssertEqual(BookWordCount.count(text: "cafe\u{0301}"), 1)
        XCTAssertEqual(BookWordCount.count(text: "好\u{FE0F}"), 1)
        XCTAssertEqual(BookWordCount.count(text: "👨‍👩‍👧 好"), 2)
        XCTAssertEqual(BookWordCount.count(text: "a\u{200B}b"), 1, "zero-width space is a format character, not a separator")
    }

    func testHTMLSkipsMarkupHeadRubyAndDecodesEntities() {
        let html = """
        <html><head><title>标题不计</title><style>p{}</style></head><body>
        <h1>第一章</h1><p>Hello<br/>world &amp; <ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>&#x5B57;</p>
        <!-- 注释 --><script>var x = 1;</script><img alt="插图" src="a.png"/></body></html>
        """
        // 第一章(3) + Hello + world + & + 漢 + 字
        XCTAssertEqual(BookWordCount.count(html: html), 8)
    }

    func testTXTChapterCountsTitleAndBody() {
        let chapter = TXTChapter(index: 0, title: "第一章 开始", body: "他说：“走吧。”\nOK", volumeTitle: "第一卷")
        XCTAssertEqual(BookWordCount.count(chapter: chapter), 5 + 8 + 1)
    }

    func testGeneratedTXTTitlesAreNotCounted() throws {
        let text = "没有标题的正文。\n第二行"
        let chapters = TXTChapterParser.parse(text)
        XCTAssertEqual(chapters.map(\.title), ["全文"])
        XCTAssertEqual(chapters.map(BookWordCount.count(chapter:)).reduce(0, +), BookWordCount.count(text: text))
    }

    func testTOCCountsSpanUntilTheNextLaterEntry() {
        let chapters = [10, 100, 200, 300, 400]
        // 封面（spine 0）没有目录项；同一文件的锚点不重复计数；没有位置的条目不显示。
        let counts = BookWordCount.tocCounts(entrySpines: [1, 1, 3, nil, 9], chapterCounts: chapters)
        XCTAssertEqual(counts, [300, nil, 700, nil, nil])
        XCTAssertEqual(BookWordCount.tocCounts(entrySpines: [], chapterCounts: chapters), [])
    }

    func testFormat() {
        XCTAssertEqual(BookWordCount.format(0), "0字")
        XCTAssertEqual(BookWordCount.format(9_999), "9999字")
        XCTAssertEqual(BookWordCount.format(10_000), "1万字")
        XCTAssertEqual(BookWordCount.format(325_400), "32.5万字")
        XCTAssertEqual(BookWordCount.format(1_999_999), "200万字")
        XCTAssertEqual(BookWordCount.format(123_000_000), "1.2亿字")
    }

    func testCacheSharesConcurrentRequestsAndPersistsByVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = String(repeating: "ab", count: 32)
        let calls = Counter()
        let cache = BookWordCountCache(directory: directory)
        let first = Task {
            try await cache.counts(hash: hash) {
                await calls.increment()
                try await Task.sleep(for: .milliseconds(300))
                return BookWordCounts(total: 42, chapters: [40, 2])
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let second = try await cache.counts(hash: hash) {
            await calls.increment()
            return BookWordCounts(total: 0)
        }
        let results = [try await first.value, second]
        XCTAssertEqual(results, [BookWordCounts(total: 42, chapters: [40, 2]), BookWordCounts(total: 42, chapters: [40, 2])])
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)

        let reopened = BookWordCountCache(directory: directory)
        let cached = await reopened.cached(hash: hash)
        XCTAssertEqual(cached, BookWordCounts(total: 42, chapters: [40, 2]))

        // 口径版本不符的旧文件视为未命中。
        let file = directory.appendingPathComponent(hash + ".json")
        let stale = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
            .replacingOccurrences(of: "\"version\":\(BookWordCount.ruleVersion)", with: "\"version\":0")
        try Data(stale.utf8).write(to: file)
        let afterVersionChange = await BookWordCountCache(directory: directory).cached(hash: hash)
        XCTAssertNil(afterVersionChange)
    }

    func testCacheDoesNotStoreFailuresOrUseNonHexFileNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BookWordCountCache(directory: directory)
        do {
            _ = try await cache.counts(hash: "abcd") { throw CocoaError(.fileReadCorruptFile) }
            XCTFail("expected failure")
        } catch {}
        let retried = try await cache.counts(hash: "abcd") { BookWordCounts(total: 7) }
        XCTAssertEqual(retried.total, 7)

        _ = try await cache.counts(hash: "../escape") { BookWordCounts(total: 1) }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["abcd.json"])
    }

    func testCacheEvictsOldestFilesBeyondLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BookWordCountCache(directory: directory, fileLimit: 2)
        for (index, hash) in ["aa", "bb", "cc"].enumerated() {
            _ = try await cache.counts(hash: hash) { BookWordCounts(total: index) }
            let file = directory.appendingPathComponent(hash + ".json")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                                                  ofItemAtPath: file.path)
        }
        _ = try await cache.counts(hash: "dd") { BookWordCounts(total: 3) }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["cc.json", "dd.json"])
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
