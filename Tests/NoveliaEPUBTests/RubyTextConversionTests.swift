import XCTest
import UIKit
import YueduCoreText
@testable import NoveliaEPUB

/// 原生分页引擎把 ruby 注音改写为「底文（读音）」正文文本；
/// 这些测试固定转换结果，并确认真实引擎能排版改写后的章节。
@MainActor
final class RubyTextConversionTests: XCTestCase {
    func testComplexRubyBecomesParentheticalText() throws {
        let html = "<html><body><p>前文<ruby><rb>漢字</rb><rp>（</rp><rtc><rt>かんじ</rt></rtc><rp>）</rp></ruby><a href='next.xhtml'>后文</a></p></body></html>"
        let converted = try EPUBPageBook.rubyParentheticalText(html)
        XCTAssertTrue(converted.contains("漢字（かんじ）"))
        XCTAssertTrue(converted.contains("后文"))
        XCTAssertTrue(converted.contains("next.xhtml"))
        XCTAssertFalse(converted.contains("<ruby"))
        XCTAssertFalse(converted.contains("<rt"))
        XCTAssertEqual(converted.components(separatedBy: "（").count - 1, 1, "原书的 rp 括号不能重复出现")
    }

    func testSimpleRubyWithRbAndRpUsesOneParenthesisPair() throws {
        let html = "<p><ruby><rb>漢字</rb><rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby></p>"
        let converted = try EPUBPageBook.rubyParentheticalText(html)
        XCTAssertTrue(converted.contains("漢字（かんじ）"))
        XCTAssertEqual(converted.components(separatedBy: "（").count - 1, 1)
        XCTAssertEqual(converted.components(separatedBy: "）").count - 1, 1)
    }

    func testEachReadingGetsItsOwnParentheses() throws {
        let converted = try EPUBPageBook.rubyParentheticalText("<p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby></p>")
        XCTAssertTrue(converted.contains("漢（かん）字（じ）"))
    }

    func testRubyWithoutReadingKeepsBaseText() throws {
        let converted = try EPUBPageBook.rubyParentheticalText("<p><ruby>漢字</ruby></p>")
        XCTAssertTrue(converted.contains("漢字"))
        XCTAssertFalse(converted.contains("（"))
        XCTAssertFalse(converted.contains("<ruby"))
    }

    func testEmptyReadingKeepsBaseTextWithoutParentheses() throws {
        let converted = try EPUBPageBook.rubyParentheticalText("<p><ruby>漢字<rt>  </rt></ruby></p>")
        XCTAssertTrue(converted.contains("漢字"))
        XCTAssertFalse(converted.contains("（"))
    }

    func testReadingWhitespaceIsNormalised() throws {
        let html = "<p><ruby>\n 漢字\n <rt>\n かんじ \n</rt>\n</ruby></p>"
        let converted = try EPUBPageBook.rubyParentheticalText(html)
        XCTAssertTrue(converted.contains("漢字（かんじ）"))
    }

    func testReadingIsEscapedAsText() throws {
        let converted = try EPUBPageBook.rubyParentheticalText("<p><ruby>A&amp;B<rt>x&lt;y</rt></ruby></p>")
        XCTAssertTrue(converted.contains("A&amp;B（x&lt;y）"))
    }

    func testStrayRubyTagsOutsideRubyAreRemoved() throws {
        // 不在 ruby 内的 rb/rt 属于无效标记：SwiftSoup 会丢掉标签、保留可见文字，
        // 这里只保证引擎排版前不再出现 ruby 相关标签。
        let converted = try EPUBPageBook.rubyParentheticalText("<p><rb>漢</rb>字<rt>かん</rt></p>")
        XCTAssertTrue(converted.contains("漢字"))
        XCTAssertTrue(converted.contains("かん"))
        XCTAssertFalse(converted.contains("<rb"))
        XCTAssertFalse(converted.contains("<rt"))
    }

    func testChapterWithoutRubyIsReturnedUnchanged() throws {
        let html = "<html><body><p>没有注音</p></body></html>"
        XCTAssertEqual(try EPUBPageBook.rubyParentheticalText(html), html)
    }

    func testConvertedChapterNoLongerReportsUnsupportedRuby() throws {
        let html = "<html><body><p>前文<ruby><rb>漢字</rb><rtc><rt>かんじ</rt></rtc></ruby>后文</p></body></html>"
        let config = EPUBLayoutTests.readerConfig(workarounds: true)
        let raw = HTMLLayoutDocument(html: html, css: [], configuration: config, images: [:])
        XCTAssertTrue(raw.capabilities().unsupportedFeatures.contains(.ruby))
        let converted = HTMLLayoutDocument(
            html: try EPUBPageBook.rubyParentheticalText(html), css: [], configuration: config, images: [:]
        )
        XCTAssertFalse(converted.capabilities().unsupportedFeatures.contains(.ruby))
    }
}

@MainActor
private final class RubyTestSource: EPUBChapterSource {
    var bookTitle = "注音转换测试"
    var chapterCount = 1
    var toc = [EPUBTOCEntry(title: "章", spineIndex: 0)]
    var themeTextColor: UIColor = .black
    let html = "<html><body><p>前文<ruby><rb>漢字</rb><rtc><rt>かんじ</rt></rtc></ruby>后文</p></body></html>"
    func chapterHref(at index: Int) -> String { "chapter.xhtml" }
    func chapterHTML(at index: Int) async throws -> String { html }
    func cssTexts(forChapterHTML html: String, chapterHref: String, aspectRatio: CGFloat) async -> [String] { [] }
    func images(forChapterHTML html: String, chapterHref: String) async -> [String: UIImage] { [:] }
    func spineIndex(forLinkHref href: String, relativeTo chapterHref: String) -> Int? { nil }
}

extension RubyTextConversionTests {
    func testEngineLaysOutChapterWithParentheticalReading() async throws {
        let source = RubyTestSource(), config = EPUBLayoutTests.readerConfig(workarounds: true)
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: config)
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 0)
        XCTAssertTrue(book.sourceText(spineIndex: 0)?.contains("漢字（かんじ）") == true)
        XCTAssertTrue(source.html.contains("<rtc>"), "原书内容不能被改写")
    }
}
