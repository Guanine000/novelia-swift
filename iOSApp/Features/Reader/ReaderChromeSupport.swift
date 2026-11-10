import SwiftUI

/// 阅读页共用的显示选项与外观组件：底栏位置口径、目录诊断开关。
/// 这里只放展示层内容，不参与排版、进度、书签或搜索计算。

/// 底栏位置信息的口径。按顺序点击循环。
enum ReaderPositionStyle: String, CaseIterable, Identifiable {
    case chapterPage
    case chapterProgress
    case bookProgress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chapterPage: "章节页码"
        case .chapterProgress: "本章进度"
        case .bookProgress: "全书进度"
        }
    }
}

/// 阅读页底栏的位置文字：点击在几种口径之间循环，选择按设备记住。
/// 两种分页引擎共用，各引擎只负责给出每种口径的文字。
struct ReaderPositionLabel: View {
    let texts: [ReaderPositionStyle: String]

    @AppStorage("reader.positionStyle") private var storedStyle = ReaderPositionStyle.chapterPage.rawValue

    private var style: ReaderPositionStyle {
        ReaderPositionStyle(rawValue: storedStyle) ?? .chapterPage
    }

    var body: some View {
        let text = texts[style] ?? texts.values.first ?? ""
        Button {
            storedStyle = Self.next(after: style).rawValue
        } label: {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("阅读位置：\(text)")
        .accessibilityHint("轻点切换为\(Self.next(after: style).title)")
    }

    private static func next(after style: ReaderPositionStyle) -> ReaderPositionStyle {
        guard let index = ReaderPositionStyle.allCases.firstIndex(of: style) else { return .chapterPage }
        return ReaderPositionStyle.allCases[(index + 1) % ReaderPositionStyle.allCases.count]
    }
}

/// 阅读页底栏的进度拖动条：细轨道加小圆点，拖动中放大；两个分页引擎共用。
/// 系统滑杆自 iOS 26 起使用大尺寸旋钮，与 11pt 的位置文字不成比例，这里自行绘制。
/// 拖动语义与原 Slider 一致：开始时回调 editing，移动中更新 value，松手才真正跳转。
struct ReaderScrubber: View {
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = min(1, max(0, value))
            let thumbSize: CGFloat = isDragging ? 16 : 10
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                Capsule()
                    .fill(NoveliaStyle.brandGreen)
                    .frame(width: width * fraction, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .offset(x: width * fraction - thumbSize / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        guard width > 0 else { return }
                        value = min(1, max(0, gesture.location.x / width))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阅读进度")
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: scrub(by: 0.05)
            case .decrement: scrub(by: -0.05)
            @unknown default: break
            }
        }
    }

    /// VoiceOver 调节走完整的一次拖动：先进入编辑态，再提交跳转。
    private func scrub(by delta: Double) {
        onEditingChanged(true)
        value = min(1, max(0, value + delta))
        onEditingChanged(false)
    }
}

/// 两个分页引擎共用的阅读页顶栏骨架：返回、双行标题与「阅读菜单」容器。
/// 菜单内容与显隐策略因引擎而异，由调用方传入；这里只统一布局、材质与无障碍。
struct ReaderTopBarShell<MenuContent: View, TitleTrailer: View>: View {
    @Environment(\.dismiss) private var dismiss
    let bookTitle: String
    let chapterTitle: String
    @ViewBuilder var titleTrailer: TitleTrailer
    @ViewBuilder var menu: MenuContent

    var body: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("返回")
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    Text(bookTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    titleTrailer
                }
                if !chapterTitle.isEmpty {
                    Text(chapterTitle)
                        .font(NoveliaStyle.fontMicro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Menu { menu } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("阅读菜单")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(.thinMaterial)
    }
}

/// 两个分页引擎共用的阅读页底栏容器：进度区、电量/百分比/时间状态行与显隐背景。
/// 工具栏隐藏时仍保留百分比；原生引擎隐藏时垫页面纸色，Readium 保持透明。
struct ReaderBottomBarShell<Content: View>: View {
    let showChrome: Bool
    let batteryLevel: Double
    /// 工具栏隐藏时仍显示的全书百分比；nil 表示不显示。
    let hiddenPercentText: String?
    /// 工具栏隐藏时的底色；nil 保持透明。
    var hiddenBackground: Color? = nil
    /// 工具栏显示时把材质铺到屏幕最下缘。仿真翻页的纸面满屏延伸到安全区，
    /// 不铺时底栏下方会露出正在卷动的那一条纸面；其他引擎保持原样。
    var coversBottomSafeArea = false
    var readingTime: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) {
            if showChrome {
                content
                    .transition(.opacity)
            }
            HStack {
                Text(batteryLevel >= 0 ? "电量 \(Int((batteryLevel * 100).rounded()))%" : "电量 —")
                Spacer()
                if let readingTime { readingTime }
                // 工具栏隐藏时也保留进度百分比，兼顾沉浸阅读与位置感知。
                if !showChrome, let hiddenPercentText {
                    Text(hiddenPercentText)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 18)
        .padding(.top, showChrome ? 8 : 4)
        .padding(.bottom, 10)
        .background {
            if showChrome {
                Rectangle().fill(.thinMaterial)
                    .ignoresSafeArea(edges: coversBottomSafeArea ? .bottom : [])
            } else if let hiddenBackground {
                hiddenBackground.opacity(0.92)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showChrome)
    }
}

/// 两个分页引擎共用的「位置、进度拖动条与百分比」一行；文字口径与可用状态由引擎给出。
struct ReaderPositionRow: View {
    let positionTexts: [ReaderPositionStyle: String]
    /// 拖动预览文字；nil 表示不在拖动中。
    let previewText: String?
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    let percentText: String
    let scrubDisabled: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let previewText {
                Text(previewText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            // 位置、进度与翻页都收在一行；上一页／下一页交给手势与 VoiceOver 动作。
            HStack(spacing: 10) {
                ReaderPositionLabel(texts: positionTexts)
                ReaderScrubber(value: $value, onEditingChanged: onEditingChanged)
                    .disabled(scrubDisabled)
                Text(percentText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
    }
}

/// 阅读页调试信息开关。默认关闭；打开后目录显示解析诊断说明与 spine 编号。
enum ReaderDebugOptions {
    static let showsTOCDiagnosticsKey = "reader.showTOCDiagnostics"
}

/// 「屏幕常亮」：阅读期间阻止自动锁屏。开关记忆在本机（默认关闭），
/// 只在阅读器前台持有；退出阅读器由各阅读面在 onDisappear 统一恢复。
enum ReaderKeepScreenOn {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.readerKeepScreenOn)
    }

    static func apply(_ enabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = enabled
    }

    /// 进入阅读面时按存储值生效。
    static func activate() {
        apply(isEnabled)
    }

    /// 离开阅读面时一律恢复系统默认。
    static func deactivate() {
        apply(false)
    }
}

/// 阅读菜单里的「屏幕常亮」开关项；各阅读面菜单共用。
struct ReaderKeepScreenOnMenuItem: View {
    @AppStorage(SettingsKey.readerKeepScreenOn) private var isEnabled = false

    var body: some View {
        Button {
            isEnabled.toggle()
            ReaderKeepScreenOn.apply(isEnabled)
        } label: {
            Label("屏幕常亮", systemImage: isEnabled ? "checkmark" : "sun.max")
        }
        .accessibilityLabel(isEnabled ? "屏幕常亮已开启" : "屏幕常亮已关闭")
    }
}

/// 目录中的一行：EPUB、TXT、在线小说共用。按层级缩进；当前章左侧显示竖条与「当前」标签；
/// 有子项的分组左侧显示展开/折叠按钮，点标题仍跳到该章。
struct ReaderTOCRow: View {
    let title: String
    let level: Int
    var subtitle: String? = nil
    let isCurrent: Bool
    var hasChildren = false
    var isExpanded = false
    /// 目录没有任何分组时不留出展开按钮的位置（TXT、在线小说等扁平目录）。
    var showsDisclosureColumn = true
    /// 自定义标题颜色；在线小说目录使用阅读器主题文字色。
    var titleColor: Color? = nil
    var toggle: () -> Void = {}
    let select: () -> Void

    /// 副标题：本章字数在前，其他说明在后。
    static func subtitle(wordCount: String?, detail: String?) -> String? {
        let parts = [wordCount, detail].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if hasChildren {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "折叠\(title)" : "展开\(title)")
                } else if showsDisclosureColumn {
                    Color.clear.frame(width: 28, height: 1)
                }
            }
            .padding(.leading, CGFloat(min(level, 6)) * 14)
            Button(action: select) {
                HStack(spacing: 8) {
                    if isCurrent {
                        Capsule().fill(NoveliaStyle.brandGreen).frame(width: 3, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? NoveliaStyle.brandGreen : (titleColor ?? .primary))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let subtitle {
                            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                    }
                }
                .frame(minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
        }
    }
}

/// 两种分页引擎共用的阅读设置面板：草稿样式由调用方持有，点击「应用」时回传到当前引擎。
/// 面板本身不访问任何排版模型，只负责展示与草稿编辑；主题与背景仍然即时生效。
struct ReaderStyleSheet: View {
    @EnvironmentObject private var settings: ReaderSettings
    @Binding var draftStyle: EPUBReaderStyle
    /// 当前引擎能否立即重排：排版进行中禁用「应用」，避免并发触发两套布局。
    let canApply: Bool
    let onApply: () -> Void
    let onClose: () -> Void
    /// 删除自定义字体后，若当前样式仍引用它则回退到书籍默认字体。
    let onDeletedFont: (String) -> Void
    let onMarkIssue: () -> Void
    var supportsNativePageTurn = false
    var supportsReadiumPageTurn = false

    var body: some View {
        CompatNavigationStack {
            Form {
                ReaderBookStyleScopeSection {
                    draftStyle = settings.defaults.data(forKey: settings.styleStorageKey).flatMap { try? JSONDecoder().decode(EPUBReaderStyle.self, from: $0) } ?? EPUBReaderStyle()
                    draftStyle.fontSize = CGFloat(settings.fontSize)
                }

                Section {
                    NavigationLink("阅读背景") { ReaderBackgroundSettingsView() }
                    HStack(spacing: 10) {
                        ForEach(ReaderAppearance.allCases) { option in
                            ReaderThemeSwatch(option: option,
                                              isSelected: settings.appearanceRaw == option.rawValue) {
                                settings.appearanceRaw = option.rawValue
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: { Text("主题与背景") } footer: {
                    Text("主题与背景即时生效；字体、字号和排版调整点击“应用”后保存。")
                }
                Section("分页") {
                    if supportsNativePageTurn {
                        Picker("翻页动画", selection: $settings.nativePageCurlEnabled) {
                            Text("跟手平移").tag(false)
                            Text("仿真翻页").tag(true)
                        }
                        .accessibilityIdentifier("reader-native-page-turn")
                        Text("即时生效，仅用于原生分页。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if supportsReadiumPageTurn {
                        Picker("翻页动画", selection: $settings.readiumPageCurlEnabled) {
                            Text("跟手平移").tag(false)
                            Text("仿真翻页").tag(true)
                        }
                        .accessibilityIdentifier("reader-readium-page-turn")
                        Text("即时生效。朗读会话期间保持实时滑动，停止朗读后恢复仿真翻页。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("双页模式", isOn: Binding(get: { draftStyle.doublePage == true }, set: { draftStyle.doublePage = $0 }))
                    Text("每次显示两页；横屏或 iPad 上阅读更舒适。章节末尾不足两页时保留空白页。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("字体") {
                    NavigationLink {
                        EPUBFontPicker(selection: $draftStyle.fontFamily) { deletedFamily in
                            onDeletedFont(deletedFamily)
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
                        Spacer(minLength: 8)
                        Button { draftStyle.fontSize = max(12, draftStyle.fontSize - 1) } label: {
                            Text("A−").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(draftStyle.fontSize <= 12)
                        .accessibilityLabel("缩小字号")
                        Text("\(Int(draftStyle.fontSize))")
                            .monospacedDigit().frame(minWidth: 32)
                            .accessibilityLabel("字号 \(Int(draftStyle.fontSize)) 点")
                        Button { draftStyle.fontSize = min(36, draftStyle.fontSize + 1) } label: {
                            Text("A+").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(draftStyle.fontSize >= 36)
                        .accessibilityLabel("放大字号")
                    }
                }
                Section("段落") {
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
                    Text("恢复默认后点击“应用”才会重新排版并保存。行间距、段落间距和首行缩进设为非默认值时会覆盖书籍原有的段落样式；全部保持默认则沿用书籍排版。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("点击“应用”后重新分页，并按当前章节的页数比例恢复位置；文字位置可能略有变化。缩进选择“沿用书籍”可恢复原排版。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ReaderIssueMarkSection { onMarkIssue() }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 按钮放导航栏，避免 sheet 底部再铺一条与表单不同色的操作条。
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("关闭") { onClose() }
                }
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("应用") { onApply() }
                        .font(.body.weight(.semibold))
                        .disabled(!canApply)
                }
            }
        }
        .compatPresentationDetents(.medium, .large)
        // 不透明纸色底：半透明 sheet 在滚动时要持续重算背后内容的模糊，容易掉帧。
        .compatPresentationBackground(NoveliaStyle.paper)
    }

    private func styleSlider(_ label: String, value: Binding<CGFloat>,
                             range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text(label).frame(width: 68, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value.wrappedValue))")
            Text("\(Int(value.wrappedValue))")
                .monospacedDigit().frame(width: 30, alignment: .trailing)
        }
    }
}

/// 进度百分比文本：底栏位置与拖动预览共用，统一取整与夹取写法。
enum FractionText {
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }
}

/// 阅读主题色块：用该主题真实的背景与正文色做预览，点按即时切换。
/// 「跟随系统」用浅深对角渐变表示会随系统变化。
private struct ReaderThemeSwatch: View {
    let option: ReaderAppearance
    let isSelected: Bool
    let action: () -> Void

    private var previewScheme: ColorScheme {
        option.preferredColorScheme ?? .light
    }

    private var previewBackground: AnyShapeStyle {
        if option == .system {
            return AnyShapeStyle(LinearGradient(
                colors: [option.background(system: .light), option.background(system: .dark)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(option.background(system: previewScheme))
    }

    private var previewText: Color {
        option.primaryText(system: option == .system ? .light : previewScheme)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall)
                        .fill(previewBackground)
                    Text("A")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(previewText)
                }
                .frame(height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall)
                        .strokeBorder(isSelected ? NoveliaStyle.brandGreen : Color.secondary.opacity(0.25),
                                      lineWidth: isSelected ? 2 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(NoveliaStyle.fontBody)
                            .foregroundStyle(.white, NoveliaStyle.brandGreen)
                            .padding(4)
                    }
                }
                Text(option.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? NoveliaStyle.brandGreen : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
