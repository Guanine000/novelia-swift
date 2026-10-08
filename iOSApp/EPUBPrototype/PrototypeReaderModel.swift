import OSLog
import CoreText
import SwiftUI
import UIKit
import YueduCoreText

/// 阅读器自己的排版偏好；字体名称来自设备当前可用的 UIFont 字体族。
struct PrototypeReaderStyle: Codable, Equatable {
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
enum PrototypeLocalFonts {
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
            throw FontImportError.registrationFailed
        }
        guard registered || UIFont.familyNames.contains(family) else {
            throw FontImportError.registrationFailed
        }
        return family
    }

    private enum FontImportError: LocalizedError {
        case unsupportedFormat, registrationFailed
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "请选择 TTF、OTF 或 TTC 字体文件。"
            case .registrationFailed: "无法注册该字体文件，请确认文件完整且格式受 iOS 支持。"
            }
        }
    }
}

// MARK: - 原型阅读模型
//
// 不变量：
// 1. 手势中的下一页、动画结束后的落页引用同一个 PageID（见 PrototypePageBook）。
// 2. 字号 / 视口尺寸变化 → generation += 1，整组页面作废重排；翻页动画进行中
//    （isAnimating）不切换代次。
// 3. 跨章节翻页必须先把目标章排版完成，才允许开始动画。

@MainActor
final class PrototypeReaderModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var container: PrototypeEPUBContainer?
    private(set) var pageBook: PrototypePageBook?
    @Published private(set) var location = PrototypeReadingLocation(spineIndex: 0, pageIndex: 0)
    @Published private(set) var generation = 0
    @Published private(set) var style = PrototypeReaderStyle()
    @Published private(set) var isAnimating = false
    @Published private(set) var isLayingOut = false
    /// 当前展示的注脚弹窗；nil = 无弹窗。关闭弹层不改变阅读位置。
    @Published var activeNote: PrototypeNote?
    /// 普通链接点击提示（本轮不导航）。
    @Published var plainLinkMessage: String?
    /// Files 导入等产生的提示。
    @Published var importMessage: String?

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
    private var viewportAspectRatio: CGFloat {
        viewportSize.width / max(viewportSize.height, 1)
    }

    private var relayoutTask: Task<Void, Never>?
    private static let styleDefaultsKey = "epubPrototype.readerStyle.v1"

    init() {
        PrototypeLocalFonts.registerSavedFonts()
        if let data = UserDefaults.standard.data(forKey: Self.styleDefaultsKey),
           let saved = try? JSONDecoder().decode(PrototypeReaderStyle.self, from: data) {
            style = saved
        }
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

    // MARK: 链接 / 注脚命中

    /// 视图点击点 → 链接语义。注脚返回其文本；普通链接返回 href（本轮不导航）。
    func linkHit(at point: CGPoint) -> PrototypeLinkHit? {
        guard let pageBook else { return nil }
        let id = pageID(location.spineIndex, location.pageIndex)
        guard let region = pageBook.linkRegion(at: point, for: id) else { return nil }
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
        do {
            let container = try await PrototypeEPUBContainer.open(fileURL: url)
            self.container = container
            location = PrototypeReadingLocation(spineIndex: 0, pageIndex: 0)
            await relayout(keepingCurrentSpine: false)
        } catch {
            status = .failed(describeLayoutError(error))
        }
    }

    /// Files 导入：security-scoped 资源在 NSFileCoordinator 协调下复制到本地，
    /// 再走同一打开流程。失败写入 importMessage。
    func importEPUB(from pickedURL: URL) async {
        let needsScope = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }

        let importsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrototypeImports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
            let destination = importsDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("epub")
            var coordinatedError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: pickedURL, options: .forUploading,
                                           error: &coordinatedError) { sourceURL in
                // .forUploading 给出临时快照（目录/安全区外文件也可复制）。
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                } catch {
                    copyError = error
                }
            }
            if let coordinatedError { throw coordinatedError }
            if let copyError { throw copyError }
            importMessage = nil
            await open(url: destination)
        } catch {
            importMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: 主题与排版配置

    /// 跟随系统深浅色（由视图在 colorScheme 变化时同步）。变化触发代次重排。
    @Published private(set) var isDarkMode = false

    /// 页面底色（浅色=米色纸面，深色=近黑）。
    var pageBackground: UIColor {
        isDarkMode
            ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
            : UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1)
    }

    /// 正文颜色（浅色=黑，深色=近白）。
    var pageTextColor: UIColor {
        isDarkMode ? UIColor(white: 0.92, alpha: 1) : .black
    }

    /// 页面底色（SwiftUI 视图背景用）。
    var pageBackgroundColor: Color {
        Color(pageBackground)
    }

    func setDarkMode(_ dark: Bool) {
        guard dark != isDarkMode, !isAnimating else { return }
        isDarkMode = dark
        container?.themeTextColor = pageTextColor
        Task { await relayout(keepingCurrentSpine: true) }
    }

    private func makeConfig() -> BrowserLayoutConfig {
        let contentInsets = style.contentInsets
        let contentWidth = max(1, viewportSize.width - contentInsets.left - contentInsets.right)
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
        config.backgroundColor = pageBackground
        config.defaultTextAlignment = .natural
        config.onDiagnostic = { diagnostic in
            engineDiagLog.fault("ENGINE_DIAG \(String(describing: diagnostic), privacy: .public)")
        }
        return config
    }

    /// 重排当前章（以及前后相邻章的预取）。generation 递增使旧页面全部失效。
    private func relayout(keepingCurrentSpine: Bool) async {
        guard let container else { return }
        container.themeTextColor = pageTextColor
        relayoutTask?.cancel()
        let spineIndex = keepingCurrentSpine ? location.spineIndex : 0
        let previousCount = max(pageCount(spineIndex: spineIndex), 1)
        let previousFraction = keepingCurrentSpine
            ? CGFloat(location.pageIndex) / CGFloat(previousCount)
            : 0
        generation += 1
        let book = PrototypePageBook(generation: generation)
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
                location.pageIndex = min(Int(previousFraction * CGFloat(max(pageCount(spineIndex: spineIndex), 1))),
                                         max(pageCount(spineIndex: spineIndex) - 1, 0))
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

    /// 调试：`-prototypeJumpSpine <n>` 打开后自动跳到指定 spine（0 起），供自动化目检。
    private func applyDebugJumpIfNeeded() {
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

    private func pageID(_ spineIndex: Int, _ pageIndex: Int) -> PrototypePageID {
        PrototypePageID(generation: generation, spineIndex: spineIndex, pageIndex: pageIndex)
    }

    /// 已缓存页面位图的读取（不触发渲染，供预览槽位使用）。
    private func cachedImage(_ spineIndex: Int, _ pageIndex: Int, background: UIColor) -> CGImage? {
        pageBook?.cachedRenderedImage(for: pageID(spineIndex, pageIndex))
    }

    /// 空闲渲染相邻页位图，避免拖动开始/落页提交瞬间同步解码大图造成卡顿。
    private func schedulePrerender(around spineIndex: Int, pageIndex: Int) {
        guard let pageBook, let container else { return }
        let background = pageBackground
        var ids: [PrototypePageID] = [
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
                _ = self.pageBook?.renderedImage(for: id, scale: self.displayScale, background: background)
                self.scheduledRenders.remove(id)
                self.objectWillChange.send()
            }
        }
    }

    private var scheduledRenders = Set<PrototypePageID>()

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
            location = PrototypeReadingLocation(
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
    func pagerImages() -> PrototypePagerView.PageImages {
        guard let pageBook else { return .init(previous: nil, current: nil, next: nil) }
        let size = viewportSize
        guard size.width > 0 else { return .init(previous: nil, current: nil, next: nil) }
        let background = pageBackground

        var result = PrototypePagerView.PageImages(
            previous: cachedImage(location.spineIndex, location.pageIndex - 1, background: background),
            current: pageBook.renderedImage(for: pageID(location.spineIndex, location.pageIndex),
                                            scale: displayScale, background: background),
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

    // MARK: 翻页

    /// 目标页是否已经排版好（拖动开始的门槛：保证动画只移动已渲染结果）。
    func canTurn(forward: Bool) -> Bool {
        guard !isAnimating, !isLayingOut, status == .ready, let pageBook else { return false }
        if forward {
            let count = pageCount(spineIndex: location.spineIndex)
            if location.pageIndex + 1 < count { return true }
            return pageBook.hasChapter(location.spineIndex + 1) && pageCount(spineIndex: location.spineIndex + 1) > 0
        } else {
            if location.pageIndex > 0 { return true }
            return pageBook.hasChapter(location.spineIndex - 1) && pageCount(spineIndex: location.spineIndex - 1) > 0
        }
    }

    /// 动画结束后的落页提交：只切换索引，不触发任何排版。
    func commitTurn(forward: Bool) {
        guard canTurn(forward: forward) else { return }
        let count = pageCount(spineIndex: location.spineIndex)
        if forward {
            if location.pageIndex + 1 < count {
                location.pageIndex += 1
            } else {
                location.spineIndex += 1
                location.pageIndex = 0
            }
        } else {
            if location.pageIndex > 0 {
                location.pageIndex -= 1
            } else {
                location.spineIndex -= 1
                location.pageIndex = max(pageCount(spineIndex: location.spineIndex) - 1, 0)
            }
        }
        prefetchNeighbors(of: location.spineIndex)
    }

    // MARK: 目录跳转与字号

    /// 翻页动画期间冻结：字号、代次重排都会被拒绝，避免动画中途切换分页代次。
    func setAnimating(_ animating: Bool) {
        isAnimating = animating
    }

    func jump(to entry: PrototypeTOCEntry) {
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

    func applyStyle(_ requested: PrototypeReaderStyle) {
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
        Task { await relayout(keepingCurrentSpine: true) }
    }
}

// MARK: - 注脚弹窗模型

struct PrototypeNote: Identifiable, Equatable {
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
    if let prototypeError = error as? PrototypeEPUBError {
        return prototypeError.localizedDescription
    }
    return error.localizedDescription
}
