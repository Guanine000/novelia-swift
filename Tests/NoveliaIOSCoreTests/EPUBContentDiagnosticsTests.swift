import XCTest
@testable import NoveliaIOSCore

final class EPUBContentDiagnosticsTests: XCTestCase {
    func testWholeBookIncludesChapterAndExternalCSS() {
        var report = EPUBContentDiagnostics()
        report.inspect("<script>display:grid</script><svg></svg><img src='https://example.com/a.png'><p style='opacity:.5'>text</p>", isCSS: false)
        report.inspect("@media screen { body { display:grid; text-shadow:1px 1px black; } }", isCSS: true)
        XCTAssertEqual(report.scannedDocuments, 2)
        XCTAssertEqual(report.scripts, 1)
        XCTAssertEqual(report.svg, 1)
        XCTAssertEqual(report.remoteReferences, 1)
        XCTAssertEqual(report.opacity, 1)
        XCTAssertEqual(report.mediaQueries, 1)
        XCTAssertEqual(report.flexGrid, 1) // Script body is not CSS.
        XCTAssertEqual(report.textShadows, 1)
    }

    func testCommentsAreNotCountedAndFailedScanIsDisclosed() {
        var report = EPUBContentDiagnostics()
        report.inspect("<!-- <script></script><svg></svg> --><p>text</p>", isCSS: false)
        report.inspect("/* display:flex; opacity:0; @media print {} */ p { color:black; }", isCSS: true)
        report.recordFailure()
        XCTAssertEqual(report.scripts + report.svg + report.flexGrid + report.opacity + report.mediaQueries, 0)
        XCTAssertEqual(report.failedDocuments, 1)
        XCTAssertTrue(report.messages.contains { $0.contains("未能读取") })
    }

    func testReadiumReportsPreservedStylesRatherThanYueduFallbacks() {
        var report = EPUBContentDiagnostics()
        report.inspect("p { display: table-cell; vertical-align:middle; opacity:.3; text-shadow:0 0 black; background:url(//example.com/bg.png); }", isCSS: true)
        XCTAssertEqual(report.tableLayouts, 2)
        XCTAssertEqual(report.remoteReferences, 1)
        XCTAssertTrue(report.messages.contains { $0.contains("不转换为文字颜色") })
        XCTAssertTrue(report.messages.contains { $0.contains("保留原始阴影") })
    }
}
