import UIKit
import XCTest
import YueduCoreText
@testable import NoveliaEPUB

/// Generated TXT / online chapters laid out by the same page book as EPUB.
@MainActor
final class TextChapterSourceTests: XCTestCase {
    private static let paragraph = "　　月光透过窗棂洒在书桌上，她轻轻合上那本旧书，指尖还残留着纸页的温度。「明天，」她低声说，「我们再去一次那座桥吧。」"

    private func source(_ chapters: [TextChapterContent], maximumUTF16: Int = 12_000) -> TextChapterSource {
        TextChapterSource(bookTitle: "测试", units: TextChapterSource.units(splitting: chapters, maximumUTF16: maximumUTF16))
    }

    func testEscapingKeepsMarkupOutOfDocument() {
        let html = TextChapterXHTML.document(TextChapterContent(
            title: "<b>标题</b> & \"引号\"", subtitle: nil,
            paragraphs: [TextChapterParagraph(text: "a<script>x</script>\u{0}\u{1B}b\tc")]))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<b>"))
        XCTAssertTrue(html.contains("&lt;b&gt;标题&lt;/b&gt; &amp; &quot;引号&quot;"))
        XCTAssertTrue(html.contains("<p>a&lt;script&gt;x&lt;/script&gt;b c</p>"))
        XCTAssertFalse(html.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" })
    }

    func testLinesBecomeTrimmedParagraphs() {
        let paragraphs = TextChapterXHTML.paragraphs(fromLines: "　　第一段\r\n\n  \n第二段  \n\u{3000}")
        XCTAssertEqual(paragraphs.map(\.text), ["第一段", "第二段"])
        XCTAssertEqual(TextChapterXHTML.paragraphs(fromLines: "译文", role: .secondary).first?.role, .secondary)
    }

    func testLongChaptersSplitAtParagraphsWithOneTOCEntry() {
        let long = TextChapterContent(title: "第一章", subtitle: "第一卷",
                                      paragraphs: Array(repeating: TextChapterParagraph(text: Self.paragraph), count: 400))
        let short = TextChapterContent(title: "第二章", subtitle: nil, paragraphs: [TextChapterParagraph(text: "短")])
        let book = source([long, short])
        let longUTF16 = 400 * Self.paragraph.utf16.count
        XCTAssertGreaterThanOrEqual(book.chapterCount - 1, longUTF16 / 12_000)
        XCTAssertGreaterThanOrEqual(book.chapterCount, 3)
        XCTAssertEqual(book.toc.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(book.toc.map(\.spineIndex), [0, book.chapterCount - 1])
        XCTAssertEqual(book.tocEntry(containingUnit: book.chapterCount - 2), 0)
        XCTAssertEqual(book.tocEntry(containingUnit: book.chapterCount - 1), 1)
        XCTAssertEqual(book.firstUnit(ofTOCEntry: 1), book.chapterCount - 1)
    }

    func testThemeColourDrivesSecondaryText() {
        XCTAssertTrue(TextChapterXHTML.css(textColor: .black).contains("body { color: #000000; }"))
        XCTAssertTrue(TextChapterXHTML.css(textColor: .black).contains("p.secondary { color: #6B6B70; }"))
        XCTAssertTrue(TextChapterXHTML.css(textColor: .white).contains("p.secondary { color: #ADADB5; }"))
    }

    /// The same text paginates at two font sizes; a page's source offset finds the page
    /// showing that text after re-pagination (what font changes and reopening rely on).
    func testLayoutAndOffsetRestoreAcrossFontSizes() async throws {
        let content = TextChapterContent(title: "第一章　桥", subtitle: "测试书",
                                         paragraphs: Array(repeating: TextChapterParagraph(text: Self.paragraph), count: 60)
                                            + [TextChapterParagraph(text: "译文段落", role: .secondary)])
        let book = source([content])
        var small = EPUBLayoutTests.readerConfig(workarounds: true)
        small.rootFontSize = 18
        var large = small
        large.rootFontSize = 28
        let first = EPUBPageBook(generation: 1)
        try await first.layoutChapter(0, container: book, config: small, aspectRatio: 440 / 956)
        let second = EPUBPageBook(generation: 2)
        try await second.layoutChapter(0, container: book, config: large, aspectRatio: 440 / 956)
        XCTAssertGreaterThan(first.pageCount(spineIndex: 0), 1)
        XCTAssertGreaterThan(second.pageCount(spineIndex: 0), first.pageCount(spineIndex: 0))
        let text = first.displayLists(spineIndex: 0).flatMap(\.items).compactMap { item -> String? in
            if case .text(let run) = item { return run.text } else { return nil }
        }.joined()
        XCTAssertTrue(text.contains("第一章"))
        XCTAssertTrue(text.contains("译文段落"))
        let page = first.pageCount(spineIndex: 0) - 1
        let offset = try XCTUnwrap(first.sourceOffset(spineIndex: 0, pageIndex: page))
        let restored = try XCTUnwrap(second.pageIndex(spineIndex: 0, containingSourceOffset: offset))
        let start = try XCTUnwrap(second.sourceOffset(spineIndex: 0, pageIndex: restored))
        XCTAssertLessThanOrEqual(start, offset)
        if restored + 1 < second.pageCount(spineIndex: 0) {
            XCTAssertGreaterThan(try XCTUnwrap(second.sourceOffset(spineIndex: 0, pageIndex: restored + 1)), offset)
        }
    }

    /// A unit at the split limit (the size TXT chapters are cut to) must lay out promptly.
    func testFullUnitLayoutTime() async throws {
        let book = source([TextChapterContent(title: "长章", subtitle: nil,
                                              paragraphs: Array(repeating: TextChapterParagraph(text: Self.paragraph), count: 1_000))])
        let pages = EPUBPageBook(generation: 1)
        let elapsed = try await ContinuousClock().measure {
            try await pages.layoutChapter(0, container: book, config: EPUBLayoutTests.readerConfig(workarounds: true), aspectRatio: 440 / 956)
        }
        print("TEXTUNIT units=\(book.chapterCount) firstUnitPages=\(pages.pageCount(spineIndex: 0)) elapsed=\(elapsed)")
        XCTAssertGreaterThan(pages.pageCount(spineIndex: 0), 10)
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    func testFailedLoadIsRetried() async throws {
        struct Offline: Error {}
        var attempts = 0
        let book = TextChapterSource(bookTitle: "在线", units: [
            .init(tocTitle: "第一话") {
                attempts += 1
                if attempts == 1 { throw Offline() }
                return TextChapterContent(title: "第一话", subtitle: nil, paragraphs: [TextChapterParagraph(text: "正文")])
            },
        ])
        let pages = EPUBPageBook(generation: 1)
        let config = EPUBLayoutTests.readerConfig(workarounds: true)
        do {
            try await pages.layoutChapter(0, container: book, config: config)
            XCTFail("first load should fail")
        } catch is Offline {}
        try await pages.layoutChapter(0, container: book, config: config)
        XCTAssertEqual(pages.pageCount(spineIndex: 0), 1)
        XCTAssertEqual(attempts, 2)
        _ = try await book.chapterHTML(at: 0)
        XCTAssertEqual(attempts, 2, "successful chapters are cached")
    }

    /// Lazy units keep every paragraph exactly once, in order, cut only at line breaks.
    func testLazyUnitsMatchTextAndCutAtLines() async throws {
        let lines = (0..<900).map { "　　\($0)：" + Self.paragraph }
        let body = lines.joined(separator: "\r\n") + "\n\n尾行"
        let chapters = [TextChapterBody(title: "第一章", subtitle: "第一卷", body: body),
                        TextChapterBody(title: "第二章", subtitle: nil, body: "短\n"),
                        TextChapterBody(title: "空章", subtitle: nil, body: "")]
        let units = TextChapterSource.units(lazilySplitting: chapters, maximumUTF8: 36_000)
        let book = TextChapterSource(bookTitle: "测试", units: units)
        XCTAssertGreaterThan(book.chapterCount, 4)
        XCTAssertEqual(book.toc.map(\.title), ["第一章", "第二章", "空章"])
        var paragraphs: [String] = []
        for index in 0..<book.chapterCount {
            let content = try await units[index].load()
            XCTAssertEqual(content.title != nil, book.toc.contains { $0.spineIndex == index })
            paragraphs += content.paragraphs.map(\.text)
            XCTAssertLessThanOrEqual(content.paragraphs.reduce(0) { $0 + $1.text.utf8.count }, 36_000 + 400)
        }
        let expected = TextChapterXHTML.paragraphs(fromLines: body).map(\.text) + ["短"]
        XCTAssertEqual(paragraphs, expected)
        let first = try await units[0].load()
        XCTAssertEqual(first.subtitle, "第一卷")
    }

    func testTOCLookupUsesUnitOrder() {
        let units = TextChapterSource.units(lazilySplitting: (0..<500).map {
            TextChapterBody(title: "第\($0)章", subtitle: nil, body: $0 % 7 == 0 ? String(repeating: "长段落内容\n", count: 4_000) : "短")
        })
        let book = TextChapterSource(bookTitle: "目录", units: units)
        for unit in 0..<book.chapterCount {
            XCTAssertEqual(book.tocEntry(containingUnit: unit), book.toc.lastIndex { ($0.spineIndex ?? .max) <= unit })
        }
        XCTAssertNil(TextChapterSource(bookTitle: "空", units: []).tocEntry(containingUnit: 0))
    }

    /// Scroll and paged readers share one record: a chapter change from scroll mode drops a
    /// stale page, the same chapter keeps it, and a changed split falls back to the chapter.
    func testReadingPositionSharedBetweenModes() throws {
        let suite = "TXTReadingPosition-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TXTReadingPosition.key(hash: "abc"), "txtReadingPosition.v1.abc")
        let units = TextChapterSource.units(lazilySplitting: (0..<5).map {
            TextChapterBody(title: "第\($0)章", subtitle: nil, body: String(repeating: "段落内容\n", count: $0 == 2 ? 6_000 : 10))
        })
        let book = TextChapterSource(bookTitle: "共享", units: units)
        let chapter2 = try XCTUnwrap(book.firstUnit(ofTOCEntry: 2))
        XCTAssertGreaterThan(book.firstUnit(ofTOCEntry: 3)! - chapter2, 1, "chapter 2 spans several units")

        let paged = TXTReadingPosition(chapter: 2, unit: chapter2 + 1, offset: 40, unitCount: book.chapterCount)
        paged.save(hash: "abc", defaults: defaults)
        let loaded = try XCTUnwrap(TXTReadingPosition.load(hash: "abc", defaults: defaults))
        XCTAssertEqual(loaded, paged)
        XCTAssertEqual(loaded.pagedStart(in: book).unit, chapter2 + 1)
        XCTAssertEqual(loaded.pagedStart(in: book).offset, 40)
        XCTAssertEqual(loaded.movingToChapter(2), paged, "scroll mode reopening the same chapter keeps the page")

        let scrolled = loaded.movingToChapter(4)
        XCTAssertEqual(scrolled, TXTReadingPosition(chapter: 4))
        XCTAssertEqual(scrolled.pagedStart(in: book).unit, book.firstUnit(ofTOCEntry: 4))
        XCTAssertNil(scrolled.pagedStart(in: book).offset)

        var resplit = paged
        resplit.unitCount = book.chapterCount + 3
        XCTAssertEqual(resplit.pagedStart(in: book).unit, chapter2, "another split keeps only the chapter")
        XCTAssertEqual(TXTReadingPosition(chapter: 99).pagedStart(in: book).unit, book.firstUnit(ofTOCEntry: 4))
    }
}

extension TextChapterSourceTests {
    /// Building paged units for a 1,675-chapter book: eager paragraph splitting (0.12.0 (51))
    /// against the boundary scan used now. Both produce the same units here.
    func testLargeBookUnitBuildTiming() {
        let body = String(repeating: "　　月光透过窗棂洒在书桌上，她轻轻合上那本旧书，指尖还残留着纸页的温度。\n", count: 140)
        let bodies = (1...1_675).map { TextChapterBody(title: "第\($0)章", subtitle: nil, body: body) }
        let clock = ContinuousClock()
        var eagerCount = 0, lazyCount = 0
        let eager = clock.measure {
            eagerCount = TextChapterSource.units(splitting: bodies.map {
                TextChapterContent(title: $0.title, subtitle: nil, paragraphs: TextChapterXHTML.paragraphs(fromLines: $0.body))
            }).count
        }
        let lazy = clock.measure { lazyCount = TextChapterSource.units(lazilySplitting: bodies).count }
        // Package tests build without optimisation, where the byte scan's bounds checks dominate;
        // an -O build of the same code measured eager 143 ms vs lazy 4.8 ms. Print only.
        print("TXTUNITS chapters=1675 eager=\(eager) units=\(eagerCount) lazy=\(lazy) units=\(lazyCount)")
        XCTAssertEqual(lazyCount, eagerCount)
    }
}
