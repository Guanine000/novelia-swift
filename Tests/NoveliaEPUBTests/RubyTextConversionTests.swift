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

@MainActor
private final class UpgradedLayoutSource: EPUBChapterSource {
    var bookTitle = "新版排版回归"
    var chapterCount = 1
    var toc = [EPUBTOCEntry(title: "章", spineIndex: 0)]
    var themeTextColor: UIColor = .black
    let html: String
    let css: [String]
    let images: [String: UIImage]
    init(html: String, css: [String] = [], images: [String: UIImage] = [:]) {
        self.html = html; self.css = css; self.images = images
    }
    func chapterHref(at index: Int) -> String { "chapter.xhtml" }
    func chapterHTML(at index: Int) async throws -> String { html }
    func cssTexts(forChapterHTML html: String, chapterHref: String, aspectRatio: CGFloat) async -> [String] { css }
    func images(forChapterHTML html: String, chapterHref: String) async -> [String: UIImage] { images }
    func spineIndex(forLinkHref href: String, relativeTo chapterHref: String) -> Int? { nil }
}

extension RubyTextConversionTests {
    func testSupportedRubyRemainsNativeAndMapsOldPosition() async throws {
        let source = UpgradedLayoutSource(html: "<p>前文<ruby>漢字<rt>かんじ</rt></ruby>后文</p>")
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: EPUBLayoutTests.readerConfig(workarounds: true))
        let text = try XCTUnwrap(book.sourceText(spineIndex: 0))
        XCTAssertTrue(text.contains("漢字"))
        XCTAssertFalse(text.contains("（かんじ）"))
        let oldOffset = ("前文漢字（かんじ）后文" as NSString).range(of: "后文").location
        let newOffset = (text as NSString).range(of: "后文").location
        XCTAssertEqual(book.restoredOffset(spineIndex: 0, savedOffset: oldOffset), newOffset)
        XCTAssertEqual(book.mainThreadLayoutSteps(spineIndex: 0), 0)
    }

    func testTablePreservesCellContents() async throws {
        let source = UpgradedLayoutSource(html: "<table><tr><td>人物甲</td><td>人物乙</td></tr><tr><td>资料甲</td><td>资料乙</td></tr></table>",
                                         css: ["table { border-collapse: separate; border-spacing: 4px } td { vertical-align: middle; border: 1px solid black }"])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: EPUBLayoutTests.readerConfig(workarounds: true))
        let text = try XCTUnwrap(book.sourceText(spineIndex: 0))
        for expected in ["人物甲", "人物乙", "资料甲", "资料乙"] { XCTAssertTrue(text.contains(expected)) }
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 0)
    }

    func testPicturePagesHaveDistinctOffsetsAndRestoreToThemselves() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        }
        let source = UpgradedLayoutSource(html: "<img src='a.png'/><img src='a.png'/><p>后文</p>",
                                         css: ["body { margin: 0 } img { display: block; width: 100%; height: 100vh; page-break-after: always }"],
                                         images: ["a.png": image])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: EPUBLayoutTests.readerConfig(workarounds: true))
        XCTAssertGreaterThanOrEqual(book.pageCount(spineIndex: 0), 3)
        var previous = -1
        for page in 0..<book.pageCount(spineIndex: 0) {
            let offset = try XCTUnwrap(book.sourceOffset(spineIndex: 0, pageIndex: page))
            XCTAssertGreaterThan(offset, previous)
            XCTAssertEqual(book.pageIndex(spineIndex: 0, containingSourceOffset: offset), page)
            previous = offset
        }
    }

    func testLargeRubyPositionMapKeepsEveryBaseBoundary() {
        let count = 13_500
        let oldUnit = "前漢（かん）後文", newUnit = "前漢後文"
        let map = EPUBSourcePositionMap(legacy: String(repeating: oldUnit, count: count),
                                        current: String(repeating: newUnit, count: count))
        for index in stride(from: 0, to: count, by: 97) {
            let old = index * oldUnit.utf16.count + 6
            let current = index * newUnit.utf16.count + 2
            XCTAssertEqual(map.current(old), current)
            XCTAssertEqual(map.legacy(current), old)
        }
    }

    func testPositionMapHandlesSurrogatesAndRepeatedReadings() {
        let old = "😀前漢（かん）後漢（かん）末"
        let new = "😀前漢後\u{FFFC}漢末"
        let map = EPUBSourcePositionMap(legacy: old, current: new)
        for word in ["前", "後", "末"] {
            let a = (old as NSString).range(of: word).location
            let b = (new as NSString).range(of: word).location
            XCTAssertEqual(map.current(a), b)
            XCTAssertEqual(map.legacy(b), a)
        }
    }
}

extension RubyTextConversionTests {
    func testPseudoTableImageKeepsLegacyFallback() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 180)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 180))
        }
        let source = UpgradedLayoutSource(html: "<div class='page'><div class='cell'><img src='a.png'/></div></div>",
                                         css: [".page { display: table; width: 100% } .cell { display: table-cell; vertical-align: middle }"],
                                         images: ["a.png": image])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: EPUBLayoutTests.readerConfig(workarounds: true))
        XCTAssertEqual(book.tableFallbackChapterCount, 1)
        XCTAssertTrue(book.displayLists(spineIndex: 0).contains { list in
            list.items.contains { if case .image(let item) = $0 { return !item.isBackgroundPaint }; return false }
        }, "伪表格降级后必须仍绘制原插图")
    }
}
