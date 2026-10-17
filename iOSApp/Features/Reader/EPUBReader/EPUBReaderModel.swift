import OSLog
import CoreText
import SwiftUI
import UIKit
import YueduCoreText
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

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
        let hash = try FileContentHash.sha256(destination)
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
        let hash = try FileContentHash.sha256(font.url)
        CTFontManagerUnregisterFontsForURL(font.url as CFURL, .process, nil)
        try FileManager.default.removeItem(at: font.url)
        recordSync(SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: true, updatedAt: Date()))
    }

    static func syncSnapshot() throws -> [String: SyncedImportedFont] {
        var records = syncRecords()
        for font in importedFonts() {
            let hash = try FileContentHash.sha256(font.url)
            if records[hash] == nil { records[hash] = SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: false, updatedAt: .distantPast) }
        }
        return records
    }
    static func syncFiles() throws -> [String: URL] {
        var files: [String: URL] = [:]
        for font in importedFonts() { files[try FileContentHash.sha256(font.url)] = font.url }
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
            let matches = try importedFonts().filter { try FileContentHash.sha256($0.url) == hash }
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
    @Published private(set) var source: (any EPUBChapterSource)?
    /// 来源为 EPUB 时保存其容器；目录诊断与文件哈希阅读位置仅适用于 EPUB。
    var container: EPUBContainer? { source as? EPUBContainer }
    private(set) var pageBook: EPUBPageBook?
    @Published private(set) var location = EPUBReadingLocation(spineIndex: 0, pageIndex: 0) {
        didSet {
            trimPageCaches()
            guard !isRestoringPosition, status == .ready else { return }
            if let positionHandler {
                positionHandler(location.spineIndex, pageBook?.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex))
            } else if let openedBookHash {
                let offset = pageBook?.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex)
                let length = pageBook?.sourceLength(spineIndex: location.spineIndex)
                settings.recordEPUBPosition(
                    hash: openedBookHash, fraction: overallProgress, spineIndex: location.spineIndex,
                    chapterOffset: offset,
                    chapterProgression: offset.flatMap { offset in length.map { EPUBChapterProgress.progression(offset: offset, length: $0) } })
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
                let rotated = (oldValue.width > oldValue.height) != (viewportSize.width > viewportSize.height)
                scheduleRelayout(rotated ? .rotate : .resize)
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

    /// 当前等待中的代次重排任务；新任务会取消旧任务。
    private var relayoutTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    /// 按 spine 预取相邻章节；阅读器移开或代次变化时取消。
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    /// 当前代次的目录、链接、定位和调试跳转排版任务。
    private var layoutTasks: [UUID: Task<Void, Never>] = [:]
    private var navigateTaskID: UUID?
    /// 关联本次阅读器会话的打开、排版和关闭日志。
    private(set) var traceID = DiagnosticContext.newTraceID()
    /// 限定共享排版结果范围的内容身份；在线章节为 `nil`。
    private var layoutBookID: String?
    private var bookKind = "epub"
    private let layoutCoordinator: EPUBLayoutCoordinator
    private static let styleDefaultsKey = ReaderSettings.epubStyleKey

    private let settings: ReaderSettings

    init(settings: ReaderSettings, layoutCoordinator: EPUBLayoutCoordinator = .shared) {
        self.settings = settings
        self.layoutCoordinator = layoutCoordinator
        EPUBLocalFonts.registerSavedFonts()
        if let data = UserDefaults.standard.data(forKey: Self.styleDefaultsKey),
           let saved = try? JSONDecoder().decode(EPUBReaderStyle.self, from: data) {
            style = saved
        }
        style.fontSize = CGFloat(settings.fontSize)
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

    /// 在 3× 分辨率下，每页位图约占 14 MB。保留可见页面和两侧各 `radius`
    /// 页（可跨越相邻章节）；其他页面再次进入可视范围时，
    /// 从缓存的排版结果重新渲染。
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

    /// 仅启动一次打开流程；阅读器视图在 `onAppear` 时调用此方法，离开时调用 `close()`。
    func start(url: URL) {
        guard status == .idle, openTask == nil else { return }
        openTask = Task { [weak self] in
            await self?.open(url: url)
            if !Task.isCancelled { self?.openTask = nil }
        }
    }

    /// 容器打开失败时尚无章节来源；重新读取原文件，沿用可取消的打开任务。
    func retryOpening(url: URL) {
        guard case .failed = status, source == nil, openTask == nil else { return }
        status = .idle
        start(url: url)
    }

    func start(textBook: PagedTextBook) {
        guard status == .idle, openTask == nil else { return }
        textBookmarkKey = textBook.bookmarkKey
        openTask = Task { [weak self] in
            await self?.open(source: textBook.source, unit: textBook.startUnit,
                             offset: textBook.startOffset, onPosition: textBook.onPosition)
            if !Task.isCancelled { self?.openTask = nil }
        }
    }

    /// 阅读器离开屏幕时，停止其启动的所有排版任务。已完成的章节排版
    /// 保留在共享协调器缓存中，供下次打开同一本书复用。
    func close() {
        var cancelled = cancelLayoutTasks()
        if let openTask {
            openTask.cancel()
            cancelled += 1
            self.openTask = nil
        }
        if status == .opening { status = .idle }
        EPUBLayoutLog.logger.info("EPUB reader closed; trace=\(self.traceID, privacy: .public), gen=\(self.generation, privacy: .public), cancelledTasks=\(cancelled, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
    }

    /// 取消等待中的重排、预取和导航排版任务；返回已运行的任务数。
    @discardableResult
    private func cancelLayoutTasks() -> Int {
        var count = 0
        if let relayoutTask { relayoutTask.cancel(); count += 1 }
        relayoutTask = nil
        for task in prefetchTasks.values { task.cancel(); count += 1 }
        prefetchTasks.removeAll()
        for task in layoutTasks.values { task.cancel(); count += 1 }
        layoutTasks.removeAll()
        navigateTaskID = nil
        return count
    }

    /// 运行当前代次的排版操作，使重排或关闭时可以取消它。
    @discardableResult
    private func track(_ operation: @escaping @MainActor () async -> Void) -> UUID {
        let id = UUID()
        layoutTasks[id] = Task { [weak self] in
            await operation()
            self?.layoutTasks[id] = nil
        }
        return id
    }

    /// 替换等待中的重排任务：取消旧代次排版，不让它们继续运行到结束。
    private func scheduleRelayout(_ reason: EPUBLayoutReason) {
        guard source != nil, status != .idle, status != .opening else { return }
        let cancelled = cancelLayoutTasks()
        EPUBLayoutLog.logger.info("EPUB relayout scheduled; trace=\(self.traceID, privacy: .public), gen=\(self.generation, privacy: .public), reason=\(reason.rawValue, privacy: .public), cancelledTasks=\(cancelled, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        relayoutTask = Task { [weak self] in
            await self?.relayout(keepingCurrentSpine: true, reason: reason)
            // 替换操作总会先取消此任务，因此未被取消的完成结果仍属于当前任务。
            if !Task.isCancelled { self?.relayoutTask = nil }
        }
    }

    private func layoutContext(_ reason: EPUBLayoutReason) -> EPUBLayoutContext {
        EPUBLayoutContext(bookID: layoutBookID, kind: bookKind, trace: traceID, reason: reason,
                          totalSpine: source?.chapterCount ?? 0, currentSpine: location.spineIndex)
    }

    func open(url: URL) async {
        status = .opening
        isRestoringPosition = true
        bookKind = "epub"
        let start = ContinuousClock.now
        var stage = "hash"
        var restored = false
        EPUBLayoutLog.logger.info("EPUB open started; kind=epub, trace=\(self.traceID, privacy: .public), source=open, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        defer { logOpenOutcome(stage: stage, start: start, restored: restored) }
        do {
            let bookHash = try await Task.detached(priority: .utility) {
                try FileContentHash.sha256(url)
            }.value
            try Task.checkCancellation()
            stage = "container"
            let container = try await EPUBContainer.open(fileURL: url)
            try Task.checkCancellation()
            self.source = container
            openedBookHash = bookHash
            layoutBookID = "epub|" + bookHash
            stage = "layout"
            lastLayoutFailure = nil
            // 直接排版保存位置的章节，避免先排版第 0 章再恢复位置。
            let saved = settings.epubPosition(hash: bookHash)
            if let spine = saved?.chapterIndex, let offset = saved?.chapterOffset, container.spine.indices.contains(spine) {
                restored = true
                await relayout(keepingCurrentSpine: false, reason: .restore, target: (spine, offset))
            } else if let spine = saved?.chapterIndex, let progression = saved?.chapterProgression, container.spine.indices.contains(spine) {
                // Readium 阅读器保存的位置：保留同一章节，按章节文本长度定位。
                restored = true
                await relayout(keepingCurrentSpine: false, reason: .restore, target: (spine, nil), targetProgression: progression)
            } else {
                await relayout(keepingCurrentSpine: false, reason: .first, target: (0, nil))
            }
            isRestoringPosition = false
            if status == .ready, !restored, let fraction = saved?.fraction, fraction > 0 {
                restored = true
                seek(to: fraction, restoring: true)
            }
            if status == .ready {
                prepareTOCDiagnosticsPrompt(bookHash: bookHash)
            }
        } catch {
            isRestoringPosition = false
            lastLayoutFailure = EPUBLayoutLog.failure(error)
            if error is CancellationError { return }
            status = .failed(describeLayoutError(error))
        }
    }

    /// 生成内容的阅读位置回调：（单元序号，单元文本中的 UTF-16 偏移量）。
    private var positionHandler: ((Int, Int?) -> Void)?

    /// 在指定单元和可选文本偏移量处打开生成的章节（TXT / 在线小说）。
    /// 阅读位置通过 `onPosition` 报告，不使用 EPUB 文件哈希存储。
    func open(source: any EPUBChapterSource, unit: Int, offset: Int?,
              onPosition: @escaping (Int, Int?) -> Void) async {
        status = .opening
        isRestoringPosition = true
        positionHandler = onPosition
        self.source = source
        layoutBookID = (source as? TextChapterSource)?.layoutIdentity
        bookKind = layoutBookID == nil ? "online" : "txt"
        let startTime = ContinuousClock.now
        EPUBLayoutLog.logger.info("\(EPUBLayoutLog.label(kind: self.bookKind), privacy: .public) open started; kind=\(self.bookKind, privacy: .public), trace=\(self.traceID, privacy: .public), source=open, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        defer { logOpenOutcome(stage: "layout", start: startTime, restored: offset != nil) }
        guard source.chapterCount > 0 else {
            isRestoringPosition = false
            status = .failed("没有可阅读的章节。")
            return
        }
        let start = min(max(unit, 0), source.chapterCount - 1)
        await relayout(keepingCurrentSpine: false, reason: offset == nil ? .first : .restore, target: (start, offset))
        isRestoringPosition = false
        if status == .ready {
            onPosition(location.spineIndex, pageBook?.sourceOffset(spineIndex: location.spineIndex, pageIndex: location.pageIndex))
        }
    }

    /// 失败后重新排版当前章节（例如网络章节未加载成功）。
    func retry() {
        guard case .failed = status, source != nil, !isLayingOut else { return }
        cancelLayoutTasks()
        status = .opening
        relayoutTask = Task { [weak self] in
            await self?.relayout(keepingCurrentSpine: true, reason: .retry)
            if !Task.isCancelled { self?.relayoutTask = nil }
        }
    }

    /// 因取消以外的原因导致预取失败的相邻章节。
    @Published private(set) var failedChapters = Set<Int>()

    var neighborLoadFailed: Bool {
        failedChapters.contains(location.spineIndex + 1) || failedChapters.contains(location.spineIndex - 1)
    }

    func retryNeighbors() {
        failedChapters.removeAll()
        prefetchNeighbors(of: location.spineIndex)
    }

    /// 最近一次排版或打开错误的类型，供打开结果摘要日志使用。
    private var lastLayoutFailure: (kind: String, code: Int)?

    /// 每次打开书籍记录一行结果；章节日志记录各章节详情。
    private func logOpenOutcome(stage: String, start: ContinuousClock.Instant, restored: Bool) {
        let elapsed = EPUBLayoutLog.milliseconds(since: start)
        let failure = lastLayoutFailure
        let mono = DiagnosticContext.monotonicMilliseconds()
        if Task.isCancelled || failure?.kind == "cancelled" {
            EPUBLayoutLog.logger.info("\(EPUBLayoutLog.label(kind: self.bookKind), privacy: .public) open cancelled; kind=\(self.bookKind, privacy: .public), trace=\(self.traceID, privacy: .public), elapsedMs=\(elapsed, privacy: .public), mono=\(mono, privacy: .public)")
        } else if case .failed = status {
            let failure = failure ?? ("other", 0)
            EPUBLayoutLog.logger.error("\(EPUBLayoutLog.label(kind: self.bookKind), privacy: .public) open failed; kind=\(self.bookKind, privacy: .public), trace=\(self.traceID, privacy: .public), stage=\(stage, privacy: .public), error=\(failure.kind, privacy: .public), code=\(failure.code, privacy: .public), elapsedMs=\(elapsed, privacy: .public), mono=\(mono, privacy: .public)")
        } else {
            let book = DiagnosticContext.bookTag(layoutBookID ?? "private-\(traceID)")
            let spine = source?.chapterCount ?? 0
            let toc = source?.toc.count ?? 0
            let pages = pageCount(spineIndex: location.spineIndex)
            EPUBLayoutLog.logger.info("\(EPUBLayoutLog.label(kind: self.bookKind), privacy: .public) open succeeded; kind=\(self.bookKind, privacy: .public), trace=\(self.traceID, privacy: .public), book=\(book, privacy: .public), totalSpine=\(spine, privacy: .public), toc=\(toc, privacy: .public), currentSpine=\(self.location.spineIndex, privacy: .public), currentChapterPages=\(pages, privacy: .public), restored=\(restored, privacy: .public), elapsedMs=\(elapsed, privacy: .public), mono=\(mono, privacy: .public)")
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
        let settings = self.settings
        return UIColor(settings.backgrounds.color(dark: isDarkMode,
            fallback: settings.appearance.background(system: isDarkMode ? .dark : .light)))
    }

    /// 正文颜色（浅色=黑，深色=近白）。
    var pageTextColor: UIColor {
        UIColor(settings.appearance.primaryText(system: isDarkMode ? .dark : .light))
    }

    /// 页面底色（SwiftUI 视图背景用）。
    var pageBackgroundColor: Color {
        Color(pageBackground)
    }

    private var backgroundRefreshTask: Task<Void, Never>?
    /// 合并短时间内密集出现的背景或字体通知（用于防抖，不用于解决竞态）。
    func refreshBackground() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            self?.scheduleRelayout(.backgroundChange)
        }
    }

    func setDarkMode(_ dark: Bool) {
        guard dark != isDarkMode, !isAnimating else { return }
        isDarkMode = dark
        source?.themeTextColor = pageTextColor
        scheduleRelayout(.themeChange)
    }

    /// 等待当前翻页或排版完成后，通过一次重排应用共享字体和主题变化。
    func synchronizeSharedSettings(systemIsDark: Bool) {
        guard !isAnimating, !isLayingOut else { return }
        let settings = self.settings
        let dark = settings.isDark(systemIsDark: systemIsDark)
        let font = CGFloat(settings.fontSize)
        guard dark != isDarkMode || font != style.fontSize else { return }
        let reason: EPUBLayoutReason = font != style.fontSize ? .fontChange : .themeChange
        isDarkMode = dark
        style.fontSize = font
        source?.themeTextColor = pageTextColor
        scheduleRelayout(reason)
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
        config.backgroundColor = settings.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height) == nil ? pageBackground : .clear
        config.defaultTextAlignment = .natural
        EPUBPageBook.applyEngineWorkarounds(to: &config)
        return config
    }

    /// 重排当前章（以及前后相邻章的预取）。generation 递增使旧页面全部失效。
    /// `target` 用于在源文本偏移量处打开章节（打开书籍或恢复保存位置）。
    private func relayout(keepingCurrentSpine: Bool, reason: EPUBLayoutReason,
                          target: (spine: Int, offset: Int?)? = nil, targetProgression: Double? = nil) async {
        guard let container = source else { return }
        let wasRestoringPosition = isRestoringPosition
        isRestoringPosition = true
        defer { isRestoringPosition = wasRestoringPosition }
        container.themeTextColor = pageTextColor
        // 预取和跳转任务属于即将被替换的代次。
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        for task in layoutTasks.values { task.cancel() }
        layoutTasks.removeAll()
        let spineIndex = target?.spine ?? (keepingCurrentSpine ? location.spineIndex : 0)
        let previousCount = max(pageCount(spineIndex: spineIndex), 1)
        let previousFraction = keepingCurrentSpine && target == nil
            ? CGFloat(location.pageIndex) / CGFloat(previousCount)
            : 0
        // 重新分页时保持屏幕上显示同一段文本；比例仅用于
        // 没有文本的页面作为回退。
        let previousOffset = target != nil ? target?.offset
            : (keepingCurrentSpine ? pageBook?.sourceOffset(spineIndex: spineIndex, pageIndex: location.pageIndex) : nil)
        spreadCache.removeAll()
        failedChapters.removeAll()
        generation += 1
        let book = EPUBPageBook(generation: generation, coordinator: layoutCoordinator)
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
                                         aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                         context: layoutContext(reason))
            if book.generation == generation {
                status = .ready
                location.spineIndex = spineIndex
                let restoreOffset = previousOffset ?? targetProgression.flatMap { progression in
                    book.sourceLength(spineIndex: spineIndex).map { EPUBChapterProgress.offset(progression: progression, length: $0) }
                }
                if let restoreOffset, let page = book.pageIndex(spineIndex: spineIndex, containingSourceOffset: restoreOffset) {
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
                lastLayoutFailure = EPUBLayoutLog.failure(error)
                // 已取消的重排任务被新任务替代，或阅读器已关闭。
                if EPUBLayoutLog.failure(error).kind != "cancelled" {
                    status = .failed(describeLayoutError(error))
                }
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
        track { [weak self] in
            guard let self else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            guard let book = pageBook, !book.isChapterComplete(target) else { return }
            try? await book.layoutChapter(target, container: container, config: makeConfig(),
                                          aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                          context: layoutContext(.navigate))
        }
        prefetchNeighbors(of: target)
        #endif
    }

    /// 空闲时预排前后相邻章，让跨章拖动时目标页位图已经就位。
    /// 仅预取前后两个相邻章节；取消已移开章节的预取，
    /// 同一章节已有预取任务运行时不重复启动。
    private func prefetchNeighbors(of spineIndex: Int) {
        guard let container = source, let book = pageBook else { return }
        let neighbors = [spineIndex + 1, spineIndex - 1].filter { (0..<container.chapterCount).contains($0) }
        for (spine, task) in prefetchTasks where !neighbors.contains(spine) {
            task.cancel()
            prefetchTasks[spine] = nil
        }
        let generationSnapshot = generation
        for neighbor in neighbors {
            guard !book.isChapterComplete(neighbor), prefetchTasks[neighbor] == nil else { continue }
            let config = makeConfig()
            let context = layoutContext(.prefetch)
            prefetchTasks[neighbor] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await book.layoutChapter(neighbor, container: container, config: config,
                                                 aspectRatio: viewportAspectRatio, readerCSS: style.readerCSS,
                                                 context: context)
                    failedChapters.remove(neighbor)
                } catch {
                    // 预取结果挂在当前 book 上，代次切换即整体作废
                    if generationSnapshot == generation, EPUBLayoutLog.failure(error).kind != "cancelled" {
                        failedChapters.insert(neighbor)
                    }
                }
                if generationSnapshot == generation { prefetchTasks[neighbor] = nil }
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
        guard let pageBook, let container = source else { return }
        let background = pageBackground
        var ids: [EPUBPageID] = [
            pageID(spineIndex, pageIndex - 1),
            pageID(spineIndex, pageIndex + 1),
        ]
        if pageIndex == 0, spineIndex > 0, pageCount(spineIndex: spineIndex - 1) > 0 {
            ids.append(pageID(spineIndex - 1, pageCount(spineIndex: spineIndex - 1) - 1))
        }
        if pageIndex + 1 >= pageCount(spineIndex: spineIndex),
           spineIndex + 1 < container.chapterCount {
            ids.append(pageID(spineIndex + 1, 0))
        }
        // 只预渲染实际存在的页：章首的“上一页”（-1）与章末的“下一页”永远渲染不出来，
        // 若照样排队，每次失败都会发布变化、触发重绘并再次排队，形成持续占满 CPU 的循环。
        for id in ids where (0..<pageCount(spineIndex: id.spineIndex)).contains(id.pageIndex)
            && !pageBook.isRendered(id) && !scheduledRenders.contains(id) {
            scheduledRenders.insert(id)
            Task { [weak self] in
                guard let self else { return }
                let image = self.pageBook?.renderedImage(for: id, scale: self.displayScale, background: background, backgroundImage: settings.backgrounds.image(dark: self.isDarkMode, landscape: self.viewportSize.width > self.viewportSize.height))
                self.scheduledRenders.remove(id)
                if image != nil { self.objectWillChange.send() }
            }
        }
    }

    private var scheduledRenders = Set<EPUBPageID>()

    func pageCount(spineIndex: Int) -> Int {
        pageBook?.pageCount(spineIndex: spineIndex) ?? 0
    }

    var locationDescription: String {
        guard let source else { return "" }
        let total = pageCount(spineIndex: location.spineIndex)
        let page = "第 \(min(location.pageIndex + 1, max(total, 1)))/\(max(total, 1)) 页"
        guard container != nil else {
            let chapter = (source as? TextChapterSource)?.tocEntry(containingUnit: location.spineIndex)
            return "第 \((chapter ?? location.spineIndex) + 1)/\(max(source.toc.count, 1)) 章 · \(page)"
        }
        return "spine \(location.spineIndex + 1)/\(source.chapterCount) · \(page) · gen \(generation)"
    }

    /// 全书进度估计（0...1）：spine 粒度 + 当前章内页进度。
    /// 章节尚未全部排版时无法精确总页数，按章节平均权重近似。
    var overallProgress: Double {
        guard let source, source.chapterCount > 0 else { return 0 }
        let chapterTotal = max(pageCount(spineIndex: location.spineIndex), 1)
        let chapterProgress = min(Double(location.pageIndex + 1), Double(chapterTotal)) / Double(chapterTotal)
        return min((Double(location.spineIndex) + chapterProgress) / Double(source.chapterCount), 1)
    }

    /// 拖动进度条后才定位，避免手指移动时反复排版和重建分页位图。
    /// `restoring` 为 true 时（打开时按旧版全书比例恢复）落页不写入阅读位置，不刷新同步时间戳。
    func seek(to progress: Double, restoring: Bool = false) {
        guard !isAnimating, !isLayingOut, status == .ready,
              let container = source, let book = pageBook, container.chapterCount > 0 else { return }
        let fraction = min(max(progress, 0), 1)
        let position = fraction * Double(container.chapterCount)
        let spineIndex = min(Int(position), container.chapterCount - 1)
        let pageFraction = fraction >= 1 ? 1 : position - Double(spineIndex)
        isLayingOut = true
        track { [weak self] in
            guard let self else { return }
            defer { isLayingOut = false }
            if !book.isChapterComplete(spineIndex) {
                do {
                    try await book.layoutChapter(spineIndex, container: container,
                                                 config: makeConfig(), aspectRatio: viewportAspectRatio,
                                                 readerCSS: style.readerCSS, context: layoutContext(.seek))
                } catch {
                    if EPUBLayoutLog.failure(error).kind != "cancelled", pageBook === book {
                        status = .failed(describeLayoutError(error))
                    }
                    return
                }
            }
            guard pageBook === book else { return }
            let count = max(pageCount(spineIndex: spineIndex), 1)
            let wasRestoringPosition = isRestoringPosition
            if restoring { isRestoringPosition = true }
            location = EPUBReadingLocation(
                spineIndex: spineIndex,
                pageIndex: min(Int(pageFraction * Double(count)), count - 1)
            )
            isRestoringPosition = wasRestoringPosition
            prefetchNeighbors(of: spineIndex)
        }
    }

    /// 与当前阅读位置对应的目录条目序号：最后一个 spineIndex ≤ 当前章的条目。
    var currentTOCIndex: Int? {
        guard let toc = source?.toc, !toc.isEmpty else { return nil }
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
                                            scale: displayScale, background: background, backgroundImage: settings.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height)),
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
        if result.next == nil, let source, location.spineIndex + 1 < source.chapterCount {
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
        let leaves = ids.map { pageBook.renderedImage(for: $0, scale: displayScale, background: pageBackground, backgroundImage: settings.backgrounds.image(dark: isDarkMode, landscape: viewportSize.width > viewportSize.height)) }
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
        // 两个页面共用章节 UTF-16 偏移量，因此选择范围可以跨越中缝。
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
        location.spineIndex = spineIndex
        location.pageIndex = 0
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
                if pageBook === book { prefetchNeighbors(of: spineIndex) }
            } catch {
                guard pageBook === book, EPUBLayoutLog.failure(error).kind != "cancelled" else { return }
                lastLayoutFailure = EPUBLayoutLog.failure(error)
                status = .failed(describeLayoutError(error))
            }
        }
    }

    // MARK: 书签与书内搜索

    private var textBookmarkKey: String?

    /// 书签与搜索使用的书籍身份：EPUB 为 `epub:<文件哈希>`，本地 TXT 为 `txt:<文件哈希>`；在线小说为 nil。
    var bookmarkKey: String? { openedBookHash.map { "epub:\($0)" } ?? textBookmarkKey }

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
    func chapterPlainText(_ index: Int) async throws -> String {
        guard let source, (0..<source.chapterCount).contains(index) else { throw CancellationError() }
        return BookTextSearch.plainText(html: try await source.chapterHTML(at: index))
    }

    /// 章节标题：取 spine 不晚于该章的最后一个目录项。
    func chapterTitle(_ index: Int) -> String? {
        source?.toc.last { ($0.spineIndex ?? .max) <= index }?.title
    }

    /// 跳到书签或搜索结果：目标章未排版时先排版，再按章内比例找到所在页。属于用户操作，会记录阅读位置。
    func jump(toChapter spineIndex: Int, progression: Double) {
        guard !isAnimating, !isLayingOut, let container = source, let book = pageBook,
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
                let offset = book.sourceLength(spineIndex: spineIndex).map {
                    EPUBChapterProgress.offset(progression: progression, length: $0)
                }
                var page = offset.flatMap { book.pageIndex(spineIndex: spineIndex, containingSourceOffset: $0) } ?? 0
                if usesDoublePage { page = (page / 2) * 2 }
                location = EPUBReadingLocation(spineIndex: spineIndex, pageIndex: page)
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
            UserDefaults.standard.set(data, forKey: Self.styleDefaultsKey)
        }
        settings.fontSize = Double(updated.fontSize)
        scheduleRelayout(fontChanged ? .fontChange : .styleChange)
    }
}

// MARK: - 注脚弹窗模型

struct EPUBNote: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// 把 YueduCoreText 的排版错误翻译成可诊断的中文信息（真实 EPUB 排查必需）。
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
