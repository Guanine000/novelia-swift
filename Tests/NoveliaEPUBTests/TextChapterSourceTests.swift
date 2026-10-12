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

    func testTXTPositionIgnoredWhenUnitsChange() throws {
        let suite = "TXTPagedPosition-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = TXTPagedPosition.key(hash: "abc")
        XCTAssertEqual(key, "txtPagedPosition.v1.abc")
        TXTPagedPosition.save(TXTPagedPosition(unit: 4, offset: 120, unitCount: 10), key: key, defaults: defaults)
        XCTAssertEqual(TXTPagedPosition.load(key: key, unitCount: 10, defaults: defaults),
                       TXTPagedPosition(unit: 4, offset: 120, unitCount: 10))
        XCTAssertNil(TXTPagedPosition.load(key: key, unitCount: 11, defaults: defaults))
    }
}
