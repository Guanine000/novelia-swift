import Foundation
import UIKit
import YueduCoreText

// MARK: - 页面标识与排版缓存（原型的核心不变量）
//
// PageID = (generation, spineIndex, pageIndex)。
// 关键规则：手势中看到的下一页、松手后的落页，必须引用同一个 PageID 对应的
// 同一份 PageFragments → DisplayList → 位图。翻页动画只移动已渲染的位图，
// 动画结束绝不重新排版或重新计算目标页。
// generation 在字号或视口尺寸变化时 +1，旧的一组页面整体作废。

struct PrototypePageID: Equatable, Hashable {
    let generation: Int
    let spineIndex: Int
    let pageIndex: Int
}

enum PrototypeLayoutFailure: LocalizedError {
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

@MainActor
final class PrototypePageBook {
    let generation: Int

    private struct ChapterLayout {
        var pages: [PageFragments]
        var sourceText: String
        /// 每页的 DisplayList（渲染与链接命中共用，避免重复构建）。
        var displayLists: [DisplayList]
        /// 每页可点击链接区域（含 noteref 语义），页序号 → 区域集合。
        var linkRegions: [LinkInteractionRegionSet]
        /// 本章注脚文本：noteID（不含 #）→ 文本。
        var footnotes: [String: String]
    }

    private var chapters: [Int: ChapterLayout] = [:]
    private var completedChapters = Set<Int>()
    private var renderedImages: [PrototypePageID: CGImage] = [:]
    /// 每排出一页回调一次（主线程）；宿主借此刷新"下一页已就绪"的可用性。
    var onPagesChanged: (() -> Void)?

    init(generation: Int) {
        self.generation = generation
    }

    /// 把一章交给 YueduCoreText 逐页排版。
    /// 每页之间让路主线程（yield）并立即发布已完成的页——真实书籍整章一次排完
    /// 会冻结 UI 数秒（卡顿），逐页增量让第一页立即可用、翻页预览尽早就绪。
    func layoutChapter(_ spineIndex: Int, container: PrototypeEPUBContainer,
                       config: BrowserLayoutConfig, aspectRatio: CGFloat = 0.5,
                       readerCSS: String? = nil) async throws {
        let html = try await container.chapterHTML(at: spineIndex)
        let chapterHref = container.spine[spineIndex].href
        var css = await container.cssTexts(forChapterHTML: html, chapterHref: chapterHref,
                                           aspectRatio: aspectRatio)
        if let readerCSS { css.append(readerCSS) }
        let images = await container.images(forChapterHTML: html, chapterHref: chapterHref)

        let document = HTMLLayoutDocument(
            html: html,
            css: css,
            configuration: config,
            images: images
        )
        let session = try document.makePageSession()
        // 先构建流水线（不排版页面），使 sourceText 就绪——DisplayList 文本切片依赖它。
        _ = try await session.prepare()
        var layout = ChapterLayout(
            pages: [], sourceText: session.sourceText, displayLists: [], linkRegions: [], footnotes: [:]
        )
        while let page = try await session.layoutNextPage() {
            let list = DisplayListBuilder.build(for: page, sourceText: session.sourceText)
            layout.pages.append(page)
            layout.displayLists.append(list)
            layout.linkRegions.append(LinkInteractionRegionSet.build(
                from: list, spineIndex: spineIndex, anchors: session.pipelineLinkAnchors
            ))
            // 渐进发布：即使本章尚未排完，已完成的页即可用于显示与预览。
            chapters[spineIndex] = layout
            onPagesChanged?()
            await Task.yield()
            try Task.checkCancellation()
        }
        layout.footnotes = session.pipelineFootnotes
        chapters[spineIndex] = layout
        completedChapters.insert(spineIndex)
        onPagesChanged?()
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

    func isPageAvailable(_ id: PrototypePageID) -> Bool {
        guard let chapter = chapters[id.spineIndex] else { return false }
        return id.pageIndex < chapter.pages.count
    }

    func displayList(for id: PrototypePageID) -> DisplayList? {
        guard let chapter = chapters[id.spineIndex],
              chapter.displayLists.indices.contains(id.pageIndex) else { return nil }
        return chapter.displayLists[id.pageIndex]
    }

    func selectionRange(at point: CGPoint, for id: PrototypePageID) -> NSRange? {
        guard let chapter = chapters[id.spineIndex],
              chapter.displayLists.indices.contains(id.pageIndex) else { return nil }
        return BrowserTextGeometry.range(
            at: point,
            in: chapter.displayLists[id.pageIndex],
            source: chapter.sourceText as NSString,
            nearest: true
        )
    }

    func selectionRects(for range: NSRange, on id: PrototypePageID) -> [CGRect] {
        guard let chapter = chapters[id.spineIndex],
              chapter.displayLists.indices.contains(id.pageIndex) else { return [] }
        return BrowserTextGeometry.rects(in: chapter.displayLists[id.pageIndex], range: range)
    }

    func selectedText(for range: NSRange, on id: PrototypePageID) -> String? {
        guard let chapter = chapters[id.spineIndex] else { return nil }
        let source = chapter.sourceText as NSString
        guard range.location >= 0, range.length > 0,
              range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        return source.substring(with: range)
    }

    // MARK: 链接与注脚命中

    /// 页面本地点的链接命中；点为视图坐标（当前页槽位与视口重合，故直接同页本地坐标）。
    func linkRegion(at point: CGPoint, for id: PrototypePageID) -> LinkInteractionRegion? {
        guard let chapter = chapters[id.spineIndex],
              chapter.linkRegions.indices.contains(id.pageIndex) else { return nil }
        return chapter.linkRegions[id.pageIndex].hitTest(point)
    }

    /// 注脚链接对应的注释文本。href 形如 "#note1"；键为不含 "#" 的 noteID。
    func footnoteText(forHref href: String, id: PrototypePageID) -> String? {
        guard let chapter = chapters[id.spineIndex] else { return nil }
        let noteID = href.hasPrefix("#") ? String(href.dropFirst()) : href
        return chapter.footnotes[noteID] ?? chapter.footnotes[href]
    }

    /// 页面画布尺寸（含页边距的整页视口），用于渲染与翻页布局。
    func pageCanvasSize(_ id: PrototypePageID) -> CGSize? {
        guard let chapter = chapters[id.spineIndex],
              chapter.pages.indices.contains(id.pageIndex) else { return nil }
        return chapter.pages[id.pageIndex].pageRect.rawValue.size
    }

    /// 只读已缓存的位图（不触发渲染）；预览槽位用，避免 body 更新时同步解码大图。
    func cachedRenderedImage(for id: PrototypePageID) -> CGImage? {
        renderedImages[id]
    }

    func isRendered(_ id: PrototypePageID) -> Bool {
        renderedImages[id] != nil
    }

    /// 渲染并缓存页面位图。预览与落页取同一缓存键，天然是同一份结果。
    func renderedImage(for id: PrototypePageID, scale: CGFloat,
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

    func dropRenderedImages(keeping ids: Set<PrototypePageID>) {
        renderedImages = renderedImages.filter { ids.contains($0.key) }
    }
}

// MARK: - 阅读位置

struct PrototypeReadingLocation: Equatable {
    var spineIndex: Int
    var pageIndex: Int
}
