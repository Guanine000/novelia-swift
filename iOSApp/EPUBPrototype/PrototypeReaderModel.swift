import SwiftUI
import UIKit
import YueduCoreText

// MARK: - 原型阅读模型
//
// 不变量：
// 1. 手势中的下一页、动画结束后的落页引用同一个 PageID（见 PrototypePageBook）。
// 2. 字号 / 视口尺寸变化 → generation += 1，整组页面作废重排；翻页动画进行中
//    （isAnimating）不切换代次。
// 3. 跨章节翻页必须先把目标章排版完成，才允许开始动画。

@MainActor
final class PrototypeReaderModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var container: PrototypeEPUBContainer?
    private(set) var pageBook: PrototypePageBook?
    @Published private(set) var location = PrototypeReadingLocation(spineIndex: 0, pageIndex: 0)
    @Published private(set) var generation = 0
    @Published private(set) var fontSize: CGFloat = 21
    @Published private(set) var isAnimating = false
    @Published private(set) var isLayingOut = false

    /// 视口内容区尺寸（由界面测量后注入；变化即触发重排）。
    var viewportSize: CGSize = .zero {
        didSet {
            if oldValue != viewportSize, oldValue != .zero, status == .ready {
                Task { await relayout(keepingCurrentSpine: true) }
            }
        }
    }

    var displayScale: CGFloat = UIScreen.main.scale

    private var relayoutTask: Task<Void, Never>?
    private var contentInsets = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)

    var statusMessage: String {
        if case .failed(let message) = status { return message }
        return ""
    }

    // MARK: 打开

    func open(url: URL) async {
        status = .opening
        do {
            let container = try await PrototypeEPUBContainer.open(fileURL: url)
            self.container = container
            location = PrototypeReadingLocation(spineIndex: 0, pageIndex: 0)
            await relayout(keepingCurrentSpine: false)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: 排版配置

    private func makeConfig() -> BrowserLayoutConfig {
        let contentWidth = max(1, viewportSize.width - contentInsets.left - contentInsets.right)
        let contentHeight = max(1, viewportSize.height - contentInsets.top - contentInsets.bottom)
        var config = BrowserLayoutConfig()
        config.renderWidth = contentWidth
        config.renderHeight = contentHeight
        config.rootFontSize = fontSize
        config.contentInsets = contentInsets
        config.backgroundColor = UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1)
        config.defaultTextAlignment = .natural
        return config
    }

    /// 重排当前章（以及前后相邻章的预取）。generation 递增使旧页面全部失效。
    private func relayout(keepingCurrentSpine: Bool) async {
        guard let container else { return }
        relayoutTask?.cancel()
        generation += 1
        let book = PrototypePageBook(generation: generation)
        pageBook = book
        let spineIndex = keepingCurrentSpine ? location.spineIndex : 0
        location.pageIndex = 0
        location.spineIndex = spineIndex

        isLayingOut = true
        defer { isLayingOut = false }
        do {
            try await book.layoutChapter(spineIndex, container: container, config: makeConfig())
            if book.generation == generation {
                status = .ready
                location.spineIndex = spineIndex
                location.pageIndex = 0
                prefetchNeighbors(of: spineIndex)
            }
        } catch {
            if book.generation == generation {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// 空闲时预排前后相邻章，让跨章拖动时目标页位图已经就位。
    private func prefetchNeighbors(of spineIndex: Int) {
        guard let container, let book = pageBook else { return }
        let generationSnapshot = generation
        for neighbor in [spineIndex + 1, spineIndex - 1] where container.spine.indices.contains(neighbor) {
            guard !book.hasChapter(neighbor) else { continue }
            let config = makeConfig()
            Task {
                try? await book.layoutChapter(neighbor, container: container, config: config)
                _ = generationSnapshot // 预取结果挂在当前 book 上，代次切换即整体作废
            }
        }
    }

    // MARK: 页面查询

    private func pageID(_ spineIndex: Int, _ pageIndex: Int) -> PrototypePageID {
        PrototypePageID(generation: generation, spineIndex: spineIndex, pageIndex: pageIndex)
    }

    func pageCount(spineIndex: Int) -> Int {
        pageBook?.pageCount(spineIndex: spineIndex) ?? 0
    }

    var locationDescription: String {
        guard let container else { return "" }
        let total = pageCount(spineIndex: location.spineIndex)
        return "spine \(location.spineIndex + 1)/\(container.spine.count) · 第 \(min(location.pageIndex + 1, max(total, 1)))/\(max(total, 1)) 页 · gen \(generation)"
    }

    /// 三页位图（同一份缓存结果，预览与落页共用）。
    func pagerImages() -> PrototypePagerView.PageImages {
        guard let pageBook else { return .init(previous: nil, current: nil, next: nil) }
        let size = viewportSize
        guard size.width > 0 else { return .init(previous: nil, current: nil, next: nil) }
        func image(_ spineIndex: Int, _ pageIndex: Int) -> CGImage? {
            pageBook.renderedImage(for: pageID(spineIndex, pageIndex),
                                   scale: displayScale,
                                   background: UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1))
        }
        var result = PrototypePagerView.PageImages(
            previous: image(location.spineIndex, location.pageIndex - 1),
            current: image(location.spineIndex, location.pageIndex),
            next: image(location.spineIndex, location.pageIndex + 1)
        )
        result.size = size
        // 跨章边界：上一章末页 / 下一章首页。
        if result.previous == nil, location.spineIndex > 0,
           pageCount(spineIndex: location.spineIndex - 1) > 0 {
            result.previous = image(location.spineIndex - 1, pageCount(spineIndex: location.spineIndex - 1) - 1)
        }
        if result.next == nil, container != nil,
           location.spineIndex + 1 < (container?.spine.count ?? 0) {
            result.next = image(location.spineIndex + 1, 0)
        }
        return result
    }

    // MARK: 翻页

    /// 目标页是否已经排版好（拖动开始的门槛：保证动画只移动已渲染结果）。
    func canTurn(forward: Bool) -> Bool {
        guard !isAnimating, !isLayingOut, status == .ready, let pageBook else { return false }
        if forward {
            let count = pageCount(spineIndex: location.spineIndex)
            if location.pageIndex + 1 < count { return true }
            return pageBook.hasChapter(location.spineIndex + 1) && pageCount(spineIndex: location.spineIndex + 1) > 0
        } else {
            if location.pageIndex > 0 { return true }
            return pageBook.hasChapter(location.spineIndex - 1) && pageCount(spineIndex: location.spineIndex - 1) > 0
        }
    }

    /// 动画结束后的落页提交：只切换索引，不触发任何排版。
    func commitTurn(forward: Bool) {
        guard canTurn(forward: forward) else { return }
        let count = pageCount(spineIndex: location.spineIndex)
        if forward {
            if location.pageIndex + 1 < count {
                location.pageIndex += 1
            } else {
                location.spineIndex += 1
                location.pageIndex = 0
            }
        } else {
            if location.pageIndex > 0 {
                location.pageIndex -= 1
            } else {
                location.spineIndex -= 1
                location.pageIndex = max(pageCount(spineIndex: location.spineIndex) - 1, 0)
            }
        }
        prefetchNeighbors(of: location.spineIndex)
    }

    // MARK: 目录跳转与字号

    /// 翻页动画期间冻结：字号、代次重排都会被拒绝，避免动画中途切换分页代次。
    func setAnimating(_ animating: Bool) {
        isAnimating = animating
    }

    func jump(to entry: PrototypeTOCEntry) {
        guard !isAnimating, !isLayingOut, let spineIndex = entry.spineIndex else { return }
        location.spineIndex = spineIndex
        location.pageIndex = 0
        Task {
            isLayingOut = true
            defer { isLayingOut = false }
            guard let container, let book = pageBook, !book.hasChapter(spineIndex) else { return }
            try? await book.layoutChapter(spineIndex, container: container, config: makeConfig())
        }
    }

    func setFontSize(_ value: CGFloat) {
        guard !isAnimating else { return }
        let clamped = min(30, max(14, value))
        guard clamped != fontSize else { return }
        fontSize = clamped
        Task { await relayout(keepingCurrentSpine: true) }
    }
}
