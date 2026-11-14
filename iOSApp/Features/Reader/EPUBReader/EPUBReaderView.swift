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
    @Environment(\.readerCloseAction) private var readerCloseAction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.speechHandoff) private var speechHandoff
    @AppStorage(SettingsKey.readerBookBackgroundFollow) private var bookBackgroundFollow = ReaderBookBackgroundFollow.default.rawValue
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
    @State private var isShowingAnnotations = false
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
                                          pageInsets: geometry.safeAreaInsets, curlEnabled: settings.nativePageCurlEnabled,
                                          speechRects: model.speechHighlightRects, searchRects: model.searchHighlightRects,
                                          annotationHighlights: model.annotationHighlights)
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
                model.bookBackgroundFollow = ReaderBookBackgroundFollow(storedValue: bookBackgroundFollow)
                model.onManualNavigation = { speech.suspendFollow(true) }
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
        .pageKeyboardActions(enabled: keyboardEnabled, keyboardActions)
        .modifier(ReaderRecapPresentation(store: settings.recaps, source: model.localRecapSource,
            active: model.status == .ready && !model.isLayingOut && !speech.isActive
                && !isShowingTOC && !isShowingStyle && !isShowingBookmarks && !isShowingAnnotations && !isShowingSpeech
                && !isShowingBookPreferences && model.activeNote == nil && model.plainLinkMessage == nil,
            libraryBookKey: statisticsBook?.id))
        .modifier(ReaderSpeechPresentation(controller: speech, isPresented: $isShowingSpeech,
                                  anchor: { model.speechAnchor },
                                  title: model.source?.bookTitle ?? "阅读器",
                                  bookKey: model.bookmarkKey ?? settings.activeBookID,
                                  isReady: model.status == .ready,
                                  chapterTitle: { model.chapterTitle($0) },
                                  jumpToSpoken: { model.jumpToSpeechPosition() },
                                  onResumeSaved: { point in resumeSpeech(at: point) },
                                  onProgressSave: { [weak model = model] point in model?.recordListeningProgress(point) }) {
                SystemSpeechEngine(chapterCount: model.chapterCount,
                                   onReadingPosition: { position, settings in model.updateSpeechPosition(position, settings: settings) }) { index in
                    try await model.speechChapterText(index)
                }
            })
        .sheet(isPresented: $isShowingTOC) { tocSheet.keyboardDismissible() }
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
                    .keyboardDismissible()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NoveliaImportedFontsChanged"))) { _ in model.refreshBackground() }
        .onValueChange(of: settings.fontSize) { _, _ in synchronizeSettings(systemIsDark: colorScheme == .dark) }
        .sheet(isPresented: $isShowingBookPreferences) { ReaderBookPreferencesView() }
        .sheet(isPresented: $isShowingAnnotations) {
            if let key = model.bookmarkKey ?? settings.activeBookID {
                ReaderAnnotationsSheet(store: settings.annotations, bookKey: key,
                                       bookTitle: model.source?.bookTitle ?? "阅读",
                                       chapterTitle: { model.chapterTitle($0) },
                                       onJump: { annotation in
                                           isShowingAnnotations = false
                                           model.jump(to: annotation)
                                       })
            }
        }
        .onValueChange(of: settings.projectionRevision) { _, _ in speech.stop(); model.reloadBookPreferences() }
        .onValueChange(of: settings.appearanceRaw) { _, _ in synchronizeSettings(systemIsDark: colorScheme == .dark) }
        .onValueChange(of: model.isAnimating) { _, active in
            if !active { synchronizeSettings(systemIsDark: colorScheme == .dark) }
        }
        .onValueChange(of: model.isLayingOut) { _, active in
            if !active { synchronizeSettings(systemIsDark: colorScheme == .dark) }
        }
        .onValueChange(of: bookBackgroundFollow) { _, value in
            model.bookBackgroundFollow = ReaderBookBackgroundFollow(storedValue: value)
            model.refreshBackground()
        }
        .onValueChange(of: backgrounds.revision) { _, _ in model.refreshBackground() }
        .sheet(isPresented: $isShowingStyle) { styleSheet.keyboardDismissible() }
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

    /// 从上次收听位置继续：先跳到该章，再按当前阅读位置起播。
    private func resumeSpeech(at point: SpeechResumePoint) {
        model.jump(toChapter: point.chapterIndex, progression: point.progression)
        speech.start(from: point.anchor)
    }

    // MARK: 顶部工具栏（覆盖层，显隐不改视口）

    private var topBar: some View {
        // 布局与材质由共用骨架提供；菜单内容与显隐（不淡出，直接禁用）保持本引擎行为。
        ReaderTopBarShell(
            bookTitle: model.source?.bookTitle ?? "阅读器",
            chapterTitle: currentChapterTitle,
            titleTrailer: { EmptyView() },
            menu: {
                if let action = textBook?.adjustTXTChapters {
                    Button {
                        speech.stop()
                        action()
                    } label: {
                        Label("TXT分章调整", systemImage: "text.alignleft")
                    }
                    .accessibilityLabel("TXT分章调整")
                }
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
                    Button {
                        isShowingAnnotations = true
                    } label: {
                        Label("摘录与笔记", systemImage: "highlighter")
                    }
                    .accessibilityLabel("摘录与笔记")
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
                if model.localTimeSource != nil { ReaderRemainingTimeMenu(store: settings.remainingTime) }
                if model.localRecapSource != nil { ReaderRecapMenu(store: settings.recaps) }
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

    private var keyboardEnabled: Bool {
        !isShowingTOC && !isShowingStyle && !isShowingBookmarks && !isShowingAnnotations
            && !isShowingSpeech && !isShowingBookPreferences && model.activeNote == nil && model.plainLinkMessage == nil
    }
    private var keyboardActions: [PageKeyAction] {
        var actions = readerKeyboardActions(search: { bookmarksTab = .search; isShowingBookmarks = true },
            contents: { isShowingTOC = true }, settings: { isShowingStyle = true },
            close: { if let readerCloseAction { readerCloseAction() } else { dismiss() } })
        if model.status == .ready {
            actions += PageKeyAction.pages(previous: { speech.suspendFollow(true); model.commitTurn(forward: false) }, next: { speech.suspendFollow(true); model.commitTurn(forward: true) })
        }
        return actions
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
            hiddenBackground: settings.nativePageCurlEnabled ? .clear : model.pageBackgroundColor,
            coversBottomSafeArea: settings.nativePageCurlEnabled,
            readingTime: AnyView(ReaderRemainingTimeView(store: settings.remainingTime,
                source: model.localTimeSource, point: model.readingTimePoint, mode: "paged|" + settings.projection.identity,
                active: model.status == .ready && !model.isLayingOut && !isScrubbing && !speech.isActive
                    && !isShowingTOC && !isShowingStyle && !isShowingBookmarks && !isShowingAnnotations && !isShowingSpeech
                    && !isShowingBookPreferences && model.activeNote == nil && model.plainLinkMessage == nil,
                isListening: speech.isActive))
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
                         onMarkIssue: { model.markIssue() }, supportsNativePageTurn: true)
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


/// 仅阅读器界面控件变化时复用页面绘制视图。分页、阅读位置或缓存页面
/// 变化时，模型仍会使此观察视图更新。
private struct EPUBReaderPageSurface: View, Equatable {
    @ObservedObject var model: EPUBReaderModel
    let speech: SpeechPlaybackController
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settings: ReaderSettings
    @Binding var showChrome: Bool
    let size: CGSize
    let pageInsets: EdgeInsets
    let curlEnabled: Bool
    let speechRects: [CGRect]
    let searchRects: [CGRect]
    let annotationHighlights: [EPUBReaderModel.AnnotationHighlight]
    @Environment(\.readerSpeechActions) private var speechActions
    @Environment(\.characterLookup) private var characterLookup
    @State private var translateText: String?
    @State private var showsTranslate = false
    @State private var annotationEditor: AnnotationEditorTarget?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.size == rhs.size && lhs.pageInsets == rhs.pageInsets && lhs.curlEnabled == rhs.curlEnabled && lhs.speechRects == rhs.speechRects && lhs.searchRects == rhs.searchRects && lhs.annotationHighlights == rhs.annotationHighlights
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
            characterLookup: characterLookup,
            selectionTranslate: { text in
                translateText = text
                showsTranslate = true
            },
            annotationHitTest: { point in model.annotationID(at: point) },
            onAnnotationTap: { id in
                if let annotation = settings.annotations.annotation(id: id) {
                    annotationEditor = .init(range: nil, quote: annotation.quote, annotation: annotation)
                }
            },
            onHighlightSelection: { range, quote in
                _ = model.addAnnotation(range: range, quote: quote)
            },
            onNoteSelection: { range, quote in
                annotationEditor = .init(range: range, quote: quote, annotation: nil)
            },
            curlEnabled: curlEnabled,
            paperInsets: UIEdgeInsets(top: pageInsets.top, left: pageInsets.leading, bottom: pageInsets.bottom, right: pageInsets.trailing),
            paperColor: UIColor(model.pageBackgroundColor),
            paperBackground: settings.backgrounds.image(dark: model.isDarkMode, landscape: size.width > size.height),
            images: model.pagerImages()
        )
        .overlay {
            ForEach(ReaderAnnotation.Color.allCases, id: \.self) { color in
                Path { path in
                    for highlight in annotationHighlights where highlight.color == color {
                        path.addRect(highlight.rect)
                    }
                }
                .fill(color.swiftUIColor.opacity(0.35))
                .offset(x: curlEnabled ? pageInsets.leading : 0, y: curlEnabled ? pageInsets.top : 0)
                // 卷页纸面已画入标注；覆盖层再画一次会叠加变深，动画中也会悬在卷起的页面上。
                .opacity(curlEnabled || model.isAnimating ? 0 : 1)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay {
            Path { path in for rect in searchRects { path.addRect(rect) } }
                .fill(Color.yellow.opacity(0.35))
                .offset(x: curlEnabled ? pageInsets.leading : 0, y: curlEnabled ? pageInsets.top : 0)
                .opacity(model.isAnimating ? 0 : 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .sheet(item: $annotationEditor) { target in
            AnnotationEditorSheet(target: target,
                                  onSave: { color, note in
                                      if let annotation = target.annotation {
                                          try? settings.annotations.update(annotation.id, color: color, note: note)
                                      } else if let range = target.range {
                                          _ = model.addAnnotation(range: range, quote: target.quote, color: color, note: note)
                                      }
                                  },
                                  onDelete: target.annotation.map { annotation in
                                      { try? settings.annotations.remove(annotation.id) }
                                  })
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            Text("\(annotationHighlights.count)")
                .font(.system(size: 1)).opacity(0.01)
                .accessibilityIdentifier("native-annotation-count")
                .allowsHitTesting(false)
        }
        #endif
        .compatTranslationPresentation(isPresented: $showsTranslate, text: translateText)
        .ignoresSafeArea(edges: curlEnabled ? .all : [])
    }

}

#endif
