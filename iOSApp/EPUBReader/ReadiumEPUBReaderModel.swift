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
// 水平滑动。TXT 与在线章节仍走 YueduCoreText（EPUBReaderModel）。
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

    static let logger = Logger(subsystem: "Novelia", category: "ReadiumEPUB")

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
    @Published var activeNote: EPUBNote?

    private(set) var navigator: EPUBNavigatorViewController?
    private var publication: Publication?
    private var bookHash: String?
    private var positionCount = 0
    private var navigationAdapter: DirectionalNavigationAdapter?
    private var tapToken: InputObservableToken?
    /// 点按正文中部（非翻页区域）时调用。
    var onCenterTap: () -> Void = {}

    private static let styleDefaultsKey = ReaderSettings.epubStyleKey

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.styleDefaultsKey),
           let saved = try? JSONDecoder().decode(EPUBReaderStyle.self, from: data) {
            style = saved
        }
        style.fontSize = CGFloat(ReaderSettings.shared.fontSize)
    }

    // MARK: 打开

    func open(url: URL, systemIsDark: Bool) async {
        guard status == .idle else { return }
        status = .opening
        isDarkMode = ReaderSettings.shared.isDark(systemIsDark: systemIsDark)
        do {
            let hash = try await Task.detached(priority: .utility) {
                try WebDAVFileHash.sha256(url)
            }.value
            bookHash = hash
            isTOCDiagnosticsExpanded = false
            let publication = try await Self.openPublication(url: url)
            self.publication = publication
            bookTitle = publication.metadata.title ?? url.deletingPathExtension().lastPathComponent
            if case .success(let positions) = await publication.positions() {
                positionCount = positions.count
            }
            var embedded: [ReadiumTOCItem] = []
            if case .success(let links) = await publication.tableOfContents() {
                embedded = Self.flatten(links)
            } else {
                tocReadFailed = true
            }
            embeddedTOCCount = embedded.count
            toc = await preferGeneratedTOCIfSparse(embedded, publication: publication)
            let initial = await savedLocator(publication: publication, hash: hash)
            try makeNavigator(initialLocation: initial)
            status = .ready
            Self.logger.info("Readium EPUB opened: \(publication.readingOrder.count, privacy: .public) resources, \(self.positionCount, privacy: .public) positions")
        } catch {
            Self.logger.error("Readium EPUB open failed: \(String(describing: error), privacy: .public)")
            status = .failed(Self.describe(error))
        }
    }

    /// Read every local manifest resource, including unread chapters and independent assets.
    /// Only actual failures are published. No external URL is fetched by this scan.
    func scanBookDiagnostics() async {
        guard !diagnosticsComplete, !isScanningDiagnostics, let publication else { return }
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
            // Read every resource as a stream, without retaining full images/fonts or forcing
            // valid non-UTF8 documents through the diagnostic scanner's text decoder.
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

    private static func openPublication(url: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else { throw ReadiumOpenError.invalidURL }
        let retriever = AssetRetriever(httpClient: DefaultHTTPClient())
        let asset: Asset
        switch await retriever.retrieve(url: fileURL, mediaType: .epub) {
        case .success(let value): asset = value
        case .failure(let error): throw ReadiumOpenError.asset(String(describing: error))
        }
        let opener = PublicationOpener(parser: EPUBParser())
        switch await opener.open(asset: asset, allowUserInteraction: false) {
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

        let adapter = DirectionalNavigationAdapter(animatedTransition: true)
        adapter.bind(to: navigator)
        navigationAdapter = adapter
        // 翻页区域之外（中部）的点按显隐工具栏；适配器已处理的边缘点按不会到这里。
        tapToken = navigator.addObserver(.tap { [weak self] _ in
            self?.onCenterTap()
            return true
        })

        self.navigator = navigator
        navigatorRevision += 1
    }

    /// 样式中只有边距和导入字体需要重建导航器；其余偏好可直接提交。
    private func rebuildNavigator() {
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
        UIColor(ReaderSettings.shared.appearance.primaryText(system: isDarkMode ? .dark : .light))
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
        let settings = ReaderSettings.shared
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
            navigator?.submitPreferences(preferences())
        }
    }

    /// 背景颜色变化后重新提交偏好（背景图由宿主视图绘制在导航器之下）。
    func refreshBackground() {
        navigator?.submitPreferences(preferences())
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
        ReaderSettings.shared.fontSize = Double(updated.fontSize)
        if needsRebuild {
            rebuildNavigator()
        } else {
            navigator?.submitPreferences(preferences())
        }
    }

    // MARK: 导航

    func goForward() { Task { _ = await navigator?.goForward(options: .animated) } }
    func goBackward() { Task { _ = await navigator?.goBackward(options: .animated) } }

    func jump(to item: ReadiumTOCItem) {
        Task { _ = await navigator?.go(to: item.link) }
    }

    func seek(to progression: Double) {
        guard let publication else { return }
        Task {
            if let target = await publication.locate(progression: min(max(progression, 0), 1)) {
                _ = await navigator?.go(to: target)
            }
        }
    }

    var overallProgress: Double { locator?.locations.totalProgression ?? 0 }

    var locationDescription: String {
        guard let position = locator?.locations.position, positionCount > 0 else {
            return "\(Int((overallProgress * 100).rounded()))%"
        }
        return "\(position) / \(positionCount)"
    }

    /// 当前所在目录项：同一资源内取最后一个不晚于当前位置的条目。
    var currentTOCIndex: Int? {
        guard let locator, let publication else { return nil }
        let href = locator.href.string
        guard let currentResource = publication.readingOrder.firstIndexWithHREF(locator.href) else {
            return toc.lastIndex { $0.link.url().removingFragment().string == href }
        }
        var best: Int?
        for item in toc {
            guard let index = publication.readingOrder.firstIndexWithHREF(item.link.url().removingFragment()),
                  index <= currentResource else { continue }
            best = item.id
        }
        return best
    }

    var currentChapterTitle: String {
        if let index = currentTOCIndex, toc.indices.contains(index) { return toc[index].title }
        return locator?.title ?? bookTitle
    }

    // MARK: 进度

    private var locatorKey: String? { bookHash.map { "readium.locator.v1.\($0)" } }
    private var locatorTimeKey: String? { bookHash.map { "readium.locatorTime.v1.\($0)" } }

    private func save(_ locator: Locator) {
        guard let hash = bookHash, let publication,
              let key = locatorKey, let timeKey = locatorTimeKey,
              let json = try? locator.jsonString() else { return }
        UserDefaults.standard.set(json, forKey: key)
        UserDefaults.standard.set(Date(), forKey: timeKey)
        let spine = publication.readingOrder.firstIndexWithHREF(locator.href) ?? 0
        ReaderSettings.shared.recordEPUBPosition(
            hash: hash, fraction: locator.locations.totalProgression ?? 0,
            spineIndex: spine, chapterOffset: nil, chapterProgression: locator.locations.progression)
    }

    /// 本机 Locator 优先；若 WebDAV 合并来的位置更新（例如来自旧引擎或其他设备），改按其恢复。
    private func savedLocator(publication: Publication, hash: String) async -> Locator? {
        let defaults = UserDefaults.standard
        let synced = ReaderSettings.shared.epubPosition(hash: hash)
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
            // Neither: e.g. written by 0.12.0 (54); the whole-book fraction below is closer than the chapter start.
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
        self.locator = locator
        save(locator)
        makeWebViewsTransparent()
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
        Self.logger.error("Readium failed to load \(href.string, privacy: .private): \(String(describing: error), privacy: .public)")
    }

    /// 注脚不跳转，改为底部弹层显示纯文本。
    func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: ReadiumShared.Link, content: String, referrer: String?) -> Bool {
        let text = Self.plainText(fromHTML: content)
        activeNote = EPUBNote(text: text.isEmpty ? "（注释内容为空）" : text)
        return false
    }

    /// 新章节的 WebView 创建时触发（此时已开始加载，注入的脚本不保证作用于当页，
    /// 所以根背景透明改由 RS__backgroundColor 在 HTML 注入阶段完成，见 makeNavigator）。
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        // 此回调在新章节的 WebView 创建时触发；待其加入视图层级后再设为透明。
        DispatchQueue.main.async { [weak self] in self?.makeWebViewsTransparent() }
    }

    /// Readium 只为固定版式书籍关闭 WebView 的不透明绘制；流式书籍的 WebView 会画出
    /// 自己的底色盖住阅读背景，因此逐个关闭。
    private func makeWebViewsTransparent() {
        guard let root = navigator?.view else { return }
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let webView = view as? WKWebView, webView.isOpaque {
                webView.isOpaque = false
                webView.underPageBackgroundColor = .clear
            }
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
