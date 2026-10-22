import XCTest
import ReadiumShared
@testable import NoveliaEPUB

@MainActor
final class ReadiumTextPublicationTests: XCTestCase {
    func testOpeningAndPositionsDoNotLoadOnlineChapters() async throws {
        var loads = 0
        let source = TextChapterSource(bookTitle: "在线书", units: (0..<500).map { index in
            .init(tocTitle: "第\(index)章") {
                loads += 1
                return TextChapterContent(title: "第\(index)章", paragraphs: [.init(text: "正文")])
            }
        })
        let publication = ReadiumTextPublication.make(source: source)
        let positions = try await publication.positions().get()
        XCTAssertEqual(positions.count, 500)
        XCTAssertEqual(loads, 0)
        let location = await publication.locate(progression: 0.5)
        XCTAssertEqual(location?.href, publication.readingOrder[250].url())
        XCTAssertEqual(loads, 0, "Jump resolution must not download intervening chapters")
        XCTAssertEqual(publication.metadata.title, "在线书")
    }

    func testGeneratedResourceEscapesTextAndUsesThemeNeutralStyles() async throws {
        let source = TextChapterSource(bookTitle: "TXT", units: [.init(tocTitle: "第一章") {
            TextChapterContent(title: "第一章", subtitle: "第一卷",
                               paragraphs: [.init(text: "<script>alert(1)</script> & 👨‍👩‍👧‍👦"),
                                            .init(text: "译文", role: .secondary)])
        }])
        let publication = ReadiumTextPublication.make(source: source)
        let resource = try XCTUnwrap(publication.get(publication.readingOrder[0]))
        let html = try await resource.read().asString().get()
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("👨‍👩‍👧‍👦"))
        XCTAssertTrue(html.contains("class=\"secondary\""))
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertFalse(html.contains("color: #"), "ReadiumCSS owns the theme color")
    }

    func testSplitTXTOnlyExposesChapterStartsInTOC() async throws {
        let units = TextChapterSource.units(lazilySplitting: [
            TextChapterBody(title: "第一章", body: String(repeating: "正文内容\n", count: 100)),
            TextChapterBody(title: "第二章", body: "末章")
        ], maximumUTF8: 80)
        let source = TextChapterSource(bookTitle: "TXT", units: units)
        let publication = ReadiumTextPublication.make(source: source)
        let toc = try await publication.tableOfContents().get()
        XCTAssertGreaterThan(publication.readingOrder.count, 2)
        XCTAssertEqual(toc.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(toc[1].url(), publication.readingOrder.last?.url())
        let target = await publication.locate(toc[1])
        XCTAssertEqual(target?.href, toc[1].url())
    }

    func testFailedResourceCanBeRequestedAgain() async throws {
        struct Offline: Error {}
        var attempts = 0
        let source = TextChapterSource(bookTitle: "重试", units: [.init(tocTitle: "一") {
            attempts += 1
            if attempts == 1 { throw Offline() }
            return TextChapterContent(title: "一", paragraphs: [.init(text: "恢复后正文")])
        }])
        let publication = ReadiumTextPublication.make(source: source)
        let link = publication.readingOrder[0]
        let first = try XCTUnwrap(publication.get(link))
        if case .success = await first.read() { XCTFail("Offline resource must fail") }
        let retry = try XCTUnwrap(publication.get(link))
        let html = try await retry.read().asString().get()
        XCTAssertTrue(html.contains("恢复后正文"))
        XCTAssertEqual(attempts, 2)
        _ = try await XCTUnwrap(publication.get(link)).read().get()
        XCTAssertEqual(attempts, 2, "Successful source content remains cached")
    }

    func testUnknownResourceIsNotServed() {
        let source = TextChapterSource(bookTitle: "空", units: [])
        let publication = ReadiumTextPublication.make(source: source)
        XCTAssertNil(publication.get(Link(href: "https://example.com/chapter.xhtml")))
        XCTAssertNil(publication.get(Link(href: "../chapter-0.xhtml")))
        XCTAssertTrue(publication.readingOrder.isEmpty)
    }
}

extension ReadiumTextPublicationTests {
    func testPreciseLocatorWinsOnlyWhenNewerAndInCurrentUnit() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReadiumText-\(UUID())"))
        defer { defaults.dictionaryRepresentation().keys.forEach { defaults.removeObject(forKey: $0) } }
        var loads = 0
        let source = TextChapterSource(bookTitle: "TXT", units: (0..<2).map { index in
            .init(tocTitle: "第\(index)章") {
                loads += 1
                return TextChapterContent(title: "第\(index)章", paragraphs: [.init(text: String(repeating: "正文", count: 100))])
            }
        })
        let publication = ReadiumTextPublication.make(source: source)
        let precise = Locator(href: publication.readingOrder[0].url(), mediaType: .xhtml,
                              locations: .init(fragments: ["p10"], progression: 0.7))
        let time = Date(timeIntervalSince1970: 10_000)
        defaults.set(try precise.jsonString(), forKey: "readium.text.locator.v1.identity")
        defaults.set(time, forKey: "readium.text.time.v1.identity")
        let restored = try await ReadiumTextPublication.initialLocation(
            publication: publication, source: source, unit: 0, offset: 20,
            identity: "identity", updatedAt: time.addingTimeInterval(-1), defaults: defaults)
        XCTAssertEqual(restored, precise)
        XCTAssertEqual(loads, 0, "Precise restoration must not pre-read the chapter")
        let remote = try await ReadiumTextPublication.initialLocation(
            publication: publication, source: source, unit: 0, offset: 20,
            identity: "identity", updatedAt: time.addingTimeInterval(1), defaults: defaults)
        XCTAssertNotEqual(remote, precise, "Newer synchronized position wins")
        XCTAssertEqual(loads, 1)
        let anotherChapter = try await ReadiumTextPublication.initialLocation(
            publication: publication, source: source, unit: 1, offset: nil,
            identity: "identity", updatedAt: nil, defaults: defaults)
        XCTAssertEqual(anotherChapter?.href, publication.readingOrder[1].url())
        XCTAssertEqual(defaults.object(forKey: "readium.text.time.v1.identity") as? Date, time,
                       "Opening must not refresh timestamps")
    }
}

extension ReadiumTextPublicationTests {
    func testNavigationIndexPreservesReadiumHrefMatchingAndTOCOrder() {
        let readingOrder = ["chapter-0.xhtml", "chapter-1.xhtml", "chapter-1.xhtml", "part/../chapter-2.xhtml"].map {
            Link(href: $0, mediaType: .xhtml)
        }
        // 特意使用非资源顺序的目录，包含同章多个锚点、重复资源与 query。
        let toc = ["chapter-1.xhtml#first", "chapter-0.xhtml", "chapter-1.xhtml#second", "chapter-2.xhtml"].map {
            Link(href: $0, mediaType: .xhtml)
        }
        let index = ReadiumNavigationIndex(readingOrder: readingOrder, tableOfContents: toc)
        for value in ["chapter-0.xhtml", "chapter-0.xhtml#p1", "chapter-1.xhtml?view=1#note",
                      "chapter-2.xhtml", "part/../chapter-2.xhtml", "missing.xhtml"] {
            let href = Link(href: value).url()
            let resource = readingOrder.firstIndexWithHREF(href)
            XCTAssertEqual(index.resourceIndex(for: href), resource, value)
            let expected = resource.flatMap { resource in
                toc.indices.last { item in
                    readingOrder.firstIndexWithHREF(toc[item].url().removingFragment()).map { $0 <= resource } ?? false
                }
            }
            XCTAssertEqual(index.tocIndex(for: href), expected, value)
        }
    }

    func testDocumentURLResolvesFullPathsRatherThanDuplicateBasenames() {
        let index = ReadiumNavigationIndex(readingOrder: ["a/text.xhtml", "b/text.xhtml", "text.xhtml", "中文.xhtml"].map { Link(href: $0) }, tableOfContents: [])
        for (path, expected) in [("a/text.xhtml?x=1#p", 0), ("b/text.xhtml", 1), ("text.xhtml", 2), ("%E4%B8%AD%E6%96%87.xhtml", 3)] {
            XCTAssertEqual(index.resourceIndex(forDocumentURL: URL(string: "readium://12345678-1234-1234-1234-123456789abc/" + path)!), expected)
        }
        for path in ["missing.xhtml", "a/not-text.xhtml", "wrapper.html", "other/text.xhtml"] {
            XCTAssertNil(index.resourceIndex(forDocumentURL: URL(string: "readium://12345678-1234-1234-1234-123456789abc/" + path)!))
        }
    }

    func testDocumentURLDoesNotGuessFromUnknownOriginsOrAssets() {
        let index = ReadiumNavigationIndex(readingOrder: [Link(href: "text.xhtml")], tableOfContents: [])
        for url in ["https://example.test/text.xhtml", "readium://assets/text.xhtml", "file:///text.xhtml"] {
            XCTAssertNil(index.resourceIndex(forDocumentURL: URL(string: url)!))
        }
        let remote = ReadiumNavigationIndex(readingOrder: [Link(href: "https://example.test/text.xhtml")], tableOfContents: [])
        XCTAssertEqual(remote.resourceIndex(forDocumentURL: URL(string: "https://example.test/text.xhtml?x=1#p")!), 0)
    }

    func testNavigationIndexHandlesEmptyAndNonReadingOrderTOC() {
        let empty = ReadiumNavigationIndex(readingOrder: [], tableOfContents: [])
        XCTAssertNil(empty.tocIndex(for: Link(href: "missing.xhtml").url()))
        let index = ReadiumNavigationIndex(readingOrder: [Link(href: "text.xhtml")],
                                           tableOfContents: [Link(href: "extra.xhtml#note")])
        XCTAssertNil(index.tocIndex(for: Link(href: "text.xhtml").url()))
        XCTAssertEqual(index.tocIndex(for: Link(href: "extra.xhtml").url()), 0)
    }

    /// 约 9 MB、1675 章：首屏后的标题和目录刷新不得再次进行平方次数的 URL 解析。
    /// 单独测量导航工作，不把构造样本的时间算进读取器刷新。
    func testNineMegabyteTXTNavigationRemainsResponsive() {
        let count = 1_675
        let line = "　　月光照着书页，下一段文字保留完整的标点与空格。\n"
        let body = String(repeating: line, count: 9 * 1_024 * 1_024 / count / line.utf8.count)
        let byteCount = body.utf8.count * count
        XCTAssertGreaterThan(byteCount, 8 * 1_024 * 1_024)
        let units = TextChapterSource.units(lazilySplitting: (0..<count).map {
            TextChapterBody(title: "第\($0)章", body: body)
        })
        let source = TextChapterSource(bookTitle: "大 TXT", units: units)
        let publication = ReadiumTextPublication.make(source: source)
        var index: ReadiumNavigationIndex!
        let setup = ContinuousClock().measure {
            index = ReadiumNavigationIndex(readingOrder: publication.readingOrder,
                                           tableOfContents: publication.manifest.tableOfContents)
        }
        let hrefs = publication.readingOrder.map { $0.url() }
        let refresh = ContinuousClock().measure {
            for unit in 0..<count {
                XCTAssertEqual(index.tocIndex(for: hrefs[unit]), unit)
                XCTAssertEqual(index.resourceIndex(for: hrefs[unit]), unit)
            }
        }
        print("READIUM_INDEX bytes=\(byteCount) chapters=\(count) setup=\(setup) refreshAll=\(refresh)")
        XCTAssertLessThan(setup, .seconds(2))
        XCTAssertLessThan(refresh, .seconds(2))
    }
}
