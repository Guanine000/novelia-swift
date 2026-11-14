import Combine
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

    @Published var status: Status = .idle
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
    @Published var readingTimePoint = ReadingTimePoint.start
    @Published var locator: Locator?
    @Published private(set) var style = EPUBReaderStyle()
    @Published private(set) var isDarkMode = false
    /// 每次重建导航器递增，让宿主视图换上新的控制器。
    @Published private(set) var navigatorRevision = 0
    /// 朗读控制器：每本书独立实例，不恢复全局 shared。
    let speech = SpeechPlaybackController()
    var speechSelection: (any SpeechEngineSelecting)?
    private var lastSpeechDecorationTap = Date.distantPast
    /// 各章节 WebView 读到的书籍 html/body 底色（WebView 释放后自动移除）。
    /// 书籍底色只画在 WebView 内；把它涂在包住 WebView 的整屏章节视图上，四周边距就随书页一起滑动，
    /// 翻页时不必等位置回报后再换色。
    let pageBackgrounds = NSMapTable<WKWebView, UIColor>.weakToStrongObjects()
    /// 观察各 WebView 的加载状态，每次加载完成后重新读取底色。
    let pageLoadObservations = NSMapTable<WKWebView, NSKeyValueObservation>.weakToStrongObjects()
    @Published var activeNote: EPUBNote?
    var lastAnnotationDecorationTap = Date.distantPast
    /// 点按正文高亮时打开的标注编辑面板；保存/删除都写回同一份 ReaderAnnotationStore。
    @Published var activeAnnotation: ReaderAnnotation?
    @Published var annotationError: String?
#if DEBUG
    /// 独立验证 App 检查重开书后标注装饰是否重新套用。
    @Published var appliedAnnotationDecorationCount = 0
#endif
    /// 当前章节已套用的标注；章节切换或标注变化时重算，避免每次位置回报都重扫正文。
    var annotationDecorationChapter: Int?
    var annotationRefreshGeneration = UUID()
    /// 最近一次已算好的当前章装饰，供卷页预取导航器同步套用，避免快照抢在异步计算前。
    var cachedAnnotationDecorations: (chapter: Int, decorations: [Decoration])?
    private var annotationObservation: AnyCancellable?
    /// 每次刷新使用新的装饰组名：Readium 按组内差异注入脚本，复用旧组名会因“内容相同”跳过注入。
    var annotationDecorationGroup = "user-annotations"
    /// 书内图片（点图查看与目录页“图片”）；EPUB 复用打开前预检的原生容器读取图片。
    let imageLibrary = ReaderImageLibrary()
    var imageContainer: EPUBContainer?

#if DEBUG
    /// 仅独立验证 App 的合成 EPUB 回归使用。WebKit 无障碍树可能包含已翻过的段落，
    /// 因此从 DOM 的实际可见矩形采集编号，不能用无障碍元素“存在”判断正文连续性。
    @Published private(set) var validationVisibleParagraphs = ""
    var validatesPagination: Bool {
        Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation"
            && ProcessInfo.processInfo.arguments.contains("-architecturePagination")
    }

    func refreshPaginationValidation() {
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
    /// 临时快照导航不发布位置、不记录统计或保存进度；只在明确落页后提交一次。
    @Published var curlBusy = false
    @Published var curlReady = false
#if DEBUG
    @Published var curlPreparationCount = 0
    @Published var curlCompletedTurns = 0
    @Published var curlCancelledTurns = 0
    @Published var curlTurnReadyMilliseconds = 0
    @Published var curlSnapshotCount = 0
    @Published var curlLiveSnapshotCount = 0
    @Published var curlPreparedDirections = 0
    @Published var curlInputLost = 0
    @Published var curlBetweenTurnsMilliseconds = 0
    var curlPreparationFailure = ""
    @Published var curlInputTrace = ""
    @Published var curlOpeningMilliseconds = [-1, -1, -1, -1]
    private var curlOpeningStartedAt = ProcessInfo.processInfo.systemUptime
    func recordCurlOpeningStage(_ index: Int) {
        guard curlOpeningMilliseconds[index] < 0 else { return }
        curlOpeningMilliseconds[index] = Int((ProcessInfo.processInfo.systemUptime - curlOpeningStartedAt) * 1000)
    }
#endif
    @Published var curlError: String?
    var onCurlTurn: ((Bool) -> Bool)?
    var cancelCurl: (() async -> Void)?
    /// 一次卷页会话可以覆盖多段动画；会话打开期间真实导航器按提交队列逐页追赶，
    /// `committing` 允许提交结果通过位置回调发布，其余预览期位置事件仍被忽略。
    struct CurlPreviewSession {
        let id: UUID
        let origin: Locator
        let navigator: EPUBNavigatorViewController
        let snapshot: EPUBNavigatorViewController
        var committing = false
    }
    var curlPreview: CurlPreviewSession?

    var publication: Publication?
    var navigationIndex: ReadiumNavigationIndex?
    @Published var currentTOCIndex: Int?
    var textBook: PagedTextBook?
    var textPositionTask: Task<Void, Never>?
    /// 翻页换算与听书进度共用代次。后发起的写入生效，先完成的过期任务不能把进度写回去。
    var textProgressGeneration = 0
    private var receivedTextLocation = false
    /// EPUB 打开后导航器报告的第一个位置就是恢复的位置，不写入，避免刷新同步时间戳。
    var receivedBookLocation = false
    @Published var textLoadFailure: String?
    var failedTextHref: RelativeURL?

    var bookHash: String?
    var positionCount = 0
    var positionsPerResource: [Int: Int] = [:]
    @Published var readingReturnPoint: Locator?
    private var navigationAdapter: DirectionalNavigationAdapter?
    private var tapToken: InputObservableToken?
    private var gestureToken: InputObservableToken?
    /// 点按正文中部（非翻页区域）时调用。
    var onCenterTap: () -> Void = {}

    private static let styleDefaultsKey = ReaderSettings.epubStyleKey

    let settings: ReaderSettings
    let webContext: WebNovelEPUBContext?
    let onReachedEnd: (() -> Void)?

    init(settings: ReaderSettings, webContext: WebNovelEPUBContext? = nil, onReachedEnd: (() -> Void)? = nil) {
        self.settings = settings
        self.webContext = webContext; self.onReachedEnd = onReachedEnd
        if let data = settings.defaults.data(forKey: settings.styleStorageKey),
           let saved = try? JSONDecoder().decode(EPUBReaderStyle.self, from: data) {
            style = saved
        }
        style.fontSize = CGFloat(settings.fontSize)
        annotationObservation = settings.annotations.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refreshAnnotationDecorations(force: true) }
        }
    }

    deinit {
        annotationObservation?.cancel()
    }

    // MARK: 打开

    func open(url: URL, systemIsDark: Bool) async {
        guard status == .idle else { return }
        status = .opening
#if DEBUG
        curlOpeningStartedAt = ProcessInfo.processInfo.systemUptime
        curlOpeningMilliseconds = [-1, -1, -1, -1]
#endif
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
            reloadStoredStyle()
            isTOCDiagnosticsExpanded = false
            let publication = try await Self.openPublication(
                url: url, disablesScripts: UserDefaults.standard.bool(forKey: SettingsKey.readerEPUBDisablesScripts), projection: settings.projection)
            self.publication = publication
            bookTitle = publication.metadata.title ?? url.deletingPathExtension().lastPathComponent
            speech.bookTitle = bookTitle
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
        if afterCurlRestores({ [weak self] in self?.retryOpening(url: url) }) { return }
        guard case .failed = status, textBook == nil else { return }
        status = .idle
        Task { await open(url: url, systemIsDark: isDarkMode) }
    }

    /// 惰性 Publication 不走 EPUB 文件解析，也不写入 EPUB 的进度命名空间。
    func open(textBook: PagedTextBook, systemIsDark: Bool) async {
        guard status == .idle, let source = textBook.source as? TextChapterSource else { return }
        status = .opening
#if DEBUG
        curlOpeningStartedAt = ProcessInfo.processInfo.systemUptime
        curlOpeningMilliseconds = [-1, -1, -1, -1]
#endif
        self.textBook = textBook
        isDarkMode = settings.isDark(systemIsDark: systemIsDark)
        do {
            if let id = textBook.preferenceKey ?? textBook.bookmarkKey { settings.activateBook(id) }
            source.displayProjection = settings.projection
            reloadStoredStyle()
            let publication = ReadiumTextPublication.make(source: source)
            self.publication = publication
            bookTitle = source.bookTitle
            speech.bookTitle = bookTitle
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
        if afterCurlRestores({ [weak self] in self?.retryTextLoad() }) { return }
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
    func saveTextPosition(_ location: Locator) {
        guard let book = textBook, let source = book.source as? TextChapterSource,
              let unit = navigationIndex?.resourceIndex(for: location.href) else { return }
        // 打开或恢复页面时不刷新同步时间戳。
        if !receivedTextLocation {
            receivedTextLocation = true
            if book.readiumIdentity != nil { return }
        }
        textPositionTask?.cancel()
        textProgressGeneration += 1
        let generation = textProgressGeneration
        textPositionTask = Task { [weak self] in
            guard let html = try? await source.chapterHTML(at: unit), !Task.isCancelled,
                  let self, self.locator == location, self.textProgressGeneration == generation else { return }
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

    static func diagnosticReason(_ error: ReadError) -> String {
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
    private static func openPublication(url: URL, disablesScripts: Bool, projection: ReadingTextProjection) async throws -> Publication {
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
                    var result = EPUBReadiumImageLayout.normalizingSVGAttributes(inHTML: html)
                    if reflowable {
                        result = EPUBReadiumImageLayout.keepingStandaloneImagesTogether(inHTML: result)
                    }
                    if disablesScripts {
                        result = EPUBScriptRemoval.removingScripts(fromHTML: result)
                        result = EPUBScriptRemoval.hidingPopupNoteBodies(inHTML: result)
                    }
                    return Data(projection.applyHTML(result).utf8)
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

    func navigatorConfiguration() -> EPUBNavigatorViewController.Configuration {
        var config = EPUBNavigatorViewController.Configuration(
            preferences: preferences(),
            fontFamilyDeclarations: Self.importedFontDeclarations()
        )
        config.decorationTemplates["novelia-search"] = HTMLDecorationTemplate(
            layout: .boxes, element: "<span class='novelia-search-current'></span>",
            stylesheet: ".novelia-search-current { background: rgba(255,210,0,0.30); border-radius: 3px; }")
        // 朗读高亮提供可访问名称，点按只覆盖当前实际句子矩形。
        config.decorationTemplates["novelia-speech"] = HTMLDecorationTemplate(
            layout: .boxes, element: "<span role='button' aria-label='当前朗读句' class='novelia-speech-current'></span>",
            stylesheet: ".novelia-speech-current { background: rgba(255,210,0,0.30); border-radius: 3px; }")
        config.editingActions = [EditingAction(title: "人物词条", action: #selector(ReadiumNavigatorContainer.lookupCharacterSelection)),
                                EditingAction(title: "高亮", action: #selector(ReadiumNavigatorContainer.highlightSelection)),
                                EditingAction(title: "添加笔记", action: #selector(ReadiumNavigatorContainer.noteSelection)),
                                EditingAction(title: "从此句朗读", action: #selector(ReadiumNavigatorContainer.speakSelection))] + EditingAction.defaultActions
        config.readiumCSSRSProperties.pageGutter = CSSPxLength(Double(style.leftMargin + style.rightMargin) / 2)
        // 根背景透明：书籍未设背景时露出宿主绘制的阅读背景；书籍给 body 设的背景
        // （如 `<body bgcolor>`）按 CSS 规则延伸到整个页面。
        config.readiumCSSRSProperties.backgroundColor = TransparentCSSColor()
        return config
    }

    private func makeNavigator(initialLocation: Locator?) throws {
        guard let publication else { return }
        let config = navigatorConfiguration()
        let navigator = try EPUBNavigatorViewController(
            publication: publication, initialLocation: initialLocation, config: config)
        navigator.delegate = self
        for group in ["tts", "edge-tts"] {
            navigator.observeDecorationInteractions(inGroup: group) { [weak self] _ in
                self?.lastSpeechDecorationTap = Date()
                self?.speech.toggleHighlightedSpeech()
            }
        }
        // 点按高亮只打开编辑面板；每次刷新用新组名时会重新注册该组的回调。
        observeAnnotationInteractions(in: annotationDecorationGroup, of: navigator)

        // 先于翻页适配器注册且不消费事件：只记下点按，供位置日志区分用户翻页与 Readium 自行移动。
        gestureToken = navigator.addObserver(.tap { [weak self] event in

            // 同次 WebKit 点击先激活高亮，再上报普通点按；后者不能把刚恢复的朗读再次暂停。
            if let self, Date().timeIntervalSince(self.lastSpeechDecorationTap) < 0.3 { return true }
            if let self, Date().timeIntervalSince(self.lastAnnotationDecorationTap) < 0.3 { return true }
            if let self, let view = self.navigator?.view,
               event.location.x < view.bounds.width / 3 || event.location.x > view.bounds.width * 2 / 3,
               self.onCurlTurn?(self.curlForward(atRightEdge: event.location.x > view.bounds.width / 2)) == true { return true }
            self?.noteGesture("tap")
            if let self, let view = self.navigator?.view,
               event.location.x < view.bounds.width / 3 || event.location.x > view.bounds.width * 2 / 3 { self.speech.suspendFollow(true); self.pendingWebPositionWrite = true }
            if let self, self.isAtWebNovelEnd, let view = self.navigator?.view,
               event.location.x > view.bounds.width * 2 / 3 { self.pendingWebPositionWrite = false; self.onReachedEnd?(); return true }
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
        annotationDecorationChapter = nil
        redirectedOperation = nil
        pendingLocationCause = nil
        navigatorRevision += 1
        attachSpeechEngine(publication: publication, navigator: navigator)
        refreshAnnotationDecorations(force: true)
    }

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

    /// 每次重建导航器都要换朗读引擎：旧引擎持有的导航器已失效。
    private var externalSpeechTask: Task<Void, Never>?
    private var externalSpeechGeneration = UUID()

    /// 用同一份上传正文的前后文定位句子，Readium 在 HTML 中解析精确文本范围。
    private func updateExternalSpeechPosition(_ position: SpeechReadingPosition?, settings: SpeechSettings) {
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

    /// 当前朗读句定位（Readium 官方引擎上报），供「回到正在朗读的段落」。
    private var spokenLocator: Locator?

    /// 用户翻页或滚动后回到正在朗读的段落。
    func jumpToSpoken() {
        if afterCurlRestores({ [weak self] in self?.jumpToSpoken() }) { return }
        guard let spokenLocator else { return }
        markNavigation("speech")
        Task { _ = await navigator?.go(to: spokenLocator) }
    }

    private func attachSpeechEngine(publication: Publication, navigator: EPUBNavigatorViewController) {
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

    private var listeningProgressTask: Task<Void, Never>?
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
        if afterCurlRestores({ [weak self] in self?.rebuildNavigator() }) { return }
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
        // 默认文字色沿用 Readium，自带夜间主题可通过偏好更新，书内浅色配色保留。
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
        if afterCurlRestores({ [weak self] in self?.synchronizeSharedSettings(systemIsDark: systemIsDark) }) { return }
        let settings = self.settings
        let dark = settings.isDark(systemIsDark: systemIsDark)
        let font = CGFloat(settings.fontSize)
        guard dark != isDarkMode || font != style.fontSize else { return }
        isDarkMode = dark
        style.fontSize = font
        // 深浅色是 Readium 的可更新偏好，保留当前导航器与页面事件通道。
        // 默认文字色由 Readium 主题负责，避免为静态 RS 配置在主题切换时重建整页。
        markNavigation("preferences")
        navigator?.submitPreferences(preferences())
        reapplyPageBackgrounds()
    }

    /// 自定义背景变化只更新外层颜色，不提交分页偏好或重写正文样式。
    func refreshBackground() {
        if afterCurlRestores({ [weak self] in self?.refreshBackground() }) { return }
        reapplyPageBackgrounds()
    }

    /// 只有去白底规则变化时重算正文；位置/显示回报仍只消费缓存，避免刷新反馈。
    func refreshPageBackgroundRule() {
        if afterCurlRestores({ [weak self] in self?.refreshPageBackgroundRule() }) { return }
        for case let page as WKWebView in pageLoadObservations.keyEnumerator().allObjects {
            guard !page.isLoading, page.url != nil else { continue }
            readPageBackground(of: page)
        }
    }

    private func reloadStoredStyle() {
        style = settings.defaults.data(forKey: settings.styleStorageKey).flatMap { try? JSONDecoder().decode(EPUBReaderStyle.self, from: $0) } ?? EPUBReaderStyle()
        style.fontSize = CGFloat(settings.fontSize)
    }
    func reloadBookPreferences(url: URL?) {
        if afterCurlRestores({ [weak self] in self?.reloadBookPreferences(url: url) }) { return }
        readingReturnPoint = nil
        navigator?.apply(decorations: [], in: "book-search")
        speech.stop()
        reloadStoredStyle()
        if let textBook, let source = textBook.source as? TextChapterSource {
            source.displayProjection = settings.projection
            rebuildNavigator()
        } else if let url {
            status = .idle
            Task { await open(url: url, systemIsDark: isDarkMode) }
        }
    }

    func applyStyle(_ requested: EPUBReaderStyle) {
        if afterCurlRestores({ [weak self] in self?.applyStyle(requested) }) { return }
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
            settings.defaults.set(data, forKey: settings.styleStorageKey)
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
        if onCurlTurn?(true) == true { return }
        markNavigation("turnForward")
        Task { if await navigator?.goForward(options: .animated) == false, isAtWebNovelEnd { pendingWebPositionWrite = false; onReachedEnd?() } }
    }
    func goBackward() {
        if onCurlTurn?(false) == true { return }
        markNavigation("turnBackward")
        Task { _ = await navigator?.goBackward(options: .animated) }
    }

    func jump(to item: ReadiumTOCItem) {
        if afterCurlRestores({ [weak self] in self?.jump(to: item) }) { return }
        rememberReadingPoint()
        markNavigation("navigate")
        Task { _ = await navigator?.go(to: item.link) }
    }

    /// 宿主在尺寸过渡前保留已提交位置；Readium 重排中的临时章首回报不参与进度保存。
    /// 连续过渡复用最初的锚点，新的显式导航会在 markNavigation 中撤销旧恢复。
    var viewportRestoration: (id: UUID, origin: Locator, navigator: EPUBNavigatorViewController)?

    func beginViewportTransition() -> UUID? {
        guard status == .ready, let navigator,
              let origin = viewportRestoration?.origin ?? navigator.currentLocation ?? locator else { return nil }
        let id = UUID()
        viewportRestoration = (id, origin, navigator)
        return id
    }

    func finishViewportTransition(_ id: UUID) async {
        guard let restoration = viewportRestoration, restoration.id == id,
              navigator === restoration.navigator else { return }
        await cancelCurl?()
        guard viewportRestoration?.id == id, navigator === restoration.navigator else { return }
        let restored = await restoration.navigator.go(to: restoration.origin, options: .none)
        // go 完成后位置回报仍可能晚一拍；与翻页共用稳定位置等待，期间不保存临时回报。
        let current = restored ? await settledCurlLocation(in: restoration.navigator, minimumStable: 3) : nil
        guard !Task.isCancelled, viewportRestoration?.id == id, navigator === restoration.navigator else { return }
        // 恢复失败时保留位置保护并显示重开入口，不能把临时章首保存为用户进度。
        guard let current else {
            status = .failed("调整窗口后无法恢复阅读位置，请重新打开阅读器。")
            return
        }
        viewportRestoration = nil
        self.navigator(restoration.navigator, locationDidChange: current)
    }

    // MARK: 位置诊断

    /// 匿名标识仅在此阅读器实例内有效；导航器重建另由 navigatorRevision 区分。
    private let diagnosticSession = DiagnosticContext.newTraceID()
    private var diagnosticOperation = 0
    var pendingWebPositionWrite = false
    /// 导航来源在下一次位置回报时取用并清空；超过 3 秒视为过期。
    /// 点按和拖动观察者也注册来源，未能关联时记为 unattributed。
    private var pendingLocationCause: (cause: String, time: MonotonicInstant)?
    private let diagnosticViews = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    private var nextDiagnosticView = 0
    private var redirectedOperation: Int?

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
        readingTimePoint = .init(resource: resource(current), fraction: current.locations.progression ?? 0,
            reason: ["turnForward", "swipe", "outerSwipe"].contains(cause) ? .forward : .reset)
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
    var createdWebViews = 0
    /// 章节 WebView 与章节间滚动视图的拖动手势观察者。
    lazy var gestureProbe = ReadiumGestureProbe { [weak self] recognizer in self?.swipeBegan(recognizer) }

    /// Readium 用两层横向滚动视图：章节 WebView 自己的滚动视图负责章内翻页，外层分页视图负责切换章节。
    /// 拖动从 WebView 以外的区域开始（上下页边距、章节标题栏区域）时只有外层能响应，会直接切到相邻章节，
    /// 跳过本章剩余页面。因此外层开始拖动时，若本章在该方向上仍有页面，就取消这次拖动并改为章内翻一页；
    /// 已在章首或章末时保留外层的切章行为。
    private func swipeBegan(_ recognizer: UIPanGestureRecognizer) {
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

}
