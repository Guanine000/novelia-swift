import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - EPUB 阅读界面（全屏阅读页）
//
// 布局与交互参考 Yuedu-reader 的阅读器行为（仅参考布局/交互，不复制源码、
// 不使用其品牌素材）：全屏正文，点击中部显隐工具栏，左右侧点击翻页，
// 注脚点击底部弹层显示注释文本。工具栏为覆盖层，显隐不改变正文视口，
// 因此不会触发重排。
//
// 分页不变量见 EPUBPageBook：预览页与落页共用同一份排版结果。

/// 分页阅读器显示的生成章节（TXT / 在线小说），代替 EPUB 文件。
struct PagedTextBook {
    let source: any EPUBChapterSource
    let startUnit: Int
    let startOffset: Int?
    /// （单元序号，单元文本中的 UTF-16 偏移量），每次翻页后报告。
    let onPosition: (Int, Int?) -> Void
    /// TXT 的 Readium Locator 独立保存，身份包含内容哈希及分章规则。
    var readiumIdentity: String? = nil
    var positionUpdatedAt: Date? = nil
    /// 书签与书内搜索使用的身份（本地 TXT 为 `txt:<文件哈希>`）；在线小说书签身份为 nil，搜索通过本机缓存回调提供。
    var bookmarkKey: String? = nil
    var preferenceKey: String? = nil
    var searchChapterText: ((Int) async throws -> String)? = nil
    /// 目录字数（本地 TXT）；在线小说为 nil，不显示字数。
    var tocWordCounts: (@Sendable () async -> ReaderTOCWordCounts)? = nil
}

#if !NOVELIA_READIUM_ONLY
struct EPUBReaderView: View {
    @EnvironmentObject private var settings: ReaderSettings
    let bookURL: URL?
    var textBook: PagedTextBook? = nil
    var accessory: AnyView? = nil
    var statisticsBook: ReadingBook? = nil
    var webContext: WebNovelEPUBContext? = nil
    var onReachedEnd: (() -> Void)? = nil
    var body: some View {
        EPUBReaderViewContent(bookURL: bookURL, textBook: textBook, accessory: accessory,
                          statisticsBook: statisticsBook, settings: settings, webContext: webContext, onReachedEnd: onReachedEnd)
    }
}

private struct EPUBReaderViewContent: View {
    @ObservedObject private var settings: ReaderSettings
    @ObservedObject private var backgrounds: ReaderBackgroundStore
    @StateObject private var model: EPUBReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingTOC = false
    /// 目录中已展开的分组（条目序号）；每次打开目录时重置为只展开当前章节所在分组。
    @State private var tocExpanded = Set<Int>()
    @State private var tocTab = ReaderTOCTab.contents
    @State private var tocWordCounts: ReaderTOCWordCounts?
    @State private var isShowingBookPreferences = false
    @State private var isShowingStyle = false
    @StateObject private var speech = SpeechPlaybackController()
    @State private var isShowingSpeech = false
    @State private var isShowingBookmarks = false
    @State private var bookmarksTab = ReaderBookmarksSearchSheet.Tab.bookmarks
    @State private var didCopyDiagnostics = false
    /// 目录诊断说明与 spine 编号默认隐藏，在设置里打开调试选项后才显示。
    @AppStorage(ReaderDebugOptions.showsTOCDiagnosticsKey) private var showsTOCDiagnostics = false
    @State private var showChrome = true
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var draftStyle = EPUBReaderStyle()
    @State private var batteryLevel: Float = -1
    @State private var wasBatteryMonitoringEnabled = false
    let bookURL: URL?
    var textBook: PagedTextBook? = nil

    /// TXT / 在线小说包装视图提供的额外顶部栏控件。
    var accessory: AnyView? = nil
    var statisticsBook: ReadingBook? = nil


    init(bookURL: URL?, textBook: PagedTextBook?, accessory: AnyView?, statisticsBook: ReadingBook?, settings: ReaderSettings, webContext: WebNovelEPUBContext?, onReachedEnd: (() -> Void)?) {
        self.bookURL = bookURL; self.textBook = textBook; self.accessory = accessory
        self.statisticsBook = statisticsBook
        _settings = ObservedObject(wrappedValue: settings)
        _backgrounds = ObservedObject(wrappedValue: settings.backgrounds)
        _model = StateObject(wrappedValue: EPUBReaderModel(settings: settings, webContext: webContext, onReachedEnd: onReachedEnd))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ReaderBackgroundView(dark: model.isDarkMode, fallback: model.pageBackgroundColor).ignoresSafeArea()
                switch model.status {
                case .idle, .opening:
                    ProgressView(textBook == nil ? "正在解析 EPUB…" : "正在排版…")
                case .failed(let message):
                    CompatUnavailable {
                        Label("无法读取或排版", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message).textSelection(.enabled)
                    } actions: {
                        if model.source != nil {
                            Button("重试") { model.retry() }
                                .buttonStyle(.borderedProminent)
                                .tint(NoveliaStyle.brandGreen)
                        } else if let bookURL {
                            Button("重新打开") { model.retryOpening(url: bookURL) }
                                .buttonStyle(.borderedProminent)
                        }
                        if model.source?.toc.isEmpty == false {
                            Button("选择其他章节") { isShowingTOC = true }
                        }
                        Button("复制错误说明") { UIPasteboard.general.string = message }
                        Button("关闭阅读器") { dismiss() }
                    }
                case .ready:
                    EPUBReaderPageSurface(model: model, speech: speech, showChrome: $showChrome, size: geometry.size,
                                          speechRects: model.speechHighlightRects, searchRects: model.searchHighlightRects)
                        .equatable()
                        // 底栏不再放上一页／下一页按钮，保留 VoiceOver 的翻页动作。
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: model.commitTurn(forward: true)
                            case .decrement: model.commitTurn(forward: false)
                            @unknown default: break
                            }
                        }
                }
                if model.isLayingOut {
                    ProgressView().scaleEffect(1.4)
                        .padding(22)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .overlay(alignment: .top) {
                if showChrome {
                    topBar
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if model.status == .ready, model.neighborLoadFailed {
                        Button("相邻章节加载失败，点击重试", systemImage: "arrow.clockwise") {
                            model.retryNeighbors()
                        }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                    }
                    bottomBar
                }
            }
            .overlay(alignment: .bottom) {
                // 常驻细进度条：工具栏隐藏时仍可见当前阅读进度。
                Rectangle()
                    .fill(NoveliaStyle.brandGreen.opacity(0.8))
                    .frame(width: max(4, geometry.size.width * model.overallProgress), height: 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            }
            .onValueChange(of: geometry.size) { _, newSize in
                // 进入后台后系统会按其他方向/尺寸截取快照，这些临时尺寸不触发重排。
                guard scenePhase != .background else { return }
                model.viewportSize = newSize
            }
            .onValueChange(of: colorScheme) { _, newScheme in
                synchronizeSettings(systemIsDark: newScheme == .dark)
            }
            .onValueChange(of: scenePhase) { _, phase in
                // 回到前台后按当时的真实外观与尺寸补一次同步；没有变化时不会重排。
                guard phase != .background else { return }
                synchronizeSettings(systemIsDark: colorScheme == .dark)
                if model.viewportSize != geometry.size {
                    model.viewportSize = geometry.size
                }
            }
            .onAppear {
                model.onManualNavigation = { speech.pause() }
                wasBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
                UIDevice.current.isBatteryMonitoringEnabled = true
                updateBatteryLevel()
                synchronizeSettings(systemIsDark: colorScheme == .dark)
                if model.viewportSize != geometry.size {
                    model.viewportSize = geometry.size
                }
                ReaderKeepScreenOn.activate()
                if let textBook {
                    model.start(textBook: textBook)
                } else if let bookURL {
                    model.start(url: bookURL)
                }
            }
            .onDisappear {
                speech.stop()
                model.onManualNavigation = nil
                // 停止已关闭书籍的排版；重新打开时复用缓存中已完成的章节。
                model.close()
                if !wasBatteryMonitoringEnabled {
                    UIDevice.current.isBatteryMonitoringEnabled = false
                }
                ReaderKeepScreenOn.deactivate()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                updateBatteryLevel()
            }
            .sheet(isPresented: Binding(get: { showsTOCDiagnostics && model.isShowingTOCDiagnosticsPrompt },
                                        set: { model.isShowingTOCDiagnosticsPrompt = $0 })) { tocDiagnosticsPrompt }
            .onValueChange(of: showsTOCDiagnostics) { _, enabled in
                if !enabled { model.isShowingTOCDiagnosticsPrompt = false }
            }
        }
        // 书签／搜索面板弹出键盘时不缩小阅读视口，避免整书重新分页并跳页。
        .ignoresSafeArea(.keyboard)
        .compatToolbar(.hidden, for: .navigationBar)
        .compatToolbar(.hidden, for: .tabBar)
        // 阅读器已经在自己的浮层中显示时间和电量。
        // 切换系统状态栏会改变安全区高度，并触发书籍重新分页。
        .statusBarHidden(true)
        .trackReadingTime(statisticsBook ?? ReadingBook(id: "epub:\(bookURL?.lastPathComponent ?? "sample")",
                                                       title: bookURL?.deletingPathExtension().lastPathComponent ?? "样例书", kind: .epub),
                          ready: model.status == .ready)
        .modifier(ReaderSpeechPresentation(controller: speech, isPresented: $isShowingSpeech,
                                  anchor: { model.speechAnchor },
                                  title: model.source?.bookTitle ?? "阅读器") {
                SystemSpeechEngine(chapterCount: model.chapterCount,
                                   onReadingPosition: { position, settings in model.updateSpeechPosition(position, settings: settings) }) { index in
                    try await model.speechChapterText(index)
                }
            })
        .sheet(isPresented: $isShowingTOC) { tocSheet }
        .modifier(ReaderImagePresenter(library: model.imageLibrary, chapterTitle: { model.chapterTitle($0) },
                                       onJump: { model.jump(toImage: $0) }))
        .sheet(isPresented: $isShowingBookmarks) {
            if let key = model.bookmarkKey ?? settings.activeBookID {
                ReaderBookmarksSearchSheet(store: settings.bookmarks, bookKey: key, chapterCount: model.chapterCount,
                                           chapterTitle: { model.chapterTitle($0) },
                                           chapterText: { index in if let cached = textBook?.searchChapterText { _ = try await cached(index) }; return try await model.chapterPlainText(index) },
                                           onJump: { model.jump(toChapter: $0, progression: $1) },
                                           legacyBookKey: model.legacyBookmarkKey,
                                           chapterIDAtIndex: { model.webChapterID($0) },
                                           resolveChapter: { model.bookmarkIndex($0) }, scopeDescription: textBook?.searchChapterText == nil ? nil : "仅搜索已缓存章节，不会下载未缓存正文。", onSearchHit: { model.showSearchHit($0) }, tab: bookmarksTab)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NoveliaImportedFontsChanged"))) { _ in model.refreshBackground() }
        .onValueChange(of: settings.fontSize) { _, _ in synchronizeSettings(systemIsDark: colorScheme == .dark) }
        .sheet(isPresented: $isShowingBookPreferences) { ReaderBookPreferencesView() }
        .onValueChange(of: settings.projectionRevision) { _, _ in speech.stop(); model.reloadBookPreferences() }
        .onValueChange(of: settings.appearanceRaw) { _, _ in synchronizeSettings(systemIsDark: colorScheme == .dark) }
        .onValueChange(of: model.isAnimating) { _, active in
            if !active { synchronizeSettings(systemIsDark: colorScheme == .dark) }
        }
        .onValueChange(of: model.isLayingOut) { _, active in
            if !active { synchronizeSettings(systemIsDark: colorScheme == .dark) }
        }
        .onValueChange(of: backgrounds.revision) { _, _ in model.refreshBackground() }
        .sheet(isPresented: $isShowingStyle) { styleSheet }
        .sheet(item: $model.activeNote) { note in noteSheet(note) }
        .alert("链接", isPresented: .init(
            get: { model.plainLinkMessage != nil },
            set: { if !$0 { model.plainLinkMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.plainLinkMessage = nil }
        } message: {
            Text(model.plainLinkMessage ?? "")
        }
    }

    // MARK: 顶部工具栏（覆盖层，显隐不改视口）

    private var topBar: some View {
        // 布局与材质由共用骨架提供；菜单内容与显隐（不淡出，直接禁用）保持本引擎行为。
        ReaderTopBarShell(
            bookTitle: model.source?.bookTitle ?? "阅读器",
            chapterTitle: currentChapterTitle,
            titleTrailer: { EmptyView() },
            menu: {
                if let accessory { accessory }
                if let key = model.bookmarkKey {
                    ReaderBookmarkButton(store: settings.bookmarks, bookKey: model.currentBookmarkKey ?? key, pageRange: model.currentPageRange,
                                         chapterTitle: currentChapterTitle, snippet: { model.currentPageSnippet }, chapterID: model.currentPageRange.flatMap { model.webChapterID($0.chapter) })
                    Button {
                        bookmarksTab = .bookmarks; isShowingBookmarks = true
                    } label: {
                        Label("书签与搜索", systemImage: "magnifyingglass")
                    }
                    .accessibilityLabel("书签与搜索")
                }
                Button {
                    isShowingTOC = true
                } label: {
                    Label("目录", systemImage: "list.bullet")
                }
                .accessibilityLabel("目录")
                if model.readingReturnPoint != nil {
                    Button("回到刚才阅读处") { model.returnToReading() }
                }
                ReaderKeepScreenOnMenuItem()
                Button { isShowingBookPreferences = true } label: { Label("本书文字处理", systemImage: "slider.horizontal.3") }
                Button {
                    draftStyle = model.style
                    isShowingStyle = true
                } label: {
                    Label("阅读设置", systemImage: "textformat.size")
                }
                .accessibilityLabel("阅读设置")
                Button { isShowingSpeech = true } label: { Label("朗读", systemImage: "speaker.wave.2") }
            }
        )
        .opacity(showChrome ? 1 : 0)
        .disabled(!showChrome)
    }

    private var currentChapterTitle: String {
        guard let source = model.source else { return "" }
        if let index = model.currentTOCIndex {
            return source.toc[index].title
        }
        return source.bookTitle
    }

    // MARK: 底部状态栏（页码 + 进度条）

    private var bottomBar: some View {
        ReaderBottomBarShell(
            showChrome: showChrome,
            batteryLevel: Double(batteryLevel),
            hiddenPercentText: showChrome ? nil : FractionText.percent(model.overallProgress),
            hiddenBackground: model.pageBackgroundColor
        ) {
            positionAndScrub
        }
    }

    /// 位置、进度条与百分比。拆成独立视图，避免 `body` 的类型推导过重。
    private var positionAndScrub: some View {
        ReaderPositionRow(
            positionTexts: [
                .chapterPage: showsTOCDiagnostics ? model.locationDescription : model.pageDescription,
                .chapterProgress: model.chapterProgressDescription,
                .bookProgress: model.bookProgressDescription
            ],
            previewText: isScrubbing ? scrubPreviewText : nil,
            value: scrubBinding,
            onEditingChanged: handleScrub,
            percentText: FractionText.percent(isScrubbing ? scrubProgress : model.overallProgress),
            scrubDisabled: model.status != .ready || model.isAnimating || model.isLayingOut
        )
    }

    private var scrubBinding: Binding<Double> {
        Binding(get: { isScrubbing ? scrubProgress : model.overallProgress },
                set: { scrubProgress = $0 })
    }

    private func handleScrub(editing: Bool) {
        if editing {
            scrubProgress = model.overallProgress
            withAnimation(.easeInOut(duration: 0.15)) { isScrubbing = true }
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { isScrubbing = false }
            model.seek(to: scrubProgress)
        }
    }

    /// 拖动进度条时预览目标位置：章节名来自与 `seek(to:)` 相同的章节权重换算。
    private var scrubPreviewText: String {
        let progress = isScrubbing ? scrubProgress : model.overallProgress
        let percent = FractionText.percent(progress)
        if let title = model.chapterTitle(forProgress: progress) {
            return "\(title) · 全书 \(percent)"
        }
        return "全书 \(percent)"
    }

    private func updateBatteryLevel() {
        batteryLevel = UIDevice.current.batteryLevel
    }

    // MARK: 目录

    private var tocSheet: some View {
        CompatNavigationStack {
            Group {
                if tocTab == .images, model.imageLibrary.isAvailable {
                    ReaderImageGallery(library: model.imageLibrary, chapterTitle: { model.chapterTitle($0) }) { entry in
                        isShowingTOC = false
                        model.jump(toImage: entry)
                    }
                } else if let diagnostic = model.tocDiagnosticText {
                    CompatUnavailable {
                        Label("没有目录", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text(diagnostic)
                    }
                } else {
                    ScrollViewReader { proxy in
                        List {
                            if showsTOCDiagnostics, !model.tocDiagnosticMessages.isEmpty {
                                Section {
                                    DisclosureGroup(isExpanded: $model.isTOCDiagnosticsExpanded) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            ForEach(Array(model.tocDiagnosticMessages.enumerated()), id: \.offset) { _, message in
                                                Text(message)
                                                    .font(.footnote)
                                                    .foregroundStyle(.secondary)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    } label: {
                                        Label("目录诊断说明（\(model.tocDiagnosticMessages.count)）", systemImage: "info.circle")
                                            .font(.footnote)
                                    }
                                }
                            }
                            if let tocWordCounts {
                                ReaderTOCWordCountHeader(total: tocWordCounts.total)
                            }
                            let tocEntries = model.source?.toc ?? []
                            // 每次渲染只计算一次：列表行是惰性加载的，但之前每行都会重新扫描整个目录。
                            let currentIndex = model.currentTOCIndex
                            let levels = tocEntries.map(\.level)
                            let hasChildren = TOCOutline.hasChildren(levels: levels)
                            ForEach(TOCOutline.visibleIndices(levels: levels, expanded: tocExpanded), id: \.self) { index in
                                let entry = tocEntries[index]
                                ReaderTOCRow(title: entry.title, level: entry.level,
                                             subtitle: ReaderTOCRow.subtitle(wordCount: tocWordCounts?.entry(index),
                                                                             detail: showsTOCDiagnostics && model.container != nil ? entry.spineIndex.map { "spine \($0 + 1)" } : nil),
                                             isCurrent: currentIndex == index,
                                             hasChildren: hasChildren[index],
                                             isExpanded: tocExpanded.contains(index),
                                             showsDisclosureColumn: hasChildren.contains(true),
                                             toggle: { toggleTOCGroup(index) }) {
                                    isShowingTOC = false
                                    model.jump(to: entry)
                                }
                                .id(index)
                            }
                        }
                        .task {
                            if tocWordCounts == nil { tocWordCounts = await model.tocWordCounts() }
                        }
                        .onAppear {
                            if let current = model.currentTOCIndex {
                                tocExpanded = Set(TOCOutline.ancestors(of: current, levels: (model.source?.toc ?? []).map(\.level)))
                                // 等展开后的行进入列表再定位。
                                DispatchQueue.main.async { proxy.scrollTo(current, anchor: .center) }
                            } else {
                                tocExpanded = []
                            }
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ReaderTOCNavigationToolbar(
                showsImageTabs: model.imageLibrary.isAvailable,
                levels: (model.source?.toc ?? []).map(\.level),
                tocTab: $tocTab,
                expanded: $tocExpanded,
                onClose: { isShowingTOC = false }
            ))
        }
        .compatPresentationDetents(.medium, .large)

    }

    private func toggleTOCGroup(_ index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if tocExpanded.contains(index) { tocExpanded.remove(index) } else { tocExpanded.insert(index) }
        }
    }

    private var tocDiagnosticsPrompt: some View {
        CompatNavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("本书有目录与排版说明", systemImage: "info.circle")
                    .font(.headline)
                Text("打开目录可以查看本书的目录解析和排版兼容性诊断。可点击复制全部说明，也支持长按选择文字。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DisclosureGroup(isExpanded: $model.isTOCDiagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.tocDiagnosticMessages.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("诊断说明（\(model.tocDiagnosticMessages.count)）")
                        .font(.subheadline.weight(.medium))
                }
                Button {
                    UIPasteboard.general.string = model.tocDiagnosticMessages.joined(separator: "\n\n")
                    didCopyDiagnostics = true
                } label: {
                    Label(didCopyDiagnostics ? "已复制" : "复制全部说明",
                          systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
                }
                .disabled(model.tocDiagnosticMessages.isEmpty)
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("目录说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("知道了") { model.isShowingTOCDiagnosticsPrompt = false }
                }
            }
        }
        .compatPresentationDetents(.medium)
        .compatPresentationDragIndicatorVisible()
        .onAppear { didCopyDiagnostics = false }
    }

    // MARK: 阅读设置（二级面板；点击应用后一次性重排）

    private func synchronizeSettings(systemIsDark: Bool) {
        // 进入后台后系统会分别以浅色和深色截取快照，环境外观会短暂来回切换；
        // 这时重排既浪费又可能被挂起打断，等回到前台再按实际外观同步。
        guard scenePhase != .background else { return }
        model.synchronizeSharedSettings(systemIsDark: systemIsDark)
    }

    private var styleSheet: some View {
        ReaderStyleSheet(draftStyle: $draftStyle,
                         canApply: !(model.isAnimating || model.isLayingOut),
                         onApply: {
                             model.applyStyle(draftStyle)
                             isShowingStyle = false
                         },
                         onClose: { isShowingStyle = false },
                         onDeletedFont: { deletedFamily in
                             if model.style.fontFamily == deletedFamily {
                                 var fallback = model.style
                                 fallback.fontFamily = nil
                                 model.applyStyle(fallback)
                             }
                         },
                         onMarkIssue: { model.markIssue() })
    }

    // MARK: 注脚弹层

    private func noteSheet(_ note: EPUBNote) -> some View {
        CompatNavigationStack {
            ScrollView {
                Text(note.text)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .navigationTitle("注释")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("关闭") { model.activeNote = nil }
                }
            }
        }
        .compatPresentationDetents(.medium)
        // 半屏 sheet 默认为半透明材质，注释正文需要不透明底色才易读。
        .compatPresentationBackground(Color(uiColor: .systemBackground))
    }
}

#endif

/// UIFont 列出的字体族包含系统字体以及已安装且对本 App 可见的设备字体。
struct EPUBFontPicker: View {
    @Binding var selection: String?
    var onDeleteImportedFamily: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var families: [String] {
        UIFont.familyNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { query.isEmpty || $0.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            NavigationLink {
                EPUBImportedFontsView(selection: $selection,
                                           onDeleteImportedFamily: onDeleteImportedFamily)
            } label: {
                Label("管理导入的字体", systemImage: "square.and.arrow.down")
            }
            Button {
                selection = nil
                dismiss()
            } label: {
                HStack {
                    Text("书籍默认")
                    Spacer()
                    if selection == nil { Image(systemName: "checkmark") }
                }
            }
            ForEach(families, id: \.self) { family in
                Button {
                    selection = family
                    dismiss()
                } label: {
                    HStack {
                        Text(family)
                            .font(.custom(UIFont.fontNames(forFamilyName: family).first ?? family, size: 17))
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection == family { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .navigationTitle("本机字体")
        .searchable(text: $query, prompt: "搜索字体")
    }
}

private struct EPUBImportedFontsView: View {
    @Binding var selection: String?
    var onDeleteImportedFamily: (String) -> Void
    @State private var fonts: [EPUBLocalFonts.ImportedFont] = []
    @State private var isImportingFont = false
    @State private var importError: String?
    @State private var importedFamily: String?
    @State private var fontToDelete: EPUBLocalFonts.ImportedFont?

    var body: some View {
        List {
            Button {
                isImportingFont = true
            } label: {
                Label("从“文件”导入字体", systemImage: "plus")
            }
            if let importedFamily {
                Text("已导入并选中：\(importedFamily)。返回阅读设置后点击“应用”生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if fonts.isEmpty {
                CompatUnavailable("尚未导入字体", systemImage: "textformat",
                                       description: Text("支持从“文件”导入 TTF、OTF、TTC 字体。"))
            } else {
                ForEach(fonts) { font in
                    HStack {
                        Button {
                            selection = font.family
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(font.family)
                                    Text(font.format).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == font.family { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            fontToDelete = font
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除 \(font.family)")
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { fontToDelete = font }
                    }
                }
            }
        }
        .navigationTitle("导入的字体")
        .onAppear { reload() }
        .sheet(isPresented: $isImportingFont) {
            EPUBFilePicker(contentTypes: [.item]) { urls in
                isImportingFont = false
                guard let url = urls.first else { return }
                do {
                    let family = try EPUBLocalFonts.importFont(from: url)
                    selection = family
                    importedFamily = family
                    reload()
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .alert("字体导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog("删除导入的字体？", isPresented: Binding(
            get: { fontToDelete != nil },
            set: { if !$0 { fontToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除字体文件", role: .destructive) {
                if let fontToDelete { delete(fontToDelete) }
                fontToDelete = nil
            }
            Button("取消", role: .cancel) { fontToDelete = nil }
        } message: {
            Text("删除后如需再次使用，请重新导入字体文件。")
        }
    }

    private func reload() {
        fonts = EPUBLocalFonts.importedFonts()
    }

    private func delete(_ font: EPUBLocalFonts.ImportedFont) {
        do {
            try EPUBLocalFonts.deleteFont(font)
            if selection == font.family { selection = nil }
            onDeleteImportedFamily(font.family)
            if importedFamily == font.family { importedFamily = nil }
            reload()
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - 文件选择（UIKit 文档选择器：iCloud 按需下载可靠，任意文件可选）

struct EPUBFilePicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.data]
    var allowsMultipleSelection = false
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // copy 导入模式：系统把所选文件复制进应用沙箱后回调，
        // 不受 open 模式的 UTI 启用规则与 iCloud 占位文件影响，条目总能点选。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

// MARK: - 打开入口（注入样例书或指定 EPUB；以全屏页方式呈现）

struct EPUBReaderHost: View {
    @EnvironmentObject private var settings: ReaderSettings
    @State private var preferenceID: String?
    let initialURL: URL?
    var statisticsID: String? = nil
    var statisticsTitle: String? = nil
    var webContext: WebNovelEPUBContext? = nil
    var onReachedEnd: (() -> Void)? = nil
    var accessory: AnyView? = nil
    @State private var resolvedURL: URL?
    /// 实验：EPUB 改由 Readium（WKWebView）排版。iOS 15 目标没有原生分页，固定走 Readium。
    #if !NOVELIA_READIUM_ONLY
    @AppStorage(SettingsKey.readerEPUBReadium) private var usesReadium = false
    #endif

    private func descriptor(for url: URL) -> ReadingBook {
        ReadingBook(id: statisticsID ?? "epub:\(url.lastPathComponent)",
                    title: statisticsTitle ?? url.deletingPathExtension().lastPathComponent, kind: .epub)
    }

    /// 调试：Debug 构建中 `-prototypeBookPath <路径>` 直接打开指定 EPUB（自动化/真机排查用）。
    private var debugBookURL: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-prototypeBookPath"),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
        #else
        return nil
        #endif
    }

    var body: some View {
        Group {
            if let resolvedURL {
                #if NOVELIA_READIUM_ONLY
                ReadiumEPUBReaderView(bookURL: resolvedURL, accessory: accessory, statisticsBook: descriptor(for: resolvedURL), webContext: webContext, onReachedEnd: onReachedEnd)
                #else
                if usesReadium {
                    ReadiumEPUBReaderView(bookURL: resolvedURL, accessory: accessory, statisticsBook: descriptor(for: resolvedURL), webContext: webContext, onReachedEnd: onReachedEnd)
                } else {
                    EPUBReaderView(bookURL: resolvedURL, accessory: accessory, statisticsBook: descriptor(for: resolvedURL), webContext: webContext, onReachedEnd: onReachedEnd)
                }
                #endif
            } else {
                ProgressView("准备样例书…")
            }
        }
        .onDisappear { if let preferenceID { settings.deactivateBook(preferenceID) } }
        .task {
            if resolvedURL == nil {
                if let debugBookURL {
                    resolvedURL = debugBookURL
                } else if let initialURL {
                    let hash = try? await Task.detached { try FileContentHash.sha256(initialURL) }.value
                    let id = webContext?.bookKey ?? hash.map { "epub:\($0)" } ?? "file:\(initialURL.lastPathComponent)"
                    settings.activateBook(id); preferenceID = id
                    resolvedURL = initialURL
                } else {
                    #if DEBUG
                    resolvedURL = try? await EPUBSampleBook.sampleURL()
                    #endif
                }
            }
        }
    }
}

#if !NOVELIA_READIUM_ONLY
/// 仅阅读器界面控件变化时复用页面绘制视图。分页、阅读位置或缓存页面
/// 变化时，模型仍会使此观察视图更新。
private struct EPUBReaderPageSurface: View, Equatable {
    @ObservedObject var model: EPUBReaderModel
    let speech: SpeechPlaybackController
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settings: ReaderSettings
    @Binding var showChrome: Bool
    let size: CGSize
    let speechRects: [CGRect]
    let searchRects: [CGRect]
    @Environment(\.readerSpeechActions) private var speechActions
    @State private var translateText: String?
    @State private var showsTranslate = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.size == rhs.size && lhs.speechRects == rhs.speechRects && lhs.searchRects == rhs.searchRects
    }

    var body: some View {
        EPUBPagerView(
            canTurn: { forward in model.canTurn(forward: forward) },
            onCommit: { forward in
                model.commitTurn(forward: forward)
            },
            onBlockedTurn: { model.blockedTurn(forward: $0) },
            onAnimatingChange: { animating in model.setAnimating(animating) },
            linkHitTest: { point in model.linkHit(at: point) },
            onImageTap: { point in model.openImage(at: point) },
            onNoteTap: { text in model.activeNote = EPUBNote(text: text) },
            onPlainLinkTap: { href in
                // 生成的在线章节包含网页链接，按滚动阅读器的方式打开；
                // EPUB 链接仍解析为书内章节。
                if model.container == nil, let url = URL(string: href),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    openURL(url)
                } else {
                    model.openLink(href)
                }
            },
            onCenterTap: { withAnimation(.easeInOut(duration: 0.15)) { showChrome.toggle() } },
            selectionRangeAt: { point in model.selectionRange(at: point) },
            selectionRects: { range in model.selectionRects(for: range) },
            selectedText: { range in model.selectedText(for: range) },
            speechRects: speechRects,
            onSpeechTap: { speech.toggleHighlightedSpeech() },
            onSpeakSelection: { range in
                speechActions.start(SpeechAnchor(chapterIndex: model.location.spineIndex, progression: 0,
                                                chapterUTF16Length: 0, startIndexHint: nil, sourceUTF16Offset: range.location))
            },
            selectionTranslate: { text in
                translateText = text
                showsTranslate = true
            },
            images: model.pagerImages()
        )
        .overlay {
            Path { path in for rect in searchRects { path.addRect(rect) } }
                .fill(Color.yellow.opacity(0.35)).allowsHitTesting(false).accessibilityHidden(true)
        }
        .compatTranslationPresentation(isPresented: $showsTranslate, text: translateText)
        .frame(width: size.width, height: size.height)
    }

}

#endif

// MARK: - 可折叠目录（YueduCoreText 与 Readium 阅读器共用）

/// 目录顶部的全书字数（口径见 `BookWordCount`）。
struct ReaderTOCWordCountHeader: View {
    let total: Int

    var body: some View {
        Text("全书 \(BookWordCount.format(total))")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("全书字数 \(BookWordCount.format(total))")
    }
}

/// 目录面板的导航栏按钮。iOS 16 及以上按条件插入项目；
/// iOS 15 的 `ToolbarContentBuilder` 不能生成 `Optional`，改成确定的按钮组合。
struct ReaderTOCNavigationToolbar: ViewModifier {
    let showsImageTabs: Bool
    let levels: [Int]
    @Binding var tocTab: ReaderTOCTab
    @Binding var expanded: Set<Int>
    let onClose: () -> Void

    private var showsExpand: Bool {
        (tocTab == .contents || !showsImageTabs) && levels.contains { $0 > 0 }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.toolbar {
                ToolbarItem(placement: .compatTopBarLeading) { Button("关闭", action: onClose) }
                if showsImageTabs {
                    ToolbarItem(placement: .principal) { ReaderTOCTabPicker(selection: $tocTab) }
                }
                if showsExpand {
                    ToolbarItem(placement: .compatTopBarTrailing) {
                        ReaderTOCExpandAllButton(levels: levels, expanded: $expanded)
                    }
                }
            }
        } else if showsImageTabs && showsExpand {
            content.toolbar { closeButton; imageTabs; expandButton }
        } else if showsImageTabs {
            content.toolbar { closeButton; imageTabs }
        } else if showsExpand {
            content.toolbar { closeButton; expandButton }
        } else {
            content.toolbar { closeButton }
        }
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .compatTopBarLeading) { Button("关闭", action: onClose) }
    }

    private var imageTabs: some ToolbarContent {
        ToolbarItem(placement: .principal) { ReaderTOCTabPicker(selection: $tocTab) }
    }

    private var expandButton: some ToolbarContent {
        ToolbarItem(placement: .compatTopBarTrailing) {
            ReaderTOCExpandAllButton(levels: levels, expanded: $expanded)
        }
    }
}

/// 目录右上角的「全部展开／全部折叠」。
struct ReaderTOCExpandAllButton: View {
    let levels: [Int]
    @Binding var expanded: Set<Int>

    var body: some View {
        let flags = TOCOutline.hasChildren(levels: levels)
        let groups = Set(levels.indices.filter { flags[$0] })
        let allExpanded = !groups.isEmpty && groups.isSubset(of: expanded)
        Button(allExpanded ? "全部折叠" : "全部展开") {
            withAnimation(.easeInOut(duration: 0.2)) { expanded = allExpanded ? [] : groups }
        }
    }
}
