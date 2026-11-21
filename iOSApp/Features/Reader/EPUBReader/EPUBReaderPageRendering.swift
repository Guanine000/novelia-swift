import SwiftUI
import UIKit
import YueduCoreText
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

// MARK: - 原生 EPUB 页面查询、位图预渲染与标注高亮

@MainActor
extension EPUBReaderModel {
    func pageID(_ spineIndex: Int, _ pageIndex: Int) -> EPUBPageID {
        EPUBPageID(generation: generation, spineIndex: spineIndex, pageIndex: pageIndex)
    }

    /// 已缓存页面位图的读取（不触发渲染，供预览槽位使用）。
    private func cachedImage(_ spineIndex: Int, _ pageIndex: Int, background: UIColor) -> CGImage? {
        pageBook?.cachedRenderedImage(for: pageID(spineIndex, pageIndex))
    }

    /// 空闲渲染相邻页位图，避免拖动开始/落页提交瞬间同步解码大图造成卡顿。
    private func schedulePrerender(around spineIndex: Int, pageIndex: Int) {
        guard let pageBook, let container = source else { return }
        let background = pageBackground
        var ids: [EPUBPageID] = [
            pageID(spineIndex, pageIndex - 1),
            pageID(spineIndex, pageIndex + 1),
        ]
        if pageIndex == 0, spineIndex > 0, pageCount(spineIndex: spineIndex - 1) > 0 {
            ids.append(pageID(spineIndex - 1, pageCount(spineIndex: spineIndex - 1) - 1))
        }
        if pageIndex + 1 >= pageCount(spineIndex: spineIndex),
           spineIndex + 1 < container.chapterCount {
            ids.append(pageID(spineIndex + 1, 0))
        }
        // 只预渲染实际存在的页：章首的“上一页”（-1）与章末的“下一页”永远渲染不出来，
        // 若照样排队，每次失败都会发布变化、触发重绘并再次排队，形成持续占满 CPU 的循环。
        for id in ids where (0..<pageCount(spineIndex: id.spineIndex)).contains(id.pageIndex)
            && !pageBook.isRendered(id) && !scheduledRenders.contains(id) {
            scheduledRenders.insert(id)
            Task { [weak self] in
                guard let self else { return }
                let image = self.pageBook?.renderedImage(for: id, scale: self.displayScale, background: background, backgroundImage: settings.backgrounds.image(dark: self.isDarkMode, landscape: self.viewportSize.width > self.viewportSize.height))
                self.scheduledRenders.remove(id)
                if image != nil { self.objectWillChange.send() }
            }
        }
    }

    func pageCount(spineIndex: Int) -> Int {
        pageBook?.pageCount(spineIndex: spineIndex) ?? 0
    }

    /// 底栏默认位置文字：只保留页（TXT 带章），诊断版另见 `locationDescription`。
    var pageDescription: String {
        guard let source else { return "" }
        let total = max(pageCount(spineIndex: location.spineIndex), 1)
        let page = "第 \(min(location.pageIndex + 1, total))/\(total) 页"
        guard container != nil else {
            let chapter = (source as? TextChapterSource)?.tocEntry(containingUnit: location.spineIndex)
            return "第 \((chapter ?? location.spineIndex) + 1)/\(max(source.toc.count, 1)) 章 · \(page)"
        }
        return page
    }

    var locationDescription: String {
        guard let source else { return "" }
        let total = pageCount(spineIndex: location.spineIndex)
        let page = "第 \(min(location.pageIndex + 1, max(total, 1)))/\(max(total, 1)) 页"
        guard container != nil else {
            let chapter = (source as? TextChapterSource)?.tocEntry(containingUnit: location.spineIndex)
            return "第 \((chapter ?? location.spineIndex) + 1)/\(max(source.toc.count, 1)) 章 · \(page)"
        }
        return "spine \(location.spineIndex + 1)/\(source.chapterCount) · \(page) · gen \(generation)"
    }

    /// 当前章内的页码进度，供底栏切换「本章进度」。
    var chapterProgressDescription: String {
        let total = max(pageCount(spineIndex: location.spineIndex), 1)
        let page = min(location.pageIndex + 1, total)
        return "本章 \(Int((Double(page) / Double(total) * 100).rounded()))%"
    }

    /// 全书进度百分比，供底栏切换「全书进度」。
    var bookProgressDescription: String {
        "全书 \(Int((overallProgress * 100).rounded()))%"
    }

    /// 进度条拖动预览用：按章节平均权重换算目标章节标题。
    /// 与 `seek(to:)` 使用同一套换算，保证预览与松手后的落点一致。
    func chapterTitle(forProgress progress: Double) -> String? {
        guard let source, source.chapterCount > 0 else { return nil }
        let fraction = min(max(progress, 0), 1)
        let index = min(Int(fraction * Double(source.chapterCount)), source.chapterCount - 1)
        return chapterTitle(index)
    }

    /// 全书进度估计（0...1）：spine 粒度 + 当前章内页进度。
    /// 章节尚未全部排版时无法精确总页数，按章节平均权重近似。
    var overallProgress: Double {
        guard let source, source.chapterCount > 0 else { return 0 }
        let chapterTotal = max(pageCount(spineIndex: location.spineIndex), 1)
        let chapterProgress = min(Double(location.pageIndex + 1), Double(chapterTotal)) / Double(chapterTotal)
        return min((Double(location.spineIndex) + chapterProgress) / Double(source.chapterCount), 1)
    }

    /// 拖动进度条后才定位，避免手指移动时反复排版和重建分页位图。
    /// `restoring` 为 true 时（打开时按旧版全书比例恢复）落页不写入阅读位置，不刷新同步时间戳。
    func seek(to progress: Double, restoring: Bool = false) {
        guard !isAnimating, !isLayingOut, status == .ready,
              let container = source, let book = pageBook, container.chapterCount > 0 else { return }
        let fraction = min(max(progress, 0), 1)
        let position = fraction * Double(container.chapterCount)
        let spineIndex = min(Int(position), container.chapterCount - 1)
        let pageFraction = fraction >= 1 ? 1 : position - Double(spineIndex)
        isLayingOut = true
        track { [weak self] in
            guard let self else { return }
            defer { isLayingOut = false }
            if !book.isChapterComplete(spineIndex) {
                do {
                    try await book.layoutChapter(spineIndex, container: container,
                                                 config: makeConfig(), aspectRatio: viewportAspectRatio,
                                                 readerCSS: effectiveReaderCSS,
                                                 writingDirection: writingDirectionRequest,
                                                 context: layoutContext(.seek))
                } catch {
                    if EPUBLayoutLog.failure(error).kind != "cancelled", pageBook === book {
                        status = .failed(describeLayoutError(error))
                    }
                    return
                }
            }
            guard pageBook === book else { return }
            let count = max(pageCount(spineIndex: spineIndex), 1)
            let wasRestoringPosition = isRestoringPosition
            if restoring { isRestoringPosition = true }
            moveLocation(to: EPUBReadingLocation(
                spineIndex: spineIndex,
                pageIndex: min(Int(pageFraction * Double(count)), count - 1)
            ), cause: restoring ? "restore" : "seek")
            isRestoringPosition = wasRestoringPosition
            prefetchNeighbors(of: spineIndex)
        }
    }

    /// 与当前阅读位置对应的目录条目序号：最后一个 spineIndex ≤ 当前章的条目。
    var currentTOCIndex: Int? {
        guard let toc = source?.toc, !toc.isEmpty else { return nil }
        var match: Int?
        for (index, entry) in toc.enumerated() {
            if let spineIndex = entry.spineIndex, spineIndex <= location.spineIndex {
                match = index
            }
        }
        return match
    }

    /// 三页位图（同一份缓存结果，预览与落页共用）。
    /// 当前页同步渲染（保证首屏立即可见）；相邻页只用缓存并异步预渲染，
    /// 渲染完成后再刷新——拖动开始瞬间不再有解码大图造成的卡顿。
    func pagerImages() -> EPUBPagerView.PageImages {
        guard let pageBook else { return .init(previous: nil, current: nil, next: nil) }
        if usesDoublePage {
            var result = EPUBPagerView.PageImages(previous: spreadImage(at: turnLocation(forward: false)),
                                                  current: spreadImage(at: location),
                                                  next: spreadImage(at: turnLocation(forward: true)), size: viewportSize)
            if settings.nativePageCurlEnabled {
                result.currentHighlights = pageHighlights(spineIndex: location.spineIndex,
                                                         pageIndex: location.pageIndex, leafCount: 2)
                result.previousHighlights = neighborHighlights(forward: false)
                result.nextHighlights = neighborHighlights(forward: true)
            }
            return result
        }
        let size = viewportSize
        guard size.width > 0 else { return .init(previous: nil, current: nil, next: nil) }
        let background = pageBackground

        var result = EPUBPagerView.PageImages(
            previous: cachedImage(location.spineIndex, location.pageIndex - 1, background: background),
            current: pageBook.renderedImage(for: pageID(location.spineIndex, location.pageIndex),
                                            scale: displayScale, background: background, backgroundImage: settings.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height)),
            next: cachedImage(location.spineIndex, location.pageIndex + 1, background: background)
        )
        result.size = size
        // 跨章边界：上一章末页 / 下一章首页。
        if result.previous == nil, location.spineIndex > 0,
           pageCount(spineIndex: location.spineIndex - 1) > 0 {
            result.previous = cachedImage(location.spineIndex - 1,
                                          pageCount(spineIndex: location.spineIndex - 1) - 1,
                                          background: background)
        }
        if result.next == nil, let source, location.spineIndex + 1 < source.chapterCount {
            result.next = cachedImage(location.spineIndex + 1, 0, background: background)
        }
        if settings.nativePageCurlEnabled {
            result.currentHighlights = pageHighlights(spineIndex: location.spineIndex,
                                                     pageIndex: location.pageIndex, leafCount: usesDoublePage ? 2 : 1)
            result.previousHighlights = neighborHighlights(forward: false)
            result.nextHighlights = neighborHighlights(forward: true)
        }
        schedulePrerender(around: location.spineIndex, pageIndex: location.pageIndex)
        return result
    }

    /// 仿真卷页纸面需要当前/相邻页的标注矩形；矩形坐标与分页页一致，由纸面合成时加安全区偏移。
    private func pageHighlights(spineIndex: Int, pageIndex: Int, leafCount: Int) -> [EPUBPagerView.PageHighlight] {
        guard let bookKey = bookmarkKey, let pageBook,
              let text = pageBook.sourceText(spineIndex: spineIndex),
              spineIndex >= 0, pageIndex >= 0 else { return [] }
        let annotations = settings.annotations.annotations(for: bookKey, chapter: spineIndex)
        guard !annotations.isEmpty else { return [] }
        var result: [EPUBPagerView.PageHighlight] = []
        for annotation in annotations {
            guard let range = ReaderAnnotationResolver.resolve(annotation, in: text) else { continue }
            for leaf in 0..<leafCount {
                let offsetX = leafOriginX(for: leaf, spineIndex: spineIndex)
                for rect in pageBook.selectionRects(for: range, on: pageID(spineIndex, pageIndex + leaf)) {
                    result.append(.init(rect: rect.offsetBy(dx: offsetX, dy: 0),
                                        color: annotation.color))
                }
            }
        }
        return result
    }

    private func neighborHighlights(forward: Bool) -> [EPUBPagerView.PageHighlight] {
        guard let target = turnLocation(forward: forward) else { return [] }
        return pageHighlights(spineIndex: target.spineIndex, pageIndex: target.pageIndex,
                              leafCount: usesDoublePage ? 2 : 1)
    }

    private func spreadImage(at target: EPUBReadingLocation?) -> CGImage? {
        guard let target, let pageBook,
              pageBook.isPageAvailable(pageID(target.spineIndex, target.pageIndex)) else { return nil }
        let ids = (0..<2).map { pageID(target.spineIndex, target.pageIndex + $0) }
        let secondAvailable = pageBook.isPageAvailable(ids[1])
        if let cached = spreadCache[ids[0]], cached.secondLeafAvailable == secondAvailable { return cached.image }
        let leaves = ids.map { pageBook.renderedImage(for: $0, scale: displayScale, background: pageBackground, backgroundImage: settings.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height)) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: viewportSize, format: format).image { context in
            pageBackground.setFill()
            context.fill(CGRect(origin: .zero, size: viewportSize))
            for (index, image) in leaves.enumerated() {
                if let image {
                    let originX = leafOriginX(for: index, spineIndex: target.spineIndex)
                    UIImage(cgImage: image, scale: displayScale, orientation: .up)
                        .draw(in: CGRect(x: originX, y: 0, width: leafWidth, height: viewportSize.height))
                }
            }
        }.cgImage
        if let image {
            spreadCache[ids[0]] = SpreadCacheEntry(secondLeafAvailable: secondAvailable, image: image)
            let nearby = [location, turnLocation(forward: true), turnLocation(forward: false)].compactMap { $0 }
            let keep = Set(nearby.map { pageID($0.spineIndex, $0.pageIndex) })
            spreadCache = spreadCache.filter { keep.contains($0.key) }
        }
        return image
    }

    func selectionRange(at point: CGPoint) -> NSRange? {
        // 两个页面共用章节 UTF-16 偏移量，因此选择范围可以跨越中缝。
        let leaf = leafIndex(atX: point.x, spineIndex: location.spineIndex)
        selectionLeaf = leaf
        let originX = leafOriginX(for: leaf, spineIndex: location.spineIndex)
        return pageBook?.selectionRange(at: CGPoint(x: point.x - originX, y: point.y),
                                       for: pageID(location.spineIndex, location.pageIndex + leaf))
    }

    func selectionRects(for range: NSRange) -> [CGRect] {
        (0..<(usesDoublePage ? 2 : 1)).flatMap { leaf in
            let originX = leafOriginX(for: leaf, spineIndex: location.spineIndex)
            return (pageBook?.selectionRects(for: range, on: pageID(location.spineIndex, location.pageIndex + leaf)) ?? [])
                .map { $0.offsetBy(dx: originX, dy: 0) }
        }
    }

    func selectedText(for range: NSRange) -> String? {
        pageBook?.selectedText(for: range, on: pageID(location.spineIndex, location.pageIndex + selectionLeaf))
    }

    /// 提取选区前后各约 240 个 UTF-16 字符的上下文，供「AI 语境解析」使用。
    func selectionContext(for range: NSRange) -> String? {
        guard let text = pageBook?.sourceText(spineIndex: location.spineIndex) else { return nil }
        let nsText = text as NSString
        let total = nsText.length
        guard total > 0, range.location != NSNotFound, range.location < total else { return nil }
        let clampedEnd = min(total, NSMaxRange(range))
        let start = max(0, range.location - 240)
        let end = min(total, clampedEnd + 240)
        guard end > start else { return nil }
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }

    /// 把当前选中的章内范围保存为标注；位置以引文和 UTF-16 范围持久化，不保存页面坐标。
    @discardableResult
    func addAnnotation(range: NSRange, quote: String, color: ReaderAnnotation.Color = .yellow,
                       note: String = "") -> ReaderAnnotation? {
        guard let bookKey = bookmarkKey,
              let text = pageBook?.sourceText(spineIndex: location.spineIndex),
              NSMaxRange(range) <= (text as NSString).length else { return nil }
        do {
            let annotation = try settings.annotations.add(
                bookKey: bookKey, chapterIndex: location.spineIndex,
                chapterID: webChapterID(location.spineIndex),
                resourceHref: container.flatMap {
                    $0.spine.indices.contains(location.spineIndex) ? $0.spine[location.spineIndex].href : nil
                },
                progression: min(1, max(0, Double(range.location) / Double(max(1, text.utf16.count)))),
                range: range, quote: quote, chapterText: text,
                projectionIdentity: settings.projection.identity, color: color, note: note
            )
            refreshAnnotationHighlights()
            return annotation
        } catch {
            annotationError = error.localizedDescription
            return nil
        }
    }

    func annotationID(at point: CGPoint) -> UUID? {
        annotationHighlights.last(where: { $0.rect.contains(point) })?.id
    }

    func jump(to annotation: ReaderAnnotation) {
        jump(toChapter: annotation.chapterIndex, progression: annotation.progression ?? 0,
             exactOffset: annotation.startUTF16)
    }

    /// 当前页的标注矩形。只从持久化引文计算，不写回页面位图；翻页、重排或标注变化后重算。
    func refreshAnnotationHighlights() {
        guard status == .ready, let bookKey = bookmarkKey, let pageBook,
              let text = pageBook.sourceText(spineIndex: location.spineIndex) else {
            if !annotationHighlights.isEmpty { annotationHighlights = [] }
            return
        }
        let annotations = settings.annotations.annotations(for: bookKey, chapter: location.spineIndex)
        var next: [AnnotationHighlight] = []
        for annotation in annotations {
            guard let range = ReaderAnnotationResolver.resolve(annotation, in: text) else { continue }
            next.append(contentsOf: selectionRects(for: range).map {
                AnnotationHighlight(id: annotation.id, rect: $0, color: annotation.color)
            })
        }
        if next != annotationHighlights { annotationHighlights = next }
    }
}
