import ReadiumZIPFoundation
import XCTest
@testable import NoveliaEPUB
@testable import NoveliaKindle

/// AZW3／MOBI → EPUB 转换：输出可被书库的 EPUB 容器打开、内容确定，不支持的情况给出对应错误。
final class KindleEPUBConverterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kindle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    private func convert(_ name: String) async throws -> URL {
        let output = directory.appendingPathComponent("\(UUID().uuidString).epub")
        try await KindleEPUBConverter.convert(source: try fixture(name), destination: output)
        return output
    }

    func testConvertsKF8WithChaptersAndNestedTOC() async throws {
        let epub = try await convert("kf8-ncx.azw3")
        let container = try await EPUBContainer.open(fileURL: epub)
        XCTAssertEqual(container.spine.count, 3)
        XCTAssertEqual(container.toc.map(\.title), ["Test chapter 1", "Test chapter 2", "Test subchapter 2-1", "Test subchapter 2-2"])
        XCTAssertEqual(container.toc.map(\.level), [0, 0, 1, 1])
        let second = try await container.chapterHTML(at: 1)
        XCTAssertTrue(second.contains("Test page 2"))
    }

    func testConvertsLegacyMOBIIntoWellFormedChapters() async throws {
        let epub = try await convert("mobi6-cp1252.mobi")
        let container = try await EPUBContainer.open(fileURL: epub)
        XCTAssertGreaterThan(container.spine.count, 1, "应在 mbp:pagebreak 处分章")
        XCTAssertEqual(container.toc.count, 2)
        XCTAssertEqual(Set(container.toc.compactMap(\.spineIndex)).count, 2, "目录应指向分章后的不同文件")

        let archive = try await Archive(url: epub, accessMode: .read)
        for entry in try await archive.entries() where entry.path.hasSuffix(".html") {
            let extracted = directory.appendingPathComponent(UUID().uuidString)
            _ = try await archive.extract(entry, to: extracted)
            let data = try Data(contentsOf: extracted)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("mbp:"), entry.path)
            XCTAssertFalse(text.contains("<guide"), entry.path)
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(entry.path) 不是合法 XML：\(String(describing: parser.parserError))")
        }

        let metadata = await EPUBContainer.metadata(fileURL: epub, coverMaxSize: CGSize(width: 240, height: 320))
        XCTAssertEqual(metadata?.title, "Libmobi test sample")
        XCTAssertNotNil(metadata?.cover)
    }

    func testMimetypeIsFirstAndStored() async throws {
        let epub = try await convert("kf8-ncx.azw3")
        let archive = try await Archive(url: epub, accessMode: .read)
        let entries = try await archive.entries()
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.path, "mimetype")
        XCTAssertEqual(first.compressedSize, first.uncompressedSize)
    }

    func testOutputIsByteIdentical() async throws {
        for name in ["kf8-ncx.azw3", "mobi6-cp1252.mobi"] {
            let first = try Data(contentsOf: try await convert(name))
            let second = try Data(contentsOf: try await convert(name))
            XCTAssertEqual(first, second, name)
        }
    }

    func testRejectsDRMProtectedBook() async throws {
        await assertConversionFails(try fixture("drm-v1.mobi"), with: .drmProtected)
    }

    func testRejectsKFXAndCorruptFiles() async throws {
        let kfx = directory.appendingPathComponent("book.azw")
        try Data("CONT\u{02}\u{00}".utf8 + [UInt8](repeating: 0, count: 100)).write(to: kfx)
        await assertConversionFails(kfx, with: .unsupportedKindleFormat)

        let drmKFX = directory.appendingPathComponent("drm.kfx")
        try Data([0xEA] + Array("DRMION".utf8) + [0xEE] + [UInt8](repeating: 0, count: 100)).write(to: drmKFX)
        await assertConversionFails(drmKFX, with: .unsupportedKindleFormat)

        let garbage = directory.appendingPathComponent("broken.mobi")
        try Data(repeating: 0x41, count: 200).write(to: garbage)
        await assertConversionFails(garbage, with: .invalidFile)

        var truncated = try Data(contentsOf: try fixture("kf8-ncx.azw3"))
        truncated = truncated.prefix(400)
        let truncatedURL = directory.appendingPathComponent("truncated.azw3")
        try truncated.write(to: truncatedURL)
        do {
            _ = try KindleEPUBConverter.makeEntries(source: truncatedURL)
            XCTFail("截断的文件不应转换成功")
        } catch let error as KindleImportError {
            XCTAssertTrue([.invalidFile, .conversionFailed].contains(error))
        }
    }

    func testFailedConversionLeavesNoOutput() async throws {
        let output = directory.appendingPathComponent("out.epub")
        do {
            try await KindleEPUBConverter.convert(source: try fixture("drm-v1.mobi"), destination: output)
            XCTFail("应拒绝 DRM")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    private func entryText(_ epub: URL, _ path: String) async throws -> String {
        let archive = try await Archive(url: epub, accessMode: .read)
        let found = try await archive.get(path)
        let entry = try XCTUnwrap(found, path)
        let extracted = directory.appendingPathComponent(UUID().uuidString)
        _ = try await archive.extract(entry, to: extracted)
        return try String(contentsOf: extracted, encoding: .utf8)
    }

    /// calibre 生成、样式表中原位写回 `@media amzn-kf8／amzn-mobi` 的 KF8 样本（见 scripts/make_kindle_fixtures.py）。
    func testKF8StylesAreFlattenedAndFootnotesKeepSemantics() async throws {
        let epub = try await convert("kindle-styles.azw3")
        let container = try await EPUBContainer.open(fileURL: epub)
        XCTAssertEqual(container.toc.map(\.title), ["第一章 排版", "第二章 注释", "第三章 尾注", "第四章 表格"])

        // flow 编号随 calibre 输出变化，按内容找到主样式表。
        let archive = try await Archive(url: epub, accessMode: .read)
        var css = ""
        for entry in try await archive.entries() where entry.path.hasSuffix(".css") {
            let text = try await entryText(epub, entry.path)
            if text.contains(".marker") { css = text }
        }
        XCTAssertFalse(css.contains("amzn-"), css)
        XCTAssertTrue(css.contains(".marker1{color:#b00020}"))
        XCTAssertTrue(css.contains(".marker2{display:none}"))
        XCTAssertFalse(css.contains(".marker1{display:none}"))
        XCTAssertTrue(css.contains("text-indent: 2em"))

        let notes = try await container.chapterHTML(at: 1)
        XCTAssertTrue(notes.contains("epub:type=\"noteref\""), notes)
        XCTAssertTrue(notes.contains("<aside epub:type=\"footnote\""), notes)
        XCTAssertFalse(notes.contains(" type=\"noteref\""))
        XCTAssertNotNil(EPUBFootnoteTarget.noteHTML(id: "fn1", inDocument: notes))
        XCTAssertTrue(notes.contains("href=\"#fn1\""), "同章注脚应为同文档链接")
        XCTAssertTrue(notes.contains("href=\"part00002.html#en1\""), "跨章尾注保留文件名")
        XCTAssertNotNil(EPUBFootnoteTarget.noteHTML(id: "note_1", inDocument: notes), "多看注释按目标识别")
        let endnotes = try await container.chapterHTML(at: 2)
        XCTAssertNotNil(EPUBFootnoteTarget.noteHTML(id: "en1", inDocument: endnotes))
        for index in container.spine.indices {
            let html = try await container.chapterHTML(at: index)
            XCTAssertTrue(XMLParser(data: Data(html.utf8)).parse(), "第 \(index) 章不是合法 XML")
        }
    }

    func testLegacyMOBIFormattingBecomesCSS() async throws {
        let epub = try await convert("kindle-styles.mobi")
        let container = try await EPUBContainer.open(fileURL: epub)
        // 四章正文与 calibre 生成的目录页；书尾只有空锚点的片段不成章。
        XCTAssertEqual(container.spine.count, 5)
        let first = try await container.chapterHTML(at: 0)
        XCTAssertTrue(first.contains("text-indent: 2em"), first)
        XCTAssertTrue(first.contains("text-align: center"))
        XCTAssertTrue(first.contains("font-size: xx-large"))
        XCTAssertTrue(first.contains("color: #b00020"))
        XCTAssertFalse(first.contains("<font"))
        XCTAssertFalse(first.contains("<p height="))
        XCTAssertTrue(first.contains("p { margin-top: 0; margin-bottom: 0; }"))
    }

    func testAddsRenditionLayoutForFixedLayoutBooks() {
        let opf = "<metadata><meta name=\"fixed-layout\" content=\"true\"/>\n </metadata>"
        XCTAssertEqual(KindleEPUBConverter.addingFixedLayoutRendition(to: opf),
                       "<metadata><meta name=\"fixed-layout\" content=\"true\"/>\n <meta property=\"rendition:layout\">pre-paginated</meta>\n </metadata>")
        let reflowable = "<metadata></metadata>"
        XCTAssertEqual(KindleEPUBConverter.addingFixedLayoutRendition(to: reflowable), reflowable)
    }

    private func assertConversionFails(_ url: URL, with expected: KindleImportError,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try KindleEPUBConverter.makeEntries(source: url)
            XCTFail("应失败：\(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? KindleImportError, expected, file: file, line: line)
        }
    }
}
