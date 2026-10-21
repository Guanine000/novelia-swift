import XCTest
@testable import NoveliaEPUB

/// YueduCoreText 遇到 absolute/fixed/sticky 定位会整章拒绝排版；宿主将其降级为普通流。
final class EPUBPositioningRewriteTests: XCTestCase {
    func testDowngradesUnsupportedPositioningAndCounts() {
        let css = """
        .mg1{ position:fixed; bottom:0; }
        .a { POSITION : absolute ; top: 2px }
        .b { position: -webkit-sticky; position: sticky; }
        """
        var count = 0
        let result = EPUBContainer.rewriteUnsupportedPositioning(in: css, counter: &count)
        XCTAssertEqual(count, 4)
        XCTAssertFalse(result.lowercased().contains("fixed"))
        XCTAssertFalse(result.lowercased().contains("absolute"))
        XCTAssertFalse(result.contains("sticky"))
        // 其他声明保持原样。
        XCTAssertTrue(result.contains("bottom:0;"))
        XCTAssertTrue(result.contains("top: 2px"))
    }

    func testLeavesOtherPropertiesUntouched() {
        let css = ".r { position: relative; } .bg { background-attachment: fixed; } p { background-position: center; }"
        var count = 0
        XCTAssertEqual(EPUBContainer.rewriteUnsupportedPositioning(in: css, counter: &count), css)
        XCTAssertEqual(count, 0)
    }

    func testRewritesInlineStyleAttributes() {
        let html = #"<p style="position: fixed; bottom: 0">导语</p>"#
        var count = 0
        let result = EPUBContainer.rewriteUnsupportedPositioning(in: html, counter: &count)
        XCTAssertEqual(result, #"<p style="position: static; bottom: 0">导语</p>"#)
        XCTAssertEqual(count, 1)
    }
}
