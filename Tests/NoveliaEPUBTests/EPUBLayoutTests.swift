import CoreText
import UIKit
import XCTest
import YueduCoreText
@testable import NoveliaEPUB

/// 中日韩文本两端对齐的全书排版检查。
///
/// “间隙”指中日韩字形的前进宽度减去引擎添加的字距后，仍超过 1.3 em：
/// 这是 Core Text 在仅部分字符调整字距的行中压缩标点时留下的半字空隙。
/// “宽度不匹配”指一行的实际绘制宽度与排版宽度相差超过 1 pt，
/// 即文字可能越过页边距。
final class EPUBLayoutTests: XCTestCase {
    struct Report: CustomStringConvertible {
        var pages = 0
        var lines = 0
        var gaps = 0
        var widthMismatches = 0
        var examples: [String] = []
        var description: String {
            "pages=\(pages) lines=\(lines) gaps=\(gaps) widthMismatches=\(widthMismatches)"
                + examples.map { "\n  \($0)" }.joined()
        }
    }

    /// 阅读器在 440 × 956 pt 手机上的默认页面（见 EPUBReaderStyle）。
    @MainActor
    static func readerConfig(workarounds: Bool) -> BrowserLayoutConfig {
        let size = CGSize(width: 440, height: 956)
        let insets = UIEdgeInsets(top: 64, left: 20, bottom: 72, right: 20)
        var config = BrowserLayoutConfig()
        config.renderWidth = size.width - insets.left - insets.right
        config.renderHeight = size.height - insets.top - insets.bottom
        config.rootFontSize = 21
        config.contentInsets = insets
        config.defaultTextAlignment = .natural
        if workarounds { EPUBPageBook.applyEngineWorkarounds(to: &config) }
        return config
    }

    @MainActor
    static func scan(_ url: URL, workarounds: Bool = true) async throws -> Report {
        let container = try await EPUBContainer.open(fileURL: url)
        let config = readerConfig(workarounds: workarounds)
        let book = EPUBPageBook(generation: 1)
        var report = Report()
        for spine in container.spine.indices {
            try await book.layoutChapter(spine, container: container, config: config, aspectRatio: 440 / 956)
            let lists = book.displayLists(spineIndex: spine)
            report.pages += lists.count
            for list in lists {
                for item in list.items {
                    guard case .text(let text) = item, text.text.count > 1 else { continue }
                    report.lines += 1
                    let attributed = text.attributedText
                    let line = CTLineCreateWithAttributedString(attributed)
                    let drawn = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
                    let mismatch = abs(drawn - text.rect.rawValue.width) > 1
                    var gap = false
                    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                        let count = CTRunGetGlyphCount(run)
                        var advances = [CGSize](repeating: .zero, count: count)
                        var indices = [CFIndex](repeating: 0, count: count)
                        CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
                        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
                        for (advance, index) in zip(advances, indices) {
                            let kern = (attributed.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                            // 仅检查中日韩字形：破折号和省略号超过 1.3 em 是正常情况。
                            let scalar = (attributed.string as NSString).character(at: index)
                            if scalar >= 0x3000, advance.width - CGFloat(kern) > text.font.pointSize * 1.3 { gap = true }
                        }
                    }
                    if gap { report.gaps += 1 }
                    if mismatch { report.widthMismatches += 1 }
                    if (gap || mismatch), report.examples.count < 5 {
                        report.examples.append("\(text.text) [drawn \(Int(drawn)) / laid out \(Int(text.rect.rawValue.width))]")
                    }
                }
            }
        }
        return report
    }

    func testJustifiedCJKHasNoGaps() async throws {
        let report = try await Self.scan(try EPUBMetadataTests.fixture("justified_cjk"))
        XCTAssertGreaterThan(report.lines, 50, "fixture should produce many justified lines")
        XCTAssertEqual(report.gaps, 0, report.description)
        XCTAssertEqual(report.widthMismatches, 0, report.description)
    }

    /// 验证兼容处理仍有必要：当 YueduCoreText 无需此处理也不再留下间隙时，测试失败，
    /// 提示应移除 `EPUBPageBook.applyEngineWorkarounds`。
    func testEngineStillNeedsWorkaround() async throws {
        let report = try await Self.scan(try EPUBMetadataTests.fixture("justified_cjk"), workarounds: false)
        XCTAssertGreaterThan(report.gaps, 0, "YueduCoreText justifies cleanly without the workaround; remove it. \(report)")
    }

    /// 阅读位置保存为章节偏移量；每页必须能映射回自身。
    @MainActor
    func testPageOffsetsRoundTrip() async throws {
        let container = try await EPUBContainer.open(fileURL: try EPUBMetadataTests.fixture("justified_cjk"))
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: container, config: Self.readerConfig(workarounds: true), aspectRatio: 440 / 956)
        let count = book.pageCount(spineIndex: 0)
        XCTAssertGreaterThan(count, 2)
        var previous = -1
        for page in 0..<count {
            let offset = try XCTUnwrap(book.sourceOffset(spineIndex: 0, pageIndex: page), "page \(page)")
            XCTAssertGreaterThan(offset, previous, "offsets increase")
            previous = offset
            XCTAssertEqual(book.pageIndex(spineIndex: 0, containingSourceOffset: offset), page)
            XCTAssertEqual(book.pageIndex(spineIndex: 0, containingSourceOffset: offset + 1), page)
        }
    }

    /// 字号变化后，阅读器重新打开显示同一文本的页面。
    @MainActor
    func testOffsetSurvivesRepagination() async throws {
        let container = try await EPUBContainer.open(fileURL: try EPUBMetadataTests.fixture("justified_cjk"))
        let original = EPUBPageBook(generation: 1)
        try await original.layoutChapter(0, container: container, config: Self.readerConfig(workarounds: true), aspectRatio: 440 / 956)
        var larger = Self.readerConfig(workarounds: true)
        larger.rootFontSize = 27
        let resized = EPUBPageBook(generation: 2)
        try await resized.layoutChapter(0, container: container, config: larger, aspectRatio: 440 / 956)
        XCTAssertGreaterThan(resized.pageCount(spineIndex: 0), original.pageCount(spineIndex: 0))
        for page in 0..<original.pageCount(spineIndex: 0) {
            let offset = try XCTUnwrap(original.sourceOffset(spineIndex: 0, pageIndex: page))
            let target = try XCTUnwrap(resized.pageIndex(spineIndex: 0, containingSourceOffset: offset))
            let drawn = resized.displayLists(spineIndex: 0)[target].items.contains { item in
                guard case .text(let text) = item else { return false }
                return NSLocationInRange(offset, text.sourceRange)
            }
            XCTAssertTrue(drawn, "page \(page) text not on resized page \(target)")
        }
    }

    @MainActor
    func testNearWhiteFillsPreserveBordersColoredSurfacesAndMarkers() {
        var border = BorderEdge.zero
        border.width = 2; border.color = .red
        func fill(_ color: UIColor, marker: Bool = false) -> DisplayItem {
            .fill(DisplayFillItem(rect: PageLocalRect(rawValue: CGRect(x: 1, y: 2, width: 100, height: 30)),
                color: color, cornerRadius: 3, borderTop: border, borderBottom: .zero,
                borderLeft: .zero, borderRight: .zero, nodeID: 4, writingMode: .horizontal,
                followsTextColor: marker))
        }
        let original = DisplayList(items: [fill(.white), fill(UIColor(white: 252.0 / 255, alpha: 1)),
            fill(.yellow), fill(.white, marker: true)])
        let filtered = EPUBPageBook.removingNearWhiteFills(from: original, enabled: true)
        for (index, item) in filtered.items.enumerated() {
            guard case .fill(let value) = item else { return XCTFail("Missing fill") }
            XCTAssertEqual(value.color, index < 2 ? .clear : (index == 2 ? .yellow : .white))
            XCTAssertEqual(value.borderTop, border)
            XCTAssertEqual(value.cornerRadius, 3)
            XCTAssertEqual(value.nodeID, 4)
        }
        XCTAssertTrue(EPUBPageBook.removingNearWhiteFills(from: original, enabled: false).hasSameContents(as: original))
    }

    /// `scripts/scan_epub_layout.sh <book.epub>` 可对任意本地 EPUB 运行此检查。
    func testScanExternalBook() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCAN_EPUB"], !path.isEmpty else {
            throw XCTSkip("Set SCAN_EPUB (via scripts/scan_epub_layout.sh) to scan a local book.")
        }
        let url = URL(fileURLWithPath: path)
        let current = try await Self.scan(url)
        let without = try await Self.scan(url, workarounds: false)
        for (label, report) in [("with workaround", current), ("without workaround", without)] {
            print("SCAN_RESULT \(label): pages=\(report.pages) lines=\(report.lines) gaps=\(report.gaps) widthMismatches=\(report.widthMismatches)")
            for example in report.examples { print("SCAN_EXAMPLE   \(example)") }
        }
    }

    // MARK: - 竖排分页、跟随书籍与单章自动回退

    @MainActor
    private final class StubChapterSource: EPUBChapterSource {
        let bookTitle = "Stub"
        let chapters: [(html: String, css: [String])]
        let stubImages: [String: UIImage]
        let prefersVerticalByDefault: Bool
        var themeTextColor: UIColor = .black
        var chapterCount: Int { chapters.count }
        var toc: [EPUBTOCEntry] { [] }

        init(chapters: [(html: String, css: [String])], images: [String: UIImage] = [:], prefersVerticalByDefault: Bool = false) {
            self.chapters = chapters
            self.stubImages = images
            self.prefersVerticalByDefault = prefersVerticalByDefault
        }

        func chapterHref(at index: Int) -> String { "ch\(index).xhtml" }
        func chapterHTML(at index: Int) async throws -> String { chapters[index].html }
        func cssTexts(forChapterHTML html: String, chapterHref: String, aspectRatio: CGFloat) async -> [String] {
            chapters.first(where: { $0.html == html })?.css ?? []
        }
        func images(forChapterHTML html: String, chapterHref: String) async -> [String: UIImage] { stubImages }
        func spineIndex(forLinkHref href: String, relativeTo chapterHref: String) -> Int? { nil }
    }

    @MainActor
    func testVerticalPagingOnHorizontalEPUBAndOffsetsRoundTrip() async throws {
        let container = try await EPUBContainer.open(fileURL: try EPUBMetadataTests.fixture("justified_cjk"))
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(
            0, container: container, config: Self.readerConfig(workarounds: true),
            aspectRatio: 440 / 956, writingDirection: .verticalRTL)
        XCTAssertEqual(book.writingMode(spineIndex: 0), .verticalRTL)
        XCTAssertNil(book.verticalFallbackFeatures(spineIndex: 0))
        let count = book.pageCount(spineIndex: 0)
        XCTAssertGreaterThan(count, 2)
        var previous = -1
        for page in 0..<count {
            let offset = try XCTUnwrap(book.sourceOffset(spineIndex: 0, pageIndex: page), "page \(page)")
            XCTAssertGreaterThan(offset, previous)
            previous = offset
            XCTAssertEqual(book.pageIndex(spineIndex: 0, containingSourceOffset: offset), page)
        }
    }

    @MainActor
    func testVerticalPagingOnTextChapterSource() async throws {
        let paragraphs = (0..<24).map { index in
            TextChapterParagraph(text: "第\(index + 1)段：窗外下着细雨，远山被雾气笼罩，书页在指尖轻轻翻动。")
        }
        let source = TextChapterSource(bookTitle: "竖排纯文本测试", units: [
            .init(tocTitle: "第一章", load: {
                TextChapterContent(title: "第一章", paragraphs: paragraphs)
            })
        ])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(
            0, container: source, config: Self.readerConfig(workarounds: true),
            aspectRatio: 440 / 956, writingDirection: .verticalRTL)
        XCTAssertEqual(book.writingMode(spineIndex: 0), .verticalRTL)
        XCTAssertNil(book.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 1)
    }

    @MainActor
    func testBookDefaultFollowsDeclaredWritingModeAndHorizontalOverrideWorks() async throws {
        let verticalHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><style>html { writing-mode: vertical-rl; }</style></head>
        <body><p>这是一段原生声明了竖排的中文正文内容，用于验证跟随书籍模式与手动切横排。</p></body></html>
        """
        let horizontalHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head></head>
        <body><p>这是一段未声明竖排的普通横排正文。</p></body></html>
        """
        let source = StubChapterSource(chapters: [(verticalHTML, []), (horizontalHTML, [])])

        let autoBook = EPUBPageBook(generation: 1)
        try await autoBook.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                         aspectRatio: 440 / 956, writingDirection: .bookDefault)
        try await autoBook.layoutChapter(1, container: source, config: Self.readerConfig(workarounds: true),
                                         aspectRatio: 440 / 956, writingDirection: .bookDefault)
        XCTAssertEqual(autoBook.writingMode(spineIndex: 0), .verticalRTL)
        XCTAssertNil(autoBook.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertEqual(autoBook.writingMode(spineIndex: 1), .horizontal)

        let forcedHorizontalBook = EPUBPageBook(generation: 2)
        try await forcedHorizontalBook.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                                     aspectRatio: 440 / 956, writingDirection: .horizontal)
        XCTAssertEqual(forcedHorizontalBook.writingMode(spineIndex: 0), .horizontal)
        XCTAssertNil(forcedHorizontalBook.verticalFallbackFeatures(spineIndex: 0))
    }

    @MainActor
    func testVerticalChapterEmbedsSimpleTableAsImageWithoutFallback() async throws {
        // 单页可容纳的简单 <table> 在竖排模式下应离屏渲染为横排图片嵌回原位，整章保持竖排不回退。
        let tableHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><style>
        html { writing-mode: vertical-rl; }
        table { border-collapse: separate; border-spacing: 4px; }
        td, th { border: 1px solid #888; padding: 4px 8px; }
        </style></head>
        <body><p>表前正文。</p><table><tr><th>角色</th><th>说明</th></tr><tr><td>林舟</td><td>图书室</td></tr></table><p>表后正文。</p></body></html>
        """
        let source = StubChapterSource(chapters: [(tableHTML, [])])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                     aspectRatio: 440 / 956, writingDirection: .verticalRTL)
        XCTAssertEqual(book.writingMode(spineIndex: 0), .verticalRTL)
        XCTAssertNil(book.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 0)
        let hasTableImage = book.displayLists(spineIndex: 0).flatMap(\.items).contains { item in
            if case .image(let image) = item { return image.source.hasPrefix("__novelia_vertical_table_") }
            return false
        }
        XCTAssertTrue(hasTableImage, "vertical chapter should embed rasterized table image")
    }

    @MainActor
    func testUnsupportedVerticalChapterAutomaticallyFallsBackToHorizontal() async throws {
        // 浮动块在竖排准入中被拒绝，但横排引擎支持，应单章自动回退横排并记录回退标记。
        let floatHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><style>
        html { writing-mode: vertical-rl; }
        .box { float: left; width: 120px; }
        </style></head>
        <body><div class="box"><p>浮动框。</p></div><p>环绕正文内容。</p></body></html>
        """
        let source = StubChapterSource(chapters: [(floatHTML, [])])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                     aspectRatio: 440 / 956, writingDirection: .verticalRTL)
        XCTAssertEqual(book.writingMode(spineIndex: 0), .horizontal)
        XCTAssertNotNil(book.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertTrue(book.shouldAlertVerticalFallback(spineIndex: 0))
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 0)
    }

    @MainActor
    func testPureSVGCoverFallsBackSilentlyWithoutAlert() async throws {
        let svgCoverHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head></head>
        <body><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 300"><image width="200" height="300" href="cover.png"/></svg></body></html>
        """
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let source = StubChapterSource(chapters: [(svgCoverHTML, [])], images: ["cover.png": image])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                     aspectRatio: 440 / 956, writingDirection: .verticalRTL)
        XCTAssertEqual(book.writingMode(spineIndex: 0), .horizontal)
        XCTAssertNotNil(book.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertFalse(book.shouldAlertVerticalFallback(spineIndex: 0), "纯 SVG 封面/彩插应静默回退，不弹窗打扰")
    }

    @MainActor
    func testPlayBooksTCYWorkaroundNormalizesToNativeVerticalCombineUpright() async throws {
        let playBooksCSS = """
        .vrtl { -webkit-writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; }
        .tcy {
          -playbooks-start-tcy-workaround: true;
          display: inline-block !important;
          -epub-writing-mode: horizontal-tb !important;
          margin: 0 !important;
          -playbooks-end-tcy-workaround: true;
        }
        """
        let html = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" class="vrtl"><head></head>
        <body><p>第<span class="tcy">10</span>話の本文テストです。</p></body></html>
        """
        let source = StubChapterSource(chapters: [(html, [playBooksCSS])])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                     aspectRatio: 440 / 956, writingDirection: .bookDefault)
        XCTAssertEqual(book.writingMode(spineIndex: 0), .verticalRTL)
        XCTAssertNil(book.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 0)
    }

    func testCSSPruningDropsUnusedClassesAndPreservesSafeRules() {
        let padding = String(repeating: "/* pad */ ", count: 35)
        let css = padding + """
        @font-face { font-family: "Test"; src: url("t.otf"); }
        body { line-height: 1.6; }
        .used { color: red; }
        .unused { color: blue; }
        .unused-a, .used .inner { font-weight: bold; }
        a[href="next.xhtml"] { text-decoration: underline; }
        p:not(.unused) { margin: 0; }
        """
        let html = #"<html class="used"><body class='inner'><p><a href="next.xhtml">正文</a></p></body></html>"#
        let pruned = EPUBCSSPruning.pruningUnusedClassRules(in: css, html: html)
        XCTAssertTrue(pruned.contains("@font-face"))
        XCTAssertTrue(pruned.contains("body"))
        XCTAssertTrue(pruned.contains(".used"))
        XCTAssertTrue(pruned.contains(".used .inner"))
        XCTAssertTrue(pruned.contains(#"a[href="next.xhtml"]"#))
        XCTAssertTrue(pruned.contains("p:not(.unused)"))
        XCTAssertFalse(pruned.contains(".unused {"))
        XCTAssertFalse(pruned.contains(".unused-a"))
    }

    @MainActor
    func testVerticalChapterStripsPercentWidthAndInlineBlockWithoutFallback() async throws {
        let css = """
        .vrtl { -webkit-writing-mode: vertical-rl; writing-mode: vertical-rl; }
        .wrap { display: inline-block; width: 100%; }
        .logo { width: 2.5em; }
        """
        let html = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" class="vrtl"><head></head>
        <body><div class="wrap"><p class="logo">奥付の縦書きテスト。</p></div></body></html>
        """
        let source = StubChapterSource(chapters: [(html, [css])])
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                     aspectRatio: 440 / 956, writingDirection: .bookDefault)
        XCTAssertEqual(book.writingMode(spineIndex: 0), .verticalRTL)
        XCTAssertNil(book.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertGreaterThan(book.pageCount(spineIndex: 0), 0)
    }

    @MainActor
    func testVerticalTypographyOptimizationPreservesOffsetsAndTransformsQuotesTCYAndIndent() async throws {
        let html = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>“标题不改”</title></head>
        <body>
          <p class="lead">“你好，世界！”她说，“里面有‘嵌套’、第12章、2026年和 3.14，真的吗!?”</p>
          <p>普通叙述段落在2026年11月22日共有99条记录，确认两位数字纵中横且不拆四位年份。</p>
          <p style="text-align:center;">居中标题不加缩进</p>
        </body></html>
        """
        let optimized = try EPUBVerticalTypographyOptimizer.apply(html: html)
        // 属性与 <title> 不被改动；正文弯引号转直角引号
        XCTAssertTrue(optimized.html.contains("<title>“标题不改”</title>"))
        XCTAssertTrue(optimized.html.contains("「你好，世界！」"))
        XCTAssertTrue(optimized.html.contains("『嵌套』"))
        // 独立两位数字与双标点包裹 TCY；四位年份 2026 与小数 3.14 不被拆包
        XCTAssertTrue(optimized.html.contains(#"<span class="__novelia_tcy">12</span>"#))
        XCTAssertTrue(optimized.html.contains(#"<span class="__novelia_tcy">99</span>"#))
        XCTAssertTrue(optimized.html.contains(#"<span class="__novelia_tcy">!?</span>"#))
        XCTAssertTrue(optimized.html.contains("2026年"))
        XCTAssertTrue(optimized.html.contains("3.14"))
        // 对话段顶格、普通叙述段缩进一格、居中段落保持原样
        XCTAssertTrue(optimized.html.contains(#"class="lead __novelia_v_noindent""#))
        XCTAssertTrue(optimized.html.contains(#"<p class="__novelia_v_indent">"#))
        XCTAssertFalse(optimized.html.contains(#"style="text-align:center;" class="__novelia_v_indent""#))

        // 验证开启与关闭优化后，竖排排版均成功且章节 UTF-16 长度完全一致（不破坏进度与书签偏移）
        let source = StubChapterSource(chapters: [(html, ["p { text-indent: 2em; }"])])
        let bookPlain = EPUBPageBook(generation: 1)
        let bookOpt = EPUBPageBook(generation: 2)
        try await bookPlain.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                          aspectRatio: 440 / 956, writingDirection: .verticalRTL,
                                          verticalTypographyOptimization: false)
        try await bookOpt.layoutChapter(0, container: source, config: Self.readerConfig(workarounds: true),
                                        aspectRatio: 440 / 956, writingDirection: .verticalRTL,
                                        verticalTypographyOptimization: true)
        XCTAssertEqual(bookOpt.writingMode(spineIndex: 0), .verticalRTL)
        XCTAssertNil(bookOpt.verticalFallbackFeatures(spineIndex: 0))
        XCTAssertEqual(bookPlain.sourceLength(spineIndex: 0), bookOpt.sourceLength(spineIndex: 0))
    }
}
