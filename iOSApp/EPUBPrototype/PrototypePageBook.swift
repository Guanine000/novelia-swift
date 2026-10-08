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
    }

    private var chapters: [Int: ChapterLayout] = [:]
    private var renderedImages: [PrototypePageID: CGImage] = [:]

    init(generation: Int) {
        self.generation = generation
    }

    /// 把一章交给 YueduCoreText 完整排版成连续页面（原型先整章排完，性能验证后再改增量）。
    func layoutChapter(_ spineIndex: Int, container: PrototypeEPUBContainer,
                       config: BrowserLayoutConfig) async throws {
        let html = try await container.chapterHTML(at: spineIndex)
        let css = await container.cssTexts(forChapterHTML: html)
        let images = await container.images(forChapterHTML: html)

        let document = HTMLLayoutDocument(
            html: html,
            css: css,
            configuration: config,
            images: images
        )
        let session = try document.makePageSession()
        var pages: [PageFragments] = []
        while let page = try await session.layoutNextPage() {
            pages.append(page)
        }
        // 空章也允许（保留零页记录，翻页时跨过）。
        chapters[spineIndex] = ChapterLayout(pages: pages, sourceText: session.sourceText)
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
              chapter.pages.indices.contains(id.pageIndex) else { return nil }
        let page = chapter.pages[id.pageIndex]
        return DisplayListBuilder.build(for: page, sourceText: chapter.sourceText)
    }

    /// 页面画布尺寸（含页边距的整页视口），用于渲染与翻页布局。
    func pageCanvasSize(_ id: PrototypePageID) -> CGSize? {
        guard let chapter = chapters[id.spineIndex],
              chapter.pages.indices.contains(id.pageIndex) else { return nil }
        return chapter.pages[id.pageIndex].pageRect.rawValue.size
    }

    /// 渲染并缓存页面位图。预览与落页取同一缓存键，天然是同一份结果。
    func renderedImage(for id: PrototypePageID, scale: CGFloat,
                       background: UIColor) -> CGImage? {
        if let cached = renderedImages[id] { return cached }
        guard let chapter = chapters[id.spineIndex],
              chapter.pages.indices.contains(id.pageIndex) else { return nil }
        let page = chapter.pages[id.pageIndex]
        let canvas = page.pageRect.rawValue
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        let list = DisplayListBuilder.build(for: page, sourceText: chapter.sourceText)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: canvas.size), format: format)
        let image = renderer.image { context in
            let canvasRect = CGRect(origin: .zero, size: canvas.size)
            background.setFill()
            context.fill(canvasRect)
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
