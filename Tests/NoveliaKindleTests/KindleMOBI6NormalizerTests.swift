import XCTest
@testable import NoveliaKindle

/// 旧版 MOBI 的 HTML 整理与分章。
final class KindleMOBI6NormalizerTests: XCTestCase {
    func testSplitsAtTopLevelPageBreaksAndRewritesLinks() throws {
        let html = """
            <html><head><guide><reference type="text" href="#a"/></guide></head><body topmargin="0">\
            <a id="a"></a><h1>One</h1><p>see <a href="#b">two</a><br><img src="resource00000.jpg"></p>\
            <mbp:pagebreak/><a id="b"></a><h1>Two</h1><p>back <a href="#a">one</a> or <a href="#b">self</a>\
            <mbp:pagebreak/>
            </body></html>
            """
        let result = try KindleMOBI6Normalizer.normalize(html: html, sourceFilename: "part00000.html")
        XCTAssertEqual(result.chapters.map(\.filename), ["part00000.html", "part00000-001.html"])
        XCTAssertEqual(result.anchorFiles, ["a": "part00000.html", "b": "part00000-001.html"])

        let first = result.chapters[0].xhtml
        XCTAssertTrue(first.contains("href=\"part00000-001.html#b\""))
        XCTAssertTrue(first.contains("<br />") || first.contains("<br/>"))
        XCTAssertFalse(first.contains("guide"))
        XCTAssertTrue(first.contains("topmargin=\"0\""))
        let second = result.chapters[1].xhtml
        XCTAssertTrue(second.contains("href=\"part00000.html#a\""))
        XCTAssertTrue(second.contains("href=\"#b\""))
        for chapter in result.chapters {
            XCTAssertFalse(chapter.xhtml.contains("mbp:"))
            XCTAssertTrue(XMLParser(data: Data(chapter.xhtml.utf8)).parse(), chapter.filename)
        }
    }

    func testDropsSegmentsWithOnlyEmptyAnchors() throws {
        let html = "<html><body><p>a</p><mbp:pagebreak/><p><img src=\"x.jpg\"></p><mbp:pagebreak/><a></a> <a id=\"z\"></a></body></html>"
        let result = try KindleMOBI6Normalizer.normalize(html: html, sourceFilename: "part00000.html")
        XCTAssertEqual(result.chapters.map(\.filename), ["part00000.html", "part00000-001.html"])
    }

    func testUnwrapsNestedPrefixedTagsAndDropsPrefixedAttributes() throws {
        let html = "<html><body><div xmlns:o=\"x\"><mbp:nu>text<mbp:pagebreak/></mbp:nu><o:p>more</o:p></div></body></html>"
        let result = try KindleMOBI6Normalizer.normalize(html: html, sourceFilename: "part00000.html")
        XCTAssertEqual(result.chapters.count, 1)
        let xhtml = result.chapters[0].xhtml
        XCTAssertTrue(xhtml.contains("<div>textmore</div>"), xhtml)
        XCTAssertTrue(XMLParser(data: Data(xhtml.utf8)).parse())
    }

    func testRepairsMalformedKF8MarkupOnly() throws {
        let valid = "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>a</p></body></html>"
        XCTAssertNil(try KindleMOBI6Normalizer.repairedXHTML(valid))

        let malformed = "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><p>a<br><img src=\"x.jpg\"><a epub:type=\"noteref\" href=\"#n\">1</a></body></html>"
        let repaired = try XCTUnwrap(try KindleMOBI6Normalizer.repairedXHTML(malformed))
        XCTAssertTrue(XMLParser(data: Data(repaired.utf8)).parse(), repaired)
        XCTAssertTrue(repaired.contains("epub:type=\"noteref\""))
        XCTAssertTrue(repaired.contains("xmlns=\"http://www.w3.org/1999/xhtml\""))
    }

    func testConvertsMobipocketAttributesToStyles() throws {
        let html = """
            <html><body><p height="2em" width="2em" align="center" style="color: red">a</p>\
            <p width="-14pt" height="0pt">b</p><p width="30">c</p><blockquote width="0pt">d</blockquote>\
            <p><font size="6" color="#888888" face="serif">e</font><font size="+1">f</font></p>\
            <img src="x.jpg" width="120" height="40"></body></html>
            """
        let xhtml = try KindleMOBI6Normalizer.normalize(html: html, sourceFilename: "part00000.html").chapters[0].xhtml
        XCTAssertTrue(xhtml.contains("<p style=\"color: red; text-indent: 2em; margin-top: 2em; text-align: center\">a</p>"), xhtml)
        XCTAssertTrue(xhtml.contains("<p style=\"text-indent: -14pt; margin-top: 0pt\">b</p>"), xhtml)
        XCTAssertTrue(xhtml.contains("<p style=\"text-indent: 30px\">c</p>"), xhtml)
        XCTAssertTrue(xhtml.contains("<blockquote style=\"text-indent: 0pt\">d</blockquote>"), xhtml)
        XCTAssertTrue(xhtml.contains("<span style=\"font-size: xx-large; color: #888888; font-family: serif\">e</span>"), xhtml)
        XCTAssertTrue(xhtml.contains("<span style=\"font-size: large\">f</span>"), xhtml)
        XCTAssertTrue(xhtml.contains("width=\"120\"") && xhtml.contains("height=\"40\""), "图片尺寸保留")
        XCTAssertTrue(XMLParser(data: Data(xhtml.utf8)).parse())
    }

    func testRestoresEPUBTypeForNoteSemanticsOnly() {
        let html = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><style type="text/css">p{}</style></head><body>\
            <a type="noteref" href="#n">1</a><aside type="footnote" id="n">x</aside><ol type="a"><li>y</li></ol>\
            <a type='noteref' epub:type="noteref" href="#n">2</a><input type="text"/></body></html>
            """
        let result = KindleEPUBConverter.restoringEPUBTypes(html)
        XCTAssertTrue(result.hasPrefix("<html xmlns:epub=\"http://www.idpf.org/2007/ops\" xmlns="))
        XCTAssertTrue(result.contains("<a epub:type=\"noteref\" href=\"#n\">1</a>"))
        XCTAssertTrue(result.contains("<aside epub:type=\"footnote\" id=\"n\">"))
        XCTAssertTrue(result.contains("<style type=\"text/css\">"))
        XCTAssertTrue(result.contains("<ol type=\"a\">"))
        XCTAssertTrue(result.contains("<a type='noteref' epub:type=\"noteref\""), "已有 epub:type 不改")
        XCTAssertTrue(result.contains("<input type=\"text\"/>"))
        XCTAssertTrue(XMLParser(data: Data(result.utf8)).parse())
        let plain = "<html><body><p>x</p></body></html>"
        XCTAssertEqual(KindleEPUBConverter.restoringEPUBTypes(plain), plain)
    }

    func testRewritesNCXAndOPFReferences() {
        let ncx = "<content src=\"part00000.html#b\"/><content src=\"part00000.html#missing\"/><content src=\"other.html#b\"/>"
        XCTAssertEqual(
            KindleMOBI6Normalizer.rewriteReferences(in: ncx, sourceFilename: "part00000.html",
                                                    anchorFiles: ["b": "part00000-001.html"]),
            "<content src=\"part00000-001.html#b\"/><content src=\"part00000.html#missing\"/><content src=\"other.html#b\"/>")
    }

    func testInsertsSplitChaptersIntoOPF() {
        let opf = """
            <item id="part00000" href="part00000.html" media-type="application/xhtml+xml"/>
            <itemref idref="part00000"/>
            """
        XCTAssertEqual(KindleEPUBConverter.insertSplitChapters(["part00000.html", "part00000-001.html"],
                                                               replacing: "part00000.html", in: opf), """
            <item id="part00000" href="part00000.html" media-type="application/xhtml+xml"/>
              <item id="part00000-001" href="part00000-001.html" media-type="application/xhtml+xml"/>
            <itemref idref="part00000"/>
              <itemref idref="part00000-001"/>
            """)
    }
}
