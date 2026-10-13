import XCTest
@testable import NoveliaIOSCore

final class EPUBContentDiagnosticsTests: XCTestCase {
    func testSuccessfulBookHasNoDiagnosticMessages() {
        var report = EPUBContentDiagnostics()
        for path in ["Text/chapter1.xhtml", "Styles/main.css", "Images/cover.jpg", "Fonts/book.ttf"] {
            report.recordSuccess(path: path)
        }
        XCTAssertEqual(report.scannedResources, 4)
        XCTAssertTrue(report.messages.isEmpty)
    }

    func testFailedResourcesKeepPathAndReasonWithoutDuplicateMessages() {
        var report = EPUBContentDiagnostics()
        report.recordFailure(path: "Text/missing.xhtml", reason: "文件缺失")
        report.recordFailure(path: "Images/broken.jpg", reason: "压缩数据损坏")
        report.recordFailure(path: "Text/missing.xhtml", reason: "无法访问")
        XCTAssertEqual(report.messages.count, 2)
        XCTAssertTrue(report.messages[0].contains("Text/missing.xhtml"))
        XCTAssertTrue(report.messages[0].contains("无法访问"))
        XCTAssertTrue(report.messages[1].contains("压缩数据损坏"))
    }

    func testRecoveredResourceClearsItsFailureOnly() {
        var report = EPUBContentDiagnostics()
        report.recordFailure(path: "Text/chapter.xhtml", reason: "读取失败")
        report.recordFailure(path: "Styles/main.css", reason: "读取失败")
        report.recordSuccess(path: "Text/chapter.xhtml")
        XCTAssertEqual(report.messages.count, 1)
        XCTAssertTrue(report.messages[0].contains("Styles/main.css"))
    }
}
