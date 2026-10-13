import CryptoKit
import OSLog
import XCTest
@testable import NoveliaIOSCore

final class TXTBookCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("txt-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A GB18030 novel with `chapters` headed chapters, like the files users import.
    private func writeNovel(_ name: String = "novel.txt", chapters: Int = 60, marker: String = "") throws -> URL {
        var text = "书名\n作者：测试\n\n"
        for index in 1...chapters {
            text += "第\(index)章 测试标题\(marker)\n"
            for line in 0..<20 { text += "　　第\(index)章第\(line)段，月光洒在书桌上，她轻轻合上旧书。\n" }
        }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)))
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(text.data(using: encoding)).write(to: url)
        return url
    }

    func testRepeatedOpensDecodeAndParseOnce() async throws {
        let url = try writeNovel()
        let cache = TXTBookCache()
        let first = try await cache.book(at: url, rules: .defaults, source: .open)
        for _ in 0..<2 {
            let again = try await cache.book(at: url, rules: .defaults, source: .open)
            XCTAssertEqual(again.chapters, first.chapters)
        }
        let stats = await cache.statistics
        XCTAssertEqual(stats.decodes, 1)
        XCTAssertEqual(stats.parses, 1)
        XCTAssertEqual(stats.parsedHits, 2)
        XCTAssertEqual(first.chapters.count, 61, "front matter + 60 chapters")
    }

    func testConcurrentOpensShareOneTask() async throws {
        let url = try writeNovel(chapters: 400)
        let cache = TXTBookCache()
        async let a = cache.book(at: url, rules: .defaults, source: .open)
        async let b = cache.book(at: url, rules: .defaults, source: .restore)
        async let c = cache.book(at: url, rules: .defaults, source: .open)
        let books = try await [a, b, c]
        XCTAssertEqual(Set(books.map(\.contentHash)).count, 1)
        let stats = await cache.statistics
        XCTAssertEqual(stats.decodes, 1, "concurrent requests must not decode in parallel")
        XCTAssertEqual(stats.parses, 1, "concurrent requests must not parse in parallel")
        XCTAssertEqual(stats.inFlightJoins + stats.parsedHits, 2)
    }

    /// Import validates (decode only); the first open then only parses; re-importing a copy of
    /// the same file is recognised by content and reuses everything.
    func testImportThenOpenAndDuplicateImportReuse() async throws {
        let url = try writeNovel()
        let cache = TXTBookCache()
        let importedHash = try await cache.validateDecodable(at: url, source: .import)
        let opened = try await cache.book(at: url, rules: .defaults, source: .open)
        XCTAssertEqual(opened.contentHash, importedHash)

        let copy = directory.appendingPathComponent("novel (1).txt")
        try FileManager.default.copyItem(at: url, to: copy)
        let copyHash = try await cache.validateDecodable(at: copy, source: .import)
        XCTAssertEqual(copyHash, importedHash, "duplicate detection compares content hashes")
        let reopened = try await cache.book(at: copy, rules: .defaults, source: .open)
        XCTAssertEqual(reopened.chapters, opened.chapters)

        let stats = await cache.statistics
        XCTAssertEqual(stats.decodes, 1)
        XCTAssertEqual(stats.parses, 1)
        XCTAssertGreaterThanOrEqual(stats.decodedHits + stats.parsedHits, 2)
    }

    func testRulesChangeReparsesWithoutDecoding() async throws {
        let url = try writeNovel()
        let cache = TXTBookCache()
        _ = try await cache.book(at: url, rules: .defaults, source: .open)
        let fewer = TXTChapterRuleConfiguration(enabledBuiltInIDs: [], enabledCustomRules: [])
        let fullText = try await cache.book(at: url, rules: fewer, source: .open)
        XCTAssertEqual(fullText.chapters.map(\.title), ["全文"])
        let stats = await cache.statistics
        XCTAssertEqual(stats.decodes, 1)
        XCTAssertEqual(stats.parses, 2)
    }

    func testChangedFileIsDecodedAgain() async throws {
        let url = try writeNovel()
        let cache = TXTBookCache()
        let before = try await cache.book(at: url, rules: .defaults, source: .open)
        _ = try writeNovel(marker: "（修订）")
        // Same path; size changes with the marker, so the file identity changes.
        let after = try await cache.book(at: url, rules: .defaults, source: .open)
        XCTAssertNotEqual(before.contentHash, after.contentHash)
        XCTAssertTrue(after.chapters[1].title.contains("修订"))
        let decodes = await cache.statistics.decodes
        XCTAssertEqual(decodes, 2)
    }

    /// Paged reading positions are keyed by this hash; it must equal the streamed file hash.
    func testContentHashIsFileSHA256() async throws {
        let url = try writeNovel()
        let expected = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        let book = try await TXTBookCache().book(at: url, rules: .defaults, source: .open)
        XCTAssertEqual(book.contentHash, expected)
    }

    func testUndecodableFileFailsAndIsNotCached() async throws {
        let url = directory.appendingPathComponent("blank.txt")
        try Data("   \n\n".utf8).write(to: url)
        let cache = TXTBookCache()
        do {
            _ = try await cache.validateDecodable(at: url, source: .import)
            XCTFail("blank TXT must be rejected")
        } catch {
            XCTAssertTrue(error is TXTTextDecodingError)
        }
        let decodes = await cache.statistics.decodes
        XCTAssertEqual(decodes, 0)
    }

    func testParseWithStatisticsMatchesParse() {
        let text = (1...3).map { "第\($0)章 标题\n她走过长长的桥，\($0)次回头。\n夜色很深。\n风吹过河面。\n灯一盏盏亮起。" }.joined(separator: "\n")
        let (chapters, stats) = TXTChapterParser.parseWithStatistics(text)
        XCTAssertEqual(chapters, TXTChapterParser.parse(text))
        XCTAssertEqual(stats.headings, 3)
        XCTAssertFalse(stats.fellBackToFullText)
    }

    /// Scale of the reported file (≈9 MB GB18030, 1,675 chapters): three opens before the cache
    /// (decode + parse each time) versus with it. Prints both timings for the report.
    func testLargeNovelThreeOpensBeforeAndAfter() async throws {
        var text = ""
        let line = "　　月光透过窗棂洒在书桌上，她轻轻合上那本旧书，指尖还残留着纸页的温度，窗外的风很轻。\n"
        for index in 1...1_675 {
            text += "第\(index)章 归途\n"
            for _ in 0..<62 { text += line }
        }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)))
        let url = directory.appendingPathComponent("large.txt")
        try XCTUnwrap(text.data(using: encoding)).write(to: url)
        let clock = ContinuousClock()
        var chaptersBefore = 0
        let before = try clock.measure {
            for _ in 0..<3 {
                let decoded = try XCTUnwrap(TXTTextDecoder.decode(data: try Data(contentsOf: url, options: .mappedIfSafe)))
                chaptersBefore = TXTChapterParser.parse(decoded).count
            }
        }
        let cache = TXTBookCache()
        var chaptersAfter = 0
        let after = try await clock.measure {
            for _ in 0..<3 { chaptersAfter = try await cache.book(at: url, rules: .defaults, source: .open).chapters.count }
        }
        let stats = await cache.statistics
        let bytes = try Data(contentsOf: url).count
        print("TXTSCALE bytes=\(bytes) chapters=\(chaptersAfter) before(3×decode+parse)=\(before) after(cache)=\(after) decodes=\(stats.decodes) parses=\(stats.parses) hits=\(stats.parsedHits)")
        XCTAssertEqual(chaptersBefore, chaptersAfter)
        XCTAssertEqual(chaptersAfter, 1_675)
        XCTAssertEqual(stats.decodes, 1)
        XCTAssertEqual(stats.parses, 1)
        XCTAssertLessThan(after, before)
    }

    /// Integration: three opens of one book log one decode and one parse; the other two opens
    /// log cache hits. Every line carries the open's trace and passes the share-export allowlist.
    func testThreeOpensLogOneDecodeOneParse() async throws {
        let url = try writeNovel(chapters: 120)
        let cache = TXTBookCache()
        let since = Date()
        let traces = (0..<3).map { _ in DiagnosticContext.newTraceID() }
        for trace in traces {
            _ = try await cache.book(at: url, rules: .defaults, source: .open, trace: trace)
        }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let lines = try store.getEntries(at: store.position(date: since))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == ShareableLogPolicy.subsystem && $0.category == "txt" }
            .map(\.composedMessage)
            .filter { line in traces.contains { line.contains("trace=\($0)") } }
        let decodes = lines.filter { $0.hasPrefix("TXT decode succeeded;") }
        let parses = lines.filter { $0.hasPrefix("TXT chapters parsed;") }
        let hits = lines.filter { $0.hasPrefix("TXT cache hit;") }
        XCTAssertEqual(decodes.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(parses.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(hits.count, 2, lines.joined(separator: "\n"))
        XCTAssertTrue(decodes[0].contains("trace=\(traces[0])") && decodes[0].contains("reason=first, cacheHit=false"))
        XCTAssertTrue(hits.allSatisfy { $0.contains("cacheHit=true") && $0.contains("level=parsed") })
        XCTAssertTrue(lines.allSatisfy { $0.contains("thread=background") }, "decode/parse must not run on the main thread")
        for line in lines {
            XCTAssertEqual(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "txt", text: line), line)
        }
        print("TXTLOG\n" + lines.joined(separator: "\n"))
    }
}

final class LRUCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsedByCountAndCost() {
        var cache = LRUCache<String, Int>(countLimit: 2, costLimit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), 1, "touch a so b is the oldest")
        cache.insert(3, for: "c", cost: 4)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.count, 2)
        cache.insert(4, for: "d", cost: 9)
        XCTAssertEqual(cache.count, 1, "cost limit evicts down to the newest entry")
        XCTAssertEqual(cache.value(for: "d"), 4)
        cache.insert(5, for: "e", cost: 50)
        XCTAssertEqual(cache.value(for: "e"), 5, "an oversized newest entry is still kept")
        XCTAssertEqual(cache.totalCost, 50)
    }

    func testBookTagsAreOpaqueAndStablePerLaunch() {
        let tag = DiagnosticContext.bookTag("abc")
        XCTAssertEqual(tag, DiagnosticContext.bookTag("abc"))
        XCTAssertNotEqual(tag, DiagnosticContext.bookTag("abd"))
        XCTAssertNotNil(tag.range(of: "^[0-9a-f]{8}$", options: .regularExpression))
        XCTAssertNotNil(DiagnosticContext.newTraceID().range(of: "^[0-9a-f]{8}$", options: .regularExpression))
    }
}
