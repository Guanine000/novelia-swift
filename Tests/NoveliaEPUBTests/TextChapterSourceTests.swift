import UIKit
import NoveliaIOSCore
import XCTest
import YueduCoreText
@testable import NoveliaEPUB

/// 生成的 TXT / 在线章节由与 EPUB 相同的分页书籍对象排版。
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

    /// 相同文本以两种字号分页；重新分页后，页面的源文本偏移量
    /// 可以找到显示同一文本的页面（字体变化和重新打开时依赖此行为）。
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

    /// 达到拆分上限的单元（TXT 章节拆分后的大小）必须及时完成排版。
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

    /// 惰性单元按顺序保留所有段落且不重复，仅在换行处拆分。
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

    /// 滚动与分页阅读器共享一条记录：滚动模式切换章节时清除过期页面，
    /// 同一章节保留页面，单元划分变化时回退到章节位置。
    func testReadingPositionSharedBetweenModes() throws {
        let suite = "TXTReadingPosition-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TXTReadingPosition.legacyKey(hash: "abc"), "txtReadingPosition.v1.abc")
        let units = TextChapterSource.units(lazilySplitting: (0..<5).map {
            TextChapterBody(title: "第\($0)章", subtitle: nil, body: String(repeating: "段落内容\n", count: $0 == 2 ? 6_000 : 10))
        })
        let book = TextChapterSource(bookTitle: "共享", units: units)
        let chapter2 = try XCTUnwrap(book.firstUnit(ofTOCEntry: 2))
        XCTAssertGreaterThan(book.firstUnit(ofTOCEntry: 3)! - chapter2, 1, "chapter 2 spans several units")

        let paged = TXTReadingPosition(chapter: 2, unit: chapter2 + 1, offset: 40, unitCount: book.chapterCount)
        // 仍能读取旧本地键中的 0.12.0（52）记录。
        defaults.set(try JSONEncoder().encode(paged), forKey: TXTReadingPosition.legacyKey(hash: "abc"))
        let loaded = try XCTUnwrap(TXTReadingPosition.legacy(hash: "abc", defaults: defaults))
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
    /// 为含 1,675 章的书籍构建分页单元：比较提前拆分段落（0.12.0（51））
    /// 与当前边界扫描方式。这里两种方式应产生相同单元。
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
        // Swift 包测试未启用优化，字节扫描的边界检查耗时占主要部分；
        // 相同代码在 -O 构建中测得提前拆分为 143 ms、惰性拆分为 4.8 ms。仅打印耗时。
        print("TXTUNITS chapters=1675 eager=\(eager) units=\(eagerCount) lazy=\(lazy) units=\(lazyCount)")
        XCTAssertEqual(lazyCount, eagerCount)
    }
}

extension TextChapterSourceTests {
    func testOnlineURLsBecomeEscapedLinks() {
        let text = "见 https://n.novelia.cc/novel/a?x=1&y=<2> 与 ftp://host/f 以及 http://例子.测试/路径"
        let html = TextChapterXHTML.document(TextChapterContent(title: nil, subtitle: nil,
            paragraphs: [TextChapterParagraph(text: text)], linksURLs: true))
        XCTAssertTrue(html.contains(#"<a href="https://n.novelia.cc/novel/a?x=1&amp;y="#), html)
        XCTAssertFalse(html.contains("<2>"))
        XCTAssertFalse(html.contains("<a href=\"ftp"), "only http(s) links")
        XCTAssertTrue(html.contains("ftp://host/f"))
        let plain = TextChapterXHTML.document(TextChapterContent(title: nil, subtitle: nil, paragraphs: [TextChapterParagraph(text: text)]))
        XCTAssertFalse(plain.contains("<a "), "TXT keeps URLs as text")
    }

    /// URL 链接排版后在页面上形成可点击的普通链接区域。
    func testLinkRegionHitsURL() async throws {
        let url = "https://n.novelia.cc/forum/123"
        let book = TextChapterSource(bookTitle: "在线", units: [.init(tocTitle: "第一话") {
            TextChapterContent(title: "第一话", subtitle: nil, paragraphs: [TextChapterParagraph(text: "公告：\(url) 请阅读。")], linksURLs: true)
        }])
        let pages = EPUBPageBook(generation: 1)
        try await pages.layoutChapter(0, container: book, config: EPUBLayoutTests.readerConfig(workarounds: true))
        let id = EPUBPageID(generation: 1, spineIndex: 0, pageIndex: 0)
        let lists = pages.displayLists(spineIndex: 0)
        let rect = try XCTUnwrap(lists[0].items.compactMap { item -> CGRect? in
            if case .text(let run) = item, run.text.contains("novelia") { return run.rect.rawValue } else { return nil }
        }.first)
        let insets = EPUBLayoutTests.readerConfig(workarounds: true).contentInsets
        var hit: String?
        for dx in stride(from: CGFloat(4), to: rect.width, by: 8) where hit == nil {
            for point in [CGPoint(x: rect.minX + dx, y: rect.midY), CGPoint(x: rect.minX + dx + insets.left, y: rect.midY + insets.top)] where hit == nil {
                hit = pages.linkRegion(at: point, for: id)?.href
            }
        }
        XCTAssertEqual(hit, url)
    }
}

extension TextChapterSourceTests {
    /// YueduCoreText 阅读器写入的页面进度，在相同字号及另一字号下
    /// 都能映射回对应页面（Readium 写入相同字段）。
    func testChapterProgressionRestoresPage() async throws {
        let book = source([TextChapterContent(title: "第一章", subtitle: nil,
            paragraphs: Array(repeating: TextChapterParagraph(text: Self.paragraph), count: 120))])
        let pages = EPUBPageBook(generation: 1)
        try await pages.layoutChapter(0, container: book, config: EPUBLayoutTests.readerConfig(workarounds: true))
        let length = try XCTUnwrap(pages.sourceLength(spineIndex: 0))
        for page in [1, pages.pageCount(spineIndex: 0) / 2, pages.pageCount(spineIndex: 0) - 1] {
            let offset = try XCTUnwrap(pages.sourceOffset(spineIndex: 0, pageIndex: page))
            let progression = Double(offset) / Double(length)
            let restored = Int((Double(length) * progression).rounded(.down))
            XCTAssertEqual(pages.pageIndex(spineIndex: 0, containingSourceOffset: restored), page)
        }
    }
}
