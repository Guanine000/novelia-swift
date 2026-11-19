import Combine
import OSLog
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit
import WebKit

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
        warmAdjacentChapterAnnotations(around: locator)
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

    /// 注脚不跳转，改为在注释标记旁弹出气泡显示纯文本。
    func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: ReadiumShared.Link, content: String, referrer: String?) -> Bool {
        let text = Self.plainText(fromHTML: content)
        activeNote = EPUBNote(text: text.isEmpty ? "（注释内容为空）" : text, anchor: lastTapWindowRect)
        return false
    }

    /// 未标 `epub:type="noteref"` 的注释链接（多看、Sigil 注释插件等）：目标是注释正文时
    /// 同样以气泡浮层显示；不是注释或读取失败时照常跳转。读取目标需要异步，因此先拦下再决定。
    func navigator(_ navigator: VisualNavigator, shouldNavigateToLink link: ReadiumShared.Link) -> Bool {
        guard textBook == nil, let publication,
              let url = AnyURL(string: link.href), let id = url.fragment, !id.isEmpty else { return true }
        let anchor = lastTapWindowRect
        Task { [weak self] in
            let html = try? await publication.get(url.removingFragment())?.read().asString().get()
            guard let self else { return }
            if let html, let note = EPUBFootnoteTarget.noteHTML(id: id, inDocument: html) {
                let text = Self.plainText(fromHTML: note)
                if !text.isEmpty {
                    activeNote = EPUBNote(text: text, anchor: anchor)
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
/// 同时在导航器根视图挂载不拦截触摸的点按观察器，记录每次点按在窗口坐标系中的位置（WebKit 点击 `<a>` 链接时
/// Readium 的 JS tap 事件不会触发，需由原生手势提前记录注脚锚点）。
@MainActor
final class ReadiumGestureProbe: NSObject, UIGestureRecognizerDelegate {
    private let onBegan: (UIPanGestureRecognizer) -> Void
    private let onTapLocation: (CGRect) -> Void
    private let attached = NSHashTable<UIGestureRecognizer>.weakObjects()
    private let tapAttachedViews = NSHashTable<UIView>.weakObjects()

    init(onBegan: @escaping (UIPanGestureRecognizer) -> Void,
         onTapLocation: @escaping (CGRect) -> Void = { _ in }) {
        self.onBegan = onBegan
        self.onTapLocation = onTapLocation
    }

    func attach(to recognizer: UIPanGestureRecognizer) {
        guard !attached.contains(recognizer) else { return }
        attached.add(recognizer)
        recognizer.addTarget(self, action: #selector(handle(_:)))
    }

    func attachTapObserver(to view: UIView) {
        guard !tapAttachedViews.contains(view) else { return }
        tapAttachedViews.add(view)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { onBegan(recognizer) }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        let point = recognizer.location(in: view)
        let rect = view.convert(CGRect(origin: point, size: .zero).insetBy(dx: -8, dy: -10), to: nil)
        onTapLocation(rect)
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
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
        // 影子导航保留前1个位置，并提前2个位置预加载后一章，使翻近章末时下一章 WebView 已提前挂载排版。
        var config = navigatorConfiguration()
        config.preloadPreviousPositionCount = 1
        config.preloadNextPositionCount = 2
        let snapshot = try EPUBNavigatorViewController(publication: publication, initialLocation: locator, config: config)
        snapshot.delegate = self
        // 卷页快照直接截取自这个导航器；先补上与主阅读器相同的标注，否则动画期间高亮会消失。
        let index = navigationIndex?.resourceIndex(for: locator.href) ?? 0
        if let cached = cachedChapterAnnotationDecorations[index] {
            snapshot.apply(decorations: cached, in: "user-annotations-preview")
        } else if let cached = cachedAnnotationDecorations, cached.chapter == index {
            snapshot.apply(decorations: cached.decorations, in: "user-annotations-preview")
        } else {
            Task { [weak self, weak snapshot] in
                guard let self, let snapshot else { return }
                let decorations = await self.annotationDecorations(chapter: index)
                self.cachedChapterAnnotationDecorations[index] = decorations
                snapshot.apply(decorations: decorations, in: "user-annotations-preview")
            }
        }
        return snapshot
    }

    func curlSnapshotBackground(_ web: WKWebView) async -> UIColor? {
        let urlKey = web.url?.absoluteString ?? ""
        let appearance = curlAppearanceKey
        if !urlKey.isEmpty,
           let cached = curlWebBackgrounds.object(forKey: web) as? CachedCurlWebBackground,
           cached.url == urlKey, cached.appearanceKey == appearance {
            return cached.color
        }
        let rule = ReaderBookBackgroundFollow(storedValue: UserDefaults.standard.string(forKey: SettingsKey.readerBookBackgroundFollow))
        let script = EPUBReadiumPageBackground.script(ignoresNearWhite: rule == .ignoreNearWhite, threshold: ReaderBookBackgroundFollow.nearWhiteThreshold)
        let result: String? = await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value as? String) }
        }
        let computed: UIColor?
        if let result, let color = Self.opaqueColor(fromCSS: result) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let bounds = navigator?.view.bounds ?? web.bounds
            let hasImage = settings.backgrounds.image(dark: isDarkMode, landscape: bounds.width > bounds.height) != nil
            computed = rule.follows(red: r, green: g, blue: b, hasBackgroundImage: hasImage) ? color : nil
        } else {
            computed = nil
        }
        if !urlKey.isEmpty {
            curlWebBackgrounds.setObject(CachedCurlWebBackground(url: urlKey, appearanceKey: appearance, color: computed) as AnyObject, forKey: web)
        }
        return computed
    }

    /// 临近章首/章尾或短章节时，在后台提前解析相邻章的摘录高亮，消除跨章快照等待。
    func warmAdjacentChapterAnnotations(around locator: Locator) {
        guard let bookKey = bookmarkKey, let publication,
              let index = navigationIndex?.resourceIndex(for: locator.href) else { return }
        let progression = locator.locations.progression ?? 0
        let shortChapter = (positionsPerResource[index] ?? 1) <= 3
        var neighbors: [Int] = []
        if (shortChapter || progression >= 0.7), publication.readingOrder.indices.contains(index + 1) {
            neighbors.append(index + 1)
        }
        if (shortChapter || progression <= 0.3), publication.readingOrder.indices.contains(index - 1) {
            neighbors.append(index - 1)
        }
        for neighbor in neighbors where cachedChapterAnnotationDecorations[neighbor] == nil {
            if settings.annotations.annotations(for: bookKey, chapter: neighbor).isEmpty {
                cachedChapterAnnotationDecorations[neighbor] = []
                continue
            }
            let generation = annotationRefreshGeneration
            Task { [weak self] in
                guard let self else { return }
                let decorations = await self.annotationDecorations(chapter: neighbor)
                guard self.annotationRefreshGeneration == generation else { return }
                self.cachedChapterAnnotationDecorations[neighbor] = decorations
            }
        }
    }

    func syncCurlSnapshotAnnotations(in snapshot: EPUBNavigatorViewController, locator: Locator) async {
        guard let index = navigationIndex?.resourceIndex(for: locator.href) else { return }
        if let cached = cachedChapterAnnotationDecorations[index] {
            snapshot.apply(decorations: cached, in: "user-annotations-preview")
        } else if let cached = cachedAnnotationDecorations, cached.chapter == index {
            cachedChapterAnnotationDecorations[index] = cached.decorations
            snapshot.apply(decorations: cached.decorations, in: "user-annotations-preview")
        } else if let bookKey = bookmarkKey, !settings.annotations.annotations(for: bookKey, chapter: index).isEmpty {
            let decorations = await annotationDecorations(chapter: index)
            cachedChapterAnnotationDecorations[index] = decorations
            snapshot.apply(decorations: decorations, in: "user-annotations-preview")
        } else {
            cachedChapterAnnotationDecorations[index] = []
            snapshot.apply(decorations: [], in: "user-annotations-preview")
        }
    }

    /// 判断当前 Locator 在指定方向上是否已明确处于全书起点边界（避免首屏在影子导航器上来回跳页探测上一页）。
    func isAtCurlBookBoundary(_ locator: Locator, forward: Bool) -> Bool {
        guard !forward, let publication, !publication.readingOrder.isEmpty,
              navigationIndex?.resourceIndex(for: locator.href) == 0,
              let progression = locator.locations.progression else { return false }
        return progression <= 0.0000001
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
    // 同章内仅滚动 WebView 视口，不发生跨章重排，采用更短采样间隔并减少一次稳定采样；跨章仍保持完整采样次数。
    func settledCurlLocation(in navigator: EPUBNavigatorViewController, matching destination: Locator? = nil, differentFrom previous: Locator? = nil, minimumStable: Int = 3) async -> Locator? {
        var candidate: Locator?, stable = 0
        for _ in 0..<180 {
            if Task.isCancelled { return nil }
            var sleepNanoseconds: UInt64 = 20_000_000
            if let current = navigator.currentLocation {
                let progression = current.locations.progression ?? 0
                let canonical = publication?.metadata.layout == .fixed || progression < 1
                let matches = destination.map { current.href == $0.href && abs(progression - ($0.locations.progression ?? 0)) < 0.0000001 } ?? true
                let changed = previous.map { current.href != $0.href || abs(progression - ($0.locations.progression ?? 0)) > 0.0000001 } ?? true
                if canonical && matches && changed {
                    let sameResource = (destination != nil && current.href == destination?.href)
                        || (previous != nil && current.href == previous?.href)
                    let requiredStable = sameResource ? max(1, minimumStable - 1) : minimumStable
                    stable = candidate == current ? stable + 1 : 0
                    candidate = current
                    if stable >= requiredStable { return current }
                    if sameResource { sleepNanoseconds = 8_000_000 }
                } else { candidate = nil; stable = 0 }
            }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        return nil
    }

    private func curlNeighbor(in navigator: EPUBNavigatorViewController, forward: Bool) async throws -> Locator? {
        let previous = navigator.currentLocation
        let moved = forward ? await navigator.goForward(options: .none) : await navigator.goBackward(options: .none)
        try Task.checkCancellation()
        guard moved else { return nil }
        if let current = await settledCurlLocation(in: navigator, differentFrom: previous) {
            if navigator !== self.navigator, current.href != previous?.href {
                await syncCurlSnapshotAnnotations(in: navigator, locator: current)
            }
            warmAdjacentChapterAnnotations(around: current)
            return current
        }
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
