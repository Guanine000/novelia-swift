import OSLog
import SwiftUI
import UIKit
import Combine
import YueduCoreText
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

extension EPUBReaderModel {
    func turnLocation(forward: Bool) -> EPUBReadingLocation? {
        let count = pageCount(spineIndex: location.spineIndex)
        if forward {
            if location.pageIndex + pageStride < count {
                return .init(spineIndex: location.spineIndex, pageIndex: location.pageIndex + pageStride)
            }
            // 章节最后一页完成分页之前，不离开该章节。
            guard pageBook?.isChapterComplete(location.spineIndex) == true,
                  pageCount(spineIndex: location.spineIndex + 1) > 0 else { return nil }
            return .init(spineIndex: location.spineIndex + 1, pageIndex: 0)
        }
        if location.pageIndex > 0 {
            return .init(spineIndex: location.spineIndex, pageIndex: max(0, location.pageIndex - pageStride))
        }
        let previousCount = pageCount(spineIndex: location.spineIndex - 1)
        guard previousCount > 0, pageBook?.isChapterComplete(location.spineIndex - 1) == true else { return nil }
        return .init(spineIndex: location.spineIndex - 1, pageIndex: ((previousCount - 1) / pageStride) * pageStride)
    }

    // MARK: 翻页

    /// 目标页是否已经排版好（拖动开始的门槛：保证动画只移动已渲染结果）。
    func canTurn(forward: Bool) -> Bool {
        guard !isAnimating, !isLayingOut, status == .ready, pageBook != nil else { return false }
        return turnLocation(forward: forward) != nil
    }

    func commitTurn(forward: Bool) {
        guard canTurn(forward: forward), let target = turnLocation(forward: forward) else { blockedTurn(forward: forward); return }
        moveLocation(to: target, cause: forward ? "turnForward" : "turnBackward")
        prefetchNeighbors(of: location.spineIndex)
    }

    /// 写入位置并标明来源，供 `logLocationChange` 区分用户操作与无人操作的移动。
    func moveLocation(to target: EPUBReadingLocation, cause: String) {
        locationCause = cause
        if cause != "speech" { onManualNavigation?() }
        location = target
        locationCause = nil
    }

    /// 用户点了「标记问题」：记录标记与当前位置，便于在分享日志中找到问题发生的时刻。
    func markIssue() {
        EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.issueMarked(engine: "native"))
        EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.positionChanged(
            label: EPUBLayoutLog.label(kind: bookKind), trace: traceID, generation: generation, cause: "other",
            fromSpine: location.spineIndex, fromPage: location.pageIndex, fromPages: pageCount(spineIndex: location.spineIndex),
            toSpine: location.spineIndex, toPage: location.pageIndex, toPages: pageCount(spineIndex: location.spineIndex)))
    }

    /// 记录重排以外的每次位置变化（包括普通翻页），使分享日志能还原跳页前后的操作顺序。
    /// 重排中的临时归零不记录，其落点由 `relayout` 单独记录。只含序号，不含正文。
    func logLocationChange(from old: EPUBReadingLocation) {
        guard old != location, activeRelayouts == 0, status == .ready else { return }
        EPUBLayoutLog.shareable.notice(ReaderDiagnosticMessage.positionChanged(label: EPUBLayoutLog.label(kind: bookKind), trace: traceID, generation: generation, cause: locationCause ?? "other", fromSpine: old.spineIndex, fromPage: old.pageIndex, fromPages: pageCount(spineIndex: old.spineIndex), toSpine: location.spineIndex, toPage: location.pageIndex, toPages: pageCount(spineIndex: location.spineIndex)))
    }

    // MARK: 目录跳转与字号

    /// 翻页动画期间冻结：字号、代次重排都会被拒绝，避免动画中途切换分页代次。
    func setAnimating(_ animating: Bool) {
        isAnimating = animating
    }

    func jump(to entry: EPUBTOCEntry) {
        rememberReadingPoint()
        guard !isAnimating, !isLayingOut, let spineIndex = entry.spineIndex else { return }
        navigateToSpine(spineIndex)
    }

    /// 书内链接跳转：href 相对当前章节目录解析并映射到 spine；
    /// 同章锚点暂不精确定位（停留原页），跨章跳到目标章首页。
    func openLink(_ href: String) {
        guard !isAnimating, !isLayingOut, let container = source else { return }
        let chapterHref = container.chapterHref(at: location.spineIndex)
        guard let targetSpine = container.spineIndex(forLinkHref: href, relativeTo: chapterHref) else {
            plainLinkMessage = "链接目标不在本书章节列表内（\(href)）"
            return
        }
        guard targetSpine != location.spineIndex else { return }
        navigateToSpine(targetSpine)
    }

    /// 跳到指定章首页；目标章未排版时先排版（增量，首页即现）。
    private func navigateToSpine(_ spineIndex: Int) {
        moveLocation(to: EPUBReadingLocation(spineIndex: spineIndex, pageIndex: 0), cause: "navigate")
        // 新跳转替代尚未完成的旧跳转。
        if let navigateTaskID, let previous = layoutTasks.removeValue(forKey: navigateTaskID) { previous.cancel() }
        navigateTaskID = track { [weak self] in
            guard let self else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            guard let container = source, let book = pageBook, !book.isChapterComplete(spineIndex) else { return }
            do {
                try await book.layoutChapter(spineIndex, container: container, config: makeConfig(),
                                             aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                             context: layoutContext(.navigate))
                if pageBook === book {
                    // 从失败页经目录或书内链接跳到可读章节时恢复阅读状态；
                    // 否则失败页会一直盖住新排好的章节，看起来像「换章也没用」。
                    markReadyAfterRecovery(spineIndex: spineIndex)
                    prefetchNeighbors(of: spineIndex)
                }
            } catch {
                guard pageBook === book, EPUBLayoutLog.failure(error).kind != "cancelled" else { return }
                lastLayoutFailure = EPUBLayoutLog.failure(error)
                status = .failed(describeLayoutError(error))
            }
        }
    }

    /// 目录、书签或链接跳章成功，但状态仍停在失败页时，恢复为可阅读。
    private func markReadyAfterRecovery(spineIndex: Int) {
        guard status != .ready else { return }
        failedChapters.remove(spineIndex)
        status = .ready
        // 失败期间 location 的写入被忽略，这里补一次，让阅读位置照常记录。
        location = EPUBReadingLocation(spineIndex: spineIndex, pageIndex: location.pageIndex)
    }

    // MARK: 书签与书内搜索

    /// 书签与搜索使用的书籍身份：EPUB 为 `epub:<文件哈希>`，本地 TXT 为 `txt:<文件哈希>`；在线小说为 nil。
    var bookmarkKey: String? { webContext?.bookKey ?? openedBookHash.map { "epub:\($0)" } ?? textBookmarkKey }
    var webChapterPaths: [String] { container?.spine.map(\.href) ?? [] }
    var legacyBookmarkKey: String? { webContext == nil ? nil : openedBookHash.map { "epub:\($0)" } }
    var currentBookmarkKey: String? { webChapterID(location.spineIndex) == nil ? (legacyBookmarkKey ?? bookmarkKey) : bookmarkKey }
    func webChapterID(_ index: Int) -> String? { webContext?.chapterID(index: index, paths: webChapterPaths) }
    func bookmarkIndex(_ bookmark: ReaderBookmark) -> Int? {
        if let id = bookmark.chapterID { return webContext?.index(chapterID: id, paths: webChapterPaths) }
        return bookmark.chapterIndex
    }
    var canShowWebNovelEnd: Bool {
        onReachedEnd != nil && status == .ready && !isLayingOut && !isAnimating
            && location.spineIndex == (source?.chapterCount ?? 0) - 1
            && pageBook?.isChapterComplete(location.spineIndex) == true
            && location.pageIndex + pageStride >= pageCount(spineIndex: location.spineIndex)
    }
    func blockedTurn(forward: Bool) {
        guard forward, canShowWebNovelEnd else { return }
        onReachedEnd?()
    }


    // MARK: 字数

    /// 目录显示的字数：EPUB 按 spine 统计并缓存，TXT 由打开方提供；在线小说为 nil，不为字数逐章联网。
    func tocWordCounts() async -> ReaderTOCWordCounts? {
        if let textTOCWordCounts { return await textTOCWordCounts() }
        guard let container, let hash = openedBookHash else { return nil }
        return await BookWordCounter.epubTOCCounts(fileURL: container.fileURL, hash: hash,
                                                   entrySpines: container.toc.map(\.spineIndex))
    }

    /// 当前显示的页（双页时两页）在本章内的比例范围。
    var currentPageRange: (chapter: Int, range: Range<Double>)? {
        guard status == .ready, let book = pageBook, let length = book.sourceLength(spineIndex: location.spineIndex), length > 0,
              let start = book.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex) else { return nil }
        let end = book.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex + pageStride) ?? length
        let lower = min(1, Double(start) / Double(length))
        // 本章最后一页包含比例 1。
        let upper = end >= length ? 1.000_001 : max(lower + 1e-9, Double(end) / Double(length))
        return (location.spineIndex, lower..<upper)
    }

    /// 当前页开头的一段正文，作为书签摘要。
    var currentPageSnippet: String {
        guard let book = pageBook, let text = book.sourceText(spineIndex: location.spineIndex),
              let start = book.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex) else { return "" }
        let utf16 = text.utf16
        guard let from = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
              let index = from.samePosition(in: text) else { return "" }
        return String(text[index...].prefix(ReaderBookmark.maxSnippetLength))
    }

    var chapterCount: Int { source?.chapterCount ?? 0 }

    /// 一章的纯文本（书内搜索与书签摘要使用），换算口径与阅读位置一致。
    // MARK: 朗读

    var speechAnchor: SpeechAnchor {
        let index = location.spineIndex
        let offset = pageBook?.sourceOffset(spineIndex: index, pageIndex: location.pageIndex)
        return SpeechAnchor(chapterIndex: index, progression: currentPageRange?.range.lowerBound ?? 0,
                            chapterUTF16Length: pageBook?.sourceLength(spineIndex: index) ?? 0,
                            startIndexHint: nil, sourceUTF16Offset: offset, startsAtVisibleOffset: true)
    }

    func speechChapterText(_ index: Int) async throws -> String {
        guard let source, let book = pageBook, (0..<source.chapterCount).contains(index) else { throw CancellationError() }
        if !book.isChapterComplete(index) {
            try await book.layoutChapter(index, container: source, config: makeConfig(),
                                         aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                         context: layoutContext(.navigate))
        }
        try Task.checkCancellation()
        guard pageBook === book, let text = book.sourceText(spineIndex: index) else { throw CancellationError() }
        return text
    }

    /// 保存听书进度不驱动页面导航，因此关闭跟读也不会丢失书籍续读位置。
    func recordListeningProgress(_ point: SpeechResumePoint) {
        guard let source, (0..<source.chapterCount).contains(point.chapterIndex),
              let book = pageBook else { return }
        let unit = point.chapterIndex
        guard let length = book.sourceLength(spineIndex: unit), length > 0 else { return }
        let offset = min(max(0, point.sourceUTF16Offset ?? Int(point.progression * Double(length))), length)
        let legacy = book.savedOffset(spineIndex: unit, sourceOffset: offset)
        if let positionHandler {
            guard point.bookKey == textBookmarkKey else { return }
            positionHandler(unit, legacy)
        } else if let hash = openedBookHash, point.bookKey == bookmarkKey {
            let fraction = (Double(unit) + point.progression) / Double(max(1, source.chapterCount))
            if webContext == nil {
                settings.positions.recordEPUB(hash: hash, fraction: fraction, spineIndex: unit, chapterOffset: legacy,
                    chapterProgression: point.progression, nativeChapterOffset: offset, nativeSourceHash: book.sourceHash(spineIndex: unit))
            } else {
                settings.recordEPUBPosition(hash: hash, fraction: fraction, spineIndex: unit, chapterOffset: legacy,
                    chapterProgression: point.progression, context: webContext, paths: webChapterPaths)
            }
        }
    }

    func updateSpeechPosition(_ position: SpeechReadingPosition?, settings: SpeechSettings) {
        speechPosition = position
        speechSettings = settings
        if let position, settings.followsReadingPosition, !isAnimating, !isLayingOut,
           let book = pageBook, book.isChapterComplete(position.chapterIndex),
           let rawPage = book.pageIndex(spineIndex: position.chapterIndex, containingSourceOffset: position.currentOffset) {
            let page = usesDoublePage ? (rawPage / 2) * 2 : rawPage
            let target = EPUBReadingLocation(spineIndex: position.chapterIndex, pageIndex: page)
            if target != location {
                moveLocation(to: target, cause: "speech")
                prefetchNeighbors(of: position.chapterIndex)
            }
        }
        refreshSpeechHighlight()
    }

    /// 用户手动翻页后回到当前朗读句所在页；与自动跟读不同，这里无视「自动翻到朗读位置」开关。
    func jumpToSpeechPosition() {
        guard let position = speechPosition, let book = pageBook,
              book.isChapterComplete(position.chapterIndex),
              let rawPage = book.pageIndex(spineIndex: position.chapterIndex,
                                           containingSourceOffset: position.currentOffset) else { return }
        let page = usesDoublePage ? (rawPage / 2) * 2 : rawPage
        let target = EPUBReadingLocation(spineIndex: position.chapterIndex, pageIndex: page)
        if target != location {
            moveLocation(to: target, cause: "speech")
            prefetchNeighbors(of: position.chapterIndex)
        }
        refreshSpeechHighlight()
    }

    private func refreshSpeechHighlight() {
        let rects: [CGRect]
        if let position = speechPosition, speechSettings.highlightsSpokenText,
           location.spineIndex == position.chapterIndex {
            rects = selectionRects(for: NSRange(location: position.sentenceRange.lowerBound,
                                                length: position.sentenceRange.count))
        } else { rects = [] }
        if rects != speechHighlightRects { speechHighlightRects = rects }
    }

    func chapterPlainText(_ index: Int) async throws -> String {
        guard let source, (0..<source.chapterCount).contains(index) else { throw CancellationError() }
        return BookTextSearch.plainText(html: try await source.chapterHTML(at: index))
    }

    private func rememberReadingPoint() {
        if readingReturnPoint == nil { readingReturnPoint = (location.spineIndex, currentPageRange?.range.lowerBound ?? 0) }
    }
    func returnToReading() {
        guard let point = readingReturnPoint else { return }
        jump(toChapter: point.chapter, progression: point.progression, returning: true)
    }
    func showSearchHit(_ hit: BookTextSearch.Hit) {
        searchHit = hit
        jump(toChapter: hit.chapterIndex, progression: hit.progression, exactOffset: hit.utf16Offset)
    }
    func refreshSearchHighlight() {
        guard let hit = searchHit, hit.chapterIndex == location.spineIndex else { searchHighlightRects = []; return }
        guard let mapping = searchPositionMap, mapping.chapter == hit.chapterIndex,
              mapping.hash == pageBook?.sourceHash(spineIndex: hit.chapterIndex) else { searchHighlightRects = []; return }
        let start = mapping.map.current(hit.utf16Offset)
        let end = mapping.map.current(hit.utf16Offset + hit.match.utf16.count)
        searchHighlightRects = end > start ? selectionRects(for: NSRange(location: start, length: end - start)) : []
    }

    /// 章节标题：取 spine 不晚于该章的最后一个目录项。
    func chapterTitle(_ index: Int) -> String? {
        source?.toc.last { ($0.spineIndex ?? .max) <= index }?.title
    }

    /// 跳到书签或搜索结果：目标章未排版时先排版，再按章内比例找到所在页。属于用户操作，会记录阅读位置。
    func jump(toChapter spineIndex: Int, progression: Double, exactOffset: Int? = nil, returning: Bool = false) {
        guard !isAnimating, !isLayingOut, let container = source, let book = pageBook,
              (0..<container.chapterCount).contains(spineIndex) else { return }
        if !returning { rememberReadingPoint() }
        if let navigateTaskID, let previous = layoutTasks.removeValue(forKey: navigateTaskID) { previous.cancel() }
        navigateTaskID = track { [weak self] in
            guard let self else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            do {
                if !book.isChapterComplete(spineIndex) {
                    try await book.layoutChapter(spineIndex, container: container, config: makeConfig(),
                                                 aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                                 context: layoutContext(.navigate))
                }
                guard pageBook === book else { return }
                var mappedOffset: Int?
                if let exactOffset, let text = book.sourceText(spineIndex: spineIndex) {
                    let plain = BookTextSearch.plainText(html: try await container.chapterHTML(at: spineIndex))
                    let map = await Task.detached(priority: .userInitiated) {
                        EPUBSourcePositionMap(legacy: plain, current: text)
                    }.value
                    guard pageBook === book, !Task.isCancelled else { return }
                    searchPositionMap = (spineIndex, book.sourceHash(spineIndex: spineIndex), map)
                    mappedOffset = map.current(exactOffset)
                }
                let offset = mappedOffset ?? book.sourceLength(spineIndex: spineIndex).map {
                    EPUBChapterProgress.offset(progression: progression, length: $0)
                }
                var page = offset.flatMap { book.pageIndex(spineIndex: spineIndex, containingSourceOffset: $0) } ?? 0
                if usesDoublePage { page = (page / 2) * 2 }
                markReadyAfterRecovery(spineIndex: spineIndex)
                moveLocation(to: EPUBReadingLocation(spineIndex: spineIndex, pageIndex: page), cause: "navigate")
                refreshSearchHighlight()
                if returning { readingReturnPoint = nil; searchHit = nil; searchHighlightRects = [] }
                prefetchNeighbors(of: spineIndex)
            } catch {
                guard pageBook === book, EPUBLayoutLog.failure(error).kind != "cancelled" else { return }
                lastLayoutFailure = EPUBLayoutLog.failure(error)
                status = .failed(describeLayoutError(error))
            }
        }
    }

    /// 跳到图片所在页：目标章未排版完时先排完，找不到图片时落在章首。属于用户操作，会记录阅读位置。
    func jump(toImage entry: EPUBImageEntry) {
        guard let spineIndex = entry.spineIndex, !isAnimating, !isLayingOut,
              let container = source, let book = pageBook,
              (0..<container.chapterCount).contains(spineIndex) else { return }
        if let navigateTaskID, let previous = layoutTasks.removeValue(forKey: navigateTaskID) { previous.cancel() }
        navigateTaskID = track { [weak self] in
            guard let self else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            do {
                if !book.isChapterComplete(spineIndex) {
                    try await book.layoutChapter(spineIndex, container: container, config: makeConfig(),
                                                 aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                                 context: layoutContext(.navigate))
                }
                guard pageBook === book else { return }
                var page = book.pageIndex(spineIndex: spineIndex, containingImagePath: entry.path,
                                          chapterHref: container.chapterHref(at: spineIndex)) ?? 0
                if usesDoublePage { page = (page / 2) * 2 }
                markReadyAfterRecovery(spineIndex: spineIndex)
                moveLocation(to: EPUBReadingLocation(spineIndex: spineIndex, pageIndex: page), cause: "navigate")
                prefetchNeighbors(of: spineIndex)
            } catch {
                guard pageBook === book, EPUBLayoutLog.failure(error).kind != "cancelled" else { return }
                lastLayoutFailure = EPUBLayoutLog.failure(error)
                status = .failed(describeLayoutError(error))
            }
        }
    }

    /// 跳到单元首页（用于生成内容的目录和章节列表）。
    func jump(toUnit unit: Int) {
        guard !isAnimating, !isLayingOut, let source, (0..<source.chapterCount).contains(unit) else { return }
        navigateToSpine(unit)
    }

    func reloadStoredStyle() {
        style = settings.defaults.data(forKey: settings.styleStorageKey).flatMap { try? JSONDecoder().decode(EPUBReaderStyle.self, from: $0) } ?? EPUBReaderStyle()
        style.fontSize = CGFloat(settings.fontSize)
    }
    func reloadBookPreferences() {
        searchHit = nil; searchHighlightRects = []; readingReturnPoint = nil
        annotationHighlights = []
        reloadStoredStyle()
        (source as? EPUBContainer)?.displayProjection = settings.projection
        (source as? TextChapterSource)?.displayProjection = settings.projection
        layoutBookID = (openedBookHash.map { "epub|" + $0 } ?? UUID().uuidString) + "|" + settings.projection.identity
        scheduleRelayout(.styleChange)
    }

    func applyStyle(_ requested: EPUBReaderStyle) {
        guard !isAnimating, !isLayingOut else { return }
        var updated = requested
        updated.fontSize = min(36, max(12, requested.fontSize))
        updated.lineSpacing = min(24, max(0, requested.lineSpacing))
        updated.paragraphSpacing = min(40, max(0, requested.paragraphSpacing))
        if let indent = requested.firstLineIndentEm {
            updated.firstLineIndentEm = min(4, max(0, indent))
        }
        updated.topMargin = min(120, max(0, requested.topMargin))
        updated.bottomMargin = min(120, max(0, requested.bottomMargin))
        updated.leftMargin = min(80, max(0, requested.leftMargin))
        updated.rightMargin = min(80, max(0, requested.rightMargin))
        guard updated != style else { return }
        let fontChanged = updated.fontSize != style.fontSize
        style = updated
        if let data = try? JSONEncoder().encode(updated) {
            settings.defaults.set(data, forKey: settings.styleStorageKey)
        }
        settings.fontSize = Double(updated.fontSize)
        scheduleRelayout(fontChanged ? .fontChange : .styleChange)
    }
}

// MARK: - 注脚弹窗模型

/// 把 YueduCoreText 的排版错误翻译成可诊断的中文信息（真实 EPUB 排查必需）。
func describeLayoutError(_ error: Error) -> String {
    if let layoutError = error as? HTMLLayoutError {
        switch layoutError {
        case .unsupported(let features):
            let names = features.map(\.description).joined(separator: "、")
            return "本章包含当前排版引擎不支持的内容（\(names)），需要回退策略后才能显示。"
        case .resourceFailure(let detail):
            return "章节资源缺失：\(detail)。已尝试精确路径、百分号解码与大小写回退查找。"
        case .layoutFailure(let detail):
            return "排版失败：\(detail)"
        case .cancelled:
            return "排版已取消。"
        }
    }
    if let prototypeError = error as? EPUBError {
        return prototypeError.localizedDescription
    }
    return error.localizedDescription
}
