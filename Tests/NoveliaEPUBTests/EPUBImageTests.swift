import XCTest
import UIKit
import WebKit
import ReadiumZIPFoundation
@testable import NoveliaEPUB

/// 目录页“图片”与图片查看器：全书图片收集、路径解析与解码。
final class EPUBImageTests: XCTestCase {
    func testReadiumSVGAttributeNormalizationPreservesOtherContent() {
        let html = #"""
        <!-- <svg viewbox="comment"/> -->
        <script>const sample = '<svg viewbox="script"/>';</script>
        <![CDATA[<svg viewbox="cdata"/>]]>
        <div data-example='<svg viewbox="value"/>' viewbox="ordinary"/>
        <svg data-label="viewbox='text' >" viewbox='0 0 963 1351' preserveaspectratio="xMidYMid meet" width="100%"><image width="963" height="1351"/></svg>
        <svg viewBox="0 0 10 20" preserveAspectRatio="none"/>
        """#
        let result = EPUBReadiumImageLayout.normalizingSVGAttributes(inHTML: html)
        let expected = html.replacingOccurrences(of: "viewbox='0 0 963 1351'", with: "viewBox='0 0 963 1351'")
            .replacingOccurrences(of: "preserveaspectratio=\"xMidYMid meet\"", with: "preserveAspectRatio=\"xMidYMid meet\"")
        XCTAssertEqual(result, expected)
        XCTAssertEqual(EPUBReadiumImageLayout.normalizingSVGAttributes(inHTML: result), result)
        let duplicate = #"<svg viewbox="0 0 10 20" viewBox="0 0 30 40"/>"#
        XCTAssertEqual(EPUBReadiumImageLayout.normalizingSVGAttributes(inHTML: duplicate), duplicate)
    }

    /// 必须按 XHTML 加载；HTML 解析器会自动修正 SVG 大小写，掩盖实际 EPUB 故障。
    @MainActor
    func testReadiumLowercaseSVGViewBoxClipsImageUntilNormalized() async throws {
        let data = png(width: 963, height: 1351).base64EncodedString()
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta name="viewport" content="width=device-width,initial-scale=1"/>
        <style>body { margin:0 5pt; text-align:center; } div { display:block; }</style>
        </head><body><div>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" height="100%" preserveaspectratio="xMidYMid meet" version="1.1" viewbox="0 0 963 1351" width="100%"><image height="1351" width="963" xlink:href="data:image/png;base64,\(data)"/></svg>
        </div></body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 800))
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func probe(_ document: String) async throws -> [String: Double] {
            let navigation = ImageNavigationObserver()
            webView.navigationDelegate = navigation
            try await withCheckedThrowingContinuation { continuation in
                navigation.completion = continuation
                webView.load(Data(document.utf8), mimeType: "application/xhtml+xml",
                             characterEncodingName: "utf-8", baseURL: URL(string: "https://example.invalid/")!)
            }
            let value = try await webView.evaluateJavaScript("""
            (() => {
              const svg = document.querySelector('svg').getBoundingClientRect();
              const image = document.querySelector('image').getBoundingClientRect();
              return { width:svg.width, height:svg.height, imageWidth:image.width,
                       imageHeight:image.height, right:image.right-svg.right, bottom:image.bottom-svg.bottom };
            })()
            """)
            return try XCTUnwrap(value as? [String: Double])
        }
        let original = try await probe(html)
        XCTAssertGreaterThan(try XCTUnwrap(original["imageWidth"]), try XCTUnwrap(original["width"]))
        XCTAssertGreaterThan(try XCTUnwrap(original["imageHeight"]), try XCTUnwrap(original["height"]))
        for size in [CGSize(width: 430, height: 800), CGSize(width: 834, height: 1100), CGSize(width: 1100, height: 700)] {
            webView.frame.size = size
            let fixed = try await probe(EPUBReadiumImageLayout.normalizingSVGAttributes(inHTML: html))
            XCTAssertGreaterThan(try XCTUnwrap(fixed["imageWidth"]), 0)
            XCTAssertLessThanOrEqual(try XCTUnwrap(fixed["right"]), 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(fixed["bottom"]), 1)
            XCTAssertEqual(try XCTUnwrap(fixed["imageWidth"]) / XCTUnwrap(fixed["imageHeight"]), 963.0 / 1351, accuracy: 0.001)
        }
    }

    /// 按 XHTML 加载真实 SVG 命名空间；模拟 ReadiumCSS 的默认命名空间及多栏，
    /// 防止只在 HTML 或没有分页的 WebView 中验证而漏掉封面底部跨栏。
    @MainActor
    func testReadiumSVGCoverFitsOneColumnInXHTML() async throws {
        let data = png(width: 794, height: 1126).base64EncodedString()
        func document(columns: Int, wrapped: Bool, mediaHeight: String = "95vh") -> String {
            let cover = """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
                 width="100%" height="100%" viewBox="0 0 794 1126" preserveAspectRatio="none">
              <image width="794" height="1126" xlink:href="data:image/png;base64,\(data)"/>
            </svg>
            """
            return """
            <html xmlns="http://www.w3.org/1999/xhtml"><head>
            <meta name="viewport" content="width=device-width,initial-scale=1"/>
            <style>
            @namespace url("http://www.w3.org/1999/xhtml");
            html { height:100vh; column-count:\(columns); column-gap:0; column-fill:auto;
                   --RS__maxMediaHeight:\(mediaHeight); --RS__maxMediaWidth:100%; }
            body { margin:0; padding:0 20px; box-sizing:border-box; text-align:center; }
            img, svg { width:auto; height:auto; max-width:100%; max-height:var(--RS__maxMediaHeight)!important;
                       break-inside:avoid; }
            </style></head><body>\(wrapped ? "<div>\(cover)</div>" : cover)
            <p>正文<svg xmlns="http://www.w3.org/2000/svg" id="inline" width="16" height="16" viewBox="0 0 16 16"><rect width="16" height="16"/></svg>小图</p>
            </body></html>
            """
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1373, height: 798))
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func probe(_ html: String) async throws -> [String: Double] {
            let navigation = ImageNavigationObserver()
            webView.navigationDelegate = navigation
            try await withCheckedThrowingContinuation { continuation in
                navigation.completion = continuation
                webView.load(Data(html.utf8), mimeType: "application/xhtml+xml",
                             characterEncodingName: "utf-8", baseURL: URL(string: "https://example.invalid/")!)
            }
            let value = try await webView.evaluateJavaScript("""
            (() => {
              const svg=document.querySelector('svg'), image=svg.querySelector('image');
              const s=getComputedStyle(svg), r=svg.getBoundingClientRect(), i=image.getBoundingClientRect();
              const inline=document.getElementById('inline').getBoundingClientRect();
              return { fragments:svg.getClientRects().length, height:r.height, width:r.width,
                       imageWidth:i.width, imageHeight:i.height, limit:parseFloat(s.maxHeight) || 0,
                       bottom:r.bottom,
                       inlineWidth:inline.width, inlineHeight:inline.height };
            })()
            """)
            return try XCTUnwrap(value as? [String: Double])
        }
        let original = try await probe(document(columns: 2, wrapped: true))
        XCTAssertGreaterThan(try XCTUnwrap(original["fragments"]), 1)
        XCTAssertEqual(original["limit"], 0)
        for (size, columns) in [(CGSize(width: 430, height: 800), 1),
                                (CGSize(width: 834, height: 1100), 1),
                                (CGSize(width: 1373, height: 798), 2)] {
            webView.frame.size = size
            for wrapped in [true, false] {
                let html = document(columns: columns, wrapped: wrapped, mediaHeight: "90vh")
                let fixed = try await probe(EPUBReadiumImageLayout.keepingStandaloneImagesTogether(inHTML: html))
                XCTAssertEqual(fixed["fragments"], 1)
                XCTAssertGreaterThan(try XCTUnwrap(fixed["imageWidth"]), 0)
                XCTAssertLessThanOrEqual(try XCTUnwrap(fixed["height"]), Double(size.height) * 0.9 + 1)
                XCTAssertLessThanOrEqual(try XCTUnwrap(fixed["width"]), Double(size.width) / Double(columns) + 1)
                XCTAssertLessThanOrEqual(try XCTUnwrap(fixed["bottom"]), Double(size.height) + 1)
                XCTAssertEqual(try XCTUnwrap(fixed["imageWidth"]) / XCTUnwrap(fixed["imageHeight"]), 794.0 / 1126, accuracy: 0.001)
                XCTAssertEqual(fixed["inlineWidth"], 16)
                XCTAssertEqual(fixed["inlineHeight"], 16)
            }
        }
    }

    @MainActor
    func testReadiumNearWhitePageBackgroundIsReversibleAndPreservesArtwork() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 834, height: 1100))
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><style>
        html { background-color:#faf7f0; }
        body { background:white url('data:image/png;base64,\(png(width: 2, height: 2).base64EncodedString())'); }
        #local { background-color:white; color:black; }
        </style></head><body style="background-color:white!important"><p id="local">局部底色</p></body></html>
        """
        let navigation = ImageNavigationObserver()
        webView.navigationDelegate = navigation
        try await withCheckedThrowingContinuation { continuation in
            navigation.completion = continuation
            webView.load(Data(html.utf8), mimeType: "application/xhtml+xml", characterEncodingName: "utf-8",
                         baseURL: URL(string: "https://example.invalid/")!)
        }
        func apply(_ ignores: Bool) async throws {
            _ = try await webView.evaluateJavaScript(EPUBReadiumPageBackground.script(ignoresNearWhite: ignores, threshold: 240.0 / 255))
        }
        func probe() async throws -> [String: String] {
            let result = try await webView.evaluateJavaScript("""
            (() => ({root:getComputedStyle(document.documentElement).backgroundColor,
                     body:getComputedStyle(document.body).backgroundColor,
                     image:getComputedStyle(document.body).backgroundImage,
                     local:getComputedStyle(document.getElementById('local')).backgroundColor,
                     priority:document.body.style.getPropertyPriority('background-color')}))()
            """)
            return try XCTUnwrap(result as? [String: String])
        }
        let original = try await probe()
        for _ in 0..<2 {
            try await apply(true)
            let clear = try await probe()
            XCTAssertEqual(clear["root"], "rgba(0, 0, 0, 0)")
            XCTAssertEqual(clear["body"], "rgba(0, 0, 0, 0)")
            XCTAssertEqual(clear["image"], original["image"])
            XCTAssertEqual(clear["local"], "rgb(255, 255, 255)")
        }
        try await apply(false)
        let restored = try await probe()
        XCTAssertEqual(restored, original, "切换规则应还原书内颜色、背景图片和行内 important")

        // 先清除白底，再模拟主题/书内脚本改为黑底；重算不能用旧缓存覆盖新颜色。
        try await apply(true)
        _ = try await webView.evaluateJavaScript("document.body.style.setProperty('background-color', 'black', 'important')")
        try await apply(true)
        let dark = try await probe()
        XCTAssertEqual(dark["body"], "rgb(0, 0, 0)")
        try await apply(false)
        _ = try await webView.evaluateJavaScript("document.body.style.setProperty('background-color', '#88c1ec', 'important')")
        try await apply(true)
        let colored = try await probe()
        XCTAssertEqual(colored["body"], "rgb(136, 193, 236)")
        XCTAssertEqual(colored["image"], original["image"])
    }

    /// 样式刷新可能由页面变化回调触发；相同配置必须停在稳定状态，不能再产生变化回调。
    @MainActor
    func testReadiumAppearanceDoesNotFeedBackIntoDocumentChanges() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 834, height: 1100))
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let navigation = ImageNavigationObserver()
        webView.navigationDelegate = navigation
        try await withCheckedThrowingContinuation { continuation in
            navigation.completion = continuation
            let html = "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>body{background:white}</style></head><body><p>正文</p></body></html>"
            webView.load(Data(html.utf8), mimeType: "application/xhtml+xml", characterEncodingName: "utf-8",
                         baseURL: URL(string: "https://example.invalid/")!)
        }
        let script = EPUBReadiumPageBackground.script(ignoresNearWhite: true, threshold: 240.0 / 255)
        let encoded = try JSONSerialization.data(withJSONObject: [script])
        let literal = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("""
        window.appearanceScript = \(literal)[0];
        window.appearanceCallbacks = 0;
        window.appearanceMutations = 0;
        window.appearanceObserver = new MutationObserver(records => {
          window.appearanceCallbacks++;
          window.appearanceMutations += records.length;
          // 上限防止旧实现让测试进程无限循环；正确实现应第一次回调后即稳定。
          if (window.appearanceCallbacks < 20) eval(window.appearanceScript);
        });
        window.appearanceObserver.observe(document.documentElement, {subtree:true,childList:true,attributes:true,characterData:true});
        eval(window.appearanceScript);
        """)
        try await Task.sleep(nanoseconds: 100_000_000)
        let result = try await webView.evaluateJavaScript("({callbacks:window.appearanceCallbacks,mutations:window.appearanceMutations})")
        let counts = try XCTUnwrap(result as? [String: Int])
        XCTAssertGreaterThan(counts["mutations"] ?? 0, 0)
        XCTAssertLessThanOrEqual(counts["callbacks"] ?? 20, 2, "同配置样式必须停止改写 DOM")
        _ = try await webView.evaluateJavaScript("window.appearanceObserver.disconnect()")
    }

    /// 在深色时开启去白底，切回浅色仍须处理恢复出来的书内白底。
    @MainActor
    func testReadiumWhiteBackgroundTracksOnlyActualThemeChanges() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 800))
        let navigation = ImageNavigationObserver()
        webView.navigationDelegate = navigation
        try await withCheckedThrowingContinuation { continuation in
            navigation.completion = continuation
            let html = """
            <html xmlns="http://www.w3.org/1999/xhtml" style="--USER__appearance:readium-night-on"><head><style>
            body { background:white; color:#123456; }
            :root[style*="readium-night-on"] body { background-color:transparent !important; }
            </style></head><body><p>正文</p></body></html>
            """
            webView.load(Data(html.utf8), mimeType: "application/xhtml+xml", characterEncodingName: "utf-8",
                         baseURL: URL(string: "https://example.invalid/")!)
        }
        let on = EPUBReadiumPageBackground.script(ignoresNearWhite: true, threshold: 240.0 / 255)
        let off = EPUBReadiumPageBackground.script(ignoresNearWhite: false, threshold: 240.0 / 255)
        _ = try await webView.evaluateJavaScript(on)
        for _ in 0..<3 {
            _ = try await webView.evaluateJavaScript("document.documentElement.style.removeProperty('--USER__appearance')")
            try await Task.sleep(nanoseconds: 50_000_000)
            let value = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
            XCTAssertEqual(value as? String, "rgba(0, 0, 0, 0)")
            let color = try await webView.evaluateJavaScript("getComputedStyle(document.body).color")
            XCTAssertEqual(color as? String, "rgb(18, 52, 86)", "去白底不覆盖文字色")
            _ = try await webView.evaluateJavaScript("document.documentElement.style.setProperty('--USER__appearance','readium-night-on')")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await webView.evaluateJavaScript(off)
        _ = try await webView.evaluateJavaScript("document.documentElement.style.removeProperty('--USER__appearance')")
        try await Task.sleep(nanoseconds: 50_000_000)
        let restored = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(restored as? String, "rgb(255, 255, 255)")
        let observer = try await webView.evaluateJavaScript("!!document.__noveliaWhiteBackgroundObserver")
        XCTAssertEqual(observer as? Bool, false, "关闭规则后移除观察，恢复出版社底色")
    }

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
