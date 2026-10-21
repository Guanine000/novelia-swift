import XCTest
@testable import NoveliaEPUB

/// Readium 未标 noteref 的注释链接：按目标判断是否为注释正文。
final class EPUBFootnoteTargetTests: XCTestCase {
    /// 多看／Sigil 注释插件格式（取自用户反馈的真实书籍结构）。
    func testDuokanFootnoteItemIsRecognised() throws {
        let html = """
        <p>跟班<sup><a class="duokan-footnote" href="#note_1" id="noteref_1"><img src="../Images/note.png"/></a></sup></p>
        <hr class="footnote"/>
        <ol class="duokan-footnote-content">
            <li class="duokan-footnote-item" id="note_1">
                <a href="#noteref_1" style='text-decoration:none;'><span style='color:#000'>原文为“介添人”</span></a>
            </li>
            <li class="duokan-footnote-item" id="note_2"><span>一种日式甜点</span></li>
        </ol>
        """
        let note = try XCTUnwrap(EPUBFootnoteTarget.noteHTML(id: "note_1", inDocument: html))
        XCTAssertTrue(note.contains("原文为“介添人”"))
        XCTAssertFalse(note.contains("一种日式甜点"))
        // 回链锚点本身不是注释正文。
        XCTAssertNil(EPUBFootnoteTarget.noteHTML(id: "noteref_1", inDocument: html))
    }

    func testEPUBTypeNoteBodyWithNestedElements() throws {
        let html = """
        <aside epub:type="footnote" id="n1"><aside><p>内层</p></aside><p>外层</p></aside><p id="after">正文</p>
        """
        let note = try XCTUnwrap(EPUBFootnoteTarget.noteHTML(id: "n1", inDocument: html))
        XCTAssertTrue(note.contains("内层") && note.contains("外层"))
        XCTAssertFalse(note.contains("正文"))
    }

    func testOrdinaryTargetsStillNavigate() {
        let html = """
        <h2 id="chapter2">第二章</h2><div data-id="x" class="footnote"><p id="x">普通段落</p></div><li id="empty" class="footnote"> </li>
        """
        XCTAssertNil(EPUBFootnoteTarget.noteHTML(id: "chapter2", inDocument: html))
        XCTAssertNil(EPUBFootnoteTarget.noteHTML(id: "x", inDocument: html))
        XCTAssertNil(EPUBFootnoteTarget.noteHTML(id: "empty", inDocument: html))
        XCTAssertNil(EPUBFootnoteTarget.noteHTML(id: "missing", inDocument: html))
    }
}
