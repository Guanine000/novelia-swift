import OSLog
import SwiftUI
import UIKit
import Combine
import YueduCoreText
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif


// MARK: - 阅读模型
//
// 不变量：
// 1. 手势中的下一页、动画结束后的落页引用同一个 PageID（见 EPUBPageBook）。
// 2. 字号 / 视口尺寸变化 → generation += 1，整组页面作废重排；翻页动画进行中
//    （isAnimating）不切换代次。
// 3. 跨章节翻页必须先把目标章排版完成，才允许开始动画。

@MainActor
final class EPUBReaderModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
    }

    @Published var status: Status = .idle {
        // 打开时 pageBook/location 先于 ready 变化，高亮计算会被状态守卫跳过；就绪后再补算一次。
        didSet { if status == .ready { refreshAnnotationHighlights() } }
    }
    @Published private(set) var source: (any EPUBChapterSource)?
    /// 来源为 EPUB 时保存其容器；目录诊断与文件哈希阅读位置仅适用于 EPUB。
    var container: EPUBContainer? { source as? EPUBContainer }
    private(set) var pageBook: EPUBPageBook? {
        didSet { refreshAnnotationHighlights() }
    }
    struct AnnotationHighlight: Identifiable, Equatable {
        let id: UUID
        let rect: CGRect
        let color: ReaderAnnotation.Color
    }
    @Published var annotationHighlights: [AnnotationHighlight] = []
    @Published var annotationError: String?
    @Published private(set) var readingTimePoint = ReadingTimePoint.start
    private var recapTXT: TXTParsedBook?
    private var textTimeMetrics: (@Sendable (ReadingTextProjection) async throws -> ReadingTimeMetrics)?
    @Published var location = EPUBReadingLocation(spineIndex: 0, pageIndex: 0) {
        didSet {
            refreshSearchHighlight()
            refreshAnnotationHighlights()
            trimPageCaches()
            logLocationChange(from: oldValue)
            readingTimePoint = .init(resource: location.spineIndex,
                fraction: currentPageRange?.range.lowerBound ?? 0,
                reason: locationCause == "turnForward" && !isRestoringPosition && activeRelayouts == 0 ? .forward : .reset)
            guard !isRestoringPosition, activeRelayouts == 0, status == .ready else { return }
            if let positionHandler {
                positionHandler(location.spineIndex, pageBook?.savedOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex))
            } else if let openedBookHash {
                guard webContext == nil || locationCause != nil else { return }
                let offset = pageBook?.savedOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex)
                let length = pageBook?.savedLength(spineIndex: location.spineIndex)
                let progression = offset.flatMap { offset in length.map { EPUBChapterProgress.progression(offset: offset, length: $0) } }
                if webContext == nil {
                    settings.positions.recordEPUB(
                        hash: openedBookHash, fraction: overallProgress, spineIndex: location.spineIndex, chapterOffset: offset,
                        chapterProgression: progression,
                        nativeChapterOffset: pageBook?.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex),
                        nativeSourceHash: pageBook?.sourceHash(spineIndex: location.spineIndex))
                } else {
                    settings.recordEPUBPosition(hash: openedBookHash, fraction: overallProgress, spineIndex: location.spineIndex,
                                               chapterOffset: offset, chapterProgression: progression, context: webContext, paths: webChapterPaths)
                }
            }
        }
    }
    var localRecapSource: LocalRecapSource? {
        guard status == .ready else { return nil }
        if let book = recapTXT, let source = source as? TextChapterSource {
            return .txt(book, title: source.bookTitle, chapter: source.tocEntry(containingUnit: location.spineIndex) ?? 0, projection: settings.projection)
        }
        guard let container, let hash = openedBookHash else { return nil }
        return .epub(container, hash: hash, currentSpine: location.spineIndex, projection: settings.projection)
    }
    var localTimeSource: LocalReadingTimeSource? {
        guard status == .ready, let source else { return nil }
        let projection = settings.projection
        if source is TextChapterSource, let metrics = textTimeMetrics, let key = textBookmarkKey, key.hasPrefix("txt:") {
            let identity = (source as? TextChapterSource)?.layoutIdentity ?? key
            return .init(id: identity + "|" + projection.identity, load: { try await metrics(projection) })
        }
        guard let container, let hash = openedBookHash else { return nil }
        let starts = source.toc.compactMap(\.spineIndex)
        return .epub(url: container.fileURL, hash: hash, spines: Array(container.spine.indices),
                     starts: starts.isEmpty ? Array(container.spine.indices) : starts, projection: projection)
    }

    var openedBookHash: String?
    var textBookmarkKey: String?
    var textTOCWordCounts: (@Sendable () async -> ReaderTOCWordCounts)?
    @Published var speechHighlightRects: [CGRect] = []
    var speechPosition: SpeechReadingPosition?
    var speechSettings = SpeechSettings.default
    @Published var searchHighlightRects: [CGRect] = []
    @Published var readingReturnPoint: (chapter: Int, progression: Double)?
    var searchHit: BookTextSearch.Hit?
    var searchPositionMap: (chapter: Int, hash: String?, map: EPUBSourcePositionMap)?
    var onManualNavigation: (() -> Void)?
    private var isRestoringPosition = false
    private var restoredNativePosition: (offset: Int, hash: String)?
    /// 正在进行的重排数量。重排期间位置会临时归零，此时的变化不写入阅读位置；
    /// 用计数而不是保存/恢复布尔值，避免新重排取消旧重排时旧任务的收尾把状态写乱。
    var activeRelayouts = 0
    /// 尚未完成的保位重排所要回到的位置。重排开始时会把位置归零并换成空的分页结果，
    /// 若它被下一次重排取消（例如切到后台时系统截图导致深浅色或尺寸来回切换），
    /// 后一次必须沿用这里的锚点，不能从已归零的状态重新计算，否则会落到本章第一页。
    /// `page`／`pages` 是重排前实际显示的页码与本章页数，只用于诊断日志。
    private var pendingRelayoutUsesSavedOffset = false
    private var pendingRelayoutAnchor: (spine: Int, offset: Int?, fraction: CGFloat, page: Int, pages: Int)?
    /// 当前这次位置写入的来源（翻页、目录跳转、进度条等），只用于诊断日志，写入后立即清空。
    var locationCause: String?
    @Published private(set) var generation = 0
    @Published var style = EPUBReaderStyle()
    @Published var isAnimating = false
    @Published var isLayingOut = false
    /// 当前展示的注脚弹窗；nil = 无弹窗。关闭弹层不改变阅读位置。
    @Published var activeNote: EPUBNote?

    /// 书内图片（点图查看与目录页“图片”）；仅 EPUB 挂上容器。
    let imageLibrary = ReaderImageLibrary()
    /// 普通链接点击提示（本轮不导航）。
    @Published var plainLinkMessage: String?
    @Published var isShowingTOCDiagnosticsPrompt = false
    @Published var isTOCDiagnosticsExpanded = false {
        didSet {
            guard oldValue != isTOCDiagnosticsExpanded,
                  let key = tocDiagnosticsPreferenceKey else { return }
            UserDefaults.standard.set(isTOCDiagnosticsExpanded, forKey: "\(key).expanded")
        }
    }
    private var tocDiagnosticsPreferenceKey: String?

    /// 视口内容区尺寸（由界面测量后注入；变化即触发重排）。
    var viewportSize: CGSize = .zero {
        didSet {
            if oldValue != viewportSize, oldValue != .zero, status == .ready {
                // 尺寸变化会整章重排；记录前后尺寸，判断是旋转、分屏还是界面元素改变了阅读区。
                EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.viewportChanged(trace: traceID, fromWidth: Int(oldValue.width.rounded()), fromHeight: Int(oldValue.height.rounded()), toWidth: Int(viewportSize.width.rounded()), toHeight: Int(viewportSize.height.rounded())))
                let rotated = (oldValue.width > oldValue.height) != (viewportSize.width > viewportSize.height)
                scheduleRelayout(rotated ? .rotate : .resize)
            }
        }
    }

    var displayScale: CGFloat = UIScreen.main.scale

    /// 视口宽高比（宽/高），用于 @media 的 device-aspect-ratio 条件求值。
    var usesDoublePage: Bool { style.doublePage == true }
    private var leafWidth: CGFloat { viewportSize.width / (usesDoublePage ? 2 : 1) }
    var pageStride: Int { usesDoublePage ? 2 : 1 }
    private var selectionLeaf = 0
    private struct SpreadCacheEntry {
        let secondLeafAvailable: Bool
        let image: CGImage
    }
    private var spreadCache: [EPUBPageID: SpreadCacheEntry] = [:]

    var viewportAspectRatio: CGFloat {
        leafWidth / max(viewportSize.height, 1)
    }

    /// 当前等待中的代次重排任务；新任务会取消旧任务。
    private var relayoutTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    /// 按 spine 预取相邻章节；阅读器移开或代次变化时取消。
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    /// 当前代次的目录、链接、定位和调试跳转排版任务。
    var layoutTasks: [UUID: Task<Void, Never>] = [:]
    var navigateTaskID: UUID?
    /// 关联本次阅读器会话的打开、排版和关闭日志。
    private(set) var traceID = DiagnosticContext.newTraceID()
    /// 限定共享排版结果范围的内容身份；在线章节为 `nil`。
    var layoutBookID: String?
    var bookKind = "epub"
    private let layoutCoordinator: EPUBLayoutCoordinator
    private static let styleDefaultsKey = ReaderSettings.epubStyleKey

    let settings: ReaderSettings
    let webContext: WebNovelEPUBContext?
    let onReachedEnd: (() -> Void)?

    init(settings: ReaderSettings, webContext: WebNovelEPUBContext? = nil, onReachedEnd: (() -> Void)? = nil, layoutCoordinator: EPUBLayoutCoordinator = .shared) {
        self.settings = settings
        self.webContext = webContext; self.onReachedEnd = onReachedEnd
        self.layoutCoordinator = layoutCoordinator
        annotationObservation = settings.annotations.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refreshAnnotationHighlights() }
        }
        EPUBLocalFonts.registerSavedFonts()
        if let data = settings.defaults.data(forKey: settings.styleStorageKey),
           let saved = try? JSONDecoder().decode(EPUBReaderStyle.self, from: data) {
            style = saved
        }
        style.fontSize = CGFloat(settings.fontSize)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimPageCaches(radius: 0) }
        }
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
        annotationObservation?.cancel()
    }

    private var memoryWarningObserver: NSObjectProtocol?
    private var annotationObservation: AnyCancellable?

    /// 在 3× 分辨率下，每页位图约占 14 MB。保留可见页面和两侧各 `radius`
    /// 页（可跨越相邻章节）；其他页面再次进入可视范围时，
    /// 从缓存的排版结果重新渲染。
    private func trimPageCaches(radius: Int = 3) {
        guard let pageBook else { return }
        var keep = Set<EPUBPageID>()
        let spine = location.spineIndex
        let count = pageCount(spineIndex: spine)
        for offset in -radius...(radius + pageStride - 1) {
            let index = location.pageIndex + offset
            if index < 0 {
                let previous = pageCount(spineIndex: spine - 1)
                if previous + index >= 0 { keep.insert(pageID(spine - 1, previous + index)) }
            } else if index >= count {
                keep.insert(pageID(spine + 1, index - count))
            } else {
                keep.insert(pageID(spine, index))
            }
        }
        pageBook.dropRenderedImages(keeping: keep)
        spreadCache = spreadCache.filter { keep.contains($0.key) }
    }

    var statusMessage: String {
        if case .failed(let message) = status { return message }
        return ""
    }

    /// 目录为空时的诊断原因（来自容器解析）。
    var tocDiagnosticText: String? {
        guard let container, container.toc.isEmpty else { return nil }
        return container.tocDiagnostic ?? "目录为空，原因未知"
    }

    var tocFallbackDiagnosticText: String? {
        container?.tocFallbackDiagnostic
    }

    /// 目录上方统一展示并允许折叠、复制的 EPUB 兼容性诊断。
    var tocDiagnosticMessages: [String] {
        guard let container else { return [] }
        var messages: [String] = []
        if let fallback = container.tocFallbackDiagnostic {
            messages.append(fallback)
        }
        if container.strippedScriptCount > 0 {
            messages.append("本书包含 \(container.strippedScriptCount) 处脚本内容，已忽略（脚本不参与显示）。")
        }
        if container.opacityRewriteCount > 0 {
            messages.append("本书包含 \(container.opacityRewriteCount) 处 opacity 透明度，已转换为等价文字颜色（当前排版引擎不支持 opacity 属性）。")
        }
        if container.mediaQueryRewriteCount > 0 {
            messages.append("本书包含 \(container.mediaQueryRewriteCount) 个 @media 规则块，已按设备条件求值（当前排版引擎不支持媒体查询；不匹配的规则被忽略）。")
        }
        if let count = pageBook?.tableFallbackChapterCount, count > 0 {
            messages.append("已排版章节中有 \(count) 章使用不受支持的伪表格结构，已改为普通块布局；插图保留，表格化居中效果不保留。")
        }
        if container.flexGridRewriteCount > 0 {
            messages.append("本书包含 \(container.flexGridRewriteCount) 处 Flex/Grid 布局声明，已回退为普通块布局以显示内容；相关内容的专属对齐和间距效果可能不同。")
        }
        if container.positionRewriteCount > 0 {
            messages.append("本书包含 \(container.positionRewriteCount) 处绝对／固定定位（position: absolute/fixed/sticky），当前排版引擎不支持，已改为按文档顺序显示；相关内容不再固定在原位置。")
        }
        if container.textShadowRewriteCount > 0 {
            messages.append("本书包含 \(container.textShadowRewriteCount) 处文字阴影（text-shadow），当前排版引擎不支持阴影，已改用阴影颜色作为文字颜色以保证可读。")
        }
        if container.toc.isEmpty, let diagnostic = container.tocDiagnostic {
            messages.append(diagnostic)
        }
        return messages
    }

    // MARK: 链接 / 注脚命中

    /// 视图点击点 → 链接语义。注脚返回其文本；普通链接返回 href（本轮不导航）。
    /// 点按位置是正文图片时打开查看器并返回 true（只用于页面中部，左右两侧仍翻页）。
    func openImage(at point: CGPoint) -> Bool {
        guard let pageBook, let container else { return false }
        let leaf = usesDoublePage && point.x >= leafWidth ? 1 : 0
        let id = pageID(location.spineIndex, location.pageIndex + leaf)
        let localPoint = CGPoint(x: point.x - CGFloat(leaf) * leafWidth, y: point.y)
        guard let source = pageBook.imageSource(at: localPoint, for: id),
              let path = EPUBContainer.resolveImagePath(src: source, chapterHref: container.chapterHref(at: id.spineIndex))
        else { return false }
        imageLibrary.presentTapped(path: path)
        return true
    }

    func linkHit(at point: CGPoint) -> EPUBLinkHit? {
        guard let pageBook else { return nil }
        let leaf = usesDoublePage && point.x >= leafWidth ? 1 : 0
        let id = pageID(location.spineIndex, location.pageIndex + leaf)
        let localPoint = CGPoint(x: point.x - CGFloat(leaf) * leafWidth, y: point.y)
        guard let region = pageBook.linkRegion(at: localPoint, for: id) else { return nil }
        switch region.semantic {
        case .noteref:
            if let text = pageBook.footnoteText(forHref: region.href, id: id), !text.isEmpty {
                return .footnote(text)
            }
            // noteref 但找不到注脚正文：不翻页，给出提示而不是静默。
            return .plain("未找到注脚正文（\(region.href)）")
        case .plain:
            // 多看／Sigil 注释插件的 `<a class="duokan-footnote" href="#note_1">` 不带 noteref，
            // 引擎仍把 `li.duokan-footnote-item` 收集为注脚正文；指向本章注脚的普通链接同样弹层，
            // 否则同章锚点跳转不定位，点击看起来毫无反应。
            if region.href.hasPrefix("#"), let text = pageBook.footnoteText(forHref: region.href, id: id), !text.isEmpty {
                return .footnote(text)
            }
            return .plain(region.href)
        }
    }

    // MARK: 打开

    /// 仅启动一次打开流程；阅读器视图在 `onAppear` 时调用此方法，离开时调用 `close()`。
    func start(url: URL) {
        guard status == .idle, openTask == nil else { return }
        openTask = Task { [weak self] in
            await self?.open(url: url)
            if !Task.isCancelled { self?.openTask = nil }
        }
    }

    /// 容器打开失败时尚无章节来源；重新读取原文件，沿用可取消的打开任务。
    func retryOpening(url: URL) {
        guard case .failed = status, source == nil, openTask == nil else { return }
        status = .idle
        start(url: url)
    }

    func start(textBook: PagedTextBook) {
        guard status == .idle, openTask == nil else { return }
        if let id = textBook.preferenceKey ?? textBook.bookmarkKey { settings.activateBook(id) }
        reloadStoredStyle()
        recapTXT = textBook.localRecapBook
        textTimeMetrics = textBook.localTimeMetrics
        textBookmarkKey = textBook.bookmarkKey
        textTOCWordCounts = textBook.tocWordCounts
        openTask = Task { [weak self] in
            await self?.open(source: textBook.source, unit: textBook.startUnit,
                             offset: textBook.startOffset, onPosition: textBook.onPosition)
            if !Task.isCancelled { self?.openTask = nil }
        }
    }

    /// 阅读器离开屏幕时，停止其启动的所有排版任务。已完成的章节排版
    /// 保留在共享协调器缓存中，供下次打开同一本书复用。
    func close() {
        var cancelled = cancelLayoutTasks()
        if let openTask {
            openTask.cancel()
            cancelled += 1
            self.openTask = nil
        }
        if status == .opening { status = .idle }
        EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.readerClosed(trace: traceID, generation: generation, cancelledTasks: cancelled))
    }

    /// 取消等待中的重排、预取和导航排版任务；返回已运行的任务数。
    @discardableResult
    private func cancelLayoutTasks() -> Int {
        var count = 0
        if let relayoutTask { relayoutTask.cancel(); count += 1 }
        relayoutTask = nil
        for task in prefetchTasks.values { task.cancel(); count += 1 }
        prefetchTasks.removeAll()
        for task in layoutTasks.values { task.cancel(); count += 1 }
        layoutTasks.removeAll()
        navigateTaskID = nil
        return count
    }

    /// 运行当前代次的排版操作，使重排或关闭时可以取消它。
    @discardableResult
    func track(_ operation: @escaping @MainActor () async -> Void) -> UUID {
        let id = UUID()
        layoutTasks[id] = Task { [weak self] in
            await operation()
            self?.layoutTasks[id] = nil
        }
        return id
    }

    /// 替换等待中的重排任务：取消旧代次排版，不让它们继续运行到结束。
    /// 分屏或台前调度连续拖拽改变窗口尺寸（`.resize`）时先短暂防抖，
    /// 期间保留当前 `pageBook` 画面与锚点，避免每一帧都清空页面并启动排版。
    func scheduleRelayout(_ reason: EPUBLayoutReason) {
        guard source != nil, status != .idle, status != .opening else { return }
        let cancelled = cancelLayoutTasks()
        EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.relayoutScheduled(trace: traceID, generation: generation, reason: reason.rawValue, cancelledTasks: cancelled))
        relayoutTask = Task { [weak self] in
            if reason == .resize {
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            }
            await self?.relayout(keepingCurrentSpine: true, reason: reason)
            // 替换操作总会先取消此任务，因此未被取消的完成结果仍属于当前任务。
            if !Task.isCancelled { self?.relayoutTask = nil }
        }
    }

    func layoutContext(_ reason: EPUBLayoutReason) -> EPUBLayoutContext {
        EPUBLayoutContext(bookID: layoutBookID, kind: bookKind, trace: traceID, reason: reason,
                          totalSpine: source?.chapterCount ?? 0, currentSpine: location.spineIndex)
    }

    func open(url: URL) async {
        reloadStoredStyle()
        status = .opening
        restoredNativePosition = nil
        isRestoringPosition = true
        bookKind = "epub"
        let start = ContinuousClock.now
        var stage = "hash"
        var restored = false
        EPUBLayoutLog.logger.info("EPUB open started; kind=epub, trace=\(self.traceID, privacy: .public), source=open, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        defer { logOpenOutcome(stage: stage, start: start, restored: restored) }
        do {
            let bookHash = try await Task.detached(priority: .utility) {
                try FileContentHash.sha256(url)
            }.value
            try Task.checkCancellation()
            stage = "container"
            let container = try await EPUBContainer.open(fileURL: url)
            try Task.checkCancellation()
            container.displayProjection = settings.projection
            self.source = container
            imageLibrary.attach(container)
            openedBookHash = bookHash
            layoutBookID = "epub|" + bookHash + "|" + settings.projection.identity
            stage = "layout"
            lastLayoutFailure = nil
            // 直接排版保存位置的章节，避免先排版第 0 章再恢复位置。
            let saved = settings.epubPosition(hash: bookHash, context: webContext, paths: webChapterPaths)
            if let offset = saved?.nativeChapterOffset, let hash = saved?.nativeSourceHash {
                restoredNativePosition = (offset, hash)
            }
            if let spine = saved?.chapterIndex, let offset = saved?.chapterOffset, container.spine.indices.contains(spine) {
                restored = true
                await relayout(keepingCurrentSpine: false, reason: .restore, target: (spine, offset))
            } else if let spine = saved?.chapterIndex, let progression = saved?.chapterProgression, container.spine.indices.contains(spine) {
                // Readium 阅读器保存的位置：保留同一章节，按章节文本长度定位。
                restored = true
                await relayout(keepingCurrentSpine: false, reason: .restore, target: (spine, nil), targetProgression: progression)
            } else {
                await relayout(keepingCurrentSpine: false, reason: .first, target: (0, nil))
            }
            isRestoringPosition = false
            if status == .ready, !restored, let fraction = saved?.fraction, fraction > 0 {
                restored = true
                seek(to: fraction, restoring: true)
            }
            if status == .ready {
                prepareTOCDiagnosticsPrompt(bookHash: bookHash)
            }
        } catch {
            isRestoringPosition = false
            lastLayoutFailure = EPUBLayoutLog.failure(error)
            if error is CancellationError { return }
            status = .failed(describeLayoutError(error))
        }
    }

    /// 生成内容的阅读位置回调：（单元序号，单元文本中的 UTF-16 偏移量）。
    var positionHandler: ((Int, Int?) -> Void)?

    /// 在指定单元和可选文本偏移量处打开生成的章节（TXT / 在线小说）。
    /// 阅读位置通过 `onPosition` 报告，不使用 EPUB 文件哈希存储。
    func open(source: any EPUBChapterSource, unit: Int, offset: Int?,
              onPosition: @escaping (Int, Int?) -> Void) async {
        status = .opening
        restoredNativePosition = nil
        isRestoringPosition = true
        positionHandler = onPosition
        if let text = source as? TextChapterSource { text.displayProjection = settings.projection }
        self.source = source
        layoutBookID = (source as? TextChapterSource)?.layoutIdentity.map { $0 + "|" + settings.projection.identity }
        bookKind = layoutBookID == nil ? "online" : "txt"
        let startTime = ContinuousClock.now
        EPUBLayoutLog.logger.info("\(EPUBLayoutLog.label(kind: self.bookKind), privacy: .public) open started; kind=\(self.bookKind, privacy: .public), trace=\(self.traceID, privacy: .public), source=open, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        defer { logOpenOutcome(stage: "layout", start: startTime, restored: offset != nil) }
        guard source.chapterCount > 0 else {
            isRestoringPosition = false
            status = .failed("没有可阅读的章节。")
            return
        }
        let start = min(max(unit, 0), source.chapterCount - 1)
        await relayout(keepingCurrentSpine: false, reason: offset == nil ? .first : .restore, target: (start, offset))
        isRestoringPosition = false
        if status == .ready {
            onPosition(location.spineIndex, pageBook?.savedOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex))
        }
    }

    /// 失败后重新排版当前章节（例如网络章节未加载成功）。
    func retry() {
        guard case .failed = status, source != nil, !isLayingOut else { return }
        cancelLayoutTasks()
        status = .opening
        relayoutTask = Task { [weak self] in
            await self?.relayout(keepingCurrentSpine: true, reason: .retry)
            if !Task.isCancelled { self?.relayoutTask = nil }
        }
    }

    /// 因取消以外的原因导致预取失败的相邻章节。
    @Published var failedChapters = Set<Int>()

    var neighborLoadFailed: Bool {
        failedChapters.contains(location.spineIndex + 1) || failedChapters.contains(location.spineIndex - 1)
    }

    func retryNeighbors() {
        failedChapters.removeAll()
        prefetchNeighbors(of: location.spineIndex)
    }

    /// 最近一次排版或打开错误的类型，供打开结果摘要日志使用。
    var lastLayoutFailure: (kind: String, code: Int)?

    /// 每次打开书籍记录一行结果；章节日志记录各章节详情。
    private func logOpenOutcome(stage: String, start: ContinuousClock.Instant, restored: Bool) {
        let elapsed = EPUBLayoutLog.milliseconds(since: start)
        let failure = lastLayoutFailure
        let mono = DiagnosticContext.monotonicMilliseconds()
        if Task.isCancelled || failure?.kind == "cancelled" {
            EPUBLayoutLog.logger.info("\(EPUBLayoutLog.label(kind: self.bookKind), privacy: .public) open cancelled; kind=\(self.bookKind, privacy: .public), trace=\(self.traceID, privacy: .public), elapsedMs=\(elapsed, privacy: .public), mono=\(mono, privacy: .public)")
        } else if case .failed = status {
            let failure = failure ?? ("other", 0)
            EPUBLayoutLog.logger.error("\(EPUBLayoutLog.label(kind: self.bookKind), privacy: .public) open failed; kind=\(self.bookKind, privacy: .public), trace=\(self.traceID, privacy: .public), stage=\(stage, privacy: .public), error=\(failure.kind, privacy: .public), code=\(failure.code, privacy: .public), elapsedMs=\(elapsed, privacy: .public), mono=\(mono, privacy: .public)")
        } else {
            let book = DiagnosticContext.bookTag(layoutBookID ?? "private-\(traceID)")
            let spine = source?.chapterCount ?? 0
            let toc = source?.toc.count ?? 0
            let pages = pageCount(spineIndex: location.spineIndex)
            EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.openSucceeded(label: EPUBLayoutLog.label(kind: bookKind), kind: bookKind, trace: traceID, book: book, totalSpine: spine, toc: toc, currentSpine: location.spineIndex, currentChapterPages: pages, restored: restored, elapsedMs: elapsed, mono: mono))
        }
    }

    private func prepareTOCDiagnosticsPrompt(bookHash: String) {
        // 网络小说更新面板可能仍在呈现；目录说明保留在目录中，避免打开新版时抢占更新/续读面板。
        guard webContext == nil else { return }
        guard !tocDiagnosticMessages.isEmpty else { return }
        let key = "epubPrototype.tocDiagnostics.v2.\(bookHash)"
        tocDiagnosticsPreferenceKey = key
        let defaults = UserDefaults.standard
        if let savedExpansion = defaults.object(forKey: "\(key).expanded") as? Bool {
            isTOCDiagnosticsExpanded = savedExpansion
        } else {
            isTOCDiagnosticsExpanded = false
        }
        guard !defaults.bool(forKey: "\(key).shown") else { return }
        defaults.set(true, forKey: "\(key).shown")
        isShowingTOCDiagnosticsPrompt = true
    }

    // MARK: 主题与排版配置

    /// 跟随系统深浅色（由视图在 colorScheme 变化时同步）。变化触发代次重排。
    @Published private(set) var isDarkMode = false

    /// 页面底色（浅色=米色纸面，深色=近黑）。
    var pageBackground: UIColor {
        let settings = self.settings
        return UIColor(settings.backgrounds.color(dark: isDarkMode,
            fallback: settings.appearance.background(system: isDarkMode ? .dark : .light)))
    }

    /// 正文颜色（浅色=黑，深色=近白）。
    var pageTextColor: UIColor {
        UIColor(settings.appearance.primaryText(system: isDarkMode ? .dark : .light))
    }

    /// 页面底色（SwiftUI 视图背景用）。
    var pageBackgroundColor: Color {
        Color(pageBackground)
    }

    var bookBackgroundFollow = ReaderBookBackgroundFollow.default
    private var backgroundRefreshTask: Task<Void, Never>?
    /// 合并短时间内密集出现的背景或字体通知（用于防抖，不用于解决竞态）。
    func refreshBackground() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            self?.scheduleRelayout(.backgroundChange)
        }
    }

    func setDarkMode(_ dark: Bool) {
        guard dark != isDarkMode, !isAnimating else { return }
        isDarkMode = dark
        source?.themeTextColor = pageTextColor
        scheduleRelayout(.themeChange)
    }

    /// 等待当前翻页或排版完成后，通过一次重排应用共享字体和主题变化。
    func synchronizeSharedSettings(systemIsDark: Bool) {
        guard !isAnimating, !isLayingOut else { return }
        let settings = self.settings
        let dark = settings.isDark(systemIsDark: systemIsDark)
        let font = CGFloat(settings.fontSize)
        guard dark != isDarkMode || font != style.fontSize else { return }
        let reason: EPUBLayoutReason = font != style.fontSize ? .fontChange : .themeChange
        isDarkMode = dark
        style.fontSize = font
        source?.themeTextColor = pageTextColor
        scheduleRelayout(reason)
    }

    func makeConfig() -> BrowserLayoutConfig {
        let contentInsets = style.contentInsets
        let contentWidth = max(1, leafWidth - contentInsets.left - contentInsets.right)
        let contentHeight = max(1, viewportSize.height - contentInsets.top - contentInsets.bottom)
        var config = BrowserLayoutConfig()
        config.renderWidth = contentWidth
        config.renderHeight = contentHeight
        config.rootFontSize = style.fontSize
        config.fontFamilies = style.fontFamily.map { [$0] } ?? []
        config.lineSpacing = style.lineSpacing
        config.paragraphSpacing = style.paragraphSpacing
        config.contentInsets = contentInsets
        config.textColor = pageTextColor
        config.backgroundColor = settings.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height) == nil ? pageBackground : .clear
        config.defaultTextAlignment = .natural
        EPUBPageBook.applyEngineWorkarounds(to: &config)
        return config
    }

    /// 重排当前章（以及前后相邻章的预取）。generation 递增使旧页面全部失效。
    /// `target` 用于在源文本偏移量处打开章节（打开书籍或恢复保存位置）。
    private func relayout(keepingCurrentSpine: Bool, reason: EPUBLayoutReason,
                          target: (spine: Int, offset: Int?)? = nil, targetProgression: Double? = nil) async {
        guard let container = source else { return }
        activeRelayouts += 1
        defer { activeRelayouts -= 1 }
        container.themeTextColor = pageTextColor
        // 预取和跳转任务属于即将被替换的代次。
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        for task in layoutTasks.values { task.cancel() }
        layoutTasks.removeAll()
        let anchor: (spine: Int, offset: Int?, fraction: CGFloat, page: Int, pages: Int)
        let resumed: Bool
        let usesSavedOffset: Bool
        if target == nil, keepingCurrentSpine, let pending = pendingRelayoutAnchor {
            anchor = pending
            usesSavedOffset = pendingRelayoutUsesSavedOffset
            resumed = true
        } else {
            usesSavedOffset = target != nil && reason == .restore
            let spine = target?.spine ?? (keepingCurrentSpine ? location.spineIndex : 0)
            let previousCount = max(pageCount(spineIndex: spine), 1)
            // 重新分页时保持屏幕上显示同一段文本；比例仅用于
            // 没有文本的页面作为回退。
            anchor = (
                spine,
                target != nil ? target?.offset
                    : (keepingCurrentSpine ? pageBook?.sourceOffset(spineIndex: spine, pageIndex: location.pageIndex) : nil),
                keepingCurrentSpine && target == nil ? CGFloat(location.pageIndex) / CGFloat(previousCount) : 0,
                location.pageIndex,
                pageCount(spineIndex: spine)
            )
            resumed = false
        }
        pendingRelayoutAnchor = anchor
        pendingRelayoutUsesSavedOffset = usesSavedOffset
        let spineIndex = anchor.spine
        let previousFraction = anchor.fraction
        let previousOffset = anchor.offset
        spreadCache.removeAll()
        failedChapters.removeAll()
        generation += 1
        let book = EPUBPageBook(generation: generation, coordinator: layoutCoordinator,
                                ignoresNearWhite: bookBackgroundFollow == .ignoreNearWhite)
        book.onPagesChanged = { [weak self] in
            self?.objectWillChange.send()
        }
        pageBook = book
        location.pageIndex = 0
        location.spineIndex = spineIndex

        isLayingOut = true
        defer { isLayingOut = false }
        do {
            try await book.layoutChapter(spineIndex, container: container, config: makeConfig(),
                                         aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                         context: layoutContext(reason))
            if book.generation == generation {
                pendingRelayoutAnchor = nil
                status = .ready
                location.spineIndex = spineIndex
                var restoreOffset = previousOffset.map { usesSavedOffset ? book.restoredOffset(spineIndex: spineIndex, savedOffset: $0) : $0 } ?? targetProgression.flatMap { progression in
                    book.sourceLength(spineIndex: spineIndex).map { EPUBChapterProgress.offset(progression: progression, length: $0) }
                }
                if usesSavedOffset, let native = restoredNativePosition,
                   book.sourceHash(spineIndex: spineIndex) == native.hash {
                    restoreOffset = native.offset
                }
                restoredNativePosition = nil
                let anchorKind: String
                if let restoreOffset, let page = book.pageIndex(spineIndex: spineIndex, containingSourceOffset: restoreOffset) {
                    location.pageIndex = page
                    anchorKind = previousOffset != nil ? "offset" : "progression"
                } else {
                    location.pageIndex = min(Int(previousFraction * CGFloat(max(pageCount(spineIndex: spineIndex), 1))),
                                             max(pageCount(spineIndex: spineIndex) - 1, 0))
                    anchorKind = "fraction"
                }
                if usesDoublePage { location.pageIndex = (location.pageIndex / 2) * 2 }
                // 重排是阅读中唯一会在用户不操作时移动位置的路径；记录前后页码与定位方式，
                // fraction 表示没找到原文本、按比例落页，最容易产生跳页。
                EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.relayoutPositioned(label: EPUBLayoutLog.label(kind: bookKind), trace: traceID, generation: generation, reason: reason.rawValue, spine: spineIndex, fromPage: anchor.page, fromPages: anchor.pages, toPage: location.pageIndex, toPages: pageCount(spineIndex: spineIndex), anchor: anchorKind, resumed: resumed))
                prefetchNeighbors(of: spineIndex)
                applyDebugJumpIfNeeded()
            }
        } catch {
            if book.generation == generation {
                lastLayoutFailure = EPUBLayoutLog.failure(error)
                // 已取消的重排任务被新任务替代，或阅读器已关闭；只有取消时保留锚点。
                if EPUBLayoutLog.failure(error).kind != "cancelled" {
                    pendingRelayoutAnchor = nil
                    status = .failed(describeLayoutError(error))
                }
            }
        }
    }

    private var didApplyDebugJump = false

    /// 调试：Debug 构建中 `-prototypeJumpSpine <n>` 打开后自动跳到指定 spine（0 起），供自动化目检。
    private func applyDebugJumpIfNeeded() {
        #if DEBUG
        guard !didApplyDebugJump, let container else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-prototypeJumpSpine"),
              index + 1 < arguments.count, let target = Int(arguments[index + 1]),
              container.spine.indices.contains(target) else { return }
        didApplyDebugJump = true
        location.spineIndex = target
        location.pageIndex = 0
        track { [weak self] in
            guard let self else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            guard let book = pageBook, !book.isChapterComplete(target) else { return }
            try? await book.layoutChapter(target, container: container, config: makeConfig(),
                                          aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                          context: layoutContext(.navigate))
        }
        prefetchNeighbors(of: target)
        #endif
    }

    /// 空闲时预排前后相邻章，让跨章拖动时目标页位图已经就位。
    /// 仅预取前后两个相邻章节；取消已移开章节的预取，
    /// 同一章节已有预取任务运行时不重复启动。
    func prefetchNeighbors(of spineIndex: Int) {
        guard let container = source, let book = pageBook else { return }
        let neighbors = [spineIndex + 1, spineIndex - 1].filter { (0..<container.chapterCount).contains($0) }
        for (spine, task) in prefetchTasks where !neighbors.contains(spine) {
            task.cancel()
            prefetchTasks[spine] = nil
        }
        let generationSnapshot = generation
        for neighbor in neighbors {
            guard !book.isChapterComplete(neighbor), prefetchTasks[neighbor] == nil else { continue }
            let config = makeConfig()
            let context = layoutContext(.prefetch)
            prefetchTasks[neighbor] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await book.layoutChapter(neighbor, container: container, config: config,
                                                 aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                                 context: context)
                    failedChapters.remove(neighbor)
                } catch {
                    // 预取结果挂在当前 book 上，代次切换即整体作废
                    let kind = EPUBLayoutLog.failure(error).kind
                    // 章节内容永久缺失或损坏时重试也不会成功，不值得反复弹
                    // 「相邻章节加载失败」；用户真翻到那一章会看到具体错误页。
                    if generationSnapshot == generation,
                       kind != "cancelled",
                       !EPUBLayoutLog.isPermanentContentFailure(kind) {
                        failedChapters.insert(neighbor)
                    }
                }
                if generationSnapshot == generation { prefetchTasks[neighbor] = nil }
            }
        }
    }

    // MARK: 页面查询

    private func pageID(_ spineIndex: Int, _ pageIndex: Int) -> EPUBPageID {
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

    private var scheduledRenders = Set<EPUBPageID>()

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
                                                 readerCSS: style.readerCSS, context: layoutContext(.seek))
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
                for rect in pageBook.selectionRects(for: range, on: pageID(spineIndex, pageIndex + leaf)) {
                    result.append(.init(rect: rect.offsetBy(dx: CGFloat(leaf) * leafWidth, dy: 0),
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
                    UIImage(cgImage: image, scale: displayScale, orientation: .up)
                        .draw(in: CGRect(x: CGFloat(index) * leafWidth, y: 0, width: leafWidth, height: viewportSize.height))
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
        let leaf = usesDoublePage && point.x >= leafWidth ? 1 : 0
        selectionLeaf = leaf
        return pageBook?.selectionRange(at: CGPoint(x: point.x - CGFloat(leaf) * leafWidth, y: point.y),
                                       for: pageID(location.spineIndex, location.pageIndex + leaf))
    }

    func selectionRects(for range: NSRange) -> [CGRect] {
        (0..<(usesDoublePage ? 2 : 1)).flatMap { leaf in
            (pageBook?.selectionRects(for: range, on: pageID(location.spineIndex, location.pageIndex + leaf)) ?? [])
                .map { $0.offsetBy(dx: CGFloat(leaf) * leafWidth, dy: 0) }
        }
    }

    func selectedText(for range: NSRange) -> String? {
        pageBook?.selectedText(for: range, on: pageID(location.spineIndex, location.pageIndex + selectionLeaf))
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
