import XCTest
@testable import NoveliaEPUB

/// Readium “禁用书内脚本”：章节文档去掉脚本元素和事件属性，脚本文件置空。
final class EPUBScriptRemovalTests: XCTestCase {
    func testRemovesScriptElementsAndInlineHandlers() {
        let html = """
        <head><script type="text/javascript" src="../Misc/script.js"></script><script src="a.js"/></head>
        <body onload='init()'><p>正文<a href="#n1" onclick="show(1)" ontouchstart=go() id="r1">注</a></p>
        <p>写着 onclick="x" 的正文</p></body>
        """
        let result = EPUBScriptRemoval.removingScripts(fromHTML: html)
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("init()"))
        XCTAssertFalse(result.contains("show(1)"))
        XCTAssertFalse(result.contains("go()"))
        XCTAssertTrue(result.contains("<a href=\"#n1\" id=\"r1\">注</a>"))
        // 标签外的文字不受影响。
        XCTAssertTrue(result.contains("写着 onclick=\"x\" 的正文"))
    }

    func testDocumentWithoutScriptsIsUnchanged() {
        let html = "<p class=\"note\" data-online=\"1\">正文</p>"
        XCTAssertEqual(EPUBScriptRemoval.removingScripts(fromHTML: html), html)
    }

    func testHidesPopupNoteBodiesOnlyWhenHeadExists() {
        let html = "<html><head><title>t</title></head><body><aside epub:type=\"footnote\" id=\"n1\">注</aside></body></html>"
        let result = EPUBScriptRemoval.hidingPopupNoteBodies(inHTML: html)
        let style = try? XCTUnwrap(result.range(of: "<style>"))
        let headEnd = try? XCTUnwrap(result.range(of: "</head>"))
        XCTAssertNotNil(style)
        XCTAssertTrue(style!.lowerBound < headEnd!.lowerBound)
        XCTAssertTrue(result.contains("*[epub|type~=\"footnote\"]"))
        XCTAssertTrue(result.contains("*[epub\\:type~=\"note\"]"))
        XCTAssertFalse(result.contains("endnote"))
        // 注释正文本身保留，弹层仍可从文档读取。
        XCTAssertTrue(result.contains("<aside epub:type=\"footnote\" id=\"n1\">注</aside>"))
        XCTAssertEqual(EPUBScriptRemoval.hidingPopupNoteBodies(inHTML: "<p>无 head</p>"), "<p>无 head</p>")
    }

    func testResourceClassification() {
        XCTAssertTrue(EPUBScriptRemoval.isScriptResource(path: "OEBPS/Misc/script.JS"))
        XCTAssertFalse(EPUBScriptRemoval.isScriptResource(path: "OEBPS/Styles/style.css"))
        XCTAssertTrue(EPUBScriptRemoval.isHTMLResource(path: "OEBPS/Text/Section008.xhtml"))
        XCTAssertFalse(EPUBScriptRemoval.isHTMLResource(path: "OEBPS/toc.ncx"))
    }
}
