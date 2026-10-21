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
    var body: some View {
        ReadiumEPUBReaderViewContent(bookURL: bookURL, textBook: textBook, accessory: accessory,
                          statisticsBook: statisticsBook, settings: settings)
    }
}

private struct ReadiumEPUBReaderViewContent: View {
    @ObservedObject private var settings: ReaderSettings
    @ObservedObject private var backgrounds: ReaderBackgroundStore
    @StateObject private var model: ReadiumEPUBReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showChrome = true
    @State private var isShowingTOC = false
    /// 目录中已展开的分组（条目序号）；每次打开目录时重置为只展开当前章节所在分组。
    @State private var tocExpanded = Set<Int>()
    @State private var tocTab = ReaderTOCTab.contents
    @State private var isShowingStyle = false
    @State private var isShowingBookmarks = false
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var draftStyle = EPUBReaderStyle()
    @State private var batteryLevel: Float = -1
    @State private var wasBatteryMonitoringEnabled = false
    let bookURL: URL?
    var textBook: PagedTextBook? = nil
    var accessory: AnyView? = nil
    var statisticsBook: ReadingBook? = nil

    private var pageBackground: Color {
        settings.appearance.background(system: model.isDarkMode ? .dark : .light)
    }

    init(bookURL: URL?, textBook: PagedTextBook?, accessory: AnyView?, statisticsBook: ReadingBook?, settings: ReaderSettings) {
        self.bookURL = bookURL; self.textBook = textBook; self.accessory = accessory
        self.statisticsBook = statisticsBook
        _settings = ObservedObject(wrappedValue: settings)
        _backgrounds = ObservedObject(wrappedValue: settings.backgrounds)
        _model = StateObject(wrappedValue: ReadiumEPUBReaderModel(settings: settings))
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
                    ContentUnavailableView {
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
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if showChrome { topBar }
                    chapterHeader
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
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
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
        .onChange(of: colorScheme) { _, scheme in
            // 进入后台后系统以浅色、深色分别截取快照；此时重建导航器会丢失当前页，回到前台再同步。
            guard scenePhase != .background else { return }
            model.synchronizeSharedSettings(systemIsDark: scheme == .dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .background { model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        }
        .onChange(of: settings.fontSize) { _, _ in model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        .onChange(of: settings.appearanceRaw) { _, _ in model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        .onChange(of: backgrounds.revision) { _, _ in model.refreshBackground() }
        .task(id: model.status) {
            if model.status == .ready { await model.scanBookDiagnostics() }
        }
        .sheet(isPresented: $isShowingTOC) { tocSheet }
        .modifier(ReaderImagePresenter(library: model.imageLibrary, chapterTitle: { model.imageChapterTitle($0) },
                                       onJump: { model.jump(toImage: $0) }))
        .sheet(isPresented: $isShowingBookmarks) {
            if let key = model.bookmarkKey {
                ReaderBookmarksSearchSheet(store: settings.bookmarks, bookKey: key, chapterCount: model.chapterCount,
                                           chapterTitle: { model.chapterTitle($0) },
                                           chapterText: { try await model.chapterPlainText($0) },
                                           onJump: { model.jump(toChapter: $0, progression: $1) })
            }
        }
        .sheet(isPresented: $isShowingStyle) { styleSheet }
        .sheet(item: $model.activeNote) { note in noteSheet(note) }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("返回")
            Text(model.bookTitle.isEmpty ? "阅读器" : model.bookTitle)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if textBook == nil { engineBadge }
            if let accessory { accessory }
            if let key = model.bookmarkKey, model.status == .ready {
                ReaderBookmarkButton(store: settings.bookmarks, bookKey: key, pageRange: model.currentPageRange,
                                     chapterTitle: model.currentChapterTitle, snippet: { await model.currentPageSnippet() })
                Button {
                    isShowingBookmarks = true
                } label: {
                    Image(systemName: "magnifyingglass").frame(width: 36, height: 36)
                }
                .accessibilityLabel("书签与搜索")
            }
            Button {
                model.isTOCDiagnosticsExpanded = false
                isShowingTOC = true
            } label: {
                Image(systemName: "list.bullet").frame(width: 36, height: 36)
            }
            .accessibilityLabel("目录")
            .disabled(model.status != .ready)
            Button {
                draftStyle = model.style
                isShowingStyle = true
            } label: {
                Image(systemName: "textformat.size").frame(width: 36, height: 36)
            }
            .accessibilityLabel("阅读样式")
            .disabled(model.status != .ready)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(.thinMaterial)
    }

    private var engineBadge: some View {
        Text("Readium")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(NoveliaStyle.brandGreen.opacity(0.18), in: Capsule())
            .accessibilityLabel("Readium 实验引擎")
    }

    private var chapterHeader: some View {
        HStack {
            Text(model.currentChapterTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 在线分页还需容纳滚动切换及译源菜单，标识放到章节栏以免挤出控件。
            if textBook != nil { engineBadge }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .allowsHitTesting(false)
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if showChrome {
                HStack {
                    Button { model.goBackward() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上一页")
                    Spacer()
                    Text(model.locationDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("下一页")
                }
                .disabled(model.status != .ready)
            }
            HStack {
                Text(batteryLevel >= 0 ? "电量 \(Int((batteryLevel * 100).rounded()))%" : "电量 —")
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
            if showChrome {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { isScrubbing ? scrubProgress : model.overallProgress },
                        set: { scrubProgress = $0 }
                    ), in: 0...1, onEditingChanged: { editing in
                        if editing {
                            scrubProgress = model.overallProgress
                            isScrubbing = true
                        } else {
                            isScrubbing = false
                            model.seek(to: scrubProgress)
                        }
                    })
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(model.status != .ready)
                    .accessibilityLabel("阅读进度")
                    Text("\(Int((isScrubbing ? scrubProgress : model.overallProgress) * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, showChrome ? 10 : 4)
        .padding(.bottom, 10)
        .background {
            if showChrome { Rectangle().fill(.thinMaterial) }
        }
    }

    // MARK: 目录

    private var tocSheet: some View {
        NavigationStack {
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { isShowingTOC = false }
                }
                if model.imageLibrary.isAvailable {
                    ToolbarItem(placement: .principal) {
                        ReaderTOCTabPicker(selection: $tocTab)
                    }
                }
                if tocTab == .contents || !model.imageLibrary.isAvailable, model.toc.contains(where: { $0.level > 0 }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        ReaderTOCExpandAllButton(levels: model.toc.map(\.level), expanded: $tocExpanded)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var tocList: some View {
        ScrollViewReader { proxy in
            List {
                if !model.tocDiagnosticMessages.isEmpty {
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
                if model.toc.isEmpty {
                    ContentUnavailableView("没有目录", systemImage: "list.bullet.rectangle",
                                           description: Text(model.tocNotice ?? "本书未提供目录。"))
                }
                let levels = model.toc.map(\.level)
                let hasChildren = TOCOutline.hasChildren(levels: levels)
                ForEach(TOCOutline.visibleIndices(levels: levels, expanded: tocExpanded), id: \.self) { index in
                    let item = model.toc[index]
                    ReaderTOCRow(title: item.title, level: item.level,
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

    // MARK: 阅读样式

    private var styleSheet: some View {
        NavigationStack {
            Form {
                Section("背景") { NavigationLink("阅读背景") { ReaderBackgroundSettingsView() } }
                Section("分页") {
                    Toggle("双页模式", isOn: Binding(get: { draftStyle.doublePage == true }, set: { draftStyle.doublePage = $0 }))
                }
                Section("字体") {
                    NavigationLink {
                        EPUBFontPicker(selection: $draftStyle.fontFamily) { deletedFamily in
                            if model.style.fontFamily == deletedFamily {
                                var fallback = model.style
                                fallback.fontFamily = nil
                                model.applyStyle(fallback)
                            }
                        }
                    } label: {
                        HStack {
                            Text("字体选择")
                            Spacer()
                            Text(draftStyle.fontFamily ?? "书籍默认")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack {
                        Text("字号")
                        Slider(value: $draftStyle.fontSize, in: 12...36, step: 1)
                        Text("\(Int(draftStyle.fontSize))")
                            .monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
                Section("段落") {
                    Picker("阅读主题", selection: $settings.appearanceRaw) {
                        ForEach(ReaderAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    styleSlider("行间距", value: $draftStyle.lineSpacing, range: 0...24)
                    styleSlider("段落间距", value: $draftStyle.paragraphSpacing, range: 0...40)
                    Picker("首行缩进", selection: Binding(
                        get: { Int(draftStyle.firstLineIndentEm ?? -1) },
                        set: { draftStyle.firstLineIndentEm = $0 < 0 ? nil : CGFloat($0) }
                    )) {
                        Text("沿用书籍").tag(-1)
                        Text("无").tag(0)
                        ForEach(1...4, id: \.self) { value in
                            Text("\(value) 字宽").tag(value)
                        }
                    }
                }
                Section("页面边距") {
                    styleSlider("上", value: $draftStyle.topMargin, range: 0...120)
                    styleSlider("下", value: $draftStyle.bottomMargin, range: 0...120)
                    styleSlider("左", value: $draftStyle.leftMargin, range: 0...80)
                    styleSlider("右", value: $draftStyle.rightMargin, range: 0...80)
                }
                Section {
                    Button("恢复默认样式", systemImage: "arrow.counterclockwise") {
                        draftStyle = EPUBReaderStyle()
                    }
                    Text("行间距、段落间距、首行缩进设为非默认值时会覆盖书籍原有的段落样式；全部保持默认则沿用书籍排版。左右边距取两者平均值。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ReaderIssueMarkSection { model.markIssue() }
            }
            .navigationTitle("阅读样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { isShowingStyle = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") {
                        model.applyStyle(draftStyle)
                        isShowingStyle = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func styleSlider(_ label: String, value: Binding<CGFloat>,
                             range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text(label).frame(width: 68, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))")
                .monospacedDigit().frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: 注脚

    private func noteSheet(_ note: EPUBNote) -> some View {
        NavigationStack {
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { model.activeNote = nil }
                }
            }
        }
        .presentationDetents([.medium])
        // 半屏 sheet 默认为半透明材质，注释正文需要不透明底色才易读。
        .presentationBackground(Color(uiColor: .systemBackground))
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

private final class ReadiumNavigatorContainer: UIViewController {
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
