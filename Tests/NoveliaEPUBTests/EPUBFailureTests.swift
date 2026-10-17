import XCTest
import UIKit
import ReadiumZIPFoundation
@testable import NoveliaEPUB

/// 只使用临时合成书籍，验证损坏文件不会被误报为 OPF 缺失或改写原文件。
final class EPUBFailureTests: XCTestCase {
    private let containerXML = "<container><rootfiles><rootfile full-path='Book/content.opf'/></rootfiles></container>"
    private let opf = """
    <package><metadata><title>故障测试</title></metadata><manifest>
    <item id="a" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
    <item id="b" href="Text/two.xhtml" media-type="application/xhtml+xml"/>
    </manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>
    """

    private func archive(_ entries: [(String, Data)]) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        let zip = try await Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            let temporary = directory.appendingPathComponent("entry")
            try data.write(to: temporary)
            try await zip.addEntry(with: path, fileURL: temporary, compressionMethod: .none)
        }
        return url
    }

    private func book(chapter: String = "<html><body><p>正文</p></body></html>",
                      extras: [(String, Data)] = []) async throws -> URL {
        try await archive([
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("Book/content.opf", Data(opf.utf8)),
            ("Book/Text/two.xhtml", Data(chapter.utf8)),
        ] + extras)
    }

    func testInvalidArchiveHasSpecificErrorAndPreservesInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.epub")
        let original = Data("PK but not a zip archive".utf8)
        try original.write(to: url)
        do {
            _ = try await EPUBContainer.open(fileURL: url)
            XCTFail("must reject invalid archive")
        } catch EPUBError.cannotOpenArchive {} catch { XCTFail("unexpected: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMissingContainerAndOPFAreDistinct() async throws {
        let noContainer = try await archive([("mimetype", Data("application/epub+zip".utf8))])
        do {
            _ = try await EPUBContainer.open(fileURL: noContainer)
            XCTFail("missing container")
        } catch EPUBError.missingContainer {} catch { XCTFail("unexpected: \(error)") }
        let noOPF = try await archive([("META-INF/container.xml", Data(containerXML.utf8))])
        do {
            _ = try await EPUBContainer.open(fileURL: noOPF)
            XCTFail("missing OPF")
        } catch EPUBError.missingOPF {} catch { XCTFail("unexpected: \(error)") }
    }

    func testEmptyOrUnresolvedSpineIsRejected() async throws {
        for spine in ["", "<itemref idref='unknown'/>"] {
            let url = try await archive([
                ("META-INF/container.xml", Data(containerXML.utf8)),
                ("Book/content.opf", Data("<package><manifest/><spine>\(spine)</spine></package>".utf8)),
            ])
            do {
                _ = try await EPUBContainer.open(fileURL: url)
                XCTFail("no readable chapters")
            } catch EPUBError.emptySpine {} catch { XCTFail("unexpected: \(error)") }
        }
    }

    func testMissingChapterDoesNotPreventReadingOtherChapterOrMutateBook() async throws {
        let url = try await book()
        let original = try Data(contentsOf: url)
        let publication = try await EPUBContainer.open(fileURL: url)
        for _ in 0..<2 {
            do {
                _ = try await publication.chapterHTML(at: 0)
                XCTFail("missing chapter must fail on every retry")
            } catch EPUBError.missingChapter(let path) {
                XCTAssertEqual(path, "Book/Text/one.xhtml")
            } catch { XCTFail("unexpected: \(error)") }
        }
        let readable = try await publication.chapterHTML(at: 1)
        XCTAssertTrue(readable.contains("正文"))
        XCTAssertNotNil(publication.tocDiagnostic)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testInvalidChapterPositionIsNotReportedAsEmptyBook() async throws {
        let publication = try await EPUBContainer.open(fileURL: book())
        do {
            _ = try await publication.chapterHTML(at: 9)
            XCTFail("invalid chapter")
        } catch EPUBError.invalidChapter(let index) {
            XCTAssertEqual(index, 9)
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testUnlistedImageCanResolveEncodedCaseInsensitivePath() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let html = "<html><body><img src='../images/my%20image.png'/><img src='../images/missing.png'/></body></html>"
        let url = try await book(chapter: html, extras: [("Book/Images/My Image.PNG", image)])
        let publication = try await EPUBContainer.open(fileURL: url)
        let content = try await publication.chapterHTML(at: 1)
        let images = await publication.images(forChapterHTML: content, chapterHref: publication.spine[1].href)
        XCTAssertNotNil(images["../images/my%20image.png"])
        // 缺失图片占位存在，避免排版引擎因缺少资源让整章失败。
        XCTAssertNotNil(images["../images/missing.png"])
        XCTAssertEqual(images.count, 2)
    }

    func testMissingImageFallsBackToPlaceholderSoChapterStaysReadable() async throws {
        let html = "<html><body><p>正文</p><img src='Images/absent.png'/><img src='https://example.com/remote.png'/></body></html>"
        let url = try await book(chapter: html)
        let publication = try await EPUBContainer.open(fileURL: url)
        let content = try await publication.chapterHTML(at: 1)
        let images = await publication.images(forChapterHTML: content, chapterHref: publication.spine[1].href)
        let missing = try XCTUnwrap(images["Images/absent.png"], "缺图必须回退占位图，否则整章排版失败")
        XCTAssertEqual(missing.size, CGSize(width: 1, height: 1))
        XCTAssertNotNil(images["https://example.com/remote.png"], "包外资源同样需要占位")
    }

    func testReadiumPreflightRejectsMissingChapterBeforeOpening() async throws {
        let url = try await book()
        let publication = try await EPUBContainer.open(fileURL: url)
        do {
            try await publication.validateForReadium()
            XCTFail("preflight must reject missing chapter")
        } catch EPUBError.missingChapter(let path) {
            XCTAssertEqual(path, "Book/Text/one.xhtml")
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testReadiumPreflightAcceptsReadableBook() async throws {
        let url = try await archive([
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("Book/content.opf", Data(opf.utf8)),
            ("Book/Text/one.xhtml", Data("<html><body><p>第一章</p></body></html>".utf8)),
            ("Book/Text/two.xhtml", Data("<html><body><p>第二章</p></body></html>".utf8)),
        ])
        let publication = try await EPUBContainer.open(fileURL: url)
        try await publication.validateForReadium()
        XCTAssertEqual(publication.spine.count, 2)
    }

    func testCorruptChapterIsReportedAsUnreadableEntry() async throws {
        let marker = "unique-chapter-payload"
        let url = try await book(chapter: marker)
        var bytes = try Data(contentsOf: url)
        let range = try XCTUnwrap(bytes.range(of: Data(marker.utf8)))
        bytes[range.lowerBound] ^= 1 // 保留 ZIP 结构，制造正文 CRC 不匹配。
        try bytes.write(to: url)
        let publication = try await EPUBContainer.open(fileURL: url)
        do {
            _ = try await publication.chapterHTML(at: 1)
            XCTFail("corrupt entry")
        } catch EPUBError.unreadableEntry(let path) {
            XCTAssertEqual(path, "Book/Text/two.xhtml")
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testOversizeContainerKeepsSizeErrorInsteadOfMissingContainer() async throws {
        let url = try await book()
        var bytes = try Data(contentsOf: url)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let central = try XCTUnwrap(bytes.range(of: signature)).lowerBound
        var size = UInt32(EPUBContainer.maxEntryBytes + 1).littleEndian
        withUnsafeBytes(of: &size) { bytes.replaceSubrange((central + 24)..<(central + 28), with: $0) }
        try bytes.write(to: url)
        do {
            _ = try await EPUBContainer.open(fileURL: url)
            XCTFail("oversize entry")
        } catch EPUBError.entryTooLarge {} catch { XCTFail("unexpected: \(error)") }
    }

    func testFailureLogsNeverIncludeEntryPaths() {
        let secret = "私人书名/正文.xhtml"
        XCTAssertEqual(EPUBLayoutLog.failure(EPUBError.missingChapter(path: secret)).kind, "chapterMissing")
        XCTAssertEqual(EPUBLayoutLog.failure(EPUBError.unreadableEntry(path: secret)).kind, "entryRead")
        XCTAssertEqual(EPUBLayoutLog.failure(EPUBError.invalidChapter(index: 8)).kind, "chapterIndex")
    }
}
