import XCTest
import UIKit
import YueduCoreText
@testable import NoveliaEPUB

@MainActor
final class RubyFallbackTests: XCTestCase {
    func testComplexRubyFallsBackToBaseWithoutChangingLinksOrOtherText() throws {
        let html = "<html><body><p>前文<ruby><rb>漢字</rb><rp>（</rp><rtc><rt>かんじ</rt></rtc><rp>）</rp></ruby><a href='next.xhtml'>后文</a></p></body></html>"
        let flattened = try EPUBPageBook.rubyBaseTextFallback(html)
        XCTAssertTrue(flattened.contains("漢字")); XCTAssertTrue(flattened.contains("后文"))
        XCTAssertFalse(flattened.contains("かんじ")); XCTAssertFalse(flattened.contains("<ruby"))
        XCTAssertTrue(flattened.contains("next.xhtml"))
    }
}

@MainActor
private final class RubyTestSource: EPUBChapterSource {
    var bookTitle = "注音回退测试"
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

extension RubyFallbackTests {
    func testRealEngineRejectsRubyButReaderStillLaysOutBaseText() async throws {
        let source = RubyTestSource(), config = EPUBLayoutTests.readerConfig(workarounds: true)
        let raw = HTMLLayoutDocument(html: source.html, css: [], configuration: config, images: [:])
        XCTAssertTrue(raw.capabilities().unsupportedFeatures.contains(.ruby))
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: config)
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 0)
        XCTAssertTrue(book.sourceText(spineIndex: 0)?.contains("漢字") == true)
        XCTAssertFalse(book.sourceText(spineIndex: 0)?.contains("かんじ") == true)
        XCTAssertTrue(source.html.contains("<rtc>"))
    }
}
