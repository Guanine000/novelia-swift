import XCTest
import UIKit
import ReadiumZIPFoundation
@testable import NoveliaEPUB

/// 目录页“图片”与图片查看器：全书图片收集、路径解析与解码。
final class EPUBImageTests: XCTestCase {
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func book() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let opf = """
        <package><metadata><title>图片测试</title></metadata><manifest>
        <item id="a" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
        <item id="b" href="Text/two.xhtml" media-type="application/xhtml+xml"/>
        <item id="i1" href="Images/illust.png" media-type="image/png"/>
        <item id="i2" href="Images/note.png" media-type="image/png"/>
        <item id="i3" href="Images/svg-cover.png" media-type="image/png"/>
        <item id="i4" href="Images/unused.png" media-type="image/png"/>
        </manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>
        """
        let one = """
        <html><body><p>正文<img src="../Images/note.png"/></p>
        <svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../Images/svg-cover.png"/></svg>
        <img src="data:image/png;base64,AAAA"/><img src="https://example.com/x.png"/></body></html>
        """
        let two = "<html><body><div><img src=\"../Images/illust.png#frag\" alt=\"插图\"/></div><img src=\"/Book/Images/illust.png\"/></body></html>"
        let entries: [(String, Data)] = [
            ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path='Book/content.opf'/></rootfiles></container>".utf8)),
            ("Book/content.opf", Data(opf.utf8)),
            ("Book/Text/one.xhtml", Data(one.utf8)),
            ("Book/Text/two.xhtml", Data(two.utf8)),
            ("Book/Images/illust.png", png(width: 600, height: 900)),
            ("Book/Images/note.png", png(width: 40, height: 40)),
            ("Book/Images/svg-cover.png", png(width: 300, height: 400)),
            ("Book/Images/unused.png", png(width: 200, height: 200)),
        ]
        let url = directory.appendingPathComponent("book.epub")
        let zip = try await Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            let temporary = directory.appendingPathComponent("entry")
            try data.write(to: temporary)
            try await zip.addEntry(with: path, fileURL: temporary, compressionMethod: .none)
        }
        return url
    }

    func testImageSourcesAndPathResolution() {
        let html = "<img src=\"a.png\"/><image xlink:href=\"b&amp;c.png\"/><img src=\"a.png\"/>"
        XCTAssertEqual(EPUBContainer.imageSources(inChapterHTML: html), ["a.png", "b&c.png"])
        XCTAssertEqual(EPUBContainer.resolveImagePath(src: "../Images/x.jpg#f", chapterHref: "OEBPS/Text/c1.xhtml"),
                       "OEBPS/Images/x.jpg")
        XCTAssertEqual(EPUBContainer.resolveImagePath(src: "/OEBPS/Images/x.jpg", chapterHref: "OEBPS/Text/c1.xhtml"),
                       "OEBPS/Images/x.jpg")
        XCTAssertNil(EPUBContainer.resolveImagePath(src: "data:image/png;base64,AAAA", chapterHref: "a.xhtml"))
        XCTAssertNil(EPUBContainer.resolveImagePath(src: "https://example.com/x.png", chapterHref: "a.xhtml"))
    }

    func testAllImagesFollowsSpineSkipsIconsAndAppendsUnreferenced() async throws {
        let container = try await EPUBContainer.open(fileURL: try await book())
        let images = await container.allImages()
        XCTAssertEqual(images.map(\.path), ["Book/Images/svg-cover.png", "Book/Images/illust.png", "Book/Images/unused.png"])
        XCTAssertEqual(images.map(\.spineIndex), [0, 1, nil])
    }

    func testPackagePathFromReaderURLAndDecoding() async throws {
        let container = try await EPUBContainer.open(fileURL: try await book())
        let url = try XCTUnwrap(URL(string: "https://readium/publication/Book/Images/illust.png"))
        let path = await container.packagePath(forImageURL: url)
        XCTAssertEqual(path, "Book/Images/illust.png")
        let missing = try XCTUnwrap(URL(string: "https://readium/publication/Book/Images/none.png"))
        let none = await container.packagePath(forImageURL: missing)
        XCTAssertNil(none)

        let entry = await container.entryData(atPath: "Book/Images/illust.png")
        let data = try XCTUnwrap(entry)
        XCTAssertEqual(EPUBImageDecoding.pixelSize(of: data), CGSize(width: 600, height: 900))
        let thumbnail = try XCTUnwrap(EPUBImageDecoding.image(from: data, maxPixelLength: 90))
        XCTAssertEqual(max(thumbnail.size.width, thumbnail.size.height), 90, accuracy: 1)
        let full = try XCTUnwrap(EPUBImageDecoding.image(from: data, maxPixelLength: nil))
        XCTAssertEqual(full.size, CGSize(width: 600, height: 900))
    }
}
