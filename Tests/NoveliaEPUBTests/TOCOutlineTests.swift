import XCTest
@testable import NoveliaEPUB

/// 嵌套目录的层级解析与折叠计算（目录面板的分组展开/折叠依赖这些结果）。
final class TOCOutlineTests: XCTestCase {
    func testNavNestedListsProduceLevelsInDocumentOrder() {
        let html = """
        <nav epub:type="toc"><ol>
          <li><a href="cover.xhtml">封面</a></li>
          <li><a href="v1.xhtml">第一卷</a>
            <ol>
              <li><a href="c1.xhtml">第一章</a></li>
              <li><a href="c2.xhtml">第二章</a>
                <ol><li><a href="c2.xhtml#s1">第一节</a></li></ol>
              </li>
            </ol>
          </li>
          <li><a href="v2.xhtml">第二卷</a></li>
        </ol></nav>
        """
        let entries = EPUBContainer.parseNavTOC(html: html)
        XCTAssertEqual(entries.map(\.title), ["封面", "第一卷", "第一章", "第二章", "第一节", "第二卷"])
        XCTAssertEqual(entries.map(\.level), [0, 0, 1, 1, 2, 0])
    }

    func testNavGroupWithoutLinkDoesNotAdoptPreviousSibling() {
        let html = """
        <nav epub:type="toc"><ol>
          <li><a href="p.xhtml">序</a></li>
          <li><span>第一卷</span><ol><li><a href="c1.xhtml">第一章</a></li></ol></li>
        </ol></nav>
        """
        XCTAssertEqual(EPUBContainer.parseNavTOC(html: html).map(\.level), [0, 0])
    }

    func testNCXKeepsParentPointsBeforeChildren() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <docTitle><text>书名</text></docTitle>
          <navMap>
            <navPoint id="v1"><navLabel><text>第一卷</text></navLabel><content src="v1.xhtml"/>
              <navPoint id="c1"><navLabel><text>第一章</text></navLabel><content src="c1.xhtml"/></navPoint>
              <navPoint id="c2"><navLabel><text>第二章</text></navLabel><content src="c2.xhtml"/></navPoint>
            </navPoint>
            <navPoint id="v2"><navLabel><text>第二卷</text></navLabel><content src="v2.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """
        let points = NCXParser.parse(xml: xml)
        XCTAssertEqual(points.map(\.title), ["第一卷", "第一章", "第二章", "第二卷"])
        XCTAssertEqual(points.map(\.href), ["v1.xhtml", "c1.xhtml", "c2.xhtml", "v2.xhtml"])
        XCTAssertEqual(points.map(\.level), [0, 1, 1, 0])
    }

    func testVisibleIndicesHideDescendantsOfCollapsedGroups() {
        let levels = [0, 0, 1, 1, 2, 0]
        XCTAssertEqual(TOCOutline.hasChildren(levels: levels), [false, true, false, true, false, false])
        XCTAssertEqual(TOCOutline.visibleIndices(levels: levels, expanded: []), [0, 1, 5])
        XCTAssertEqual(TOCOutline.visibleIndices(levels: levels, expanded: [1]), [0, 1, 2, 3, 5])
        // 祖先折叠时，即使子分组仍记为展开也不显示孙项。
        XCTAssertEqual(TOCOutline.visibleIndices(levels: levels, expanded: [3]), [0, 1, 5])
        XCTAssertEqual(TOCOutline.visibleIndices(levels: levels, expanded: [1, 3]), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(TOCOutline.ancestors(of: 4, levels: levels), [3, 1])
        XCTAssertEqual(TOCOutline.ancestors(of: 5, levels: levels), [])
    }
}
