import Foundation
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

/// Correlation details for one chapter layout request (diagnostics only, except `bookID`,
/// which also scopes the shared layout cache).
struct EPUBLayoutContext {
    /// Stable identity of the book content (EPUB file hash, TXT hash + rules). `nil` keeps the
    /// layout private to this page book: it is still de-duplicated but never cached.
    var bookID: String?
    /// "epub", "txt" or "online": the log line prefix and `kind` field.
    var kind = "epub"
    var trace = "00000000"
    var reason: EPUBLayoutReason = .first
    var totalSpine = 0
    var currentSpine = 0
}

@MainActor
final class EPUBPageBook {
    let generation: Int
    private let coordinator: EPUBLayoutCoordinator
    /// Scopes uncached layouts (no book identity) to this page book.
    private let privateBookID = "private-" + UUID().uuidString

    private var chapters: [Int: EPUBChapterLayout] = [:]
    private var completedChapters = Set<Int>()
    private var renderedImages: [EPUBPageID: CGImage] = [:]
    /// 每排出一页回调一次（主线程）；宿主借此刷新"下一页已就绪"的可用性。
    var onPagesChanged: (() -> Void)?

    init(generation: Int, coordinator: EPUBLayoutCoordinator = .shared) {
        self.generation = generation
        self.coordinator = coordinator
    }

    /// YueduCoreText 0.8.0 justifies a line by kerning only some of its characters.
    /// Core Text then squeezes unkerned CJK punctuation to half width and moves that
    /// width into one large gap. A negligible kern on every character avoids this.
    /// Shared by the reader and the layout regression tests.
    static func applyEngineWorkarounds(to config: inout BrowserLayoutConfig) {
        config.letterSpacing = 0.001
    }

    /// 把一章交给 YueduCoreText 逐页排版（经 EPUBLayoutCoordinator 去重与缓存）。
    /// 每页之间让路主线程（yield）并立即发布已完成的页——真实书籍整章一次排完
    /// 会冻结 UI 数秒（卡顿），逐页增量让第一页立即可用、翻页预览尽早就绪。
    func layoutChapter(_ spineIndex: Int, container: any EPUBChapterSource,
                       config: BrowserLayoutConfig, aspectRatio: CGFloat = 0.5,
                       readerCSS: String? = nil, context: EPUBLayoutContext = EPUBLayoutContext()) async throws {
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
            parameters: EPUBLayoutParameters(config: config, aspectRatio: aspectRatio, readerCSS: readerCSS))
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
                                                 aspectRatio: aspectRatio, readerCSS: readerCSS, publish: publish)
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
                // A cancelled request keeps no partial pages: they may belong to a layout that stopped early.
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
                                      publish: (EPUBChapterLayout) -> Void) async throws -> EPUBChapterLayout {
        let html = try await container.chapterHTML(at: spineIndex)
        try Task.checkCancellation()
        let chapterHref = container.chapterHref(at: spineIndex)
        var css = await container.cssTexts(forChapterHTML: html, chapterHref: chapterHref,
                                           aspectRatio: aspectRatio)
        if let readerCSS { css.append(readerCSS) }
        let images = await container.images(forChapterHTML: html, chapterHref: chapterHref)
        try Task.checkCancellation()

        let document = HTMLLayoutDocument(
            html: html,
            css: css,
            configuration: config,
            images: images
        )
        let session = try document.makePageSession()
        // 先构建流水线（不排版页面），使 sourceText 就绪——DisplayList 文本切片依赖它。
        _ = try session.prepare()
        var layout = EPUBChapterLayout(
            pages: [], sourceText: session.sourceText, displayLists: [], linkRegions: [], footnotes: [:]
        )
        while let page = try await session.layoutNextPage() {
            let list = DisplayListBuilder.build(for: page, sourceText: session.sourceText)
            layout.pages.append(page)
            layout.displayLists.append(list)
            layout.linkRegions.append(LinkInteractionRegionSet.build(
                from: list, spineIndex: spineIndex, anchors: session.pipelineLinkAnchors
            ))
            publish(layout)
            await Task.yield()
            try Task.checkCancellation()
        }
        layout.footnotes = session.pipelineFootnotes
        return layout
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

    /// UTF-16 offset in the chapter source where a page's first text begins; `nil` for
    /// pages without text (full-page images).
    func sourceOffset(spineIndex: Int, pageIndex: Int) -> Int? {
        guard let chapter = chapters[spineIndex], chapter.displayLists.indices.contains(pageIndex) else { return nil }
        return chapter.displayLists[pageIndex].items.compactMap { item -> Int? in
            guard case .text(let text) = item, text.sourceRange.length > 0 else { return nil }
            return text.sourceRange.location
        }.min()
    }

    /// UTF-16 length of a laid-out chapter's text (the space `sourceOffset` measures).
    func sourceLength(spineIndex: Int) -> Int? {
        chapters[spineIndex].map { $0.sourceText.utf16.count }
    }

    /// The page showing `offset`: the last laid-out page whose text starts at or before it.
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
            list.draw(in: context.cgContext)
        }
        renderedImages[id] = image.cgImage
        return image.cgImage
    }

    /// The display list of every page laid out so far in a chapter (layout regression tests).
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

/// One summary line per chapter layout. YueduCoreText's `onDiagnostic` is a trace hook,
/// not an error channel: it reports every styled node, matched rule and laid-out line,
/// thousands of events per chapter, and formatting them slows layout. Real failures are
/// thrown and logged here; the trace runs only in Debug builds launched with
/// `-EPUBEngineTrace`.
enum EPUBLayoutLog {
    static let logger = Logger(subsystem: "cc.novelia.ios.port", category: "epub")
    static let trace = Logger(subsystem: "cc.novelia.ios.port", category: "enginediag")

    static let traceEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-EPUBEngineTrace")
        #else
        false
        #endif
    }()

    /// Log line prefix for a book kind; TXT and online chapters are not EPUB.
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

    /// A fixed kind name and numeric code; error descriptions may hold file paths or book text.
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
}

/// Counts engine trace events by stage for the Debug-only per-chapter summary.
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
