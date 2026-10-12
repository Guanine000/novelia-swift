import OSLog
import CoreText
import SwiftUI
import UIKit
import YueduCoreText

/// 阅读器自己的排版偏好；字体名称来自设备当前可用的 UIFont 字体族。
struct EPUBReaderStyle: Codable, Equatable {
    var doublePage: Bool? = false
    var fontSize: CGFloat = 21
    var fontFamily: String? = nil
    var lineSpacing: CGFloat = 0
    var paragraphSpacing: CGFloat = 0
    /// nil 保留书籍原样；0、1、2 等值覆盖段落首行缩进（em）。
    var firstLineIndentEm: CGFloat? = nil
    var topMargin: CGFloat = 64
    var bottomMargin: CGFloat = 72
    var leftMargin: CGFloat = 20
    var rightMargin: CGFloat = 20

    var contentInsets: UIEdgeInsets {
        UIEdgeInsets(top: topMargin, left: leftMargin, bottom: bottomMargin, right: rightMargin)
    }

    var readerCSS: String? {
        var rules: [String] = []
        if let fontFamily {
            let escaped = fontFamily.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            rules.append("body, p { font-family: '\(escaped)' !important; }")
        }
        if let firstLineIndentEm {
            rules.append("p { text-indent: \(firstLineIndentEm)em !important; }")
        }
        return rules.isEmpty ? nil : rules.joined(separator: "\n")
    }
}

@MainActor
enum EPUBLocalFonts {
    struct ImportedFont: Identifiable {
        let url: URL
        let family: String
        var id: URL { url }
        var format: String { url.pathExtension.uppercased() }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EPUBReaderFonts", isDirectory: true)
    }

    static func registerSavedFonts() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    static func importFont(from sourceURL: URL) throws -> String {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        guard ["ttf", "otf", "ttc"].contains(sourceURL.pathExtension.lowercased()) else {
            throw FontImportError.unsupportedFormat
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension.lowercased())
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let registered = CTFontManagerRegisterFontsForURL(destination as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(destination as CFURL) as? [CTFontDescriptor],
              let family = descriptors.compactMap({ CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }).first else {
            try? FileManager.default.removeItem(at: destination)
            throw FontImportError.registrationFailed
        }
        guard registered || UIFont.familyNames.contains(family) else {
            try? FileManager.default.removeItem(at: destination)
            throw FontImportError.registrationFailed
        }
        let hash = try WebDAVFileHash.sha256(destination)
        recordSync(SyncedImportedFont(hash: hash, format: destination.pathExtension, deleted: false, updatedAt: Date()))
        return family
    }

    static func importedFonts() -> [ImportedFont] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file in
            guard ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
                  let family = descriptors.compactMap({
                      CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
                  }).first else { return nil }
            return ImportedFont(url: file, family: family)
        }.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    static func deleteFont(_ font: ImportedFont) throws {
        guard font.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw FontImportError.invalidLocation
        }
        let hash = try WebDAVFileHash.sha256(font.url)
        CTFontManagerUnregisterFontsForURL(font.url as CFURL, .process, nil)
        try FileManager.default.removeItem(at: font.url)
        recordSync(SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: true, updatedAt: Date()))
    }

    static func syncSnapshot() throws -> [String: SyncedImportedFont] {
        var records = syncRecords()
        for font in importedFonts() {
            let hash = try WebDAVFileHash.sha256(font.url)
            if records[hash] == nil { records[hash] = SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: false, updatedAt: .distantPast) }
        }
        return records
    }
    static func syncFiles() throws -> [String: URL] {
        var files: [String: URL] = [:]
        for font in importedFonts() { files[try WebDAVFileHash.sha256(font.url)] = font.url }
        return files
    }
    private static func syncRecords() -> [String: SyncedImportedFont] {
        UserDefaults.standard.data(forKey: SettingsKey.importedFontSync).flatMap { try? JSONDecoder().decode([String: SyncedImportedFont].self, from: $0) } ?? [:]
    }
    private static func recordSync(_ record: SyncedImportedFont) {
        var records = syncRecords(); records[record.hash] = record
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: SettingsKey.importedFontSync) }
    }
    static func applySync(_ records: [String: SyncedImportedFont], files: [String: URL]) throws {
        for (hash, record) in records {
            if let local = syncRecords()[hash], local.updatedAt > record.updatedAt { continue }
            let matches = try importedFonts().filter { try WebDAVFileHash.sha256($0.url) == hash }
            if record.deleted {
                for font in matches { try deleteFont(font) }
            } else if matches.isEmpty {
                guard ["ttf", "otf", "ttc"].contains(record.format), let file = files[hash] else { throw CocoaError(.fileReadCorruptFile) }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(record.format)
                try FileManager.default.copyItem(at: file, to: temporary)
                defer { try? FileManager.default.removeItem(at: temporary) }
                _ = try importFont(from: temporary)
            }
            recordSync(record)
        }
        NotificationCenter.default.post(name: Notification.Name("NoveliaImportedFontsChanged"), object: nil)
    }

    private enum FontImportError: LocalizedError {
        case unsupportedFormat, registrationFailed, invalidLocation
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "请选择 TTF、OTF 或 TTC 字体文件。"
            case .registrationFailed: "无法注册该字体文件，请确认文件完整且格式受 iOS 支持。"
            case .invalidLocation: "只能删除本应用导入的字体。"
            }
        }
    }
}

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

    @Published private(set) var status: Status = .idle
    @Published private(set) var container: EPUBContainer?
    private(set) var pageBook: EPUBPageBook?
    @Published private(set) var location = EPUBReadingLocation(spineIndex: 0, pageIndex: 0) {
        didSet {
            trimPageCaches()
            if !isRestoringPosition, let openedBookHash, status == .ready {
                ReaderSettings.shared.recordEPUBPosition(
                    hash: openedBookHash, fraction: overallProgress, spineIndex: location.spineIndex,
                    chapterOffset: pageBook?.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex))
            }
        }
    }
    private var openedBookHash: String?
    private var isRestoringPosition = false
    @Published private(set) var generation = 0
    @Published private(set) var style = EPUBReaderStyle()
    @Published private(set) var isAnimating = false
    @Published private(set) var isLayingOut = false
    /// 当前展示的注脚弹窗；nil = 无弹窗。关闭弹层不改变阅读位置。
    @Published var activeNote: EPUBNote?
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
                Task { await relayout(keepingCurrentSpine: true) }
            }
        }
    }

    var displayScale: CGFloat = UIScreen.main.scale

    /// 视口宽高比（宽/高），用于 @media 的 device-aspect-ratio 条件求值。
    var usesDoublePage: Bool { style.doublePage == true }
    private var leafWidth: CGFloat { viewportSize.width / (usesDoublePage ? 2 : 1) }
    private var pageStride: Int { usesDoublePage ? 2 : 1 }
    private var selectionLeaf = 0
    private struct SpreadCacheEntry {
        let secondLeafAvailable: Bool
        let image: CGImage
    }
    private var spreadCache: [EPUBPageID: SpreadCacheEntry] = [:]

    private var viewportAspectRatio: CGFloat {
        leafWidth / max(viewportSize.height, 1)
    }

    private var relayoutTask: Task<Void, Never>?
    private static let styleDefaultsKey = ReaderSettings.epubStyleKey

    init() {
        EPUBLocalFonts.registerSavedFonts()
        if let data = UserDefaults.standard.data(forKey: Self.styleDefaultsKey),
           let saved = try? JSONDecoder().decode(EPUBReaderStyle.self, from: data) {
            style = saved
        }
        style.fontSize = CGFloat(ReaderSettings.shared.fontSize)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimPageCaches(radius: 0) }
        }
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
    }

    private var memoryWarningObserver: NSObjectProtocol?

    /// Page bitmaps are about 14 MB each at 3× scale. Keep the visible leaves and `radius`
    /// pages on either side (crossing into neighbouring chapters); anything else is
    /// re-rendered from the cached layout when it comes back into view.
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
        if container.tableDisplayStripCount > 0 {
            messages.append("本书包含 \(container.tableDisplayStripCount) 处表格化垂直居中声明（display:table/vertical-align:middle），已剥离以正常显示图片，插图不再垂直居中。")
        }
        if container.flexGridRewriteCount > 0 {
            messages.append("本书包含 \(container.flexGridRewriteCount) 处 Flex/Grid 布局声明，已回退为普通块布局以显示内容；相关内容的专属对齐和间距效果可能不同。")
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
            return .plain(region.href)
        }
    }

    // MARK: 打开

    func open(url: URL) async {
        status = .opening
        isRestoringPosition = true
        do {
            let bookHash = try await Task.detached(priority: .utility) {
                try WebDAVFileHash.sha256(url)
            }.value
            let container = try await EPUBContainer.open(fileURL: url)
            self.container = container
            openedBookHash = bookHash
            location = EPUBReadingLocation(spineIndex: 0, pageIndex: 0)
            await relayout(keepingCurrentSpine: false)
            isRestoringPosition = false
            if status == .ready, let saved = ReaderSettings.shared.epubPosition(hash: bookHash) {
                if let spine = saved.chapterIndex, let offset = saved.chapterOffset, container.spine.indices.contains(spine) {
                    await restore(spineIndex: spine, sourceOffset: offset)
                } else if let fraction = saved.fraction, fraction > 0 {
                    seek(to: fraction)
                }
            }
            if status == .ready {
                prepareTOCDiagnosticsPrompt(bookHash: bookHash)
            }
        } catch {
            isRestoringPosition = false
            status = .failed(describeLayoutError(error))
        }
    }

    private func prepareTOCDiagnosticsPrompt(bookHash: String) {
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
        let settings = ReaderSettings.shared
        return UIColor(settings.backgrounds.color(dark: isDarkMode,
            fallback: settings.appearance.background(system: isDarkMode ? .dark : .light)))
    }

    /// 正文颜色（浅色=黑，深色=近白）。
    var pageTextColor: UIColor {
        UIColor(ReaderSettings.shared.appearance.primaryText(system: isDarkMode ? .dark : .light))
    }

    /// 页面底色（SwiftUI 视图背景用）。
    var pageBackgroundColor: Color {
        Color(pageBackground)
    }

    private var backgroundRefreshTask: Task<Void, Never>?
    func refreshBackground() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self else { return }
            await self.relayout(keepingCurrentSpine: true)
        }
    }

    func setDarkMode(_ dark: Bool) {
        guard dark != isDarkMode, !isAnimating else { return }
        isDarkMode = dark
        container?.themeTextColor = pageTextColor
        Task { await relayout(keepingCurrentSpine: true) }
    }

    /// Apply shared font/theme changes in one reflow after an active turn/layout finishes.
    func synchronizeSharedSettings(systemIsDark: Bool) {
        guard !isAnimating, !isLayingOut else { return }
        let settings = ReaderSettings.shared
        let dark = settings.isDark(systemIsDark: systemIsDark)
        let font = CGFloat(settings.fontSize)
        guard dark != isDarkMode || font != style.fontSize else { return }
        isDarkMode = dark
        style.fontSize = font
        container?.themeTextColor = pageTextColor
        Task { await relayout(keepingCurrentSpine: true) }
    }

    private func makeConfig() -> BrowserLayoutConfig {
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
        config.backgroundColor = ReaderSettings.shared.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height) == nil ? pageBackground : .clear
        config.defaultTextAlignment = .natural
        EPUBPageBook.applyEngineWorkarounds(to: &config)
        config.onDiagnostic = { diagnostic in
            engineDiagLog.fault("ENGINE_DIAG \(String(describing: diagnostic), privacy: .private)")
        }
        return config
    }

    /// 重排当前章（以及前后相邻章的预取）。generation 递增使旧页面全部失效。
    private func relayout(keepingCurrentSpine: Bool) async {
        guard let container else { return }
        let wasRestoringPosition = isRestoringPosition
        isRestoringPosition = true
        defer { isRestoringPosition = wasRestoringPosition }
        container.themeTextColor = pageTextColor
        relayoutTask?.cancel()
        let spineIndex = keepingCurrentSpine ? location.spineIndex : 0
        let previousCount = max(pageCount(spineIndex: spineIndex), 1)
        let previousFraction = keepingCurrentSpine
            ? CGFloat(location.pageIndex) / CGFloat(previousCount)
            : 0
        // Re-pagination keeps the same text on screen; the fraction is only a fallback
        // for pages without text.
        let previousOffset = keepingCurrentSpine
            ? pageBook?.sourceOffset(spineIndex: spineIndex, pageIndex: location.pageIndex)
            : nil
        spreadCache.removeAll()
        generation += 1
        let book = EPUBPageBook(generation: generation)
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
                                   aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS)
            if book.generation == generation {
                status = .ready
                location.spineIndex = spineIndex
                if let previousOffset, let page = book.pageIndex(spineIndex: spineIndex, containingSourceOffset: previousOffset) {
                    location.pageIndex = page
                } else {
                    location.pageIndex = min(Int(previousFraction * CGFloat(max(pageCount(spineIndex: spineIndex), 1))),
                                             max(pageCount(spineIndex: spineIndex) - 1, 0))
                }
                if usesDoublePage { location.pageIndex = (location.pageIndex / 2) * 2 }
                prefetchNeighbors(of: spineIndex)
                applyDebugJumpIfNeeded()
            }
        } catch {
            if book.generation == generation {
                status = .failed(describeLayoutError(error))
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
        Task {
            isLayingOut = true
            defer { isLayingOut = false }
            guard let book = pageBook, container != nil, !book.hasChapter(target) else { return }
            try? await book.layoutChapter(target, container: container, config: makeConfig(),
                                   aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS)
        }
        prefetchNeighbors(of: target)
        #endif
    }

    /// 空闲时预排前后相邻章，让跨章拖动时目标页位图已经就位。
    private func prefetchNeighbors(of spineIndex: Int) {
        guard let container, let book = pageBook else { return }
        let generationSnapshot = generation
        for neighbor in [spineIndex + 1, spineIndex - 1] where container.spine.indices.contains(neighbor) {
            guard !book.hasChapter(neighbor) else { continue }
            let config = makeConfig()
            Task {
                try? await book.layoutChapter(neighbor, container: container, config: config,
                                aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS)
                _ = generationSnapshot // 预取结果挂在当前 book 上，代次切换即整体作废
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
        guard let pageBook, let container else { return }
        let background = pageBackground
        var ids: [EPUBPageID] = [
            pageID(spineIndex, pageIndex - 1),
            pageID(spineIndex, pageIndex + 1),
        ]
        if pageIndex == 0, spineIndex > 0, pageCount(spineIndex: spineIndex - 1) > 0 {
            ids.append(pageID(spineIndex - 1, pageCount(spineIndex: spineIndex - 1) - 1))
        }
        if pageIndex + 1 >= pageCount(spineIndex: spineIndex),
           spineIndex + 1 < container.spine.count {
            ids.append(pageID(spineIndex + 1, 0))
        }
        for id in ids where !(pageBook.isRendered(id)) && !scheduledRenders.contains(id) {
            scheduledRenders.insert(id)
            Task { [weak self] in
                guard let self else { return }
                _ = self.pageBook?.renderedImage(for: id, scale: self.displayScale, background: background, backgroundImage: ReaderSettings.shared.backgrounds.image(dark: self.isDarkMode, landscape: self.viewportSize.width > self.viewportSize.height))
                self.scheduledRenders.remove(id)
                self.objectWillChange.send()
            }
        }
    }

    private var scheduledRenders = Set<EPUBPageID>()

    func pageCount(spineIndex: Int) -> Int {
        pageBook?.pageCount(spineIndex: spineIndex) ?? 0
    }

    var locationDescription: String {
        guard let container else { return "" }
        let total = pageCount(spineIndex: location.spineIndex)
        return "spine \(location.spineIndex + 1)/\(container.spine.count) · 第 \(min(location.pageIndex + 1, max(total, 1)))/\(max(total, 1)) 页 · gen \(generation)"
    }

    /// 全书进度估计（0...1）：spine 粒度 + 当前章内页进度。
    /// 章节尚未全部排版时无法精确总页数，按章节平均权重近似。
    var overallProgress: Double {
        guard let container, !container.spine.isEmpty else { return 0 }
        let chapterTotal = max(pageCount(spineIndex: location.spineIndex), 1)
        let chapterProgress = min(Double(location.pageIndex + 1), Double(chapterTotal)) / Double(chapterTotal)
        return min((Double(location.spineIndex) + chapterProgress) / Double(container.spine.count), 1)
    }

    /// Reopens a book on the page that shows the saved chapter offset.
    private func restore(spineIndex: Int, sourceOffset: Int) async {
        guard let container, let book = pageBook else { return }
        if !book.isChapterComplete(spineIndex) {
            isLayingOut = true
            defer { isLayingOut = false }
            do {
                try await book.layoutChapter(spineIndex, container: container, config: makeConfig(),
                                             aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS)
            } catch {
                status = .failed(describeLayoutError(error))
                return
            }
        }
        guard pageBook === book else { return }
        var page = book.pageIndex(spineIndex: spineIndex, containingSourceOffset: sourceOffset) ?? 0
        if usesDoublePage { page = (page / 2) * 2 }
        location = EPUBReadingLocation(spineIndex: spineIndex, pageIndex: page)
        prefetchNeighbors(of: spineIndex)
    }

    /// 拖动进度条后才定位，避免手指移动时反复排版和重建分页位图。
    func seek(to progress: Double) {
        guard !isAnimating, !isLayingOut, status == .ready,
              let container, let book = pageBook, !container.spine.isEmpty else { return }
        let fraction = min(max(progress, 0), 1)
        let position = fraction * Double(container.spine.count)
        let spineIndex = min(Int(position), container.spine.count - 1)
        let pageFraction = fraction >= 1 ? 1 : position - Double(spineIndex)
        isLayingOut = true
        Task {
            defer { isLayingOut = false }
            if !book.isChapterComplete(spineIndex) {
                do {
                    try await book.layoutChapter(spineIndex, container: container,
                                                 config: makeConfig(), aspectRatio: viewportAspectRatio,
                                                 readerCSS: style.readerCSS)
                } catch {
                    status = .failed(describeLayoutError(error))
                    return
                }
            }
            guard pageBook === book else { return }
            let count = max(pageCount(spineIndex: spineIndex), 1)
            location = EPUBReadingLocation(
                spineIndex: spineIndex,
                pageIndex: min(Int(pageFraction * Double(count)), count - 1)
            )
            prefetchNeighbors(of: spineIndex)
        }
    }

    /// 与当前阅读位置对应的目录条目序号：最后一个 spineIndex ≤ 当前章的条目。
    var currentTOCIndex: Int? {
        guard let toc = container?.toc, !toc.isEmpty else { return nil }
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
            return .init(previous: spreadImage(at: turnLocation(forward: false)),
                         current: spreadImage(at: location),
                         next: spreadImage(at: turnLocation(forward: true)), size: viewportSize)
        }
        let size = viewportSize
        guard size.width > 0 else { return .init(previous: nil, current: nil, next: nil) }
        let background = pageBackground

        var result = EPUBPagerView.PageImages(
            previous: cachedImage(location.spineIndex, location.pageIndex - 1, background: background),
            current: pageBook.renderedImage(for: pageID(location.spineIndex, location.pageIndex),
                                            scale: displayScale, background: background, backgroundImage: ReaderSettings.shared.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height)),
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
        if result.next == nil, let container, location.spineIndex + 1 < container.spine.count {
            result.next = cachedImage(location.spineIndex + 1, 0, background: background)
        }
        schedulePrerender(around: location.spineIndex, pageIndex: location.pageIndex)
        return result
    }

    private func spreadImage(at target: EPUBReadingLocation?) -> CGImage? {
        guard let target, let pageBook,
              pageBook.isPageAvailable(pageID(target.spineIndex, target.pageIndex)) else { return nil }
        let ids = (0..<2).map { pageID(target.spineIndex, target.pageIndex + $0) }
        let secondAvailable = pageBook.isPageAvailable(ids[1])
        if let cached = spreadCache[ids[0]], cached.secondLeafAvailable == secondAvailable { return cached.image }
        let leaves = ids.map { pageBook.renderedImage(for: $0, scale: displayScale, background: pageBackground, backgroundImage: ReaderSettings.shared.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height)) }
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
        // Both leaves share chapter UTF-16 offsets, so selection can cross the gutter.
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

    private func turnLocation(forward: Bool) -> EPUBReadingLocation? {
        let count = pageCount(spineIndex: location.spineIndex)
        if forward {
            if location.pageIndex + pageStride < count {
                return .init(spineIndex: location.spineIndex, pageIndex: location.pageIndex + pageStride)
            }
            // Do not leave a chapter until its last leaf has finished pagination.
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
        guard canTurn(forward: forward), let target = turnLocation(forward: forward) else { return }
        location = target
        prefetchNeighbors(of: location.spineIndex)
    }

    // MARK: 目录跳转与字号

    /// 翻页动画期间冻结：字号、代次重排都会被拒绝，避免动画中途切换分页代次。
    func setAnimating(_ animating: Bool) {
        isAnimating = animating
    }

    func jump(to entry: EPUBTOCEntry) {
        guard !isAnimating, !isLayingOut, let spineIndex = entry.spineIndex else { return }
        navigateToSpine(spineIndex)
    }

    /// 书内链接跳转：href 相对当前章节目录解析并映射到 spine；
    /// 同章锚点暂不精确定位（停留原页），跨章跳到目标章首页。
    func openLink(_ href: String) {
        guard !isAnimating, !isLayingOut, let container else { return }
        let chapterHref = container.spine[location.spineIndex].href
        guard let targetSpine = container.spineIndex(forLinkHref: href, relativeTo: chapterHref) else {
            plainLinkMessage = "链接目标不在本书章节列表内（\(href)）"
            return
        }
        guard targetSpine != location.spineIndex else { return }
        navigateToSpine(targetSpine)
    }

    /// 跳到指定章首页；目标章未排版时先排版（增量，首页即现）。
    private func navigateToSpine(_ spineIndex: Int) {
        location.spineIndex = spineIndex
        location.pageIndex = 0
        Task {
            isLayingOut = true
            defer { isLayingOut = false }
            guard let container, let book = pageBook, !book.hasChapter(spineIndex) else { return }
            try? await book.layoutChapter(spineIndex, container: container, config: makeConfig(),
                                    aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS)
        }
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
        style = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.styleDefaultsKey)
        }
        ReaderSettings.shared.fontSize = Double(updated.fontSize)
        Task { await relayout(keepingCurrentSpine: true) }
    }
}

// MARK: - 注脚弹窗模型

struct EPUBNote: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// 把 YueduCoreText 的排版错误翻译成可诊断的中文信息（真实 EPUB 排查必需）。
private let engineDiagLog = Logger(subsystem: "cc.novelia.ios.port", category: "enginediag")

private func describeLayoutError(_ error: Error) -> String {
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
