import Foundation
import CryptoKit
import SwiftSoup
import OSLog
import UIKit
import YueduCoreText
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

// MARK: - 页面标识与排版缓存（核心不变量）
//
// PageID = (generation, spineIndex, pageIndex)。
// 关键规则：手势中看到的下一页、松手后的落页，必须引用同一个 PageID 对应的
// 同一份 PageFragments → DisplayList → 位图。翻页动画只移动已渲染的位图，
// 动画结束绝不重新排版或重新计算目标页。
// generation 在字号或视口尺寸变化时 +1，旧的一组页面整体作废。

struct EPUBPageID: Equatable, Hashable {
    let generation: Int
    let spineIndex: Int
    let pageIndex: Int
}

enum EPUBLayoutFailure: LocalizedError {
    case unsupported(features: [String])
    case resource(String)
    case layout(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let features):
            "本章包含当前排版引擎不支持的内容（\(features.joined(separator: "、"))），需要回退策略后才能显示。"
        case .resource(let detail):
            "章节资源缺失，无法完整排版：\(detail)"
        case .layout(let detail):
            "排版失败：\(detail)"
        }
    }
}

/// 一次章节排版请求的关联信息（仅用于诊断，`bookID` 除外，
/// 它还限定共享排版缓存的范围）。
struct EPUBLayoutContext {
    /// 书籍内容的稳定身份（EPUB 文件哈希、TXT 哈希 + 规则）。为 `nil` 时，
    /// 排版结果仅在此分页书籍对象内使用：仍合并重复请求，但不缓存。
    var bookID: String?
    /// “epub”“txt”或“online”：用于日志行前缀和 `kind` 字段。
    var kind = "epub"
    var trace = "00000000"
    var reason: EPUBLayoutReason = .first
    var totalSpine = 0
    var currentSpine = 0
}

@MainActor
final class EPUBPageBook {
    let generation: Int
    let ignoresNearWhite: Bool
    private let coordinator: EPUBLayoutCoordinator
    /// 将没有书籍身份、不能缓存的排版限制在此分页书籍对象内。
    private let privateBookID = "private-" + UUID().uuidString

    private var chapters: [Int: EPUBChapterLayout] = [:]
    private var completedChapters = Set<Int>()
    private var renderedImages: [EPUBPageID: CGImage] = [:]
    /// 每排出一页回调一次（主线程）；宿主借此刷新"下一页已就绪"的可用性。
    var onPagesChanged: (() -> Void)?

    init(generation: Int, coordinator: EPUBLayoutCoordinator? = nil, ignoresNearWhite: Bool = true) {
        self.ignoresNearWhite = ignoresNearWhite
        self.generation = generation
        self.coordinator = coordinator ?? .shared
    }

    /// YueduCoreText 0.8.0 仅调整一行中部分字符的字距来实现两端对齐。
    /// Core Text 随后将未调整字距的中日韩标点挤为半宽，并把这部分宽度
    /// 移到一个大间隙中。为每个字符设置极小字距可以避免此问题。
    /// 阅读器与排版回归测试共用。
    static func applyEngineWorkarounds(to config: inout BrowserLayoutConfig) {
        config.letterSpacing = 0.001
    }

    /// 把一章交给 YueduCoreText 逐页排版（经 EPUBLayoutCoordinator 去重与缓存）。
    /// 后台 actor 准备与分页；主线程只构建显示列表并逐页发布，不持有可变会话。
    func layoutChapter(_ spineIndex: Int, container: any EPUBChapterSource,
                       config: BrowserLayoutConfig, aspectRatio: CGFloat = 0.5,
                       readerCSS: String? = nil,
                       writingDirection: EPUBWritingDirectionRequest = .horizontal,
                       verticalTypographyOptimization: Bool = false,
                       context: EPUBLayoutContext = EPUBLayoutContext()) async throws {
        let start = ContinuousClock.now
        let book = DiagnosticContext.bookTag(context.bookID ?? privateBookID)
        let label = EPUBLayoutLog.label(kind: context.kind)
        let fields = "book=\(book), trace=\(context.trace), gen=\(generation), spine=\(spineIndex), totalSpine=\(context.totalSpine), currentSpine=\(context.currentSpine), reason=\(context.reason.rawValue)"
        if completedChapters.contains(spineIndex) {
            EPUBLayoutLog.logger.info("\(label, privacy: .public) chapter layout reused; \(fields, privacy: .public), pages=\(self.pageCount(spineIndex: spineIndex), privacy: .public), cacheHit=true, level=book, elapsedMs=0, thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            return
        }
        var config = config
        let tally = EPUBLayoutLog.traceEnabled ? EPUBLayoutTraceTally() : nil
        if let tally {
            let forward = config.onDiagnostic
            config.onDiagnostic = { diagnostic in
                tally.record(diagnostic)
                EPUBLayoutLog.trace.debug("ENGINE_DIAG \(String(describing: diagnostic), privacy: .private)")
                forward?(diagnostic)
            }
        }
        let key = EPUBLayoutCoordinator.Key(
            bookID: context.bookID ?? privateBookID, spine: spineIndex,
            parameters: EPUBLayoutParameters(config: config, aspectRatio: aspectRatio, readerCSS: readerCSS,
                                             writingDirection: writingDirection,
                                             verticalTypographyOptimization: verticalTypographyOptimization))
        let runConfig = config
        do {
            let (layout, outcome) = try await coordinator.layout(
                key: key, cacheable: context.bookID != nil,
                priority: context.reason == .prefetch ? .prefetch : .current,
                observer: { [weak self] partial in
                    // 渐进发布：即使本章尚未排完，已完成的页即可用于显示与预览。
                    guard let self, !self.completedChapters.contains(spineIndex) else { return }
                    self.chapters[spineIndex] = partial
                    self.onPagesChanged?()
                },
                work: { publish in
                    try await Self.performLayout(spineIndex, container: container, config: runConfig,
                                                 aspectRatio: aspectRatio, readerCSS: readerCSS,
                                                 writingDirection: writingDirection,
                                                 verticalTypographyOptimization: verticalTypographyOptimization,
                                                 publish: publish)
                })
            chapters[spineIndex] = layout
            completedChapters.insert(spineIndex)
            onPagesChanged?()
            let elapsed = EPUBLayoutLog.milliseconds(since: start)
            switch outcome {
            case .executed:
                EPUBLayoutLog.logger.info("\(label, privacy: .public) chapter laid out; \(fields, privacy: .public), pages=\(layout.pages.count, privacy: .public), cacheHit=false, elapsedMs=\(elapsed, privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            case .inflight, .memory:
                EPUBLayoutLog.logger.info("\(label, privacy: .public) chapter layout reused; \(fields, privacy: .public), pages=\(layout.pages.count, privacy: .public), cacheHit=true, level=\(outcome.rawValue, privacy: .public), elapsedMs=\(elapsed, privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            }
        } catch {
            let failure = EPUBLayoutLog.failure(error)
            let elapsed = EPUBLayoutLog.milliseconds(since: start)
            if failure.kind == "cancelled" {
                // 取消的请求不保留部分页面，它们可能属于中途停止的排版。
                if !completedChapters.contains(spineIndex) { chapters[spineIndex] = nil }
                EPUBLayoutLog.logger.info("\(label, privacy: .public) chapter layout cancelled; \(fields, privacy: .public), elapsedMs=\(elapsed, privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            } else {
                EPUBLayoutLog.logger.error("\(label, privacy: .public) chapter layout failed; \(fields, privacy: .public), error=\(failure.kind, privacy: .public), code=\(failure.code, privacy: .public), elapsedMs=\(elapsed, privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            }
            tally?.logSummary(spineIndex: spineIndex)
            throw error
        }
        tally?.logSummary(spineIndex: spineIndex)
    }

    private static func performLayout(_ spineIndex: Int, container: any EPUBChapterSource,
                                      config: BrowserLayoutConfig, aspectRatio: CGFloat,
                                      readerCSS: String?,
                                      writingDirection: EPUBWritingDirectionRequest,
                                      verticalTypographyOptimization: Bool,
                                      publish: (EPUBChapterLayout) -> Void) async throws -> EPUBChapterLayout {
        let html = try await container.chapterHTML(at: spineIndex)
        try Task.checkCancellation()
        let chapterHref = container.chapterHref(at: spineIndex)
        let requestsVerticalCSS = writingDirection == .verticalRTL
            || (writingDirection == .bookDefault && container.prefersVerticalByDefault)
        let rawCSS = await container.cssTexts(forChapterHTML: html, chapterHref: chapterHref,
                                              aspectRatio: aspectRatio, vertical: requestsVerticalCSS)
        let usedClasses = EPUBCSSPruning.usedClasses(in: html)
        let bookCSS = rawCSS.map { EPUBCSSPruning.pruningUnusedClassRules(in: $0, usedClasses: usedClasses) }
        let images = await container.images(forChapterHTML: html, chapterHref: chapterHref)
        try Task.checkCancellation()

        let worker = EPUBBackgroundLayout()
        let prepared = try await worker.prepare(
            html: html, bookCSS: bookCSS, readerCSS: readerCSS, config: config, images: images,
            writingDirection: writingDirection, bookPrefersVertical: container.prefersVerticalByDefault,
            verticalTypographyOptimization: verticalTypographyOptimization)
        let owner = prepared.owner
        var layout = EPUBChapterLayout(
            pages: [], sourceText: prepared.facts.sourceText, displayLists: [], linkRegions: [], footnotes: prepared.facts.footnotes,
            anchorOffsets: normalizedAnchorOffsets(prepared.facts.anchorOffsets),
            positionMap: prepared.positionMap, tableFallback: prepared.tableFallback,
            effectiveWritingMode: prepared.effectiveWritingMode,
            verticalFallback: prepared.verticalFallback,
            verticalFallbackNeedsAlert: prepared.verticalFallbackNeedsAlert,
            verticalFallbackFeatures: prepared.verticalFallbackFeatures,
            sourceHash: SHA256.hash(data: Data(prepared.facts.sourceText.utf8)).map { String(format: "%02x", $0) }.joined()
        )
        return try await withTaskCancellationHandler {
            while let page = try await owner.layoutNextPage() {
                try Task.checkCancellation()
                let list = DisplayListBuilder.build(for: page, sourceText: layout.sourceText)
                layout.pages.append(page)
                layout.pageRanges.append(contentsOf: BrowserPageGeometry.buildPageRanges([page], sourceText: layout.sourceText))
                layout.displayLists.append(list)
                layout.linkRegions.append(LinkInteractionRegionSet.build(
                    from: list, spineIndex: spineIndex, anchors: prepared.facts.linkAnchors
                ))
                publish(layout)
            }
            layout.mainThreadLayoutSteps = await owner.mainThreadStepCount()
            return layout
        } onCancel: {
            owner.cancel()
        }
    }

    /// 把章节 HTML 中的 ruby 注音改写为「底文（读音）」纯文本。
    /// 只影响本次排版结果，不修改原书；没有注音标签的章节原样返回。
    nonisolated static func rubyParentheticalText(_ html: String) throws -> String {
        // 先做廉价的字符串检查，避免给普通章节增加一次完整解析。
        let rubyTags = ["<ruby", "<rb", "<rp", "<rt"]
        guard rubyTags.contains(where: { html.range(of: $0, options: .caseInsensitive) != nil }) else { return html }
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        // 先处理内层：外层重建时内层注音已经变成纯文本。
        for ruby in try document.select("ruby").array().reversed() {
            try ruby.html(Self.rubyParentheticalMarkup(of: ruby))
            try ruby.unwrap()
        }
        // 结构不完整的注音标签（散落在 ruby 外的 rb/rt/rp）没有可靠的读音配对：
        // 去掉标签、保留可见文字，避免引擎能力检查再次拒绝整章。
        // （SwiftSoup 解析这类无效标记时本身就会丢弃 rt 外壳，只留下文字。）
        try document.select("rb").unwrap()
        try document.select("rt, rp, rtc").remove()
        return try document.outerHtml()
    }

    /// 把一个 ruby 元素的内容重建为「底文（读音）」；多个 rt 按出现顺序逐对生成。
    /// `<rp>` 里的圆括号不再输出，统一改用全角括号，避免读入重复括号。
    nonisolated private static func rubyParentheticalMarkup(of ruby: Element) throws -> String {
        var markup = ""
        var base: [Node] = []
        for child in ruby.getChildNodes() {
            guard let element = child as? Element else {
                base.append(child)
                continue
            }
            switch element.tagName() {
            case "rb":
                // 去掉 rb 外壳，保留其中的内联标记（例如链接）。
                base.append(contentsOf: element.getChildNodes())
            case "rp":
                continue
            case "rt", "rtc":
                let reading = try element.text()
                guard !reading.isEmpty else { continue }
                markup += try Self.rubyBaseMarkup(base)
                base.removeAll()
                markup += "（" + Self.escapedHTMLText(reading) + "）"
            default:
                base.append(element)
            }
        }
        markup += try Self.rubyBaseMarkup(base)
        return markup
    }

    /// 底文按源码格式换行书写时，标签之间会留下只用于排版的空白；
    /// 去掉首尾空白，读音才能紧跟底文显示，而不是隔着一个空格。
    nonisolated private static func rubyBaseMarkup(_ nodes: [Node]) throws -> String {
        var markup = ""
        for node in nodes { markup += try node.outerHtml() }
        return markup.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func escapedHTMLText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func isChapterComplete(_ spineIndex: Int) -> Bool {
        completedChapters.contains(spineIndex)
    }

    func hasChapter(_ spineIndex: Int) -> Bool {
        chapters[spineIndex] != nil
    }

    func pageCount(spineIndex: Int) -> Int {
        chapters[spineIndex]?.pages.count ?? 0
    }

    /// 页面首段文字在章节源文本中的 UTF-16 偏移量；
    /// 包含图片字符，因此纯插图页也有独立的章内位置。
    func sourceOffset(spineIndex: Int, pageIndex: Int) -> Int? {
        guard let chapter = chapters[spineIndex], chapter.displayLists.indices.contains(pageIndex) else { return nil }
        return chapter.pageRanges.indices.contains(pageIndex) ? chapter.pageRanges[pageIndex].location : nil
    }

    var tableFallbackChapterCount: Int { chapters.values.filter(\.tableFallback).count }

    /// 本章最终生效的书写方向；未排版时为 nil。
    func writingMode(spineIndex: Int) -> ReaderWritingMode? { chapters[spineIndex]?.effectiveWritingMode }
    /// 本章原计划竖排但自动回退横排时，返回触发回退的不支持特性列表；未回退时为 nil。
    func verticalFallbackFeatures(spineIndex: Int) -> [String]? {
        guard let chapter = chapters[spineIndex], chapter.verticalFallback else { return nil }
        return chapter.verticalFallbackFeatures
    }
    /// 本章回退横排后是否需要弹窗提示（纯 `<svg>` 封面/插图页静默回退返回 false）。
    func shouldAlertVerticalFallback(spineIndex: Int) -> Bool {
        chapters[spineIndex]?.verticalFallbackNeedsAlert == true
    }

    func sourceHash(spineIndex: Int) -> String? { chapters[spineIndex]?.sourceHash }
    func mainThreadLayoutSteps(spineIndex: Int) -> Int? { chapters[spineIndex]?.mainThreadLayoutSteps }
    func savedOffset(spineIndex: Int, sourceOffset: Int) -> Int? {
        chapters[spineIndex].map { $0.positionMap.legacy(sourceOffset) }
    }
    func savedLength(spineIndex: Int) -> Int? {
        chapters[spineIndex].map { $0.positionMap.legacy($0.sourceText.utf16.count) }
    }

    /// 已排版章节的源文本（`sourceOffset` 所度量的文本）；未排版时为 nil。
    func sourceText(spineIndex: Int) -> String? {
        chapters[spineIndex]?.sourceText
    }

    /// 本章锚点 id → 源文本 UTF-16 偏移。章节尚未开始排版时为 nil；排完但没有锚点时为空表。
    func anchorOffsets(spineIndex: Int) -> [String: Int]? {
        guard chapters[spineIndex] != nil else { return nil }
        return chapters[spineIndex]?.anchorOffsets ?? [:]
    }

    /// 引擎给出的锚点键可能带 `#` 或百分号编码，收成与目录 fragment 相同的形式。
    private static func normalizedAnchorOffsets(_ offsets: [String: Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(offsets.count)
        for (key, value) in offsets {
            let fragment = EPUBTOCHighlight.normalizedFragment(key) ?? key
            if result[fragment] == nil { result[fragment] = value }
        }
        return result
    }

    /// 已排版章节文本的 UTF-16 长度（`sourceOffset` 所度量的文本范围）。
    func sourceLength(spineIndex: Int) -> Int? {
        chapters[spineIndex].map { $0.sourceText.utf16.count }
    }

    /// 显示 `offset` 的页面：文字起点不晚于该偏移量的最后一个已排版页面。
    func pageIndex(spineIndex: Int, containingSourceOffset offset: Int) -> Int? {
        guard let chapter = chapters[spineIndex], !chapter.displayLists.isEmpty else { return nil }
        var result = 0
        for index in chapter.displayLists.indices {
            guard let start = sourceOffset(spineIndex: spineIndex, pageIndex: index) else { continue }
            if start > offset { break }
            result = index
        }
        return result
    }

    /// 磁盘与同步继续使用旧版括号注音、无图片字符的偏移口径。
    func savedOffset(spineIndex: Int, pageIndex: Int) -> Int? {
        sourceOffset(spineIndex: spineIndex, pageIndex: pageIndex).map {
            chapters[spineIndex]?.positionMap.legacy($0) ?? $0
        }
    }

    func restoredOffset(spineIndex: Int, savedOffset: Int) -> Int {
        chapters[spineIndex]?.positionMap.current(savedOffset) ?? savedOffset
    }

    func isPageAvailable(_ id: EPUBPageID) -> Bool {
        guard let chapter = chapters[id.spineIndex] else { return false }
        return id.pageIndex < chapter.pages.count
    }

    func displayList(for id: EPUBPageID) -> DisplayList? {
        guard let chapter = chapters[id.spineIndex],
              chapter.displayLists.indices.contains(id.pageIndex) else { return nil }
        return chapter.displayLists[id.pageIndex]
    }

    func selectionRange(at point: CGPoint, for id: EPUBPageID) -> NSRange? {
        guard let chapter = chapters[id.spineIndex],
              chapter.displayLists.indices.contains(id.pageIndex) else { return nil }
        return BrowserTextGeometry.range(
            at: point,
            in: chapter.displayLists[id.pageIndex],
            source: chapter.sourceText as NSString,
            nearest: true
        )
    }

    func selectionRects(for range: NSRange, on id: EPUBPageID) -> [CGRect] {
        guard let chapter = chapters[id.spineIndex],
              chapter.displayLists.indices.contains(id.pageIndex) else { return [] }
        return BrowserTextGeometry.rects(in: chapter.displayLists[id.pageIndex], range: range)
    }

    func selectedText(for range: NSRange, on id: EPUBPageID) -> String? {
        guard let chapter = chapters[id.spineIndex] else { return nil }
        let source = chapter.sourceText as NSString
        guard range.location >= 0, range.length > 0,
              range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        return source.substring(with: range)
    }

    // MARK: 链接与注脚命中

    /// 页面本地点的链接命中；点为视图坐标（当前页槽位与视口重合，故直接同页本地坐标）。
    /// 页本地坐标处的正文图片 src（不含背景图；边长不足 32pt 的注释标记等小图不算）。
    /// 多张重叠时取面积最小的一张。
    func imageSource(at point: CGPoint, for id: EPUBPageID) -> String? {
        guard let chapter = chapters[id.spineIndex],
              chapter.displayLists.indices.contains(id.pageIndex) else { return nil }
        var match: (source: String, area: CGFloat)?
        for case .image(let item) in chapter.displayLists[id.pageIndex].items where !item.isBackgroundPaint {
            let rect = item.rect.rawValue
            guard min(rect.width, rect.height) >= 32, rect.insetBy(dx: -4, dy: -4).contains(point) else { continue }
            let area = rect.width * rect.height
            if match == nil || area < match!.area { match = (item.source, area) }
        }
        return match?.source
    }

    /// 已排版章节中第一张解析为 `path` 的正文图片所在页（图片查看器“跳到原文位置”）。
    func pageIndex(spineIndex: Int, containingImagePath path: String, chapterHref: String) -> Int? {
        guard let chapter = chapters[spineIndex] else { return nil }
        for (page, list) in chapter.displayLists.enumerated() {
            for case .image(let item) in list.items where !item.isBackgroundPaint {
                if let resolved = EPUBContainer.resolveImagePath(src: item.source, chapterHref: chapterHref),
                   resolved.caseInsensitiveCompare(path) == .orderedSame {
                    return page
                }
            }
        }
        return nil
    }

    func linkRegion(at point: CGPoint, for id: EPUBPageID) -> LinkInteractionRegion? {
        guard let chapter = chapters[id.spineIndex],
              chapter.linkRegions.indices.contains(id.pageIndex) else { return nil }
        return chapter.linkRegions[id.pageIndex].hitTest(point)
    }

    /// 注脚链接对应的注释文本。href 形如 "#note1"；键为不含 "#" 的 noteID。
    func footnoteText(forHref href: String, id: EPUBPageID) -> String? {
        guard let chapter = chapters[id.spineIndex] else { return nil }
        let noteID = href.hasPrefix("#") ? String(href.dropFirst()) : href
        return chapter.footnotes[noteID] ?? chapter.footnotes[href]
    }

    /// 页面画布尺寸（含页边距的整页视口），用于渲染与翻页布局。
    func pageCanvasSize(_ id: EPUBPageID) -> CGSize? {
        guard let chapter = chapters[id.spineIndex],
              chapter.pages.indices.contains(id.pageIndex) else { return nil }
        return chapter.pages[id.pageIndex].pageRect.rawValue.size
    }

    /// 只读已缓存的位图（不触发渲染）；预览槽位用，避免 body 更新时同步解码大图。
    func cachedRenderedImage(for id: EPUBPageID) -> CGImage? {
        renderedImages[id]
    }

    func isRendered(_ id: EPUBPageID) -> Bool {
        renderedImages[id] != nil
    }

    /// 渲染并缓存页面位图。预览与落页取同一缓存键，天然是同一份结果。
    func renderedImage(for id: EPUBPageID, scale: CGFloat,
                       background: UIColor, backgroundImage: UIImage? = nil) -> CGImage? {
        if let cached = renderedImages[id] { return cached }
        guard let chapter = chapters[id.spineIndex],
              chapter.pages.indices.contains(id.pageIndex) else { return nil }
        let page = chapter.pages[id.pageIndex]
        let canvas = page.pageRect.rawValue
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        let list = chapter.displayLists.indices.contains(id.pageIndex)
            ? chapter.displayLists[id.pageIndex]
            : DisplayListBuilder.build(for: page, sourceText: chapter.sourceText)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: canvas.size), format: format)
        let image = renderer.image { context in
            let canvasRect = CGRect(origin: .zero, size: canvas.size)
            background.setFill()
            context.fill(canvasRect)
            if let backgroundImage {
                let ratio = max(canvasRect.width / backgroundImage.size.width, canvasRect.height / backgroundImage.size.height)
                let size = CGSize(width: backgroundImage.size.width * ratio, height: backgroundImage.size.height * ratio)
                backgroundImage.draw(in: CGRect(x: (canvasRect.width - size.width) / 2, y: (canvasRect.height - size.height) / 2, width: size.width, height: size.height))
            }
            // UIKit 渲染上下文已是左上原点、y 向下，DisplayList.draw 直接可用。
            Self.removingNearWhiteFills(from: list, enabled: ignoresNearWhite).draw(in: context.cgContext)
        }
        renderedImages[id] = image.cgImage
        return image.cgImage
    }

    /// 只替换已解析的近白填充色，保留边框、变换、文字、彩色底和图片；原显示列表不变。
    static func removingNearWhiteFills(from list: DisplayList, enabled: Bool, threshold: CGFloat = 240.0 / 255) -> DisplayList {
        guard enabled else { return list }
        return DisplayList(items: list.items.map { item in
            guard case .fill(let fill) = item, !fill.followsTextColor else { return item }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard fill.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0,
                  min(red, green, blue) >= threshold else { return item }
            var clear = DisplayFillItem(rect: fill.rect, color: .clear, cornerRadius: fill.cornerRadius,
                borderTop: fill.borderTop, borderBottom: fill.borderBottom,
                borderLeft: fill.borderLeft, borderRight: fill.borderRight,
                nodeID: fill.nodeID, writingMode: fill.writingMode, fragmentPosition: fill.fragmentPosition,
                isBackgroundPaint: fill.isBackgroundPaint, followsTextColor: fill.followsTextColor)
            clear.paintTransform = fill.paintTransform
            return .fill(clear)
        })
    }

    /// 章节中目前已排版的每个页面的显示列表（用于排版回归测试）。
    func displayLists(spineIndex: Int) -> [DisplayList] {
        chapters[spineIndex]?.displayLists ?? []
    }

    func dropRenderedImages(keeping ids: Set<EPUBPageID>) {
        renderedImages = renderedImages.filter { ids.contains($0.key) }
    }
}

// MARK: - 阅读位置

struct EPUBReadingLocation: Equatable {
    var spineIndex: Int
    var pageIndex: Int
}

// MARK: - 排版日志

/// 每次章节排版记录一行摘要。YueduCoreText 的 `onDiagnostic` 是跟踪钩子，
/// 并非错误通道：它报告每个带样式的节点、匹配的规则和排版行，
/// 每章可产生数千个事件，格式化它们会拖慢排版。实际失败会抛出，
/// 并在此处记录；跟踪仅在带有以下启动参数的 Debug 构建中启用：
/// `-EPUBEngineTrace`。
enum EPUBLayoutLog {
    static let logger = Logger(subsystem: "cc.novelia.ios.port", category: "epub")
    static let trace = Logger(subsystem: "cc.novelia.ios.port", category: "enginediag")
    /// 需要出现在分享日志中、并跨启动保留的阅读器事件（notice 级）。
    static let shareable = ShareableLogger(category: "epub")

    static let traceEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-EPUBEngineTrace")
        #else
        false
        #endif
    }()

    /// 书籍类型对应的日志行前缀；TXT 和在线章节不属于 EPUB。
    static func label(kind: String) -> String {
        switch kind {
        case "txt": "TXT"
        case "online": "Online"
        default: "EPUB"
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        DiagnosticContext.milliseconds(since: start)
    }

    /// 固定类型名与数字代码；错误描述可能包含文件路径或书籍文本。
    static func failure(_ error: Error) -> (kind: String, code: Int) {
        if error is CancellationError { return ("cancelled", 0) }
        if let error = error as? HTMLLayoutError {
            switch error {
            case .unsupported: return ("unsupported", 0)
            case .resourceFailure: return ("resource", 0)
            case .layoutFailure: return ("layout", 0)
            case .cancelled: return ("cancelled", 0)
            }
        }
        if let error = error as? EPUBLayoutFailure {
            switch error {
            case .unsupported: return ("unsupported", 0)
            case .resource: return ("resource", 0)
            case .layout: return ("layout", 0)
            }
        }
        if let error = error as? EPUBError {
            switch error {
            case .cannotOpenArchive: return ("archive", 0)
            case .missingContainer: return ("container", 0)
            case .missingOPF: return ("opf", 0)
            case .emptySpine: return ("spine", 0)
            case .entryTooLarge: return ("entrySize", 0)
            case .missingChapter: return ("chapterMissing", 0)
            case .unreadableEntry: return ("entryRead", 0)
            case .invalidChapter: return ("chapterIndex", 0)
            }
        }
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain: return ("cocoa", nsError.code)
        case NSPOSIXErrorDomain: return ("posix", nsError.code)
        case NSURLErrorDomain: return ("url", nsError.code)
        default: return ("other", 0)
        }
    }

    /// 章节内容本身的永久性问题：离线文件缺失、条目损坏或章节位置无效，
    /// 重试或预取重排都不会恢复，因此不用于「相邻章节加载失败，点击重试」提示。
    static func isPermanentContentFailure(_ kind: String) -> Bool {
        kind == "chapterMissing" || kind == "entryRead" || kind == "chapterIndex"
    }
}

/// 按阶段统计引擎跟踪事件，供仅在 Debug 中启用的章节摘要使用。
final class EPUBLayoutTraceTally: @unchecked Sendable {
    static let stages = ["html", "css", "selector", "style", "ingestion", "adapter", "allocation"]
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ diagnostic: CSSFrontendDiagnostic) {
        let stage: String
        switch diagnostic.stage {
        case .html: stage = "html"
        case .css: stage = "css"
        case .selector: stage = "selector"
        case .style: stage = "style"
        case .ingestion: stage = "ingestion"
        case .adapter: stage = "adapter"
        case .allocation: stage = "allocation"
        }
        lock.lock()
        counts[stage, default: 0] += 1
        lock.unlock()
    }

    var snapshot: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func summary(spineIndex: Int) -> String {
        let counts = snapshot
        let total = counts.values.reduce(0, +)
        let stages = Self.stages.map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: ", ")
        return "EPUB layout trace summary; spine=\(spineIndex), events=\(total), \(stages)"
    }

    func logSummary(spineIndex: Int) {
        EPUBLayoutLog.trace.debug("\(self.summary(spineIndex: spineIndex), privacy: .public)")
    }
}

/// 一个请求独占的后台准备器；DOM、会话与配置闭包不会被并发访问。
private actor EPUBBackgroundLayout {
    struct Prepared: Sendable {
        let owner: BrowserPageLayoutOwner
        let facts: BrowserPageChapterFacts
        let positionMap: EPUBSourcePositionMap
        let tableFallback: Bool
        let effectiveWritingMode: ReaderWritingMode
        let verticalFallback: Bool
        let verticalFallbackNeedsAlert: Bool
        let verticalFallbackFeatures: [String]
    }

    private static func blockTableDisplay(_ css: String) -> String {
        css.replacingOccurrences(of: #"(?i)\bdisplay\s*:\s*table(?:-[a-z-]+)?\b"#,
                                 with: "display: block", options: .regularExpression)
    }

    /// Google Play Books 导出的日文竖排 EPUB 会把 `.tcy` 纵中横改写为
    /// `-playbooks-start-tcy-workaround: true; display: inline-block; -epub-writing-mode: horizontal-tb; ... -playbooks-end-tcy-workaround: true;`，
    /// 这会触发 YueduCoreText 竖排对 `inline-block` 和 `horizontal-tb` 的准入拒绝。
    /// 将其还原为标准 `text-combine-upright: all;` 可让引擎原生绘制纵中横，并避免整章回退横排。
    private static func normalizingPlayBooksTCYWorkaround(_ css: String) -> String {
        guard css.localizedCaseInsensitiveContains("-playbooks-start-tcy-workaround") else { return css }
        return css.replacingOccurrences(
            of: #"(?i)-playbooks-start-tcy-workaround\s*:\s*true\s*;[\s\S]*?-playbooks-end-tcy-workaround\s*:\s*true\s*;?"#,
            with: "text-combine-upright: all;",
            options: .regularExpression
        )
    }

    /// 竖排准入因横排/受限样式声明被拒时，移除与竖排准入直接冲突的声明后重试：
    /// - 显式 `writing-mode: horizontal-tb`、`min-width`/`min-height`/`max-width`、`text-orientation`；
    /// - 非 `auto`/`px` 的块轴 `width`（如 `width: 100%`、`width: 2.5em`）；
    /// - 容器元素上的 `display: inline-block`（改写为 `display: block`，常见于日轻插图居中容器）。
    private static func stripVerticalConflictingCSS(_ css: String) -> String {
        var result = normalizingPlayBooksTCYWorkaround(css)
        let removalPatterns = [
            #"(?i)(?:-(?:epub|webkit)-)?writing-mode\s*:\s*horizontal-tb\s*(?:!important\s*)?;?"#,
            #"(?i)\b(?:min-width|min-height|max-width)\s*:[^;{}]+;?"#,
            #"(?i)(?:-(?:epub|webkit)-)?text-orientation\s*:[^;{}]+;?"#,
            #"(?i)(?<![a-z-])width\s*:\s*(?!auto\b)(?![0-9.]+px\b)[^;{}]+;?"#,
        ]
        for pattern in removalPatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(
            of: #"(?i)\bdisplay\s*:\s*inline-block\b"#,
            with: "display: block",
            options: .regularExpression
        )
        return result
    }

    /// 强行以横排渲染竖排书（或竖排单章自动回退横排）时，移除 `writing-mode: vertical-*`，
    /// 避免能力扫描器在横排模式下因残留的竖排声明再次拒绝本章。
    private static func stripHorizontalConflictingCSS(_ css: String) -> String {
        css.replacingOccurrences(
            of: #"(?i)(?:-(?:epub|webkit)-)?writing-mode\s*:\s*(?:vertical-(?:rl|lr)|sideways-(?:rl|lr)|tb-rl|tb)\s*(?:!important\s*)?;?"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func sanitizeHTML(_ html: String, transform: (String) -> String) throws -> String {
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        for element in try document.select("[style]").array() {
            try element.attr("style", transform(try element.attr("style")))
        }
        for element in try document.select("style").array() {
            try element.html(transform(try element.html()))
        }
        return try document.outerHtml()
    }

    private struct EvaluatedChapter {
        let evaluation: BrowserChapterEvaluation
        let layoutHTML: String
        let layoutCSS: [String]
        let images: [String: UIImage]
        let tableFallback: Bool
        let effectiveConfig: BrowserLayoutConfig
    }

    /// 竖排模式下将单个受横排引擎支持的 `<table>` 离屏渲染为透明底横排图片，以块级 `<img>` 嵌回原位，
    /// 使包含简短表格的竖排章节无需整章回退横排；若表格跨多页或横排引擎也不支持，则保留原标签走整章回退。
    private static func rasterizeTablesForVertical(
        html: String,
        css: [String],
        baseConfig: BrowserLayoutConfig,
        images: [String: UIImage]
    ) async throws -> (html: String, images: [String: UIImage], replaced: Bool) {
        guard html.range(of: "<table", options: .caseInsensitive) != nil else {
            return (html, images, false)
        }
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        let allTables = try document.select("table").array()
        // 只处理顶层表格；嵌套表格交由后续回退流程处理。
        let topLevelTables = allTables.filter { table in
            var parent = table.parent()
            while let current = parent {
                if current.tagName().lowercased() == "table" { return false }
                parent = current.parent()
            }
            return true
        }
        guard !topLevelTables.isEmpty else { return (html, images, false) }

        let horizontalCSS = css.map(stripHorizontalConflictingCSS)
        var tableConfig = baseConfig
        tableConfig.writingMode = .horizontal
        tableConfig.contentInsets = .zero
        // 留出左右块轴余量，确保嵌入竖排页后不会紧贴或溢出页边距。
        tableConfig.renderWidth = max(120, baseConfig.renderWidth - baseConfig.rootFontSize * 2)
        tableConfig.renderHeight = max(120, baseConfig.renderHeight)
        tableConfig.backgroundColor = .clear

        var updatedImages = images
        var replacedAny = false
        for (index, table) in topLevelTables.enumerated() {
            let tableMarkup = try table.outerHtml()
            let snippetHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head></head><body style="margin:0;padding:0;">\(tableMarkup)</body></html>
            """
            guard let image = await renderHorizontalTableImage(
                html: snippetHTML, css: horizontalCSS, config: tableConfig, images: images
            ) else { continue }
            let key = "__novelia_vertical_table_\(index).png"
            updatedImages[key] = image
            try table.before("<p style=\"text-indent:0;margin:0 0.5em;text-align:center;\"><img src=\"\(key)\" alt=\"表格\" style=\"display:block;\"/></p>")
            try table.remove()
            replacedAny = true
        }
        guard replacedAny else { return (html, images, false) }
        return (try document.outerHtml(), updatedImages, true)
    }

    private static func renderHorizontalTableImage(
        html: String,
        css: [String],
        config: BrowserLayoutConfig,
        images: [String: UIImage]
    ) async -> UIImage? {
        let input = CSSFrontendInput.currentCompatibility(html: html, cssTexts: css)
        guard let doc = try? BrowserChapterDocument(input: input) else { return nil }
        let evaluation = doc.evaluate(configuration: config, writingMode: .horizontal)
        guard evaluation.capabilities.supported,
              let owner = try? BrowserPageLayoutOwner(
                evaluation: evaluation, imageLoader: { images[$0] }, generation: 0
              ),
              let facts = try? await owner.prepare(),
              let firstPage = try? await owner.layoutNextPage(),
              (try? await owner.layoutNextPage()) == nil else {
            // 超过一页的超长表格不强行缩成单图，交由整章回退横排正常分页。
            return nil
        }
        let list = DisplayListBuilder.build(for: firstPage, sourceText: facts.sourceText)
        var bounds = CGRect.null
        for item in list.items {
            switch item {
            case .fill(let fill): bounds = bounds.union(fill.rect.rawValue)
            case .text(let text): bounds = bounds.union(text.rect.rawValue)
            case .image(let img): bounds = bounds.union(img.rect.rawValue)
            }
        }
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return nil }
        let padding: CGFloat = 4
        let size = CGSize(width: ceil(bounds.width + padding * 2), height: ceil(bounds.height + padding * 2))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: padding - bounds.minX, y: padding - bounds.minY)
            list.draw(in: cg)
        }
    }

    /// 用已排版章节的 `sourceText` 与引擎产出的 `pronunciationHints` 线性还原旧版「底文（读音）」无图文本，
    /// 避免为计算旧版偏移映射再跑一次完整的 HTML/CSS 解析、级联与 CoreText 排版。
    static func legacyOffsetText(sourceText: String, pronunciationHints: [TTSPronunciationHint]) -> String {
        let units = Array(sourceText.utf16)
        let insertions: [(offset: Int, reading: String)] = pronunciationHints
            .compactMap { hint in
                guard let reading = hint.reading, !reading.isEmpty,
                      hint.range.location >= 0,
                      NSMaxRange(hint.range) <= units.count else { return nil }
                return (NSMaxRange(hint.range), reading)
            }
            .enumerated()
            .sorted { a, b in
                a.element.offset == b.element.offset ? a.offset < b.offset : a.element.offset < b.element.offset
            }
            .map(\.element)

        guard !insertions.isEmpty else {
            return sourceText.replacingOccurrences(of: "\u{FFFC}", with: "")
        }

        var output: [UInt16] = []
        output.reserveCapacity(units.count + insertions.count * 6)
        var insertionIndex = 0
        for index in 0...units.count {
            while insertionIndex < insertions.count, insertions[insertionIndex].offset == index {
                output.append(0xFF08) // （
                output.append(contentsOf: insertions[insertionIndex].reading.utf16)
                output.append(0xFF09) // ）
                insertionIndex += 1
            }
            if index < units.count, units[index] != 0xFFFC {
                output.append(units[index])
            }
        }
        return String(utf16CodeUnits: output, count: output.count)
    }

    private func evaluateChapter(
        html: String,
        css: [String],
        baseConfig: BrowserLayoutConfig,
        images: [String: UIImage],
        writingMode: ReaderWritingMode,
        initialDocument: BrowserChapterDocument? = nil
    ) async throws -> EvaluatedChapter {
        var effectiveConfig = baseConfig
        effectiveConfig.writingMode = writingMode
        var layoutHTML = html, layoutCSS = css, layoutImages = images
        let firstDoc: BrowserChapterDocument
        if let initialDocument {
            firstDoc = initialDocument
        } else {
            let input = CSSFrontendInput.currentCompatibility(html: layoutHTML, cssTexts: layoutCSS)
            firstDoc = try BrowserChapterDocument(input: input)
        }
        var evaluation = firstDoc.evaluate(configuration: effectiveConfig, writingMode: writingMode)

        if !evaluation.capabilities.supported,
           evaluation.capabilities.unsupportedFeatures.contains(.verticalWritingMode) {
            let transform = writingMode == .verticalRTL ? Self.stripVerticalConflictingCSS : Self.stripHorizontalConflictingCSS
            let cleanedHTML = try Self.sanitizeHTML(layoutHTML, transform: transform)
            let cleanedCSS = layoutCSS.map(transform)
            if cleanedHTML != layoutHTML || cleanedCSS != layoutCSS {
                layoutHTML = cleanedHTML
                layoutCSS = cleanedCSS
                let input = CSSFrontendInput.currentCompatibility(html: layoutHTML, cssTexts: layoutCSS)
                evaluation = try BrowserChapterDocument(input: input).evaluate(configuration: effectiveConfig, writingMode: writingMode)
            }
        }

        if writingMode == .verticalRTL,
           !evaluation.capabilities.supported,
           (evaluation.capabilities.unsupportedFeatures.contains(.table)
            || evaluation.capabilities.unsupportedFeatures.contains(.verticalWritingMode)) {
            let rasterized = try await Self.rasterizeTablesForVertical(
                html: layoutHTML, css: layoutCSS, baseConfig: effectiveConfig, images: layoutImages
            )
            if rasterized.replaced {
                layoutHTML = rasterized.html
                layoutImages = rasterized.images
                let input = CSSFrontendInput.currentCompatibility(html: layoutHTML, cssTexts: layoutCSS)
                evaluation = try BrowserChapterDocument(input: input).evaluate(configuration: effectiveConfig, writingMode: writingMode)
            }
        }

        var tableFallback = false
        if evaluation.capabilities.unsupportedFeatures.contains(.table) {
            let document = try SwiftSoup.parse(layoutHTML)
            // 真正的 table 保留原结构与错误；只恢复旧书以 div 模拟居中表格的兼容路径。
            if try document.select("table").isEmpty() {
                document.outputSettings().prettyPrint(pretty: false)
                for element in try document.select("[style]").array() {
                    try element.attr("style", Self.blockTableDisplay(try element.attr("style")))
                }
                for element in try document.select("style").array() {
                    try element.html(Self.blockTableDisplay(try element.html()))
                }
                layoutHTML = try document.outerHtml()
                layoutCSS = layoutCSS.map(Self.blockTableDisplay)
                tableFallback = true
                let input = CSSFrontendInput.currentCompatibility(html: layoutHTML, cssTexts: layoutCSS)
                evaluation = try BrowserChapterDocument(input: input).evaluate(configuration: effectiveConfig, writingMode: writingMode)
            }
        }

        if evaluation.capabilities.unsupportedFeatures.contains(.ruby) {
            EPUBLayoutLog.logger.notice("Unsupported ruby rendered as parenthetical text; source file preserved")
            let convertedHTML = try EPUBPageBook.rubyParentheticalText(layoutHTML)
            layoutHTML = convertedHTML
            let input = CSSFrontendInput.currentCompatibility(html: layoutHTML, cssTexts: layoutCSS)
            evaluation = try BrowserChapterDocument(input: input).evaluate(configuration: effectiveConfig, writingMode: writingMode)
        }

        return EvaluatedChapter(
            evaluation: evaluation,
            layoutHTML: layoutHTML,
            layoutCSS: layoutCSS,
            images: layoutImages,
            tableFallback: tableFallback,
            effectiveConfig: effectiveConfig
        )
    }

    func prepare(html: String, bookCSS: [String], readerCSS: String?, config: BrowserLayoutConfig,
                 images: [String: UIImage],
                 writingDirection: EPUBWritingDirectionRequest,
                 bookPrefersVertical: Bool,
                 verticalTypographyOptimization: Bool) async throws -> Prepared {
        try Task.checkCancellation()
        var baseCSS = bookCSS.map(Self.normalizingPlayBooksTCYWorkaround)
        if let readerCSS { baseCSS.append(Self.normalizingPlayBooksTCYWorkaround(readerCSS)) }
        let initialInput = CSSFrontendInput.currentCompatibility(html: html, cssTexts: baseCSS)
        let initialDocument = try BrowserChapterDocument(input: initialInput)

        let desiredMode: ReaderWritingMode = switch writingDirection {
        case .horizontal:
            .horizontal
        case .verticalRTL:
            .verticalRTL
        case .bookDefault:
            initialDocument.principalWritingMode ?? (bookPrefersVertical ? .verticalRTL : .horizontal)
        }

        let evalHTML: String
        let evalCSS: [String]
        let evalInitialDocument: BrowserChapterDocument?
        if desiredMode == .verticalRTL, verticalTypographyOptimization,
           let optimized = try? EPUBVerticalTypographyOptimizer.apply(html: html) {
            evalHTML = optimized.html
            var combined = bookCSS.map(Self.normalizingPlayBooksTCYWorkaround)
            combined.append(optimized.css)
            if let readerCSS { combined.append(Self.normalizingPlayBooksTCYWorkaround(readerCSS)) }
            evalCSS = combined
            evalInitialDocument = nil
        } else {
            evalHTML = html
            evalCSS = baseCSS
            evalInitialDocument = initialDocument
        }

        var result = try await evaluateChapter(
            html: evalHTML, css: evalCSS, baseConfig: config, images: images,
            writingMode: desiredMode, initialDocument: evalInitialDocument)
        var effectiveMode = desiredMode
        var verticalFallback = false
        var verticalFallbackFeatures: [String] = []

        if desiredMode == .verticalRTL, !result.evaluation.capabilities.supported {
            verticalFallbackFeatures = result.evaluation.capabilities.unsupportedFeatures.map(\.description)
            EPUBLayoutLog.logger.notice("Vertical chapter unsupported (\(verticalFallbackFeatures.joined(separator: ", "), privacy: .public)); falling back to horizontal")
            // 回退横排时恢复未做竖排标点/缩进改写的原始 HTML 与 CSS。
            let horizontalResult = try await evaluateChapter(
                html: html, css: baseCSS, baseConfig: config, images: images,
                writingMode: .horizontal, initialDocument: initialDocument)
            result = horizontalResult
            effectiveMode = .horizontal
            verticalFallback = true
        }

        guard result.evaluation.capabilities.supported else {
            throw HTMLLayoutError.unsupported(result.evaluation.capabilities.unsupportedFeatures)
        }
        let chapterImages = result.images
        let owner = try BrowserPageLayoutOwner(evaluation: result.evaluation, imageLoader: { chapterImages[$0] }, generation: 0)
        let facts = try await withTaskCancellationHandler {
            try await owner.prepare()
        } onCancel: { owner.cancel() }
        try Task.checkCancellation()
        let legacyText = Self.legacyOffsetText(sourceText: facts.sourceText, pronunciationHints: facts.pronunciationHints)
        let isPureSVGIllustration = verticalFallback
            && html.range(of: "<svg", options: .caseInsensitive) != nil
            && facts.sourceText.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Prepared(
            owner: owner, facts: facts,
            positionMap: EPUBSourcePositionMap(legacy: legacyText, current: facts.sourceText),
            tableFallback: result.tableFallback,
            effectiveWritingMode: effectiveMode,
            verticalFallback: verticalFallback,
            verticalFallbackNeedsAlert: verticalFallback && !isPureSVGIllustration,
            verticalFallbackFeatures: verticalFallbackFeatures
        )
    }
}

/// 将新版显示文本和旧版持久化文本的 UTF-16 边界对应起来。
/// 插入的图片与移除的括号注音没有共同字符时，定位到最近的正文边界。
struct EPUBSourcePositionMap: Sendable {
    private var legacyToCurrent: [Int] = []
    private var currentToLegacy: [Int] = []

    init(legacy: String, current: String) {
        guard legacy != current else { return }
        let old = Array(legacy.utf16), new = Array(current.utf16)
        var removed = Set<Int>(), inserted = Set<Int>()
        // 常见变化只有移除括号读音与插入图片字符，先线性对齐。
        // 数万处注音直接做通用差异计算会随编辑距离变慢。
        var oldIndex = 0, newIndex = 0
        var aligned = true
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, newIndex < new.count, old[oldIndex] == new[newIndex] {
                oldIndex += 1; newIndex += 1
            } else if newIndex < new.count, new[newIndex] == 0xFFFC {
                inserted.insert(newIndex); newIndex += 1
            } else if oldIndex < old.count, old[oldIndex] == 0xFF08 {
                var end = oldIndex + 1, depth = 1
                while end < old.count, depth > 0 {
                    if old[end] == 0xFF08 { depth += 1 }
                    if old[end] == 0xFF09 { depth -= 1 }
                    end += 1
                }
                guard depth == 0 else { aligned = false; break }
                removed.formUnion(oldIndex..<end)
                oldIndex = end
            } else {
                aligned = false; break
            }
        }
        if !aligned {
            removed.removeAll(); inserted.removeAll()
            for change in new.difference(from: old) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
        }
        legacyToCurrent = Array(repeating: 0, count: old.count + 1)
        currentToLegacy = Array(repeating: 0, count: new.count + 1)
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                legacyToCurrent[i] = j; i += 1
            } else if j < new.count, inserted.contains(j) {
                currentToLegacy[j] = i; j += 1
            } else {
                legacyToCurrent[i] = j; currentToLegacy[j] = i
                i += 1; j += 1
            }
        }
        legacyToCurrent[old.count] = new.count
        currentToLegacy[new.count] = old.count
    }

    func current(_ offset: Int) -> Int {
        legacyToCurrent.isEmpty ? max(0, offset) : legacyToCurrent[min(max(0, offset), legacyToCurrent.count - 1)]
    }
    func legacy(_ offset: Int) -> Int {
        currentToLegacy.isEmpty ? max(0, offset) : currentToLegacy[min(max(0, offset), currentToLegacy.count - 1)]
    }
}

/// 竖排标点与排版优化：仅在竖排排版渲染层生效，不修改原书文件，且严格保持正文 UTF-16 字符数不变以兼容进度、书签与摘录偏移。
enum EPUBVerticalTypographyOptimizer {
    static let stylesheet = """
    .__novelia_tcy { text-combine-upright: all; }
    p.__novelia_v_indent { text-indent: 1em; }
    p.__novelia_v_noindent { text-indent: 0 !important; }
    """

    private static let skippedTags: Set<String> = [
        "script", "style", "title", "code", "pre", "rt", "rp", "svg"
    ]
    private static let dialogueLeadingScalars: Set<Unicode.Scalar> = [
        "「", "『", "（", "(", "【", "［", "〈", "《"
    ]
    /// 匹配独立的 2 位半角数字（如 `12`、`99`，不拆 4 位年份 `2026` 或小数 `3.14`）以及双感叹/问号。
    private static let tcyRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z._-])(?:[0-9]{2}|!\?|\?!|!!|\?\?|！？|？！|！！|？？)(?![0-9A-Za-z._-])"#
    )

    static func apply(html: String) throws -> (html: String, css: String) {
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        guard let body = document.body() else {
            return (html, stylesheet)
        }
        try transformTextNodes(in: body)
        try classifyParagraphIndentation(in: body)
        return (try document.outerHtml(), stylesheet)
    }

    private static func transformTextNodes(in element: Element) throws {
        let tag = element.tagName().lowercased()
        if skippedTags.contains(tag) { return }
        if element.hasClass("__novelia_tcy") { return }

        let children = element.getChildNodes()
        for node in children {
            if let textNode = node as? TextNode {
                let raw = textNode.getWholeText()
                guard !raw.isEmpty else { continue }
                let quoted = convertQuotes(raw)
                let ns = quoted as NSString
                let matches = tcyRegex.matches(in: quoted, range: NSRange(location: 0, length: ns.length))
                if !matches.isEmpty {
                    var rebuilt = ""
                    rebuilt.reserveCapacity(quoted.count + matches.count * 36)
                    var cursor = 0
                    for match in matches {
                        if match.range.location > cursor {
                            let prefix = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                            rebuilt.append(Entities.escape(prefix))
                        }
                        let token = ns.substring(with: match.range)
                        rebuilt.append("<span class=\"__novelia_tcy\">")
                        rebuilt.append(Entities.escape(token))
                        rebuilt.append("</span>")
                        cursor = match.range.location + match.range.length
                    }
                    if cursor < ns.length {
                        rebuilt.append(Entities.escape(ns.substring(from: cursor)))
                    }
                    try textNode.before(rebuilt)
                    try textNode.remove()
                } else if quoted != raw {
                    textNode.text(quoted)
                }
            } else if let childElement = node as? Element {
                try transformTextNodes(in: childElement)
            }
        }
    }

    private static func convertQuotes(_ text: String) -> String {
        guard text.contains(where: { $0 == "\u{201C}" || $0 == "\u{201D}" || $0 == "\u{2018}" || $0 == "\u{2019}" }) else {
            return text
        }
        var result = String()
        result.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\u{201C}": result.append("「")
            case "\u{201D}": result.append("」")
            case "\u{2018}": result.append("『")
            case "\u{2019}": result.append("』")
            default: result.append(ch)
            }
        }
        return result
    }

    private static func classifyParagraphIndentation(in body: Element) throws {
        for paragraph in try body.select("p").array() {
            // 含插图或显式居中/零缩进的段落保持原样，不强加缩进。
            if !(try paragraph.select("img, svg").isEmpty()) { continue }
            let inlineStyle = (try? paragraph.attr("style").lowercased()) ?? ""
            if inlineStyle.contains("text-align") || inlineStyle.contains("text-indent") { continue }
            let text = (try? paragraph.text()) ?? ""
            guard let firstScalar = text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                continue
            }
            if dialogueLeadingScalars.contains(firstScalar) {
                try paragraph.addClass("__novelia_v_noindent")
            } else {
                try paragraph.addClass("__novelia_v_indent")
            }
        }
    }
}
