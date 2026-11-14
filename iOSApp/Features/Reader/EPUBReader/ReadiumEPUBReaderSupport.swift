import Combine
import OSLog
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit
import WebKit

extension ReadiumEPUBReaderModel {
    // MARK: 书签与书内搜索

    /// 书签与搜索使用的书籍身份：EPUB 为 `epub:<文件哈希>`，本地 TXT 为 `txt:<文件哈希>`；在线小说为 nil。
    var bookmarkKey: String? { webContext?.bookKey ?? bookHash.map { "epub:\($0)" } ?? textBook?.bookmarkKey }
    var webChapterPaths: [String] {
        publication?.readingOrder.map { link in
            let path = EPUBContainer.normalizePath(EPUBContainer.stripFragment(link.href.removingPercentEncoding ?? link.href))
            return imageContainer?.spine.first(where: { $0.href == path || $0.href.hasSuffix("/" + path) || path.hasSuffix("/" + $0.href) })?.href ?? path
        } ?? []
    }
    var legacyBookmarkKey: String? { webContext == nil ? nil : bookHash.map { "epub:\($0)" } }
    var currentBookmarkKey: String? { currentPageRange.flatMap { webChapterID($0.chapter) } == nil ? (legacyBookmarkKey ?? bookmarkKey) : bookmarkKey }
    func webChapterID(_ index: Int) -> String? { webContext?.chapterID(index: index, paths: webChapterPaths) }
    func bookmarkIndex(_ bookmark: ReaderBookmark) -> Int? {
        if let id = bookmark.chapterID { return webContext?.index(chapterID: id, paths: webChapterPaths) }
        return bookmark.chapterIndex
    }
    var isAtWebNovelEnd: Bool {
        guard onReachedEnd != nil, status == .ready,
              let locator, navigationIndex?.resourceIndex(for: locator.href) == chapterCount - 1,
              let page = chapterPageSelection().page else { return false }
        let scroll = page.scrollView
        return !page.isLoading && !scroll.isDecelerating && scroll.bounds.width > 0
            && scroll.contentSize.width >= scroll.bounds.width - 1
            && scroll.contentOffset.x.isFinite && scroll.contentSize.width.isFinite
            && scroll.contentOffset.x + scroll.bounds.width >= scroll.contentSize.width - 1
    }


    var localRecapSource: LocalRecapSource? {
        guard status == .ready, let publication, publication.readingOrder.indices.contains(readingTimePoint.resource) else { return nil }
        if let book = textBook?.localRecapBook, let source = textBook?.source as? TextChapterSource {
            return .txt(book, title: source.bookTitle, chapter: source.tocEntry(containingUnit: readingTimePoint.resource) ?? 0, projection: settings.projection)
        }
        guard let container = imageContainer, let hash = bookHash else { return nil }
        let href = publication.readingOrder[readingTimePoint.resource].href
        let path = EPUBContainer.normalizePath(EPUBContainer.stripFragment(href.removingPercentEncoding ?? href))
        let candidates = container.spine.indices.filter {
            container.spine[$0].href == path || container.spine[$0].href.hasSuffix("/" + path) || path.hasSuffix("/" + container.spine[$0].href)
        }
        guard candidates.count == 1 else { return nil }
        return .epub(container, hash: hash, currentSpine: candidates[0], projection: settings.projection)
    }
    var localTimeSource: LocalReadingTimeSource? {
        guard status == .ready else { return nil }
        let projection = settings.projection
        if let textBook, let metrics = textBook.localTimeMetrics,
           textBook.bookmarkKey?.hasPrefix("txt:") == true {
            return .init(id: (textBook.readiumIdentity ?? textBook.bookmarkKey!) + "|" + projection.identity,
                         load: { try await metrics(projection) })
        }
        guard let publication, let container = imageContainer, let hash = bookHash else { return nil }
        var spines = [Int](), starts = [Int](), previousGroup: Int?
        for (index, link) in publication.readingOrder.enumerated() {
            let path = EPUBContainer.normalizePath(EPUBContainer.stripFragment(link.href.removingPercentEncoding ?? link.href))
            let candidates = container.spine.indices.filter {
                container.spine[$0].href == path || container.spine[$0].href.hasSuffix("/" + path) || path.hasSuffix("/" + container.spine[$0].href)
            }
            // 无法唯一映射至本地 ZIP 资源就不估计，不通过 Publication 请求外部资源。
            guard candidates.count == 1 else { return nil }
            spines.append(candidates[0])
            let group = navigationIndex?.tocIndex(for: link.url())
            if index == 0 || group == nil || group != previousGroup { starts.append(index) }
            previousGroup = group
        }
        return .epub(url: container.fileURL, hash: hash, spines: spines, starts: starts, projection: projection)
    }

    var chapterCount: Int { publication?.readingOrder.count ?? 0 }

    /// 当前页在本章内的比例范围。Readium 不提供页尾位置，按该章位置数（约每 1024 字一个）估计页宽。
    var currentPageRange: (chapter: Int, range: Range<Double>)? {
        guard let locator, let index = navigationIndex?.resourceIndex(for: locator.href) else { return nil }
        let lower = min(1, max(0, locator.locations.progression ?? 0))
        let width = 1 / Double(max(positionsPerResource[index] ?? 1, 1))
        return (index, lower..<min(1.000_001, lower + width))
    }

    /// 当前页开头附近的正文，作为书签摘要。Readium 没有页内文本接口：按章内比例从章节纯文本中截取，
    /// 读取失败时退回 Locator 自带的文本片段。
    func currentPageSnippet() async -> String {
        if let range = currentPageRange, let text = try? await chapterPlainText(range.chapter), !text.isEmpty {
            let utf16 = text.utf16
            let offset = EPUBChapterProgress.offset(progression: range.range.lowerBound, length: utf16.count)
            if let from = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
               let start = from.samePosition(in: text) {
                return String(text[start...].prefix(ReaderBookmark.maxSnippetLength))
            }
        }
        return String((locator?.text.highlight ?? locator?.text.after ?? "").prefix(ReaderBookmark.maxSnippetLength))
    }

    /// 目录显示的字数：EPUB 按原生容器的 spine 统计并缓存（目录项按文件路径换算 spine 序号），
    /// TXT 由打开方提供；在线小说为 nil。
    func tocWordCounts() async -> ReaderTOCWordCounts? {
        if let textBook { return await textBook.tocWordCounts?() }
        guard let container = imageContainer, let hash = bookHash else { return nil }
        let spines = toc.map { item -> Int? in
            let string = item.link.url().string
            let path = EPUBContainer.stripFragment(string.removingPercentEncoding ?? string)
            return container.spine.firstIndex { EPUBContainer.normalizePath(path) == $0.href || path.hasSuffix("/" + $0.href) }
        }
        return await BookWordCounter.epubTOCCounts(fileURL: container.fileURL, hash: hash, entrySpines: spines)
    }

    /// 图片列表记录的是原生容器的 spine 序号；Readium 的 readingOrder 可能不含非线性条目，按文件路径换算。
    private func readingOrderIndex(forSpine spine: Int) -> Int? {
        guard let container = imageContainer, let publication, container.spine.indices.contains(spine) else { return nil }
        let href = container.spine[spine].href
        return publication.readingOrder.firstIndex { link in
            let string = link.url().string
            let path = string.removingPercentEncoding ?? string
            return EPUBContainer.normalizePath(path) == href || path.hasSuffix("/" + href)
        }
    }

    /// 图片所在章节的标题（spine 序号）。
    func imageChapterTitle(_ spine: Int) -> String? {
        readingOrderIndex(forSpine: spine).flatMap(chapterTitle)
    }

    /// 跳到图片所在页：先打开所在章节，再在页面中找到该图片并用 Readium 的定位脚本翻到它所在的页；
    /// 章节内容可能尚未就绪，找不到时稍后重试，仍找不到则停在章首。
    func jump(toImage entry: EPUBImageEntry) {
        if afterCurlRestores({ [weak self] in self?.jump(toImage: entry) }) { return }
        guard let spine = entry.spineIndex, let index = readingOrderIndex(forSpine: spine),
              let publication else { return }
        markNavigation("navigate")
        Task { [weak self] in
            guard let base = await publication.locate(publication.readingOrder[index]) else { return }
            _ = await self?.navigator?.go(to: base.copy(locations: { $0.progression = 0 }))
            for _ in 0..<10 {
                guard let self else { return }
                if await scrollToImage(path: entry.path) { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// 在当前章节页面中查找包内路径为 `path` 的图片，并翻到它所在的页；找到返回 true。
    private func scrollToImage(path: String) async -> Bool {
        guard let navigator, let pathLiteral = Self.javaScriptStringLiteral(path) else { return false }
        let script = """
        (function(path) {
          path = path.toLowerCase();
          var elements = document.querySelectorAll('img, image');
          for (var i = 0; i < elements.length; i++) {
            var el = elements[i];
            var src = el.tagName.toLowerCase() === 'img'
              ? (el.currentSrc || el.src)
              : (el.getAttribute('xlink:href') || el.getAttributeNS('http://www.w3.org/1999/xlink', 'href') || el.getAttribute('href') || '');
            var resolved;
            try { resolved = decodeURIComponent(new URL(src, document.baseURI).pathname).toLowerCase(); } catch (e) { continue; }
            if (resolved === '/' + path || resolved.endsWith('/' + path)) {
              el.setAttribute('data-novelia-image-target', '1');
              var done = readium.scrollToLocator({ href: '#', locations: { cssSelector: '[data-novelia-image-target="1"]' } }, false);
              el.removeAttribute('data-novelia-image-target');
              return done === true;
            }
          }
          return false;
        })(\(pathLiteral))
        """
        if case .success(let value) = await navigator.evaluateJavaScript(script) { return (value as? Bool) == true }
        return false
    }

    /// 把字符串编码为 JavaScript 字符串字面量（经 JSON 转义）。
    private static func javaScriptStringLiteral(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let array = String(data: data, encoding: .utf8) else { return nil }
        return String(array.dropFirst().dropLast())
    }

    func chapterTitle(_ index: Int) -> String? {
        guard let publication, publication.readingOrder.indices.contains(index) else { return nil }
        return navigationIndex?.tocIndex(for: publication.readingOrder[index].url()).map { toc[$0].title }
            ?? publication.readingOrder[index].title
    }

    /// 一章的纯文本：TXT 取生成的章节，EPUB 读取资源 HTML。
    func chapterPlainText(_ index: Int) async throws -> String {
        if let source = textBook?.source { return BookTextSearch.plainText(html: try await source.chapterHTML(at: index)) }
        guard let publication, publication.readingOrder.indices.contains(index),
              let resource = publication.get(publication.readingOrder[index]),
              case .success(let html) = await resource.read().asString() else { throw CancellationError() }
        return BookTextSearch.plainText(html: html)
    }

    func rememberReadingPoint() { if readingReturnPoint == nil { readingReturnPoint = locator } }
    func returnToReading() {
        if afterCurlRestores({ [weak self] in self?.returnToReading() }) { return }
        guard let point = readingReturnPoint, let navigator else { return }
        markNavigation("navigate")
        Task { if await navigator.go(to: point) { readingReturnPoint = nil; navigator.apply(decorations: [], in: "book-search") } }
    }
    func showSearchHit(_ hit: BookTextSearch.Hit) {
        if afterCurlRestores({ [weak self] in self?.showSearchHit(hit) }) { return }
        guard let publication, let navigator, publication.readingOrder.indices.contains(hit.chapterIndex) else { return }
        rememberReadingPoint(); markNavigation("navigate")
        Task {
            guard let text = try? await chapterPlainText(hit.chapterIndex),
                  let base = await publication.locate(publication.readingOrder[hit.chapterIndex]) else { return }
            let source = text as NSString, length = hit.match.utf16.count
            guard hit.utf16Offset >= 0, hit.utf16Offset + length <= source.length,
                  source.substring(with: NSRange(location: hit.utf16Offset, length: length)) == hit.match else { return }
            let start = max(0, hit.utf16Offset - 80), end = min(source.length, hit.utf16Offset + length + 80)
            let target = base.copy(locations: { $0.progression = hit.progression }, text: {
                $0.before = source.substring(with: NSRange(location: start, length: hit.utf16Offset - start))
                $0.highlight = hit.match
                $0.after = source.substring(with: NSRange(location: hit.utf16Offset + length, length: end - hit.utf16Offset - length))
            })
            if await navigator.go(to: target) {
                navigator.apply(decorations: [Decoration(id: "search-hit", locator: target, style: .init(id: "novelia-search"))], in: "book-search")
            }
        }
    }

    // MARK: 标注

    /// 选中引文在章纯文本中的 UTF-16 范围。
    /// WebKit 跨段落选择会在块之间带换行，而纯文本提取直接拼接标签；先精确匹配，失败时忽略空白再匹配。
    private static func annotationRange(quote: String, in text: String, near progression: Double) -> NSRange? {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let start = SpeechText.selectedOffset(needle, in: text, near: progression) {
            return NSRange(location: start, length: (needle as NSString).length)
        }
        let compact = needle.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }

        var scalars: [Unicode.Scalar] = []
        var offsets: [Int] = []
        /// 去空白字符串的 UTF-16 位置 → 标量下标，兼顾 BMP 以外的字符。
        var unitToScalar: [Int: Int] = [:]
        var utf16Offset = 0
        for scalar in text.unicodeScalars {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                for unit in 0..<scalar.utf16.count {
                    unitToScalar[utf16Offset + unit] = scalars.count
                }
                scalars.append(scalar)
                offsets.append(utf16Offset)
            }
            utf16Offset += scalar.utf16.count
        }
        let stripped = String(String.UnicodeScalarView(scalars)) as NSString
        let target = compact as NSString
        guard stripped.length > 0 else { return nil }
        var candidates: [(location: Int, distance: Double)] = []
        var cursor = 0
        while cursor < stripped.length {
            let found = stripped.range(of: target as String,
                                       options: [], range: NSRange(location: cursor, length: stripped.length - cursor))
            guard found.location != NSNotFound else { break }
            candidates.append((found.location, abs(Double(found.location)
                - progression * Double(stripped.length))))
            cursor = NSMaxRange(found)
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }),
              let startIndex = unitToScalar[best.location] else { return nil }
        let endUTF16 = best.location + target.length
        let end = unitToScalar[endUTF16].map { offsets[$0] } ?? utf16Offset
        let start = offsets[startIndex]
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// 保存当前选中文字。位置以章内纯文本 UTF-16 偏移与引文持久化，渲染时按引文重新定位。
    func addAnnotation(selection: Selection, color: ReaderAnnotation.Color = .yellow,
                       note: String = "", editAfter: Bool = false) {
        guard let bookKey = bookmarkKey, let publication else { return }
        let selected = selection.locator
        let index = navigationIndex?.resourceIndex(for: selected.href) ?? currentPageRange?.chapter ?? 0
        let quote = (selected.text.highlight ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, publication.readingOrder.indices.contains(index) else { return }
        let progression = selected.locations.progression ?? 0
        let href = selected.href.string
        navigator?.clearSelection()
        Task { [weak self] in
            guard let self else { return }
            guard let text = try? await self.chapterPlainText(index),
                  let range = Self.annotationRange(quote: quote, in: text, near: progression) else {
                self.annotationError = "无法定位所选文字，请重新选择。"
                return
            }
            do {
                let annotation = try self.settings.annotations.add(
                    bookKey: bookKey, chapterIndex: index, chapterID: self.webChapterID(index),
                    resourceHref: href, progression: Double(range.location) / Double(max(1, text.utf16.count)),
                    range: range, quote: (text as NSString).substring(with: range), chapterText: text,
                    projectionIdentity: self.settings.projection.identity, color: color, note: note)
                self.refreshAnnotationDecorations(force: true)
                if editAfter { self.activeAnnotation = annotation }
            } catch {
                self.annotationError = error.localizedDescription
            }
        }
    }

    func updateAnnotation(_ annotation: ReaderAnnotation, color: ReaderAnnotation.Color, note: String) {
        do {
            try settings.annotations.update(annotation.id, color: color, note: note)
            refreshAnnotationDecorations(force: true)
        } catch {
            annotationError = error.localizedDescription
        }
    }

    func deleteAnnotation(_ annotation: ReaderAnnotation) {
        do {
            try settings.annotations.remove(annotation.id)
            refreshAnnotationDecorations(force: true)
        } catch {
            annotationError = error.localizedDescription
        }
    }

    /// 跳到标注所在章节与位置；引文能解析时同时带上前后文，让 Readium 精确对齐。
    func jump(to annotation: ReaderAnnotation) {
        if afterCurlRestores({ [weak self] in self?.jump(to: annotation) }) { return }
        guard let publication, publication.readingOrder.indices.contains(annotation.chapterIndex) else { return }
        rememberReadingPoint()
        markNavigation("navigate")
        Task { [weak self] in
            guard let self else { return }
            guard let text = try? await self.chapterPlainText(annotation.chapterIndex),
                  let base = await publication.locate(publication.readingOrder[annotation.chapterIndex]) else { return }
            let source = text as NSString
            let before: String, highlight: String, after: String
            if let range = ReaderAnnotationResolver.resolve(annotation, in: text),
               NSMaxRange(range) <= source.length {
                let start = max(0, range.location - 80)
                let end = min(source.length, NSMaxRange(range) + 80)
                before = source.substring(with: NSRange(location: start, length: range.location - start))
                highlight = source.substring(with: range)
                after = source.substring(with: NSRange(location: NSMaxRange(range),
                                                       length: end - NSMaxRange(range)))
            } else {
                before = ""; highlight = annotation.quote; after = ""
            }
            let target = base.copy(locations: { $0.progression = annotation.progression }, text: {
                $0.before = before
                $0.highlight = highlight
                $0.after = after
            })
            _ = await self.navigator?.go(to: target)
        }
    }

    /// 当前章的标注装饰。主阅读器与卷页预取导航器共用，保证快照里也带高亮。
    func annotationDecorations(chapter index: Int) async -> [Decoration] {
        guard let bookKey = bookmarkKey, let publication, publication.readingOrder.indices.contains(index) else { return [] }
        let annotations = settings.annotations.annotations(for: bookKey, chapter: index)
        guard !annotations.isEmpty,
              let text = try? await chapterPlainText(index),
              let base = await publication.locate(publication.readingOrder[index]) else { return [] }
        let source = text as NSString
        return annotations.compactMap { annotation -> Decoration? in
            guard let range = ReaderAnnotationResolver.resolve(annotation, in: text),
                  NSMaxRange(range) <= source.length else { return nil }
            let start = max(0, range.location - 80)
            let end = min(source.length, NSMaxRange(range) + 80)
            let target = base.copy(locations: { $0.progression = annotation.progression }, text: {
                $0.before = source.substring(with: NSRange(location: start, length: range.location - start))
                $0.highlight = source.substring(with: range)
                $0.after = source.substring(with: NSRange(location: NSMaxRange(range),
                                                          length: end - NSMaxRange(range)))
            })
            return Decoration(id: annotation.id.uuidString, locator: target,
                              style: .highlight(tint: annotation.color.uiColor))
        }
    }

    func observeAnnotationInteractions(in group: String, of navigator: EPUBNavigatorViewController) {
        navigator.observeDecorationInteractions(inGroup: group) { [weak self] event in
            guard let self, let id = UUID(uuidString: event.decoration.id) else { return }
            self.lastAnnotationDecorationTap = Date()
            self.activeAnnotation = self.settings.annotations.annotation(id: id)
        }
    }

    /// 只在当前章节套用高亮；换章或标注变化时重算。章节定位不到时清空，避免旧高亮留在新页面。
    func refreshAnnotationDecorations(force: Bool = false) {
        guard let navigator, let bookKey = bookmarkKey, let publication, let locator,
              let index = navigationIndex?.resourceIndex(for: locator.href),
              publication.readingOrder.indices.contains(index) else {
            annotationDecorationChapter = nil
            navigator?.apply(decorations: [], in: annotationDecorationGroup)
#if DEBUG
            appliedAnnotationDecorationCount = 0
#endif
            return
        }
        if !force, annotationDecorationChapter == index { return }
        annotationDecorationChapter = index
        let generation = UUID()
        annotationRefreshGeneration = generation
        guard !settings.annotations.annotations(for: bookKey, chapter: index).isEmpty else {
            cachedAnnotationDecorations = nil
            navigator.apply(decorations: [], in: annotationDecorationGroup)
#if DEBUG
            appliedAnnotationDecorationCount = 0
#endif
            return
        }
        Task { [weak self, weak navigator] in
            guard let self, let navigator else { return }
            let decorations = await self.annotationDecorations(chapter: index)
            guard self.annotationRefreshGeneration == generation, self.navigator === navigator else { return }
            self.cachedAnnotationDecorations = (index, decorations)

            // Readium 只注入与同组旧状态有差异的装饰；重开书时首次注入可能早于正文装载而被丢弃。
            // 每次换一个新组名可强制重新注入，再清空旧组，避免重复高亮。
            let group = "user-annotations-\(generation.uuidString)"
            let previous = self.annotationDecorationGroup
            self.annotationDecorationGroup = group
            self.observeAnnotationInteractions(in: group, of: navigator)
            navigator.apply(decorations: decorations, in: group)
            if previous != group { navigator.apply(decorations: [], in: previous) }
#if DEBUG
            self.appliedAnnotationDecorationCount = decorations.count
#endif
        }
    }

    func jump(toChapter index: Int, progression: Double) {
        if afterCurlRestores({ [weak self] in self?.jump(toChapter: index, progression: progression) }) { return }
        rememberReadingPoint()
        guard let publication, publication.readingOrder.indices.contains(index) else { return }
        markNavigation("navigate")
        Task {
            guard let base = await publication.locate(publication.readingOrder[index]) else { return }
            _ = await navigator?.go(to: base.copy(locations: { $0.progression = min(1, max(0, progression)) }))
        }
    }

    func seek(to progression: Double) {
        if afterCurlRestores({ [weak self] in self?.seek(to: progression) }) { return }
        guard let publication else { return }
        markNavigation("seek")
        Task {
            if let target = await publication.locate(progression: min(max(progression, 0), 1)) {
                _ = await navigator?.go(to: target)
            }
        }
    }

    var overallProgress: Double { locator?.locations.totalProgression ?? 0 }

    var locationDescription: String {
        // 生成书籍的位置列表按单元提供，不把它冒充为实际分页数。
        if textBook != nil { return "\(Int((overallProgress * 100).rounded()))%" }
        guard let position = locator?.locations.position, positionCount > 0 else {
            return "\(Int((overallProgress * 100).rounded()))%"
        }
        return "\(position) / \(positionCount)"
    }

    /// 当前章内进度（Locator progression），供底栏切换「本章进度」。
    var chapterProgressDescription: String {
        guard let progression = locator?.locations.progression else { return "本章 —" }
        return "本章 \(Int((progression * 100).rounded()))%"
    }

    /// 全书进度百分比，供底栏切换「全书进度」。
    var bookProgressDescription: String {
        "全书 \(Int((overallProgress * 100).rounded()))%"
    }

    var currentChapterTitle: String {
        if let index = currentTOCIndex, toc.indices.contains(index) { return toc[index].title }
        return locator?.title ?? bookTitle
    }

    // MARK: 进度

    var locatorKey: String? { bookHash.map(ReadiumLocatorKeys.bookLocator(hash:)) }
    var locatorTimeKey: String? { bookHash.map(ReadiumLocatorKeys.bookTime(hash:)) }

    func save(_ locator: Locator) {
        guard let hash = bookHash,
              let key = locatorKey, let timeKey = locatorTimeKey,
              let json = try? locator.jsonString() else { return }
        guard webContext == nil || pendingWebPositionWrite else { return }
        pendingWebPositionWrite = false
        UserDefaults.standard.set(json, forKey: key)
        UserDefaults.standard.set(Date(), forKey: timeKey)
        let spine = navigationIndex?.resourceIndex(for: locator.href) ?? 0
        settings.recordEPUBPosition(
            hash: hash, fraction: locator.locations.totalProgression ?? 0,
            spineIndex: spine, chapterOffset: nil, chapterProgression: locator.locations.progression, context: webContext, paths: webChapterPaths)
    }

    /// 本机 Locator 优先；若 WebDAV 合并来的位置更新（例如来自旧引擎或其他设备），改按其恢复。
    func savedLocator(publication: Publication, hash: String) async -> Locator? {
        let defaults = UserDefaults.standard
        let synced = settings.epubPosition(hash: hash, context: webContext, paths: webChapterPaths)
        if !settings.missingWebEPUBChapter(context: webContext, paths: webChapterPaths), let key = locatorKey, let json = defaults.string(forKey: key),
           let value = try? JSONValue(jsonString: json),
           let saved = try? Locator(json: value, warnings: nil) {
            let savedAt = locatorTimeKey.flatMap { defaults.object(forKey: $0) as? Date } ?? .distantPast
            if synced.map({ $0.updatedAt <= savedAt.addingTimeInterval(1) }) ?? true {
                return saved
            }
        }
        guard let synced else { return nil }
        // 同一章内的比例：两个引擎都会写 chapterProgression；只有旧引擎的 UTF-16 偏移时，
        // 按去掉标签后的正文长度换算（偏移量度的是排版文本，不含 HTML 标签）。
        if let chapter = synced.chapterIndex, publication.readingOrder.indices.contains(chapter) {
            let link = publication.readingOrder[chapter]
            var progression = synced.chapterProgression
            if progression == nil, let offset = synced.chapterOffset,
               let resource = publication.get(link),
               case .success(let html) = await resource.read().asString() {
                progression = EPUBChapterProgress.progression(offset: offset, length: EPUBChapterProgress.textLength(html: html))
            }
            if let progression, let base = await publication.locate(link) {
                return base.copy(locations: { $0.progression = progression })
            }
            // 两者都没有时（例如 0.12.0（54）保存的位置），下方全书比例比章节开头更接近原位置。
            if (synced.fraction ?? 0) <= 0, let base = await publication.locate(link) {
                return base
            }
        }
        if let fraction = synced.fraction, fraction > 0 {
            return await publication.locate(progression: fraction)
        }
        return nil
    }

    // MARK: 错误

    enum ReadiumOpenError: LocalizedError {
        case invalidURL
        case asset(String)
        case parse(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "文件路径无效。"
            case .asset(let detail): "无法读取 EPUB 文件：\(detail)"
            case .parse(let detail): "无法解析 EPUB：\(detail)"
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - 导航器回调

extension ReadiumEPUBReaderModel: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard (navigator as AnyObject) === self.navigator else { return }
        if viewportRestoration != nil {
            makeWebViewsTransparent()
            reapplyPageBackgrounds()
            return
        }
        if let preview = curlPreview, preview.snapshot === preview.navigator, !preview.committing {
            makeWebViewsTransparent()
            reapplyPageBackgrounds()
            return
        }
        let previous = self.locator
        logLocationChange(from: previous, to: locator)
        let current = navigationIndex?.tocIndex(for: locator.href)
        if currentTOCIndex != current { currentTOCIndex = current }
        self.locator = locator
        if let chapter = navigationIndex?.resourceIndex(for: locator.href), chapter != annotationDecorationChapter {
            refreshAnnotationDecorations()
        }
        if textBook != nil {
            if previous != locator { saveTextPosition(locator) }
        } else if !receivedBookLocation {
            // 打开或恢复时不写入：同步前打开书若写入当前时间，会让本机旧进度盖过其他设备较新的进度。
            receivedBookLocation = true
        } else if previous != locator {
            save(locator)
        }
        makeWebViewsTransparent()
        // 旋转会改变横竖屏背景图片的取用，位置回报时顺带重新套用规则。
        reapplyPageBackgrounds()
#if DEBUG
        refreshPaginationValidation()
#endif
    }

    /// 上下边距从安全区边缘起算，与 YueduCoreText 阅读器一致，章节名与正文不再重叠。
    /// Readium 默认取安全区与配置边距的较大值，会让正文顶到章节名所在位置。
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        let safeArea = (navigator as? UIViewController)?.view.window?.safeAreaInsets ?? .zero
        return UIEdgeInsets(top: safeArea.top + style.topMargin, left: 0,
                            bottom: safeArea.bottom + style.bottomMargin, right: 0)
    }

    /// Readium 每次应用设置都会把根视图涂成背景色；清空以露出宿主绘制的阅读背景。
    func navigator(_ navigator: VisualNavigator, presentationDidChange presentation: VisualNavigatorPresentation) {
        guard (navigator as AnyObject) === self.navigator else { return }
        readingTimePoint.reason = .reset
        (navigator as? UIViewController)?.view.backgroundColor = .clear
        // 重开书时首次位置回报可能早于 WebView 完成排版，装饰会被随后加载的页面覆盖；排版变化后重套一次。
        refreshAnnotationDecorations(force: true)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        Self.logger.error("Readium navigator error: \(String(describing: error), privacy: .public)")
    }

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        guard (navigator as AnyObject) === self.navigator else { return }
        if textBook != nil {
            failedTextHref = href
            textLoadFailure = "章节加载失败：\(String(describing: error))"
        } else if status == .ready,
                  publication?.readingOrder.contains(where: { $0.url().string.hasSuffix(href.string) }) == true {
            // 预检之后仍可能遇到读取失败，不能让导航器停在加载态：
            // 转成失败页，提供重新打开／复制错误说明／关闭阅读器。
            status = .failed("章节加载失败：\(href.string)。\(Self.diagnosticReason(error))")
        }
        Self.logger.error("Readium failed to load \(href.string, privacy: .private): \(String(describing: error), privacy: .public)")
        let resource = publication?.readingOrder.firstIndex { $0.url().string.hasSuffix(href.string) } ?? -1
        Self.shareable.error(ReaderDiagnosticMessage.readiumResourceLoadFailed(resource: resource))
    }

    /// 注脚不跳转，改为底部弹层显示纯文本。
    func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: ReadiumShared.Link, content: String, referrer: String?) -> Bool {
        let text = Self.plainText(fromHTML: content)
        activeNote = EPUBNote(text: text.isEmpty ? "（注释内容为空）" : text)
        return false
    }

    /// 未标 `epub:type="noteref"` 的注释链接（多看、Sigil 注释插件等）：目标是注释正文时
    /// 同样以弹层显示；不是注释或读取失败时照常跳转。读取目标需要异步，因此先拦下再决定。
    func navigator(_ navigator: VisualNavigator, shouldNavigateToLink link: ReadiumShared.Link) -> Bool {
        guard textBook == nil, let publication,
              let url = AnyURL(string: link.href), let id = url.fragment, !id.isEmpty else { return true }
        Task { [weak self] in
            let html = try? await publication.get(url.removingFragment())?.read().asString().get()
            guard let self else { return }
            if let html, let note = EPUBFootnoteTarget.noteHTML(id: id, inDocument: html) {
                let text = Self.plainText(fromHTML: note)
                if !text.isEmpty {
                    activeNote = EPUBNote(text: text)
                    return
                }
            }
            _ = await self.navigator?.go(to: link)
        }
        return false
    }

    /// 新章节的 WebView 创建时触发（此时已开始加载，注入的脚本不保证作用于当页，
    /// 所以根背景透明改由 RS__backgroundColor 在 HTML 注入阶段完成，见 makeNavigator）。
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        guard navigator === self.navigator else { return }
        // 此回调在新章节的 WebView 创建时触发；待其加入视图层级后再设为透明。
        createdWebViews += 1
        Self.shareable.notice(ReaderDiagnosticMessage.readiumWebViewCreated(count: createdWebViews))
        DispatchQueue.main.async { [weak self] in self?.makeWebViewsTransparent() }
    }

    /// WebView 加载完成后读取 html（ReadiumCSS 已设透明）或 body 的计算底色。
    /// 相邻章节预加载时就已读好，翻页滑入时边距颜色与书页同步出现。
    private func observePageBackground(of webView: WKWebView) {
        guard pageLoadObservations.object(forKey: webView) == nil else { return }
        let observation = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self, !webView.isLoading, webView.url != nil else { return }
                self.readPageBackground(of: webView)
                // 章节 WebView 装载完成后再套标注；重开书时首次 apply 往往早于正文装载。
                self.refreshAnnotationDecorations(force: true)
            }
        }
        pageLoadObservations.setObject(observation, forKey: webView)
    }

    func readPageBackground(of webView: WKWebView) {
        let rule = ReaderBookBackgroundFollow(storedValue: UserDefaults.standard.string(forKey: SettingsKey.readerBookBackgroundFollow))
        let revision = navigatorRevision
        let script = EPUBReadiumPageBackground.script(
            ignoresNearWhite: rule == .ignoreNearWhite, threshold: ReaderBookBackgroundFollow.nearWhiteThreshold)
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            guard let self, let webView, self.navigatorRevision == revision,
                  rule == ReaderBookBackgroundFollow(storedValue: UserDefaults.standard.string(forKey: SettingsKey.readerBookBackgroundFollow)) else { return }
            let color = (result as? String).flatMap(Self.opaqueColor(fromCSS:))
            if let color { self.pageBackgrounds.setObject(color, forKey: webView) } else { self.pageBackgrounds.removeObject(forKey: webView) }
            self.applyPageBackground(to: webView)
        }
    }

    /// 按“书页底色铺满四周”规则给章节视图上色；不跟随时保持透明，露出宿主阅读背景。
    private func applyPageBackground(to webView: WKWebView) {
        guard let spreadView = webView.superview else { return }
        var followed: UIColor?
        if let color = pageBackgrounds.object(forKey: webView) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let bounds = navigator?.view.bounds ?? spreadView.bounds
            let hasImage = settings.backgrounds.image(dark: isDarkMode, landscape: bounds.width > bounds.height) != nil
            let rule = ReaderBookBackgroundFollow(storedValue: UserDefaults.standard.string(forKey: SettingsKey.readerBookBackgroundFollow))
            if rule.follows(red: red, green: green, blue: blue, hasBackgroundImage: hasImage) { followed = color }
        }
        if spreadView.backgroundColor != (followed ?? .clear) { spreadView.backgroundColor = followed ?? .clear }
    }

    /// 阅读背景或深浅色变化后，按现有底色重新套用规则。
    func reapplyPageBackgrounds() {
        for case let webView as WKWebView in pageBackgrounds.keyEnumerator().allObjects {
            applyPageBackground(to: webView)
        }
    }

    /// 解析 `rgb(r, g, b)`／`rgba(r, g, b, a)`；透明或无法解析时返回 nil。
    static func opaqueColor(fromCSS css: String) -> UIColor? {
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")"), open < close else { return nil }
        let parts = css[css.index(after: open)..<close].split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        let alpha = parts.count > 3 ? parts[3] : 1
        guard alpha > 0 else { return nil }
        return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: alpha)
    }

    /// Readium 只为固定版式书籍关闭 WebView 的不透明绘制；流式书籍的 WebView 会画出
    /// 自己的底色盖住阅读背景，因此逐个关闭。导航器根视图在 viewDidLoad 时也会涂成主题底色，
    /// 而首次打开不会触发 presentationDidChange，这里一并清空，否则 WebView 四周的边距露出白底。
    private func makeWebViewsTransparent() {
        guard let root = navigator?.view else { return }
        if root.backgroundColor != .clear { root.backgroundColor = .clear }
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let webView = view as? WKWebView { observePageBackground(of: webView) }
            if let webView = view as? WKWebView, webView.isOpaque {
                webView.isOpaque = false
                webView.underPageBackgroundColor = .clear
            }
            if let scrollView = view as? UIScrollView { gestureProbe.attach(to: scrollView.panGestureRecognizer) }
            stack.append(contentsOf: view.subviews)
        }
    }

    private static func plainText(fromHTML html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else {
            return html
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// ReadiumCSS 的颜色类型只输出 #RRGGBB；根背景需要 `transparent`。
struct TransparentCSSColor: CSSColor {
    func css() -> String? { "transparent" }
}


/// 给 Readium 内部滚动视图的拖动手势追加观察目标，只在开始拖动时回调（是否取消由回调决定）；
/// 已附加的手势用弱引用集合去重。
@MainActor
final class ReadiumGestureProbe: NSObject {
    private let onBegan: (UIPanGestureRecognizer) -> Void
    private let attached = NSHashTable<UIGestureRecognizer>.weakObjects()

    init(onBegan: @escaping (UIPanGestureRecognizer) -> Void) {
        self.onBegan = onBegan
    }

    func attach(to recognizer: UIPanGestureRecognizer) {
        guard !attached.contains(recognizer) else { return }
        attached.add(recognizer)
        recognizer.addTarget(self, action: #selector(handle(_:)))
    }

    @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { onBegan(recognizer) }
    }
}

// MARK: - 仿真翻页的独立预取与落页事务

extension ReadiumEPUBReaderModel {
    var curlRightToLeft: Bool { navigator?.settings.readingProgression == .rtl }
    func curlForward(atRightEdge right: Bool) -> Bool { right != curlRightToLeft }
    var curlPaperColor: UIColor {
        UIColor(settings.backgrounds.color(dark: isDarkMode,
            fallback: settings.appearance.background(system: isDarkMode ? .dark : .light)))
    }
    func curlPaperBackground(size: CGSize) -> UIImage? {
        settings.backgrounds.image(dark: isDarkMode, landscape: size.width > size.height)
    }
    var curlAppearanceKey: String {
        // 缓存键必须稳定；未排序的 JSON 会让同一份样式反复失效并阻塞用户翻页。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ((try? encoder.encode(style).base64EncodedString()) ?? "")
            + "|\(isDarkMode)|\(settings.backgrounds.revision)|\(UserDefaults.standard.string(forKey: SettingsKey.readerBookBackgroundFollow) ?? "")"
    }

    func afterCurlRestores(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard curlBusy, let cancelCurl else { return false }
        Task { await cancelCurl(); action() }
        return true
    }

    /// 预取导航器由卷页宿主持有，仅复用 Publication 与配置，不参与模型进度或正文交互。
    func makeCurlSnapshotNavigator() throws -> EPUBNavigatorViewController? {
        guard let publication, let locator else { return nil }
        // 影子导航只保留跨章定位必需的前/后各1个位置；其余页面由宿主限量预热，避免复制默认的前2/后6预加载。
        var config = navigatorConfiguration()
        config.preloadPreviousPositionCount = 1
        config.preloadNextPositionCount = 1
        let snapshot = try EPUBNavigatorViewController(publication: publication, initialLocation: locator, config: config)
        snapshot.delegate = self
        // 卷页快照直接截取自这个导航器；先补上与主阅读器相同的标注，否则动画期间高亮会消失。
        let index = navigationIndex?.resourceIndex(for: locator.href) ?? 0
        if let cached = cachedAnnotationDecorations, cached.chapter == index {
            snapshot.apply(decorations: cached.decorations, in: "user-annotations-preview")
        } else {
            Task { [weak self, weak snapshot] in
                guard let self, let snapshot else { return }
                let decorations = await self.annotationDecorations(chapter: index)
                snapshot.apply(decorations: decorations, in: "user-annotations-preview")
            }
        }
        return snapshot
    }

    func curlSnapshotBackground(_ web: WKWebView) async -> UIColor? {
        let rule = ReaderBookBackgroundFollow(storedValue: UserDefaults.standard.string(forKey: SettingsKey.readerBookBackgroundFollow))
        let script = EPUBReadiumPageBackground.script(ignoresNearWhite: rule == .ignoreNearWhite, threshold: ReaderBookBackgroundFollow.nearWhiteThreshold)
        let result: String? = await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value as? String) }
        }
        guard let result, let color = Self.opaqueColor(fromCSS: result) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let bounds = navigator?.view.bounds ?? web.bounds
        let hasImage = settings.backgrounds.image(dark: isDarkMode, landscape: bounds.width > bounds.height) != nil
        return rule.follows(red: r, green: g, blue: b, hasBackgroundImage: hasImage) ? color : nil
    }

    func beginCurlPreview(snapshot: EPUBNavigatorViewController? = nil) -> UUID? {
        guard curlPreview == nil, status == .ready, let navigator, let origin = locator else { return nil }
        let id = UUID()
        if snapshot == nil { textPositionTask?.cancel(); textProgressGeneration += 1 }
        curlPreview = CurlPreviewSession(id: id, origin: origin, navigator: navigator, snapshot: snapshot ?? navigator)
        curlBusy = true
        return id
    }

    // go 完成不等于排版位置已稳定。跨章向后时会先报告临时的 100%，
    // 分页正文的真实首可见进度应小于 1；连续稳定采样后才能缓存或提交。
    // `minimumStable` 是首个样本之后仍需一致的次数：落页提交只接受精确目标，可用 2；
    // 邻页与回位仍用 3，避免把跨章重排的中间位置当成最终页。
    func settledCurlLocation(in navigator: EPUBNavigatorViewController, matching destination: Locator? = nil, differentFrom previous: Locator? = nil, minimumStable: Int = 3) async -> Locator? {
        var candidate: Locator?, stable = 0
        for _ in 0..<60 {
            if Task.isCancelled { return nil }
            if let current = navigator.currentLocation {
                let progression = current.locations.progression ?? 0
                let canonical = publication?.metadata.layout == .fixed || progression < 1
                let matches = destination.map { current.href == $0.href && abs(progression - ($0.locations.progression ?? 0)) < 0.0000001 } ?? true
                let changed = previous.map { current.href != $0.href || abs(progression - ($0.locations.progression ?? 0)) > 0.0000001 } ?? true
                if canonical && matches && changed {
                    stable = candidate == current ? stable + 1 : 0
                    candidate = current
                    if stable >= minimumStable { return current }
                } else { candidate = nil; stable = 0 }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func curlNeighbor(in navigator: EPUBNavigatorViewController, forward: Bool) async throws -> Locator? {
        let previous = navigator.currentLocation
        let moved = forward ? await navigator.goForward(options: .none) : await navigator.goBackward(options: .none)
        try Task.checkCancellation()
        guard moved else { return nil }
        if let current = await settledCurlLocation(in: navigator, differentFrom: previous) { return current }
        try Task.checkCancellation()
        throw CurlNavigationError.locationUnavailable
    }

    func previewCurlNeighbor(forward: Bool, transaction: UUID) async throws -> Locator? {
        guard let preview = curlPreview, preview.id == transaction, self.navigator === preview.navigator else { return nil }
        return try await curlNeighbor(in: preview.snapshot, forward: forward)
    }

    /// 只移动独立预取导航器。后台预热不占用真实阅读事务，也不改变 curlBusy、正文或持久化位置。
    func prefetchCurlNeighbor(in snapshot: EPUBNavigatorViewController, from origin: Locator, forward: Bool, resetOrigin: Bool) async throws -> Locator? {
        let current = snapshot.currentLocation
        if resetOrigin || current?.href != origin.href || abs((current?.locations.progression ?? 0) - (origin.locations.progression ?? 0)) > 0.0000001 {
            guard await snapshot.go(to: origin, options: .none),
                  await settledCurlLocation(in: snapshot, matching: origin) != nil else {
                try Task.checkCancellation()
                throw CurlNavigationError.locationUnavailable
            }
        }
        try Task.checkCancellation()
        return try await curlNeighbor(in: snapshot, forward: forward)
    }

    private enum CurlNavigationError: Error { case locationUnavailable }

    func restoreCurlPreview(_ transaction: UUID) async -> Bool {
        guard let preview = curlPreview, preview.id == transaction,
              await preview.snapshot.go(to: preview.origin, options: .none) else { return false }
        return await settledCurlLocation(in: preview.snapshot, matching: preview.origin) != nil
    }

    /// 取消预取或手势只释放事务；真实导航器始终保留原页。只有明确落页才导航并发布一次位置。
    /// 成功时返回落页后稳定的 Locator，取消或失败返回 nil。
    @discardableResult
    func finishCurlPreview(_ transaction: UUID, target: Locator?, forward: Bool = true) async -> Locator? {
        guard let preview = curlPreview, preview.id == transaction else { return nil }
        let navigator = preview.navigator
        var actual = preview.origin
        var restored = true
        if let target {
            restored = await navigator.go(to: target, options: .none)
            if restored, let settled = await settledCurlLocation(in: navigator, matching: target, minimumStable: 2) {
                actual = settled
            } else { restored = false }
        }
        guard curlPreview?.id == transaction else { return nil }
        curlPreview = nil; curlBusy = false
        guard self.navigator === navigator else { return nil }
        guard restored else {
            status = .failed("仿真翻页无法恢复阅读位置，请重新打开阅读器。")
            return nil
        }
        if target != nil {
#if DEBUG
            curlCompletedTurns += 1
#endif
            markNavigation(forward ? "turnForward" : "turnBackward")
            self.navigator(navigator, locationDidChange: actual)
        }
        return actual
    }

    func curlReachedBoundary(forward: Bool) {
        if forward, isAtWebNovelEnd { pendingWebPositionWrite = false; onReachedEnd?() }
    }

    /// 当前会话 id；控制器在连续翻页时复用它，而不是每页新开事务。
    var activeCurlPreview: UUID? { curlPreview?.id }

    /// 只提交一页，不关闭会话。真实导航器按顺序追赶显示游标时使用。
    @discardableResult
    func commitCurlPreview(_ transaction: UUID, target: Locator, forward: Bool) async -> Locator? {
        guard let preview = curlPreview, preview.id == transaction, self.navigator === preview.navigator else { return nil }
        guard await preview.navigator.go(to: target, options: .none),
              let settled = await settledCurlLocation(in: preview.navigator, matching: target, minimumStable: 2),
              curlPreview?.id == transaction, self.navigator === preview.navigator else { return nil }
        curlPreview?.committing = true
        markNavigation(forward ? "turnForward" : "turnBackward")
        self.navigator(preview.navigator, locationDidChange: settled)
        curlPreview?.committing = false
#if DEBUG
        curlCompletedTurns += 1
#endif
        return settled
    }

    func endCurlPreview(_ transaction: UUID) {
        guard curlPreview?.id == transaction else { return }
        curlPreview = nil; curlBusy = false
    }
}
