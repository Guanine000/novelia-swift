import XCTest
import UIKit
import WebKit
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

    /// 使用合成图复现 Readium 的双栏／孤行保护组合，不保存用户书籍内容。
    @MainActor
    func testReadiumStandaloneImagesDoNotFragmentAcrossColumns() async throws {
        let first = png(width: 746, height: 564).base64EncodedString()
        let second = png(width: 600, height: 799).base64EncodedString()
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"/>
        <style>
        html { height:100vh; column-count:2; column-gap:40px; column-fill:auto; }
        body { margin:0; padding:0 40px; box-sizing:border-box; widows:2; orphans:2; line-height:1.4; }
        img { width:auto; height:auto; max-width:100%; max-height:95vh!important;
              -webkit-column-break-inside:avoid; page-break-inside:avoid; break-inside:avoid; }
        </style></head><body><div style="height:400px">章节文字</div>
        <img id="first" src="data:image/png;base64,\(first)"/>
        <img id="second" src="data:image/png;base64,\(second)"/>
        <p>正文中的小图<img id="inline" width="16" height="16" src="data:image/png;base64,\(first)"/>继续正文</p>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1373, height: 800))
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func load(_ document: String) async throws {
            let navigation = ImageNavigationObserver()
            webView.navigationDelegate = navigation
            try await withCheckedThrowingContinuation { continuation in
                navigation.completion = continuation
                webView.loadHTMLString(document, baseURL: nil)
            }
        }
        let probe = """
        (() => {
          const first = document.getElementById('first');
          const second = document.getElementById('second');
          const a = first.getBoundingClientRect(), b = second.getBoundingClientRect();
          return { first:first.getClientRects().length, second:second.getClientRects().length,
                   separateColumn:b.x > a.x, height:b.height,
                   inline:getComputedStyle(document.getElementById('inline')).display };
        })()
        """
        try await load(html)
        let originalValue = try await webView.evaluateJavaScript(probe)
        let original = try XCTUnwrap(originalValue as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(original["second"] as? Int), 1, "原始行内插图应复现跨栏分片")

        let patched = EPUBReadiumImageLayout.keepingStandaloneImagesTogether(inHTML: html)
        for size in [CGSize(width: 1373, height: 800), CGSize(width: 800, height: 1100)] {
            webView.frame.size = size
            try await load(patched)
            let value = try await webView.evaluateJavaScript(probe)
            let result = try XCTUnwrap(value as? [String: Any])
            XCTAssertEqual(result["first"] as? Int, 1)
            XCTAssertEqual(result["second"] as? Int, 1)
            if size.width > size.height {
                XCTAssertEqual(result["separateColumn"] as? Bool, true)
            }
            XCTAssertLessThanOrEqual(try XCTUnwrap(result["height"] as? Double), Double(size.height))
            XCTAssertEqual(result["inline"] as? String, "inline", "段落内图片保持原有行内排版")
        }
    }

}


@MainActor
private final class ImageNavigationObserver: NSObject, WKNavigationDelegate {
    var completion: CheckedContinuation<Void, Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume()
        completion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error)
        completion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error)
        completion = nil
    }
}
