import Combine
import OSLog
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit
import WebKit

// MARK: - Readium 朗读、正文图片与位置/滑动诊断

@MainActor
extension ReadiumEPUBReaderModel {
    func startSpeechFromVisiblePage() {
        if afterCurlRestores({ [weak self] in self?.startSpeechFromVisiblePage() }) { return }
        speech.stop(); prepareSpeech()
        let cloud = speech.isCloud
        speech.startSelection { [weak self] in
            guard let self, let navigator = self.navigator,
                  let visible = await navigator.firstVisibleElementLocator() else { return nil }
            let index = self.navigationIndex?.resourceIndex(for: visible.href) ?? self.currentPageRange?.chapter ?? 0
            if !cloud { return (self.speechAnchor, visible) }
            guard let source = try? await self.chapterPlainText(index),
                  let root = navigator.view,
                  let (web, _) = Self.visibleWebView(containing: CGPoint(x: root.bounds.midX, y: root.bounds.midY), in: root) else { return nil }
            let script = """
            (() => {
              const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
              let node, prefix = 0;
              const visible = r => r.width > 0 && r.height > 0 && r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight;
              while ((node = walker.nextNode())) {
                if (node.parentElement.closest('script,style')) continue;
                const text = node.data;
                const range = document.createRange(); range.selectNodeContents(node);
                if (text.trim() && Array.from(range.getClientRects()).some(visible)) {
                  let lo = 0, hi = text.length - 1;
                  while (lo < hi) {
                    const mid = Math.floor((lo + hi) / 2);
                    range.setStart(node, 0); range.setEnd(node, mid + 1);
                    if (Array.from(range.getClientRects()).some(visible)) hi = mid; else lo = mid + 1;
                  }
                  if (lo > 0 && text.charCodeAt(lo) >= 0xDC00 && text.charCodeAt(lo) <= 0xDFFF) lo--;
                  let end = Math.min(text.length, lo + 80);
                  if (end < text.length && text.charCodeAt(end) >= 0xDC00 && text.charCodeAt(end) <= 0xDFFF) end--;
                  return { offset: prefix + text.slice(0, lo).replace(/\\s/g, '').length, quote: text.slice(lo, end) };
                }
                prefix += text.replace(/\\s/g, '').length;
              }
              return null;
            })()
            """
            let result: [String: Any]? = await withCheckedContinuation { continuation in
                web.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value as? [String: Any]) }
            }
            guard let result, let offset = result["offset"] as? Int, let quote = result["quote"] as? String,
                  let sourceOffset = SpeechText.sourceOffset(visibleNonWhitespaceOffset: offset, quote: quote, in: source) else { return nil }
            return (SpeechAnchor(chapterIndex: index, progression: 0, chapterUTF16Length: source.utf16.count,
                                 startIndexHint: nil, sourceUTF16Offset: sourceOffset, startsAtVisibleOffset: true), nil)
        }
    }

    func startSpeech(selection: Selection) {
        if afterCurlRestores({ [weak self] in self?.startSpeech(selection: selection) }) { return }
        let selectedLocator = selection.locator
        let index = navigationIndex?.resourceIndex(for: selectedLocator.href) ?? currentPageRange?.chapter ?? 0
        speech.stop(); prepareSpeech()
        let cloud = speech.isCloud
        speech.startSelection { [weak self] in
            guard let self else { return nil }
            let progression = selectedLocator.locations.progression ?? 0
            if !cloud {
                return (SpeechAnchor(chapterIndex: index, progression: progression,
                                     chapterUTF16Length: 0, startIndexHint: nil), selectedLocator)
            }
            guard let source = try? await self.chapterPlainText(index),
                  let selected = selectedLocator.text.highlight,
                  let offset = SpeechText.selectedOffset(selected, in: source, near: progression) else { return nil }
            return (SpeechAnchor(chapterIndex: index, progression: progression, chapterUTF16Length: source.utf16.count,
                                 startIndexHint: nil, sourceUTF16Offset: offset), nil)
        }
        navigator?.clearSelection()
    }

    /// 用同一份上传正文的前后文定位句子，Readium 在 HTML 中解析精确文本范围。
    func updateExternalSpeechPosition(_ position: SpeechReadingPosition?, settings: SpeechSettings) {
        externalSpeechTask?.cancel()
        externalSpeechGeneration = UUID()
        let generation = externalSpeechGeneration
        guard let position, let publication, let navigator,
              publication.readingOrder.indices.contains(position.chapterIndex) else {
            navigator?.apply(decorations: [], in: "edge-tts")
            return
        }
        externalSpeechTask = Task { [weak self, weak navigator] in
            guard let self, let navigator,
                  let text = try? await self.chapterPlainText(position.chapterIndex),
                  let base = await publication.locate(publication.readingOrder[position.chapterIndex]),
                  !Task.isCancelled, self.externalSpeechGeneration == generation else { return }
            let source = text as NSString
            let range = position.sentenceRange
            guard range.lowerBound >= 0, range.upperBound <= source.length, !range.isEmpty else { return }
            let beforeStart = max(0, range.lowerBound - 80)
            let afterEnd = min(source.length, range.upperBound + 80)
            let locator = base.copy(locations: {
                $0.progression = Double(range.lowerBound) / Double(max(1, source.length))
            }, text: {
                $0.before = source.substring(with: NSRange(location: beforeStart, length: range.lowerBound - beforeStart))
                $0.highlight = source.substring(with: NSRange(location: range.lowerBound, length: range.count))
                $0.after = source.substring(with: NSRange(location: range.upperBound, length: afterEnd - range.upperBound))
            })
            let decorations = settings.highlightsSpokenText
                ? [Decoration(id: "edge-current", locator: locator,
                              style: .init(id: "novelia-speech"))] : []
            navigator.apply(decorations: decorations, in: "edge-tts")
            if settings.followsReadingPosition, self.speech.state.isPlaying {
                self.markNavigation("speech")
                _ = await navigator.go(to: locator)
            }
        }
    }

    /// 用户翻页或滚动后回到正在朗读的段落。
    func jumpToSpoken() {
        if afterCurlRestores({ [weak self] in self?.jumpToSpoken() }) { return }
        guard let spokenLocator else { return }
        markNavigation("speech")
        Task { _ = await navigator?.go(to: spokenLocator) }
    }

    func attachSpeechEngine(publication: Publication, navigator: EPUBNavigatorViewController) {
        let local = ReadiumSpeechEngine(publication: publication, navigator: navigator, onFollow: { [weak self] in
            self?.markNavigation("speech")
        }, chapterLocator: { [weak self] delta in
            guard let self else { return nil }
            let current = self.currentPageRange?.chapter ?? 0
            let index = min(publication.readingOrder.count - 1, max(0, current + delta))
            guard publication.readingOrder.indices.contains(index),
                  let base = await publication.locate(publication.readingOrder[index]) else { return nil }
            return base.copy(locations: { $0.progression = 0 })
        }, anchorForLocator: { [weak self] locator in
            guard let self, let index = self.navigationIndex?.resourceIndex(for: locator.href) else { return nil }
            return SpeechAnchor(chapterIndex: index, progression: locator.locations.progression ?? 0,
                                chapterUTF16Length: 0, startIndexHint: nil)
        }, locatorForAnchor: { [weak self] anchor in
            guard let self, publication.readingOrder.indices.contains(anchor.chapterIndex),
                  let base = await publication.locate(publication.readingOrder[anchor.chapterIndex]) else { return nil }
            return base.copy(locations: { $0.progression = anchor.progression }, text: { $0.highlight = anchor.resumeText })
        })
        local?.onSpokenLocator = { [weak self] locator in self?.spokenLocator = locator }
        speech.reloadSettings()
        if let speechSelection {
            speech.attach(speechSelection.select(local: local, chapterCount: chapterCount,
                onReadingPosition: { [weak self] position, settings in
                    self?.updateExternalSpeechPosition(position, settings: settings)
                }, chapterText: { [weak self] index in
                guard let self else { throw CancellationError() }
                return try await self.chapterPlainText(index)
            }))
        } else { speech.attach(local) }
    }

    func recordListeningProgress(_ point: SpeechResumePoint) {
        guard point.bookKey == bookmarkKey else { return }
        listeningProgressTask?.cancel()
        if let textBook, textBook.bookmarkKey?.hasPrefix("txt:") == true,
           let source = textBook.source as? TextChapterSource, (0..<source.chapterCount).contains(point.chapterIndex) {
            textProgressGeneration += 1
            let generation = textProgressGeneration
            listeningProgressTask = Task { [weak self] in
                guard let self else { return }
                guard let html = try? await source.chapterHTML(at: point.chapterIndex), !Task.isCancelled,
                      self.textProgressGeneration == generation else { return }
                let offset = point.sourceUTF16Offset ?? EPUBChapterProgress.offset(progression: point.progression,
                    length: EPUBChapterProgress.textLength(html: html))
                guard self.textProgressGeneration == generation else { return }
                textBook.onPosition(point.chapterIndex, offset)
            }
        } else if let hash = bookHash, let publication, publication.readingOrder.indices.contains(point.chapterIndex) {
            var fraction = (Double(point.chapterIndex) + point.progression) / Double(max(1, publication.readingOrder.count))
            var savedSpokenLocator = false
            if let json = point.locatorJSON, let value = try? JSONValue(jsonString: json),
               let locator = try? Locator(json: value, warnings: nil),
               navigationIndex?.resourceIndex(for: locator.href) == point.chapterIndex {
                fraction = locator.locations.totalProgression ?? fraction
                if let key = locatorKey, let timeKey = locatorTimeKey {
                    settings.defaults.set(json, forKey: key); settings.defaults.set(Date(), forKey: timeKey)
                    savedSpokenLocator = true
                }
            }
            // 系统/云端只有句首坐标；清掉旧可见页 Locator，避免一秒容差把新收听位置判旧。
            if !savedSpokenLocator, let key = locatorKey, let timeKey = locatorTimeKey {
                settings.defaults.removeObject(forKey: key); settings.defaults.removeObject(forKey: timeKey)
            }
            settings.recordEPUBPosition(hash: hash, fraction: fraction, spineIndex: point.chapterIndex,
                chapterOffset: point.sourceUTF16Offset, chapterProgression: point.progression,
                context: webContext, paths: webChapterPaths)
        }
    }

    /// 续听先解析持久化 Locator（旧记录按章与比例恢复），等待导航完成再起播。
    func resumeSpeech(at point: SpeechResumePoint) {
        if afterCurlRestores({ [weak self] in self?.resumeSpeech(at: point) }) { return }
        prepareSpeech()
        let usesLocator = speech.engineKind == .readium
        speech.startSelection { [weak self] in
            guard let self, let publication = self.publication, let navigator = self.navigator,
                  publication.readingOrder.indices.contains(point.chapterIndex) else { return nil }
            var locator: Locator?
            if usesLocator, let json = point.locatorJSON,
               let value = try? JSONValue(jsonString: json),
               let saved = try? Locator(json: value, warnings: nil),
               self.navigationIndex?.resourceIndex(for: saved.href) == point.chapterIndex {
                locator = saved
            }
            if locator == nil, let base = await publication.locate(publication.readingOrder[point.chapterIndex]) {
                locator = base.copy(locations: { $0.progression = point.progression })
            }
            guard !Task.isCancelled, let locator else { return nil }
            self.markNavigation("speech")
            guard await navigator.go(to: locator), !Task.isCancelled else { return nil }
            return (point.anchor, usesLocator ? locator : nil)
        }
    }

    /// 未在播放时重开面板，重新读取已确认的引擎偏好，不打断活动会话。
    func prepareSpeech() {
        guard !speech.isActive, let publication, let navigator else { return }
        attachSpeechEngine(publication: publication, navigator: navigator)
    }

    /// 朗读起播位置。Readium 引擎优先使用当前可见页的 Locator；
    /// 这里保留章内比例，供以后按片段队列起播的系统／云端引擎使用。
    var speechAnchor: SpeechAnchor {
        let range = currentPageRange
        return SpeechAnchor(chapterIndex: range?.chapter ?? 0,
                            progression: range?.range.lowerBound ?? 0,
                            chapterUTF16Length: 0, startIndexHint: nil)
    }

    /// 在导航器视图坐标处查找正文图片（`<img>` 或 SVG `<image>`，边长不足 32pt 的小图不算），
    /// 找到则按包内路径打开查看器。
    func openImage(at point: CGPoint) async -> Bool {
        guard let container = imageContainer, let root = navigator?.view,
              let (webView, local) = Self.visibleWebView(containing: point, in: root) else { return false }
        let script = """
        (function(x, y) {
          var el = document.elementFromPoint(x, y);
          if (el && el.tagName && el.tagName.toLowerCase() === 'svg') { el = el.querySelector('image') || el; }
          if (!el || !el.tagName) { return ''; }
          var tag = el.tagName.toLowerCase();
          var r = el.getBoundingClientRect();
          if (Math.min(r.width, r.height) < 32) { return ''; }
          if (tag === 'img') { return el.currentSrc || el.src || ''; }
          if (tag === 'image') {
            var h = el.getAttribute('xlink:href') || el.getAttributeNS('http://www.w3.org/1999/xlink', 'href') || el.getAttribute('href');
            return h ? new URL(h, document.baseURI).href : '';
          }
          return '';
        })(\(local.x), \(local.y))
        """
        // 用回调版本：异步版本在脚本返回空值时可能出错。
        let source: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
        guard let source, !source.isEmpty, let url = URL(string: source),
              let path = await container.packagePath(forImageURL: url) else { return false }
        imageLibrary.presentTapped(path: path)
        return true
    }

    /// 包含该点、当前正显示在屏幕上的章节 WebView，以及该点在 WebView 内的坐标。
    static func visibleWebView(containing point: CGPoint, in root: UIView) -> (WKWebView, CGPoint)? {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let webView = view as? WKWebView, webView.window != nil, !webView.isHidden {
                let local = webView.convert(point, from: root)
                if webView.bounds.contains(local) { return (webView, local) }
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: 位置诊断

    func markNavigation(_ cause: String) {
        viewportRestoration = nil
        if ["turnForward", "turnBackward", "navigate", "seek", "swipe", "outerSwipe"].contains(cause) { speech.suspendFollow(true) }
        diagnosticOperation += 1
        if ["turnForward", "turnBackward", "navigate", "seek", "swipe", "outerSwipe", "speech"].contains(cause) { pendingWebPositionWrite = true }
        pendingLocationCause = (cause, .now)
    }

    /// 记录每次位置变化（包括普通翻页），使分享日志能还原跳页前后的操作顺序。只含序号与比例，不含正文。
    func logLocationChange(from previous: Locator?, to current: Locator) {
        guard previous != current else { return }
        var cause = "unattributed"
        if previous == nil {
            cause = "open"
        } else if let pending = pendingLocationCause, MonotonicInstant.now.milliseconds(since: pending.time) < 3_000 {
            cause = pending.cause
        }
        pendingLocationCause = nil
        let kind = textBook == nil ? "epub" : (textBook?.bookmarkKey == nil ? "online" : "txt")
        func resource(_ locator: Locator?) -> Int { locator.flatMap { navigationIndex?.resourceIndex(for: $0.href) } ?? -1 }
        func permille(_ value: Double?) -> Int { value.map { Int((min(max($0, 0), 1) * 1000).rounded()) } ?? -1 }
        let toResource = resource(current), toFraction = current.locations.progression ?? 0
        if previous == nil || toResource != readingTimePoint.resource || abs(toFraction - readingTimePoint.fraction) >= 0.0000001 {
            readingTimePoint = .init(resource: toResource, fraction: toFraction,
                reason: ["turnForward", "tap", "swipe", "outerSwipe"].contains(cause) ? .forward : .reset)
        }
        Self.shareable.notice(ReaderDiagnosticMessage.readiumPositionChanged(
            kind: kind, cause: cause, fromResource: resource(previous), fromProgress: permille(previous?.locations.progression),
            toResource: resource(current), toProgress: permille(current.locations.progression),
            total: permille(current.locations.totalProgression)))
        // 仅表示位置回调后的采样，不宣称排版或动画已经停稳；丢弃旧导航器/旧操作的延迟采样。
        let revision = navigatorRevision
        let operation = diagnosticOperation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigatorRevision == revision, self.diagnosticOperation == operation else { return }
            self.logPageState(when: "locationCallback")
        }
    }

    /// Readium 用两层横向滚动视图：章节 WebView 自己的滚动视图负责章内翻页，外层分页视图负责切换章节。
    /// 拖动从 WebView 以外的区域开始（上下页边距、章节标题栏区域）时只有外层能响应，会直接切到相邻章节，
    /// 跳过本章剩余页面。因此外层开始拖动时，若本章在该方向上仍有页面，就取消这次拖动并改为章内翻一页；
    /// 已在章首或章末时保留外层的切章行为。
    func swipeBegan(_ recognizer: UIPanGestureRecognizer) {
        guard let scrollView = recognizer.view as? UIScrollView else { return }
        if isAtWebNovelEnd, recognizer.velocity(in: scrollView).x < -100 {
            recognizer.isEnabled = false; recognizer.isEnabled = true
            pendingWebPositionWrite = false; onReachedEnd?(); return
        }
        if let webView = scrollView.superview as? WKWebView {
            markNavigation("swipe")
            logPageState(when: "swipe", page: webView, candidates: 1)
            return
        }
        markNavigation("outerSwipe")
        let selection = chapterPageSelection()
        logPageState(when: "outerSwipe", page: selection.page, candidates: selection.count)
        let translation = recognizer.translation(in: scrollView).x
        let dx = translation != 0 ? translation : recognizer.velocity(in: scrollView).x
        let direction = dx == 0 ? "unknown" : (dx < 0 ? "right" : "left")
        let operation = diagnosticOperation
        let revision = navigatorRevision
        func decision(_ reason: String) {
            Self.shareable.notice(ReaderDiagnosticMessage.readiumSwipeDecision(
                session: diagnosticSession, nav: revision, op: operation, direction: direction, reason: reason))
        }
        func cancel() {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        // 无法证明页面归属或尺寸可靠时取消本次外层拖动，避免把未知状态当成章末直接跳章。
        // 固定版使用 wrapper/双页容器，不套用可重排章节的宽度与 URL 判定。
        if publication?.metadata.layout == .fixed { decision("fixedLayout"); return }
        guard dx != 0 else { cancel(); decision("noDirection"); return }
        guard redirectedOperation == nil else { cancel(); decision("busy"); return }
        guard let page = selection.page else {
            cancel(); decision(selection.count > 1 ? "ambiguous" : "noPage"); return
        }
        guard !page.isLoading else { cancel(); decision("loading"); return }
        let chapter = page.scrollView
        guard !chapter.isDragging, !chapter.isDecelerating else { cancel(); decision("moving"); return }
        let modelResource = locator.flatMap { navigationIndex?.resourceIndex(for: $0.href) }
        let pageResource = page.url.flatMap { navigationIndex?.resourceIndex(forDocumentURL: $0) }
        guard let modelResource, pageResource == modelResource else { cancel(); decision("mismatch"); return }
        let offset = chapter.contentOffset.x
        let width = chapter.bounds.width
        let content = chapter.contentSize.width
        guard offset.isFinite, width.isFinite, content.isFinite, width > 0, content >= width - 1,
              offset >= -1, offset + width <= content + 1 else { cancel(); decision("invalidSize"); return }
        let towardsRight = dx < 0
        let hasRoom = towardsRight ? offset + width < content - 1 : offset > 1
        guard hasRoom else { decision("boundary"); return }
        cancel()
        decision("redirect")
        redirectedOperation = operation
        Task { [weak self, weak navigator = self.navigator] in
            guard let self else { return }
            defer { if self.redirectedOperation == operation { self.redirectedOperation = nil } }
            guard let navigator, self.navigator === navigator, self.navigatorRevision == revision else {
                decision("stale"); return
            }
            let succeeded = towardsRight ? await navigator.goRight(options: .animated) : await navigator.goLeft(options: .animated)
            guard self.navigator === navigator, self.navigatorRevision == revision else { decision("stale"); return }
            decision(succeeded ? "completed" : "failed")
            self.logPageState(when: "navigationComplete", operation: operation)
        }
    }

    /// 只接受唯一覆盖阅读区中央、且没有隐藏祖先的 WebView。切章动画中的重叠页面不任意取第一个。
    func chapterPageSelection() -> (page: WKWebView?, count: Int) {
        guard let root = navigator?.view else { return (nil, 0) }
        let point = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        var stack = [root]
        var pages: [WKWebView] = []
        while let view = stack.popLast() {
            guard !view.isHidden, view.alpha > 0.01 else { continue }
            // 祖先裁剪也参与可见性判断，排除已滑出当前章节容器的预加载页面。
            if view.clipsToBounds, !view.bounds.contains(view.convert(point, from: root)) { continue }
            if let page = view as? WKWebView, page.window != nil,
               page.bounds.contains(page.convert(point, from: root)) { pages.append(page) }
            stack.append(contentsOf: view.subviews)
        }
        return (pages.count == 1 ? pages[0] : nil, pages.count)
    }

    func noteGesture(_ gesture: String) {
        markNavigation(gesture)
        logPageState(when: gesture)
    }

    /// 分别记录模型资源和页面实际资源；仅使用匿名会话/View 序号，不输出 URL。
    func logPageState(when: String, operation: Int? = nil) {
        let selection = chapterPageSelection()
        logPageState(when: when, page: selection.page, candidates: selection.count, operation: operation)
    }

    func logPageState(when: String, page: WKWebView?, candidates: Int, operation: Int? = nil) {
        var viewID = 0
        if let page {
            if let existing = diagnosticViews.object(forKey: page) { viewID = existing.intValue }
            else {
                nextDiagnosticView += 1
                viewID = nextDiagnosticView
                diagnosticViews.setObject(NSNumber(value: viewID), forKey: page)
            }
        }
        func number(_ value: CGFloat?) -> Int {
            guard let value, value.isFinite else { return 0 }
            return Int(min(max(value.rounded(), -999_999_999), 999_999_999))
        }
        let scroll = page?.scrollView
        Self.shareable.notice(ReaderDiagnosticMessage.readiumSnapshot(
            session: diagnosticSession, nav: navigatorRevision, op: operation ?? diagnosticOperation, when: when,
            model: locator.flatMap { navigationIndex?.resourceIndex(for: $0.href) } ?? -1,
            page: page?.url.flatMap { navigationIndex?.resourceIndex(forDocumentURL: $0) } ?? -1,
            view: viewID, candidates: candidates, offset: number(scroll?.contentOffset.x),
            width: min(999_999, number(scroll?.bounds.width)), content: number(scroll?.contentSize.width),
            loading: page?.isLoading ?? false, moving: (scroll?.isDragging ?? false) || (scroll?.isDecelerating ?? false)))
    }

    /// 标记是阅读轨迹中的时间点，不把此刻的页面冒充为异常落点。
    func markIssue() {
        Self.shareable.notice(ReaderDiagnosticMessage.issueMarked(engine: "readium"))
        logPageState(when: "issue")
    }
}
