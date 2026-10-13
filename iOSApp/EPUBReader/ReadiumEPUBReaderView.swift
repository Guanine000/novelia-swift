import SwiftUI
import UIKit

// MARK: - Readium EPUB 阅读界面（实验）
//
// 外观与 EPUBReaderView 一致：全屏正文、覆盖式顶栏与底栏、点击中部显隐工具栏、
// 左右边缘点击或横向滑动翻页（Readium 自带水平滑动动画）。

struct ReadiumEPUBReaderView: View {
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var backgrounds = ReaderSettings.shared.backgrounds
    @StateObject private var model = ReadiumEPUBReaderModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showChrome = true
    @State private var isShowingTOC = false
    @State private var isShowingStyle = false
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var draftStyle = EPUBReaderStyle()
    @State private var batteryLevel: Float = -1
    @State private var wasBatteryMonitoringEnabled = false
    let bookURL: URL

    private var pageBackground: Color {
        settings.appearance.background(system: model.isDarkMode ? .dark : .light)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ReaderBackgroundView(dark: model.isDarkMode, fallback: pageBackground).ignoresSafeArea()
                switch model.status {
                case .idle, .opening:
                    ProgressView("正在解析 EPUB…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("无法打开", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
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
            .overlay(alignment: .bottom) { bottomBar }
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
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
        .onAppear {
            wasBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
            model.onCenterTap = { withAnimation(.easeInOut(duration: 0.15)) { showChrome.toggle() } }
            if model.status == .idle {
                Task { await model.open(url: bookURL, systemIsDark: colorScheme == .dark) }
            }
        }
        .onDisappear {
            if !wasBatteryMonitoringEnabled {
                UIDevice.current.isBatteryMonitoringEnabled = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onChange(of: colorScheme) { _, scheme in model.synchronizeSharedSettings(systemIsDark: scheme == .dark) }
        .onChange(of: settings.fontSize) { _, _ in model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        .onChange(of: settings.appearanceRaw) { _, _ in model.synchronizeSharedSettings(systemIsDark: colorScheme == .dark) }
        .onChange(of: backgrounds.revision) { _, _ in model.refreshBackground() }
        .sheet(isPresented: $isShowingTOC) { tocSheet }
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
            Text("Readium")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(NoveliaStyle.brandGreen.opacity(0.18), in: Capsule())
                .accessibilityLabel("Readium 实验引擎")
            Button {
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

    private var chapterHeader: some View {
        Text(model.currentChapterTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                if model.toc.isEmpty {
                    ContentUnavailableView("没有目录", systemImage: "list.bullet.rectangle",
                                           description: Text("本书未提供目录。"))
                } else {
                    ScrollViewReader { proxy in
                        List(model.toc) { item in
                            let isCurrent = model.currentTOCIndex == item.id
                            Button {
                                isShowingTOC = false
                                model.jump(to: item)
                            } label: {
                                HStack {
                                    Text(item.title)
                                        .foregroundStyle(isCurrent ? NoveliaStyle.brandGreen : .primary)
                                        .fontWeight(isCurrent ? .semibold : .regular)
                                        .padding(.leading, CGFloat(item.level) * 14)
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "book.fill")
                                            .font(.caption)
                                            .foregroundStyle(NoveliaStyle.brandGreen)
                                    }
                                }
                            }
                            .id(item.id)
                        }
                        .onAppear {
                            if let current = model.currentTOCIndex {
                                proxy.scrollTo(current, anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { isShowingTOC = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
