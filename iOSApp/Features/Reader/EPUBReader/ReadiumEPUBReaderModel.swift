import OSLog
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit
import WebKit

// MARK: - Readium EPUB 阅读器（实验）
//
// EPUB 由 Readium 解析，并在 WKWebView 中用 ReadiumCSS 分页；翻页为 Readium 自带的
// 水平滑动。实验开关也可将 TXT 与在线章节接入同一导航器。
//
// 进度：本机保存 Readium Locator（JSON）；同时记录整书比例、章节序号与章内比例
// （chapterOffset 置空）。另一引擎或其他设备按章节 + 章内比例恢复，旧版本按整书比例。

/// 目录项（展平 Readium 的嵌套目录）。
struct ReadiumTOCItem: Identifiable {
    let id: Int
    let title: String
    let level: Int
    let link: ReadiumShared.Link
}

@MainActor
final class ReadiumEPUBReaderModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
    }

    static let logger = Logger(subsystem: ShareableLogPolicy.subsystem, category: "readium")
    /// 需要出现在分享日志中、并跨启动保留的事件（notice 级）。
    static let shareable = ShareableLogger(category: "readium")

    @Published private(set) var status: Status = .idle
    @Published private(set) var bookTitle = ""
    @Published private(set) var toc: [ReadiumTOCItem] = []
    /// 目录兜底说明（改用正文标题生成的目录，或完全没有目录时的原因）。
    @Published private(set) var tocNotice: String?
    @Published private(set) var contentDiagnostics = EPUBContentDiagnostics()
    @Published private(set) var isScanningDiagnostics = false
    @Published private(set) var diagnosticsComplete = false
    @Published private(set) var diagnosticDocumentCount = 0
    @Published private(set) var embeddedTOCCount = 0
    @Published private(set) var tocReadFailed = false
    @Published var isTOCDiagnosticsExpanded = false
    @Published private(set) var locator: Locator?
    @Published private(set) var style = EPUBReaderStyle()
    @Published private(set) var isDarkMode = false
    /// 每次重建导航器递增，让宿主视图换上新的控制器。
    @Published private(set) var navigatorRevision = 0
    /// 各章节 WebView 读到的书籍 html/body 底色（WebView 释放后自动移除）。
    /// 书籍底色只画在 WebView 内；把它涂在包住 WebView 的整屏章节视图上，四周边距就随书页一起滑动，
    /// 翻页时不必等位置回报后再换色。
    private let pageBackgrounds = NSMapTable<WKWebView, UIColor>.weakToStrongObjects()
    /// 观察各 WebView 的加载状态，每次加载完成后重新读取底色。
    private let pageLoadObservations = NSMapTable<WKWebView, NSKeyValueObservation>.weakToStrongObjects()
    @Published var activeNote: EPUBNote?
    /// 书内图片（点图查看与目录页“图片”）；EPUB 复用打开前预检的原生容器读取图片。
    let imageLibrary = ReaderImageLibrary()
    private var imageContainer: EPUBContainer?

#if DEBUG
    /// 仅独立验证 App 的合成 EPUB 回归使用。WebKit 无障碍树可能包含已翻过的段落，
    /// 因此从 DOM 的实际可见矩形采集编号，不能用无障碍元素“存在”判断正文连续性。
    @Published private(set) var validationVisibleParagraphs = ""
    var validatesPagination: Bool {
        Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation"
            && ProcessInfo.processInfo.arguments.contains("-architecturePagination")
    }

    private func refreshPaginationValidation() {
        guard validatesPagination, let navigator else { return }
        let location = locator
        Task { [weak self, weak navigator] in
            guard let navigator else { return }
            let result = await navigator.evaluateJavaScript("""
                JSON.stringify(Array.from(document.querySelectorAll('p[data-pagination-marker]'))
                  .filter(p => { const r = p.getBoundingClientRect();
                    return r.right > 0 && r.left < window.innerWidth && r.bottom > 0 && r.top < window.innerHeight; })
                  .map(p => Number(p.dataset.paginationMarker)))
                """)
            guard let self, self.navigator === navigator, self.locator == location,
                  case .success(let value) = result, let text = value as? String else { return }
            self.validationVisibleParagraphs = text
        }
    }
#endif

    private(set) var navigator: EPUBNavigatorViewController?
    private var publication: Publication?
    private var navigationIndex: ReadiumNavigationIndex?
    @Published private(set) var currentTOCIndex: Int?
    private var textBook: PagedTextBook?
    private var textPositionTask: Task<Void, Never>?
    private var receivedTextLocation = false
    /// EPUB 打开后导航器报告的第一个位置就是恢复的位置，不写入，避免刷新同步时间戳。
    private var receivedBookLocation = false
    @Published private(set) var textLoadFailure: String?
    private var failedTextHref: RelativeURL?

    private var bookHash: String?
    private var positionCount = 0
    private var navigationAdapter: DirectionalNavigationAdapter?
    private var tapToken: InputObservableToken?
    private var gestureToken: InputObservableToken?
    /// 点按正文中部（非翻页区域）时调用。
    var onCenterTap: () -> Void = {}

    private static let styleDefaultsKey = ReaderSettings.epubStyleKey

    private let settings: ReaderSettings

    init(settings: ReaderSettings) {
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: Self.styleDefaultsKey),
           let saved = try? JSONDecoder().decode(EPUBReaderStyle.self, from: data) {
            style = saved
        }
        style.fontSize = CGFloat(settings.fontSize)
    }

    // MARK: 打开

    func open(url: URL, systemIsDark: Bool) async {
        guard status == .idle else { return }
        status = .opening
        isDarkMode = settings.isDark(systemIsDark: systemIsDark)
        do {
            // 打开前先走原生容器：空 spine 会让 Readium streamer 崩溃，
            // 缺失／损坏章节会让导航器一直停在加载态，预检把它们变成可读错误。
            let container = try await EPUBContainer.open(fileURL: url)
            try await container.validateForReadium()
            imageContainer = container
            imageLibrary.attach(container)
            let hash = try await Task.detached(priority: .utility) {
                try FileContentHash.sha256(url)
            }.value
            bookHash = hash
            isTOCDiagnosticsExpanded = false
            let publication = try await Self.openPublication(
                url: url, disablesScripts: UserDefaults.standard.bool(forKey: SettingsKey.readerEPUBDisablesScripts))
            self.publication = publication
            bookTitle = publication.metadata.title ?? url.deletingPathExtension().lastPathComponent
            if case .success(let positions) = await publication.positions() {
                positionCount = positions.count
                let index = ReadiumNavigationIndex(readingOrder: publication.readingOrder, tableOfContents: [])
                positionsPerResource = positions.reduce(into: [:]) { counts, locator in
                    if let resource = index.resourceIndex(for: locator.href) { counts[resource, default: 0] += 1 }
                }
            }
            var embedded: [ReadiumTOCItem] = []
            if case .success(let links) = await publication.tableOfContents() {
                embedded = Self.flatten(links)
            } else {
                tocReadFailed = true
            }
            embeddedTOCCount = embedded.count
            toc = await preferGeneratedTOCIfSparse(embedded, publication: publication)
            navigationIndex = ReadiumNavigationIndex(readingOrder: publication.readingOrder,
                                                     tableOfContents: toc.map(\.link))
            let initial = await savedLocator(publication: publication, hash: hash)
            try makeNavigator(initialLocation: initial)
            status = .ready
            Self.shareable.notice(ReaderDiagnosticMessage.readiumOpened(resources: publication.readingOrder.count, positions: positionCount))
        } catch {
            Self.logger.error("Readium EPUB open failed: \(String(describing: error), privacy: .public)")
            status = .failed(Self.describe(error))
        }
    }

    /// 失败页的「重新打开」：仅用于打开 EPUB 文件失败（文本章节失败走 retryTextLoad）。
    func retryOpening(url: URL) {
        guard case .failed = status, textBook == nil else { return }
        status = .idle
        Task { await open(url: url, systemIsDark: isDarkMode) }
    }

    /// 惰性 Publication 不走 EPUB 文件解析，也不写入 EPUB 的进度命名空间。
    func open(textBook: PagedTextBook, systemIsDark: Bool) async {
        guard status == .idle, let source = textBook.source as? TextChapterSource else { return }
        status = .opening
        self.textBook = textBook
        isDarkMode = settings.isDark(systemIsDark: systemIsDark)
        do {
            let publication = ReadiumTextPublication.make(source: source)
            self.publication = publication
            bookTitle = source.bookTitle
            toc = Self.flatten(publication.manifest.tableOfContents)
            embeddedTOCCount = toc.count
            positionCount = source.chapterCount
            navigationIndex = ReadiumNavigationIndex(readingOrder: publication.readingOrder,
                                                     tableOfContents: toc.map(\.link))
            guard !publication.readingOrder.isEmpty else { throw ReadiumOpenError.parse("没有可阅读的章节。") }
            let unit = min(max(0, textBook.startUnit), source.chapterCount - 1)
            let initial = try await ReadiumTextPublication.initialLocation(
                publication: publication, source: source, unit: unit, offset: textBook.startOffset,
                identity: textBook.readiumIdentity, updatedAt: textBook.positionUpdatedAt)
            try Task.checkCancellation()
            try makeNavigator(initialLocation: initial)
            status = .ready
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    func retryTextLoad() {
        guard textBook != nil else { return }
        textLoadFailure = nil
        if status != .ready, let book = textBook {
            status = .idle
            Task { await open(textBook: book, systemIsDark: isDarkMode) }
            return
        }
        let target = failedTextHref.map { Locator(href: $0, mediaType: .xhtml) }
            ?? navigator?.currentLocation ?? locator
        failedTextHref = nil
        markNavigation("rebuild")
        do { try makeNavigator(initialLocation: target) }
        catch { textLoadFailure = Self.describe(error) }
    }

    /// 取消过期页面回调，避免慢章节的换算覆盖已经翻到的新位置。
    private func saveTextPosition(_ location: Locator) {
        guard let book = textBook, let source = book.source as? TextChapterSource,
              let unit = navigationIndex?.resourceIndex(for: location.href) else { return }
        // 打开或恢复页面时不刷新同步时间戳。
        if !receivedTextLocation {
            receivedTextLocation = true
            if book.readiumIdentity != nil { return }
        }
        textPositionTask?.cancel()
        textPositionTask = Task { [weak self] in
            guard let html = try? await source.chapterHTML(at: unit), !Task.isCancelled,
                  let self, self.locator == location else { return }
            let length = EPUBChapterProgress.textLength(html: html)
            let progression = min(1, max(0, location.locations.progression ?? 0))
            book.onPosition(unit, EPUBChapterProgress.offset(progression: progression, length: length))
            if let identity = book.readiumIdentity, let json = try? location.jsonString() {
                UserDefaults.standard.set(json, forKey: ReadiumLocatorKeys.textLocator(identity: identity))
                // 回调可能更新同步位置，精确 Locator 的时间在它之后记录。
                UserDefaults.standard.set(Date(), forKey: ReadiumLocatorKeys.textTime(identity: identity))
            }
        }
    }

    /// 读取清单中的所有本地资源，包括未读章节和独立资源文件。
    /// 仅展示实际失败；此扫描不请求外部 URL。
    func scanBookDiagnostics() async {
        guard textBook == nil, !diagnosticsComplete, !isScanningDiagnostics, let publication else { return }
        isScanningDiagnostics = true
        defer { isScanningDiagnostics = false }
        var seen = Set<String>()
        let documents = (publication.readingOrder + publication.resources).filter { link in
            let href = link.url().removingFragment().string
            guard !href.lowercased().hasPrefix("http:"), !href.lowercased().hasPrefix("https:"), !href.hasPrefix("//") else { return false }
            return seen.insert(href).inserted
        }
        diagnosticDocumentCount = documents.count
        var report = EPUBContentDiagnostics()
        for link in documents {
            guard !Task.isCancelled else { return }
            let href = link.url().removingFragment().string
            guard let resource = publication.get(link) else {
                report.recordFailure(path: href, reason: "未找到该资源。")
                contentDiagnostics = report
                continue
            }
            let error: ReadError?
            // 以流方式读取每个资源，避免保留完整图片或字体，也不强制
            // 将有效的非 UTF-8 文档交给诊断扫描器的文本解码器。
            switch await resource.stream(consume: { _ in }) {
            case .success: error = nil
            case .failure(let failure): error = failure
            }
            guard !Task.isCancelled else { return }
            if let error {
                if case .cancelled = error { return }
                report.recordFailure(path: href, reason: Self.diagnosticReason(error))
            } else {
                report.recordSuccess(path: href)
            }
            contentDiagnostics = report
        }
        guard !Task.isCancelled else { return }
        diagnosticsComplete = true
    }

    private static func diagnosticReason(_ error: ReadError) -> String {
        switch error {
        case .access: return "无法访问书内文件，文件可能缺失、损坏或受保护。"
        case .decoding: return "内容无法解码，文本编码或压缩数据可能损坏。"
        case .outOfMemory: return "资源过大，无法在可用内存中完成读取。"
        case .unsupportedOperation: return "阅读器不支持该资源的读取方式。"
        case .cancelled: return "读取已取消。"
        }
    }

    var tocDiagnosticMessages: [String] {
        var messages: [String] = []
        if tocReadFailed { messages.append("Readium 内嵌目录读取失败。") }
        if toc.count > embeddedTOCCount, let notice = tocNotice { messages.append(notice) }
        messages.append(contentsOf: contentDiagnostics.messages)
        return messages
    }

    /// `disablesScripts` 为 true 时（“禁用书内脚本”）章节文档去掉脚本并隐藏弹出式脚注正文、脚本文件置空，见 `EPUBScriptRemoval`。
    private static func openPublication(url: URL, disablesScripts: Bool) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else { throw ReadiumOpenError.invalidURL }
        let retriever = AssetRetriever(httpClient: DefaultHTTPClient())
        let asset: Asset
        switch await retriever.retrieve(url: fileURL, mediaType: .epub) {
        case .success(let value): asset = value
        case .failure(let error): throw ReadiumOpenError.asset(String(describing: error))
        }
        let opener = PublicationOpener(parser: EPUBParser())
        let transform: Publication.Builder.Transform = { manifest, container, _ in
            let reflowable = manifest.metadata.layout != .fixed
            container = container.map { href, resource in
                let path = href.removingFragment().removingQuery().path
                if disablesScripts, EPUBScriptRemoval.isScriptResource(path: path) {
                    return resource.map { _ in Data() }
                }
                guard EPUBScriptRemoval.isHTMLResource(path: path) else { return resource }
                return resource.map { data in
                    // 无法按 UTF-8 解码时保留原文，避免整章变空。
                    guard let html = String(data: data, encoding: .utf8) else { return data }
                    var result = html
                    if reflowable {
                        result = EPUBReadiumImageLayout.keepingStandaloneImagesTogether(inHTML: result)
                    }
                    if disablesScripts {
                        result = EPUBScriptRemoval.removingScripts(fromHTML: result)
                        result = EPUBScriptRemoval.hidingPopupNoteBodies(inHTML: result)
                    }
                    return Data(result.utf8)
                }
            }
        }
        switch await opener.open(asset: asset, allowUserInteraction: false, onCreatePublication: transform) {
        case .success(let publication): return publication
        case .failure(let error): throw ReadiumOpenError.parse(String(describing: error))
        }
    }

    private static func flatten(_ links: [ReadiumShared.Link], level: Int = 0, into items: inout [ReadiumTOCItem]) {
        for link in links {
            items.append(ReadiumTOCItem(id: items.count, title: link.title ?? link.href, level: level, link: link))
            flatten(link.children, level: level + 1, into: &items)
        }
    }

    private static func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumTOCItem] {
        var items: [ReadiumTOCItem] = []
        flatten(links, into: &items)
        return items
    }

    /// 与 YueduCoreText 阅读器相同的兜底：内嵌目录不超过一项（常见只有版权页或封面）时，
    /// 按 `EPUBContainer.fallbackTOCHeadings` 的规则从各章节正文识别标题生成备用目录。
    private func preferGeneratedTOCIfSparse(_ embedded: [ReadiumTOCItem],
                                            publication: Publication) async -> [ReadiumTOCItem] {
        guard embedded.count <= 1 else { return embedded }
        var generated: [ReadiumTOCItem] = []
        var seenTitles = Set<String>()
        for link in publication.readingOrder where link.mediaType?.isHTML ?? true {
            guard let resource = publication.get(link),
                  case .success(let html) = await resource.read().asString(),
                  let title = EPUBContainer.fallbackTOCHeadings(inChapterHTML: html)
                      .first(where: { seenTitles.insert($0).inserted }) else { continue }
            generated.append(ReadiumTOCItem(id: generated.count, title: title, level: 0, link: link))
        }
        guard generated.count > embedded.count else {
            if embedded.isEmpty {
                tocNotice = "本书没有内嵌目录，正文中也未识别到「序章／第N章／终章」等章节标题。"
            }
            return embedded
        }
        if embedded.isEmpty {
            tocNotice = "本书没有内嵌目录，已根据正文标题生成备用目录，共 \(generated.count) 项。"
        } else {
            let titles = embedded.map(\.title).joined(separator: "、")
            tocNotice = "原书内嵌目录只有 \(embedded.count) 项（\(titles)），已根据正文标题生成备用目录，共 \(generated.count) 项。"
        }
        Self.logger.info("Readium TOC fallback generated \(generated.count, privacy: .public) entries, embedded \(embedded.count, privacy: .public)")
        return generated
    }

    // MARK: 导航器

    private func makeNavigator(initialLocation: Locator?) throws {
        guard let publication else { return }
        var config = EPUBNavigatorViewController.Configuration(
            preferences: preferences(),
            fontFamilyDeclarations: Self.importedFontDeclarations()
        )
        config.readiumCSSRSProperties.pageGutter = CSSPxLength(Double(style.leftMargin + style.rightMargin) / 2)
        config.readiumCSSRSProperties.textColor = CSSIntColor(Self.rgb(themeTextColor))
        // 根背景透明：书籍未设背景时露出宿主绘制的阅读背景；书籍给 body 设的背景
        // （如 `<body bgcolor>`）按 CSS 规则延伸到整个页面。
        config.readiumCSSRSProperties.backgroundColor = TransparentCSSColor()
        let navigator = try EPUBNavigatorViewController(
            publication: publication, initialLocation: initialLocation, config: config)
        navigator.delegate = self

        // 先于翻页适配器注册且不消费事件：只记下点按，供位置日志区分用户翻页与 Readium 自行移动。
        gestureToken = navigator.addObserver(.tap { [weak self] _ in
            self?.noteGesture("tap")
            return false
        })
        let adapter = DirectionalNavigationAdapter(animatedTransition: true)
        adapter.bind(to: navigator)
        navigationAdapter = adapter
        // 翻页区域之外（中部）的点按：点到正文图片时打开查看器，否则显隐工具栏；
        // 适配器已处理的边缘点按不会到这里。
        tapToken = navigator.addObserver(.tap { [weak self] event in
            guard let self else { return false }
            if await self.openImage(at: event.location) { return true }
            self.onCenterTap()
            return true
        })

        self.navigator = navigator
        redirectedOperation = nil
        pendingLocationCause = nil
        navigatorRevision += 1
    }

    /// 在导航器视图坐标处查找正文图片（`<img>` 或 SVG `<image>`，边长不足 32pt 的小图不算），
    /// 找到则按包内路径打开查看器。
    private func openImage(at point: CGPoint) async -> Bool {
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
    private static func visibleWebView(containing point: CGPoint, in root: UIView) -> (WKWebView, CGPoint)? {
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

    /// 样式中只有边距和导入字体需要重建导航器；其余偏好可直接提交。
    private func rebuildNavigator() {
        markNavigation("rebuild")
        let location = navigator?.currentLocation ?? locator
        do {
            try makeNavigator(initialLocation: location)
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    private func preferences() -> EPUBPreferences {
        // 不提交背景色与文字色：ReadiumCSS 会以 !important 把它们套到所有元素，
        // 抹掉书内的配色、白字光晕与元素背景。背景由宿主绘制（HTML 根透明），
        // 默认文字色经 RS__textColor 设定（见 makeNavigator），书内颜色可正常覆盖。
        // 深色模式仍用 Readium 夜间主题，强制可读的浅色文字。
        // 行距、段距、缩进属于 ReadiumCSS 的“高级设置”，需关闭出版社样式才生效；
        // 保持默认时沿用书籍原有 CSS。
        let overridesBook = style.lineSpacing > 0 || style.paragraphSpacing > 0 || style.firstLineIndentEm != nil
        let fontSize = Double(style.fontSize)
        return EPUBPreferences(
            fontFamily: style.fontFamily.map { FontFamily(rawValue: $0) },
            // WebKit 中 1 CSS px = 1 pt；浏览器默认根字号 16px。
            fontSize: fontSize / 16,
            lineHeight: style.lineSpacing > 0 ? 1.5 + Double(style.lineSpacing) / fontSize : nil,
            paragraphIndent: style.firstLineIndentEm.map { Double($0) },
            paragraphSpacing: style.paragraphSpacing > 0 ? Double(style.paragraphSpacing) / fontSize : nil,
            publisherStyles: !overridesBook,
            scroll: false,
            spread: style.doublePage == true ? .always : .never,
            theme: isDarkMode ? .dark : .light
        )
    }

    private var themeTextColor: UIColor {
        UIColor(settings.appearance.primaryText(system: isDarkMode ? .dark : .light))
    }

    private static func rgb(_ color: UIColor) -> Int {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return (channel(red) << 16) | (channel(green) << 8) | channel(blue)
    }

    private static func importedFontDeclarations() -> [AnyHTMLFontFamilyDeclaration] {
        EPUBLocalFonts.importedFonts().compactMap { font in
            guard let file = FileURL(url: font.url) else { return nil }
            return CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: font.family),
                fontFaces: [CSSFontFace(file: file)]
            ).eraseToAnyHTMLFontFamilyDeclaration()
        }
    }

    // MARK: 设置

    func synchronizeSharedSettings(systemIsDark: Bool) {
        let settings = self.settings
        let dark = settings.isDark(systemIsDark: systemIsDark)
        let font = CGFloat(settings.fontSize)
        guard dark != isDarkMode || font != style.fontSize else { return }
        let themeChanged = dark != isDarkMode
        isDarkMode = dark
        style.fontSize = font
        // 默认文字色属于导航器配置，切换深浅色需要重建。
        if themeChanged, navigator != nil {
            rebuildNavigator()
        } else {
            markNavigation("preferences")
            navigator?.submitPreferences(preferences())
        }
    }

    /// 背景颜色变化后重新提交偏好（背景图由宿主视图绘制在导航器之下）。
    func refreshBackground() {
        markNavigation("preferences")
        navigator?.submitPreferences(preferences())
        reapplyPageBackgrounds()
    }

    func applyStyle(_ requested: EPUBReaderStyle) {
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
        let needsRebuild = updated.topMargin != style.topMargin || updated.bottomMargin != style.bottomMargin
            || updated.leftMargin != style.leftMargin || updated.rightMargin != style.rightMargin
            || updated.fontFamily != style.fontFamily
        style = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.styleDefaultsKey)
        }
        settings.fontSize = Double(updated.fontSize)
        if needsRebuild {
            rebuildNavigator()
        } else {
            markNavigation("preferences")
            navigator?.submitPreferences(preferences())
        }
    }

    // MARK: 导航

    func goForward() {
        markNavigation("turnForward")
        Task { _ = await navigator?.goForward(options: .animated) }
    }
    func goBackward() {
        markNavigation("turnBackward")
        Task { _ = await navigator?.goBackward(options: .animated) }
    }

    func jump(to item: ReadiumTOCItem) {
        markNavigation("navigate")
        Task { _ = await navigator?.go(to: item.link) }
    }

    // MARK: 位置诊断

    /// 匿名标识仅在此阅读器实例内有效；导航器重建另由 navigatorRevision 区分。
    private let diagnosticSession = DiagnosticContext.newTraceID()
    private var diagnosticOperation = 0
    /// 导航来源在下一次位置回报时取用并清空；超过 3 秒视为过期。
    /// 点按和拖动观察者也注册来源，未能关联时记为 unattributed。
    private var pendingLocationCause: (cause: String, time: ContinuousClock.Instant)?
    private let diagnosticViews = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    private var nextDiagnosticView = 0
    private var redirectedOperation: Int?

    private func markNavigation(_ cause: String) {
        diagnosticOperation += 1
        pendingLocationCause = (cause, .now)
    }

    /// 记录每次位置变化（包括普通翻页），使分享日志能还原跳页前后的操作顺序。只含序号与比例，不含正文。
    private func logLocationChange(from previous: Locator?, to current: Locator) {
        guard previous != current else { return }
        var cause = "unattributed"
        if previous == nil {
            cause = "open"
        } else if let pending = pendingLocationCause, ContinuousClock.now - pending.time < .seconds(3) {
            cause = pending.cause
        }
        pendingLocationCause = nil
        let kind = textBook == nil ? "epub" : (textBook?.bookmarkKey == nil ? "online" : "txt")
        func resource(_ locator: Locator?) -> Int { locator.flatMap { navigationIndex?.resourceIndex(for: $0.href) } ?? -1 }
        func permille(_ value: Double?) -> Int { value.map { Int((min(max($0, 0), 1) * 1000).rounded()) } ?? -1 }
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

    /// 本次阅读器会话中 Readium 新建章节 WebView 的次数。
    private var createdWebViews = 0
    /// 章节 WebView 与章节间滚动视图的拖动手势观察者。
    private lazy var gestureProbe = ReadiumGestureProbe { [weak self] recognizer in self?.swipeBegan(recognizer) }

    /// Readium 用两层横向滚动视图：章节 WebView 自己的滚动视图负责章内翻页，外层分页视图负责切换章节。
    /// 拖动从 WebView 以外的区域开始（上下页边距、章节标题栏区域）时只有外层能响应，会直接切到相邻章节，
    /// 跳过本章剩余页面。因此外层开始拖动时，若本章在该方向上仍有页面，就取消这次拖动并改为章内翻一页；
    /// 已在章首或章末时保留外层的切章行为。
    private func swipeBegan(_ recognizer: UIPanGestureRecognizer) {
        guard let scrollView = recognizer.view as? UIScrollView else { return }
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
    private func chapterPageSelection() -> (page: WKWebView?, count: Int) {
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

    private func noteGesture(_ gesture: String) {
        markNavigation(gesture)
        logPageState(when: gesture)
    }

    /// 分别记录模型资源和页面实际资源；仅使用匿名会话/View 序号，不输出 URL。
    private func logPageState(when: String, operation: Int? = nil) {
        let selection = chapterPageSelection()
        logPageState(when: when, page: selection.page, candidates: selection.count, operation: operation)
    }

    private func logPageState(when: String, page: WKWebView?, candidates: Int, operation: Int? = nil) {
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

    // MARK: 书签与书内搜索

    /// 每个阅读顺序资源的位置数，用来估计当前页在章内的范围。
    private var positionsPerResource: [Int: Int] = [:]

    /// 书签与搜索使用的书籍身份：EPUB 为 `epub:<文件哈希>`，本地 TXT 为 `txt:<文件哈希>`；在线小说为 nil。
    var bookmarkKey: String? { bookHash.map { "epub:\($0)" } ?? textBook?.bookmarkKey }

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
        guard let spine = entry.spineIndex, let index = readingOrderIndex(forSpine: spine),
              let publication else { return }
        markNavigation("navigate")
        Task { [weak self] in
            guard let base = await publication.locate(publication.readingOrder[index]) else { return }
            _ = await self?.navigator?.go(to: base.copy(locations: { $0.progression = 0 }))
            for _ in 0..<10 {
                guard let self else { return }
                if await scrollToImage(path: entry.path) { return }
                try? await Task.sleep(for: .milliseconds(150))
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

    /// 跳到书签或搜索结果；导航器报告新位置后照常记录阅读进度。
    func jump(toChapter index: Int, progression: Double) {
        guard let publication, publication.readingOrder.indices.contains(index) else { return }
        markNavigation("navigate")
        Task {
            guard let base = await publication.locate(publication.readingOrder[index]) else { return }
            _ = await navigator?.go(to: base.copy(locations: { $0.progression = min(1, max(0, progression)) }))
        }
    }

    func seek(to progression: Double) {
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

    var currentChapterTitle: String {
        if let index = currentTOCIndex, toc.indices.contains(index) { return toc[index].title }
        return locator?.title ?? bookTitle
    }

    // MARK: 进度

    private var locatorKey: String? { bookHash.map(ReadiumLocatorKeys.bookLocator(hash:)) }
    private var locatorTimeKey: String? { bookHash.map(ReadiumLocatorKeys.bookTime(hash:)) }

    private func save(_ locator: Locator) {
        guard let hash = bookHash,
              let key = locatorKey, let timeKey = locatorTimeKey,
              let json = try? locator.jsonString() else { return }
        UserDefaults.standard.set(json, forKey: key)
        UserDefaults.standard.set(Date(), forKey: timeKey)
        let spine = navigationIndex?.resourceIndex(for: locator.href) ?? 0
        settings.recordEPUBPosition(
            hash: hash, fraction: locator.locations.totalProgression ?? 0,
            spineIndex: spine, chapterOffset: nil, chapterProgression: locator.locations.progression)
    }

    /// 本机 Locator 优先；若 WebDAV 合并来的位置更新（例如来自旧引擎或其他设备），改按其恢复。
    private func savedLocator(publication: Publication, hash: String) async -> Locator? {
        let defaults = UserDefaults.standard
        let synced = settings.epubPosition(hash: hash)
        if let key = locatorKey, let json = defaults.string(forKey: key),
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

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - 导航器回调

extension ReadiumEPUBReaderModel: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard (navigator as AnyObject) === self.navigator else { return }
        let previous = self.locator
        logLocationChange(from: previous, to: locator)
        let current = navigationIndex?.tocIndex(for: locator.href)
        if currentTOCIndex != current { currentTOCIndex = current }
        self.locator = locator
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
        (navigator as? UIViewController)?.view.backgroundColor = .clear
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        Self.logger.error("Readium navigator error: \(String(describing: error), privacy: .public)")
    }

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
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
            }
        }
        pageLoadObservations.setObject(observation, forKey: webView)
    }

    private func readPageBackground(of webView: WKWebView) {
        let script = """
            (function () {
              function bg(el) { return el ? getComputedStyle(el).backgroundColor : ''; }
              var root = bg(document.documentElement);
              return /^rgba?\\(/.test(root) && !/,\\s*0\\)$/.test(root) ? root : bg(document.body);
            })()
            """
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
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
    private func reapplyPageBackgrounds() {
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
private struct TransparentCSSColor: CSSColor {
    func css() -> String? { "transparent" }
}


/// 给 Readium 内部滚动视图的拖动手势追加观察目标，只在开始拖动时回调（是否取消由回调决定）；
/// 已附加的手势用弱引用集合去重。
@MainActor
private final class ReadiumGestureProbe: NSObject {
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
