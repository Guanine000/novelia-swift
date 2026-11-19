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
        if force { cachedChapterAnnotationDecorations.removeAll() }
        annotationDecorationChapter = index
        let generation = UUID()
        annotationRefreshGeneration = generation
        guard !settings.annotations.annotations(for: bookKey, chapter: index).isEmpty else {
            cachedAnnotationDecorations = nil
            cachedChapterAnnotationDecorations[index] = []
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
            self.cachedChapterAnnotationDecorations[index] = decorations

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
