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
