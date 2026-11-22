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
    /// 仿真翻页快照使用的章节底色缓存（按 WebView + 章节 URL + 外观键复用，避免同章逐页重扫整棵 DOM）。
    struct CachedCurlWebBackground {
        let url: String
        let appearanceKey: String
        let color: UIColor?
    }
    let curlWebBackgrounds = NSMapTable<WKWebView, AnyObject>.weakToStrongObjects()
    /// 观察各 WebView 的加载状态，每次加载完成后重新读取底色。
    let pageLoadObservations = NSMapTable<WKWebView, NSKeyValueObservation>.weakToStrongObjects()
    @Published var activeNote: EPUBNote?
    /// 最近一次点按在窗口坐标系中的锚点矩形，供紧随其后的注脚回调把气泡贴在注脚标记附近。
    var lastTapWindowRect: CGRect?
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
    /// 按章节缓存已解析的摘录装饰（包含临近章尾/章首时后台预热的相邻章），跨章仿真翻页快照可直接同步命中。
    var cachedChapterAnnotationDecorations: [Int: [Decoration]] = [:]
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
    /// 当前资源上一次成功的锚点前缘进度。滚动不改变它们；字体、视口或图片引起的重排会清掉。
    var tocMeasuredResource: Int?
    var tocMeasuredAnchors: [String: Double] = [:]
    var tocMeasureGeneration = 0
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
            resetTOCGeometry()
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
            resetTOCGeometry()
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
            if let languageTag = projection.htmlLanguageTag {
                manifest.metadata.languages = [languageTag]
            }
            let reflowable = manifest.metadata.layout != .fixed
            let isHorizontalBook = manifest.metadata.readingProgression != .rtl
            container = container.map { href, resource in
                let path = href.removingFragment().removingQuery().path
                if disablesScripts, EPUBScriptRemoval.isScriptResource(path: path) {
                    return resource.map { _ in Data() }
                }
                if isHorizontalBook, EPUBHorizontalLayoutCompatibility.isCSSResource(path: path) {
                    return resource.map { data in
                        guard let css = String(data: data, encoding: .utf8) else { return data }
                        let rewritten = EPUBHorizontalLayoutCompatibility.normalizingHangingIndentsForHorizontal(in: css)
                        return rewritten == css ? data : Data(rewritten.utf8)
                    }
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
                                EditingAction(title: "AI 解析", action: #selector(ReadiumNavigatorContainer.explainSelectionWithAI)),
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
        gestureProbe.attachTapObserver(to: navigator.view)
        for group in ["tts", "edge-tts"] {
            navigator.observeDecorationInteractions(inGroup: group) { [weak self] _ in
                self?.lastSpeechDecorationTap = Date()
                self?.speech.toggleHighlightedSpeech()
            }
        }
        // 点按高亮只打开编辑面板；每次刷新用新组名时会重新注册该组的回调。
        observeAnnotationInteractions(in: annotationDecorationGroup, of: navigator)

        // 先于翻页适配器注册：按用户自定义热区处理点按翻页与工具栏显隐。
        gestureToken = navigator.addObserver(.tap { [weak self] event in
            guard let self, let view = self.navigator?.view else { return false }
            self.lastTapWindowRect = view.convert(
                CGRect(origin: event.location, size: .zero).insetBy(dx: -8, dy: -10),
                to: nil
            )
            // 同次 WebKit 点击先激活高亮，再上报普通点按；后者不能把刚恢复的朗读再次暂停。
            if Date().timeIntervalSince(self.lastSpeechDecorationTap) < 0.3 { return true }
            if Date().timeIntervalSince(self.lastAnnotationDecorationTap) < 0.3 { return true }
            let mode = ReaderTapZoneMode.current
            let action = mode.action(at: event.location, in: view.bounds.size, isRightToLeft: self.curlRightToLeft)
            switch action {
            case .menu:
                if await self.openImage(at: event.location) { return true }
                self.onCenterTap()
                return true
            case .next, .previous:
                let forward = (action == .next)
                if self.onCurlTurn?(forward) == true { return true }
                self.noteGesture("tap")
                self.speech.suspendFollow(true)
                self.pendingWebPositionWrite = true
                if forward && self.isAtWebNovelEnd {
                    self.pendingWebPositionWrite = false
                    self.onReachedEnd?()
                    return true
                }
                if mode == .standard {
                    // 标准热区交由 DirectionalNavigationAdapter 处理，保持 Readium 原生翻页体验。
                    return false
                }
                if forward { self.goForward() } else { self.goBackward() }
                return true
            }
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

    /// 每次重建导航器都要换朗读引擎：旧引擎持有的导航器已失效。
    var externalSpeechTask: Task<Void, Never>?
    var externalSpeechGeneration = UUID()
    /// 当前朗读句定位（Readium 官方引擎上报），供「回到正在朗读的段落」。
    var spokenLocator: Locator?
    var listeningProgressTask: Task<Void, Never>?

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
        let letterSpacing = style.letterSpacing ?? 0
        let textAlign: ReadiumNavigator.TextAlignment? = switch style.textAlignment ?? .bookDefault {
        case .bookDefault: nil
        case .justified: .justify
        case .left: .left
        }
        let overridesBook = style.lineSpacing > 0 || style.paragraphSpacing > 0
            || style.firstLineIndentEm != nil || letterSpacing > 0
            || textAlign != nil
        let fontSize = Double(style.fontSize)
        let projection = settings.projection
        let effectiveFont = style.fontFamily ?? projection.preferredCJKFontFamily
        return EPUBPreferences(
            fontFamily: effectiveFont.map { FontFamily(rawValue: $0) },
            // WebKit 中 1 CSS px = 1 pt；浏览器默认根字号 16px。
            fontSize: fontSize / 16,
            language: projection.htmlLanguageTag.map { Language(code: .bcp47($0)) },
            letterSpacing: letterSpacing > 0 ? Double(letterSpacing) / fontSize : nil,
            lineHeight: style.lineSpacing > 0 ? 1.5 + Double(style.lineSpacing) / fontSize : nil,
            paragraphIndent: style.firstLineIndentEm.map { Double($0) },
            paragraphSpacing: style.paragraphSpacing > 0 ? Double(style.paragraphSpacing) / fontSize : nil,
            publisherStyles: !overridesBook,
            scroll: false,
            spread: style.doublePage == true ? .always : .never,
            textAlign: textAlign,
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
            publication = ReadiumTextPublication.make(source: source)
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
        if let spacing = requested.letterSpacing {
            updated.letterSpacing = min(4, max(0, spacing))
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
        invalidateTOCGeometry()
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

    // MARK: 位置诊断状态

    /// 匿名标识仅在此阅读器实例内有效；导航器重建另由 navigatorRevision 区分。
    let diagnosticSession = DiagnosticContext.newTraceID()
    var diagnosticOperation = 0
    var pendingWebPositionWrite = false
    /// 导航来源在下一次位置回报时取用并清空；超过 3 秒视为过期。
    /// 点按和拖动观察者也注册来源，未能关联时记为 unattributed。
    var pendingLocationCause: (cause: String, time: MonotonicInstant)?
    let diagnosticViews = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    var nextDiagnosticView = 0
    var redirectedOperation: Int?
    /// 本次阅读器会话中 Readium 新建章节 WebView 的次数。
    var createdWebViews = 0
    /// 章节 WebView 与章节间滚动视图的手势观察者（同时记录点按的窗口坐标供注脚气泡定位）。
    lazy var gestureProbe = ReadiumGestureProbe(
        onBegan: { [weak self] recognizer in self?.swipeBegan(recognizer) },
        onTapLocation: { [weak self] windowRect in self?.lastTapWindowRect = windowRect },
        onTapPoint: { [weak self] point in self?.dismissStickySelectionIfNeeded(tappedAt: point) }
    )

    /// Readium 的 WebKit 选区在点按上下边距或部分空白处时可能不会自动取消，
    /// 而 `currentSelection != nil` 会让 Readium JS 吞掉所有后续点击与翻页。
    /// 若轻点落在选区外扩热区之外，短延迟后若选区仍残留则主动清除。
    private func dismissStickySelectionIfNeeded(tappedAt point: CGPoint) {
        guard let navigator, let selection = navigator.currentSelection else { return }
        if let frame = selection.frame, frame.insetBy(dx: -28, dy: -28).contains(point) { return }
        let tappedLocator = selection.locator
        Task { @MainActor [weak self, weak navigator] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard self != nil, let navigator, navigator.currentSelection?.locator == tappedLocator else { return }
            navigator.clearSelection()
            navigator.view.endEditing(true)
        }
    }
}
