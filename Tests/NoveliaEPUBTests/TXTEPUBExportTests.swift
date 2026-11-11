import Foundation
import NoveliaIOSCore
import ReadiumZIPFoundation
import XCTest
@testable import NoveliaEPUB

final class TXTEPUBExportTests: XCTestCase {
    private func entries(_ chapters: [TXTEPUBChapter],
                         projection: ReadingTextProjection = .init()) throws -> [String: String] {
        let list = try TXTEPUBExporter.makeEntries(title: "测试书", author: "作者",
                                                   chapters: chapters, projection: projection)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.path, $0.text) })
    }

    func testManualTitlesVolumesAndEscaping() throws {
        let chapters = [
            TXTEPUBChapter(title: "第一章 & 开始", volumeTitle: nil, body: "第一段\n第二段 <tag> & 符号"),
            TXTEPUBChapter(title: "第二章", volumeTitle: "第一卷", body: "正文二"),
            TXTEPUBChapter(title: "第三章", volumeTitle: "第一卷", body: "正文三"),
            TXTEPUBChapter(title: "第四章", volumeTitle: "第二卷", body: "正文四")
        ]
        let entries = try entries(chapters)

        let nav = try XCTUnwrap(entries["OEBPS/nav.xhtml"])
        XCTAssertTrue(nav.contains("<span>第一卷</span>"))
        XCTAssertTrue(nav.contains("<span>第二卷</span>"))
        XCTAssertTrue(nav.contains("第一章 &amp; 开始"))

        let first = try XCTUnwrap(entries["OEBPS/text/0001.xhtml"])
        XCTAssertTrue(first.contains("第一段"))
        XCTAssertTrue(first.contains("第二段 &lt;tag&gt; &amp; 符号"))
        let second = try XCTUnwrap(entries["OEBPS/text/0002.xhtml"])
        XCTAssertTrue(second.contains("第一卷"))
        let third = try XCTUnwrap(entries["OEBPS/text/0003.xhtml"])
        XCTAssertFalse(third.contains("第一卷"), "同一卷只在首章显示卷标题")

        let opf = try XCTUnwrap(entries["OEBPS/content.opf"])
        XCTAssertTrue(opf.contains("<dc:title>测试书</dc:title>"))
        XCTAssertTrue(opf.contains("<dc:creator>作者</dc:creator>"))
        XCTAssertEqual(entries["mimetype"], Optional("application/epub+zip"))

        let ncx = try XCTUnwrap(entries["OEBPS/toc.ncx"])
        XCTAssertTrue(ncx.contains("dtb:depth\" content=\"2"))
    }

    func testProjectionAppliedToTitlesAndBody() throws {
        var projection = ReadingTextProjection()
        projection.replacements = ["旧名": "新名"]
        let chapters = [TXTEPUBChapter(title: "旧名", volumeTitle: "旧名卷", body: "旧名正文")]
        let entries = try entries(chapters, projection: projection)

        let nav = try XCTUnwrap(entries["OEBPS/nav.xhtml"])
        XCTAssertTrue(nav.contains("新名"))
        XCTAssertFalse(nav.contains("旧名"))

        let chapter = try XCTUnwrap(entries["OEBPS/text/0001.xhtml"])
        XCTAssertTrue(chapter.contains("新名正文"))
        XCTAssertTrue(chapter.contains("新名卷"))
    }

    func testArchiveWritesMimetypeFirstAndReadable() async throws {
        let chapters = [TXTEPUBChapter(title: "第一章", volumeTitle: nil, body: "正文")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")

        try await TXTEPUBExporter.export(title: "测试书", author: "", chapters: chapters,
                                         projection: .init(), destination: url)
        let archive = try await Archive(url: url, accessMode: .read)
        let entries = try await archive.entries()

        XCTAssertEqual(entries.first?.path, "mimetype")
        XCTAssertEqual(entries.first?.compressedSize, entries.first?.uncompressedSize)
        XCTAssertTrue(entries.contains { $0.path == "META-INF/container.xml" })
        XCTAssertTrue(entries.contains { $0.path == "OEBPS/content.opf" })
        XCTAssertTrue(entries.contains { $0.path == "OEBPS/nav.xhtml" })
        XCTAssertTrue(entries.contains { $0.path == "OEBPS/toc.ncx" })
        XCTAssertTrue(entries.contains { $0.path == "OEBPS/text/0001.xhtml" })
    }

    func testEmptyBookThrows() {
        XCTAssertThrowsError(try TXTEPUBExporter.makeEntries(title: "空", author: "",
                                                             chapters: [], projection: .init()))
    }
}
