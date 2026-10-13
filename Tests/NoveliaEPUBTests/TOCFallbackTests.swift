import XCTest
@testable import NoveliaEPUB

/// 内嵌目录几乎为空时，用于构建备用目录的章节标题。
/// YueduCoreText 与 Readium 阅读器都依赖此规则。
final class TOCFallbackTests: XCTestCase {
    func testFindsChapterHeadingsInParagraphOrder() {
        let html = """
        <html><body>
          <p class="title">第 3 话　『小柴琳』</p>
          <p>正文第一段。</p>
          <p><span>终章</span>　再会</p>
        </body></html>
        """
        XCTAssertEqual(EPUBContainer.fallbackTOCHeadings(inChapterHTML: html),
                       ["第 3 话 『小柴琳』", "终章 再会"])
    }

    func testRecognisesPrologueEpilogueAndFullWidthDigits() {
        XCTAssertEqual(EPUBContainer.fallbackTOCHeadings(inChapterHTML: "<p>プロローグ</p>"), ["プロローグ"])
        XCTAssertEqual(EPUBContainer.fallbackTOCHeadings(inChapterHTML: "<p>epilogue</p>"), ["epilogue"])
        XCTAssertEqual(EPUBContainer.fallbackTOCHeadings(inChapterHTML: "<p>第１２章</p>"), ["第１２章"])
    }

    func testIgnoresBodyTextThatOnlyMentionsAChapter() {
        let html = "<p>他翻到第三章继续读。</p><p>「序章还没写完」</p>"
        XCTAssertEqual(EPUBContainer.fallbackTOCHeadings(inChapterHTML: html), [])
    }
}
