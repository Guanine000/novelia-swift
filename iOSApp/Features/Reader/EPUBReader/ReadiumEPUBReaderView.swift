import ReadiumNavigator
import SwiftUI
import UIKit

// MARK: - Readium EPUB 阅读界面（实验）
//
// 外观与 EPUBReaderView 一致：全屏正文、覆盖式顶栏与底栏、点击中部显隐工具栏、
// 左右边缘点击或横向滑动翻页（Readium 自带水平滑动动画）。

struct ReadiumEPUBReaderView: View {
    @EnvironmentObject private var settings: ReaderSettings
    let bookURL: URL?
    var textBook: PagedTextBook? = nil
    var accessory: AnyView? = nil
    var statisticsBook: ReadingBook? = nil
    var webContext: WebNovelEPUBContext? = nil
    var onReachedEnd: (() -> Void)? = nil
    var body: some View {
        ReadiumEPUBReaderViewContent(bookURL: bookURL, textBook: textBook, accessory: accessory,
                          statisticsBook: statisticsBook, settings: settings, webContext: webContext, onReachedEnd: onReachedEnd)
    }
}

private struct ReadiumEPUBReaderViewContent: View {
    @EnvironmentObject private var services: AppServices
    @ObservedObject private var settings: ReaderSettings
    @ObservedObject private var backgrounds: ReaderBackgroundStore
    @StateObject private var model: ReadiumEPUBReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showChrome = true
    @State private var isShowingTOC = false
    /// 目录诊断说明默认隐藏，在设置里打开调试选项后才显示。
    @AppStorage(ReaderDebugOptions.showsTOCDiagnosticsKey) private var showsTOCDiagnostics = false
    /// 目录中已展开的分组（条目序号）；每次打开目录时重置为只展开当前章节所在分组。
    @State private var tocExpanded = Set<Int>()
    @State private var tocTab = ReaderTOCTab.contents
    @State private var tocWordCounts: ReaderTOCWordCounts?
    @State private var isShowingBookPreferences = false
    @State private var isShowingStyle = false
    @State private var isShowingBookmarks = false
    @State private var bookmarksTab = ReaderBookmarksSearchSheet.Tab.bookmarks
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var draftStyle = EPUBReaderStyle()
    @AppStorage(SettingsKey.readerBookBackgroundFollow) private var bookBackgroundFollow = ReaderBookBackgroundFollow.default.rawValue
    @State private var batteryLevel: Float = -1
    @State private var wasBatteryMonitoringEnabled = false
    let bookURL: URL?
    var textBook: PagedTextBook? = nil
    var accessory: AnyView? = nil
    var statisticsBook: ReadingBook? = nil

    private var pageBackground: SwiftUI.Color {
        settings.appearance.background(system: model.isDarkMode ? .dark : .light)
    }


    init(bookURL: URL?, textBook: PagedTextBook?, accessory: AnyView?, statisticsBook: ReadingBook?, settings: ReaderSettings, webContext: WebNovelEPUBContext?, onReachedEnd: (() -> Void)?) {
        self.bookURL = bookURL; self.textBook = textBook; self.accessory = accessory
        self.statisticsBook = statisticsBook
        _settings = ObservedObject(wrappedValue: settings)
        _backgrounds = ObservedObject(wrappedValue: settings.backgrounds)
        _model = StateObject(wrappedValue: ReadiumEPUBReaderModel(settings: settings, webContext: webContext, onReachedEnd: onReachedEnd))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 书籍自带的页面底色由模型涂在各章节视图上，随书页一起滑动。
                ReaderBackgroundView(dark: model.isDarkMode, fallback: pageBackground).ignoresSafeArea()
                switch model.status {
                case .idle, .opening:
                    ProgressView(textBook == nil ? "正在解析 EPUB…" : "正在打开章节…")
                case .failed(let message):
                    CompatUnavailable {
                        Label("无法打开", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message).textSelection(.enabled)
                    } actions: {
                        if textBook != nil {
                            Button("重试") { model.retryTextLoad() }
                        } else if let bookURL {
                            Button("重新打开") { model.retryOpening(url: bookURL) }
                        }
                        Button("复制错误说明") { UIPasteboard.general.string = message }
                        Button("关闭阅读器") { dismiss() }
                    }
                case .ready:
                    ReadiumNavigatorHost(model: model)
                        .id(model.navigatorRevision)
                        // 只延伸到上下边缘；横屏时左右仍避开刘海。
                        .ignoresSafeArea(edges: .vertical)
                        // 底栏不再放上一页／下一页按钮，保留 VoiceOver 的翻页动作。
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: model.goForward()
                            case .decrement: model.goBackward()
                            @unknown default: break
                            }
                        }
                }
            }
            .overlay(alignment: .top) {
                if showChrome {
                    topBar
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    if let failure = model.textLoadFailure {
                        Button { model.retryTextLoad() } label: {
                            Label("\(failure) · 点击重试", systemImage: "arrow.clockwise")
                                .font(.footnote).lineLimit(2).padding(8)
                        }
                        .background(.regularMaterial)
                    }
                    bottomBar
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(NoveliaStyle.brandGreen.opacity(0.8))
                    .frame(width: max(4, geometry.size.width * model.overallProgress), height: 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
        }
        // 书签／搜索面板弹出键盘时不缩小阅读视口，避免整书重新分页并跳页。
        .ignoresSafeArea(.keyboard)
#if DEBUG
        .overlay(alignment: .topLeading) {
            if model.validatesPagination {
                Text(model.validationVisibleParagraphs)
                    .font(.system(size: 1)).opacity(0.01)
                    .accessibilityIdentifier("readium-validation-visible-paragraphs")
                    .allowsHitTesting(false)
            }
        }
#endif
        .compatToolbar(.hidden, for: .navigationBar)
        .compatToolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
        .trackReadingTime(statisticsBook ?? ReadingBook(id: "epub:\(bookURL?.lastPathComponent ?? "text")",
                                                       title: bookURL?.deletingPathExtension().lastPathComponent ?? "阅读", kind: .epub),
                          ready: model.status == .ready)
        .onAppear {
            wasBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
            model.onCenterTap = { withAnimation(.easeInOut(duration: 0.15)) { showChrome.toggle() } }
        }
        .task {
            if let textBook { await model.open(textBook: textBook, systemIsDark: colorScheme == .dark) }
            else if let bookURL { await model.open(url: bookURL, systemIsDark: colorScheme == .dark) }
        }
        .onDisappear {
            if !wasBatteryMonitoringEnabled {
                UIDevice.current.isBatteryMonitoringEnabled = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onValueChange(of: colorScheme) { _, scheme in
            // 进入后台后系统以浅色、深色分别截取快照；此时重建导航器会丢失当前页，回到前台再同步。
            guard scenePhase != .background else { return }
            model.synchronizeSharedSettings(systemIsDark: scheme == .dark)
        }
        .onValueChange(of: scenePhase) { _, phase in
            if phase != .background { model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        }
        .onValueChange(of: settings.fontSize) { _, _ in model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        .sheet(isPresented: $isShowingBookPreferences) { ReaderBookPreferencesView() }
        .onValueChange(of: settings.projectionRevision) { _, _ in model.reloadBookPreferences(url: bookURL) }
        .onValueChange(of: settings.appearanceRaw) { _, _ in model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        .onValueChange(of: backgrounds.revision) { _, _ in model.refreshBackground() }
        .onValueChange(of: bookBackgroundFollow) { _, _ in model.refreshPageBackgroundRule() }
        .onAppear { ReaderKeepScreenOn.activate() }
        .onDisappear { ReaderKeepScreenOn.deactivate() }
        .task(id: model.status) {
            if model.status == .ready { await model.scanBookDiagnostics() }
        }
        .sheet(isPresented: $isShowingTOC) { tocSheet }
        .modifier(ReaderImagePresenter(library: model.imageLibrary, chapterTitle: { model.imageChapterTitle($0) },
                                       onJump: { model.jump(toImage: $0) }))
        .sheet(isPresented: $isShowingBookmarks) {
            if let key = model.bookmarkKey ?? settings.activeBookID {
                ReaderBookmarksSearchSheet(store: settings.bookmarks, bookKey: key, chapterCount: model.chapterCount,
                                           chapterTitle: { model.chapterTitle($0) },
                                           chapterText: { index in if let cached = textBook?.searchChapterText { return try await cached(index) }; return try await model.chapterPlainText(index) },
                                           onJump: { model.jump(toChapter: $0, progression: $1) },
                                           legacyBookKey: model.legacyBookmarkKey,
                                           chapterIDAtIndex: { model.webChapterID($0) },
                                           resolveChapter: { model.bookmarkIndex($0) }, scopeDescription: textBook?.searchChapterText == nil ? nil : "仅搜索已缓存章节，不会下载未缓存正文。", onSearchHit: { model.showSearchHit($0) }, tab: bookmarksTab)
            }
        }
        .sheet(isPresented: $isShowingStyle) { styleSheet }
        .sheet(item: $model.activeNote) { note in noteSheet(note) }
    }

    // MARK: 顶栏

    private var topBar: some View {
        // 布局与材质由共用骨架提供；菜单内容保持本引擎行为（引擎说明、就绪才可用的书签/目录）。
        // 显隐沿用条件包含：隐藏时顶栏整体不参与布局。
        ReaderTopBarShell(
            bookTitle: model.bookTitle.isEmpty ? "阅读器" : model.bookTitle,
            chapterTitle: model.currentChapterTitle,
            titleTrailer: {
                // 在线分页仍需区分实验引擎，标识随章节名一起放进顶栏。
                if textBook != nil { engineBadge }
            },
            menu: {
                if textBook == nil { Text("Readium 阅读引擎") }
                if let accessory { accessory }
                if let key = model.bookmarkKey, model.status == .ready {
                    ReaderBookmarkButton(store: settings.bookmarks, bookKey: model.currentBookmarkKey ?? key, pageRange: model.currentPageRange,
                                         chapterTitle: model.currentChapterTitle, snippet: { await model.currentPageSnippet() }, chapterID: model.currentPageRange.flatMap { model.webChapterID($0.chapter) })
                    Button {
                        bookmarksTab = .bookmarks; isShowingBookmarks = true
                    } label: {
                        Label("书签与搜索", systemImage: "magnifyingglass")
                    }
                    .accessibilityLabel("书签与搜索")
                }
                Button {
                    model.isTOCDiagnosticsExpanded = false
                    isShowingTOC = true
                } label: {
                    Label("目录", systemImage: "list.bullet")
                }
                .accessibilityLabel("目录")
                .disabled(model.status != .ready)
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
                .disabled(model.status != .ready)
            }
        )
    }

    private var engineBadge: some View {
        Text("Readium")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(NoveliaStyle.brandGreen.opacity(0.18), in: Capsule())
            .accessibilityLabel("Readium 实验引擎")
    }

    // MARK: 底栏

    private var bottomBar: some View {
        ReaderBottomBarShell(
            showChrome: showChrome,
            batteryLevel: Double(batteryLevel),
            hiddenPercentText: showChrome ? nil : FractionText.percent(model.overallProgress)
        ) {
            positionAndScrub
        }
    }

    /// 位置、进度条与百分比。拆成独立视图，避免 `body` 的类型推导过重。
    /// 引擎未就绪时整行不可用，与合并前的行为一致。
    private var positionAndScrub: some View {
        ReaderPositionRow(
            positionTexts: [
                .chapterPage: model.locationDescription,
                .chapterProgress: model.chapterProgressDescription,
                .bookProgress: model.bookProgressDescription
            ],
            previewText: isScrubbing ? scrubPreviewText : nil,
            value: scrubBinding,
            onEditingChanged: handleScrub,
            percentText: FractionText.percent(isScrubbing ? scrubProgress : model.overallProgress),
            scrubDisabled: model.status != .ready
        )
        .disabled(model.status != .ready)
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

    /// 拖动进度条时预览目标位置。Readium 的章节定位需要按进展异步查询，这里只给全书百分比。
    private var scrubPreviewText: String {
        "全书 \(FractionText.percent(isScrubbing ? scrubProgress : model.overallProgress))"
    }

    // MARK: 目录

    private var tocSheet: some View {
        CompatNavigationStack {
            Group {
                if tocTab == .images, model.imageLibrary.isAvailable {
                    ReaderImageGallery(library: model.imageLibrary, chapterTitle: { model.imageChapterTitle($0) }) { entry in
                        isShowingTOC = false
                        model.jump(toImage: entry)
                    }
                } else {
                    tocList
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ReaderTOCNavigationToolbar(
                showsImageTabs: model.imageLibrary.isAvailable,
                levels: model.toc.map(\.level),
                tocTab: $tocTab,
                expanded: $tocExpanded,
                onClose: { isShowingTOC = false }
            ))
        }
        .compatPresentationDetents(.medium, .large)

    }

    private var tocList: some View {
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
                if let tocWordCounts, !model.toc.isEmpty {
                    ReaderTOCWordCountHeader(total: tocWordCounts.total)
                }
                if model.toc.isEmpty {
                    CompatUnavailable("没有目录", systemImage: "list.bullet.rectangle",
                                           description: Text(model.tocNotice ?? "本书未提供目录。"))
                }
                let levels = model.toc.map(\.level)
                let hasChildren = TOCOutline.hasChildren(levels: levels)
                ForEach(TOCOutline.visibleIndices(levels: levels, expanded: tocExpanded), id: \.self) { index in
                    let item = model.toc[index]
                    ReaderTOCRow(title: item.title, level: item.level,
                                 subtitle: tocWordCounts?.entry(index),
                                 isCurrent: model.currentTOCIndex == item.id,
                                 hasChildren: hasChildren[index],
                                 isExpanded: tocExpanded.contains(index),
                                 showsDisclosureColumn: hasChildren.contains(true),
                                 toggle: {
                                     withAnimation(.easeInOut(duration: 0.2)) {
                                         if tocExpanded.contains(index) { tocExpanded.remove(index) } else { tocExpanded.insert(index) }
                                     }
                                 }) {
                        isShowingTOC = false
                        model.jump(to: item)
                    }
                    .id(item.id)
                }
            }
            .task {
                if tocWordCounts == nil { tocWordCounts = await model.tocWordCounts() }
            }
            .onAppear {
                if let current = model.currentTOCIndex,
                   let index = model.toc.firstIndex(where: { $0.id == current }) {
                    tocExpanded = Set(TOCOutline.ancestors(of: index, levels: model.toc.map(\.level)))
                    // 等展开后的行进入列表再定位。
                    DispatchQueue.main.async { proxy.scrollTo(current, anchor: .center) }
                } else {
                    tocExpanded = []
                }
            }
        }
    }

    // MARK: 阅读设置

    private var styleSheet: some View {
        ReaderStyleSheet(draftStyle: $draftStyle,
                         canApply: model.status == .ready,
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

    // MARK: 注脚

    private func noteSheet(_ note: EPUBNote) -> some View {
        CompatNavigationStack {
            ScrollView {
                Text(note.text)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .textSelection(.enabled)
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

// MARK: - 导航器宿主

/// 把模型当前的 EPUBNavigatorViewController 作为子控制器嵌入；重建导航器时由 `.id` 换新宿主。
private struct ReadiumNavigatorHost: UIViewControllerRepresentable {
    let model: ReadiumEPUBReaderModel

    func makeUIViewController(context: Context) -> ReadiumNavigatorContainer {
        let container = ReadiumNavigatorContainer()
        if let navigator = model.navigator { container.embed(navigator) }
        return container
    }

    func updateUIViewController(_ container: ReadiumNavigatorContainer, context: Context) {
        if let navigator = model.navigator, container.embedded !== navigator {
            container.embed(navigator)
        }
    }
}

final class ReadiumNavigatorContainer: UIViewController {
    var onSpeakSelection: ((Selection) -> Void)?
    @objc func speakSelection() {
        guard let selection = (embedded as? EPUBNavigatorViewController)?.currentSelection else { return }
        onSpeakSelection?(selection)
    }
    private(set) weak var embedded: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func embed(_ child: UIViewController) {
        if let embedded {
            embedded.willMove(toParent: nil)
            embedded.view.removeFromSuperview()
            embedded.removeFromParent()
        }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
        embedded = child
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Readium 在加载与应用设置时会把根视图涂成背景色；保持透明以显示阅读背景图。
        embedded?.view.backgroundColor = .clear
    }
}
