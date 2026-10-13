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

/// Generated chapters (TXT / online novel) shown by the paged reader instead of an EPUB file.
struct PagedTextBook {
    let source: any EPUBChapterSource
    let startUnit: Int
    let startOffset: Int?
    /// (unit index, UTF-16 offset in that unit's text), reported after each page turn.
    let onPosition: (Int, Int?) -> Void
}

struct EPUBReaderView: View {
    @ObservedObject private var settings = ReaderSettings.shared
    @ObservedObject private var backgrounds = ReaderSettings.shared.backgrounds
    @StateObject private var model = EPUBReaderModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingTOC = false
    @State private var isShowingStyle = false
    @State private var showChrome = true
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var draftStyle = EPUBReaderStyle()
    @State private var batteryLevel: Float = -1
    @State private var wasBatteryMonitoringEnabled = false
    let bookURL: URL?
    var textBook: PagedTextBook? = nil
    /// Extra top-bar controls supplied by the TXT / online wrappers.
    var accessory: AnyView? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ReaderBackgroundView(dark: model.isDarkMode, fallback: model.pageBackgroundColor).ignoresSafeArea()
                switch model.status {
                case .idle, .opening:
                    ProgressView(textBook == nil ? "正在解析 EPUB…" : "正在排版…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("无法排版", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        if model.source != nil {
                            Button("重试") { model.retry() }
                                .buttonStyle(.borderedProminent)
                                .tint(NoveliaStyle.brandGreen)
                        }
                    }
                case .ready:
                    EPUBReaderPageSurface(model: model, showChrome: $showChrome, size: geometry.size)
                        .equatable()
                }
                if model.isLayingOut {
                    ProgressView().scaleEffect(1.4)
                        .padding(22)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if showChrome { topBar }
                    chapterHeader
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
            .onChange(of: geometry.size) { _, newSize in
                model.viewportSize = newSize
            }
            .onChange(of: colorScheme) { _, newScheme in
                synchronizeSettings(systemIsDark: newScheme == .dark)
            }
            .onAppear {
                wasBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
                UIDevice.current.isBatteryMonitoringEnabled = true
                updateBatteryLevel()
                synchronizeSettings(systemIsDark: colorScheme == .dark)
                if model.viewportSize != geometry.size {
                    model.viewportSize = geometry.size
                }
                if let textBook {
                    model.start(textBook: textBook)
                } else if let bookURL {
                    model.start(url: bookURL)
                }
            }
            .onDisappear {
                // Stops layouts of a closed book; reopening reuses completed chapters from the cache.
                model.close()
                if !wasBatteryMonitoringEnabled {
                    UIDevice.current.isBatteryMonitoringEnabled = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                updateBatteryLevel()
            }
            .sheet(isPresented: $model.isShowingTOCDiagnosticsPrompt) { tocDiagnosticsPrompt }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // The reader already displays time and battery in its own overlay.
        // Toggling the system bar changes safe-area height and repaginates the book.
        .statusBarHidden(true)
        .sheet(isPresented: $isShowingTOC) { tocSheet }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NoveliaImportedFontsChanged"))) { _ in model.refreshBackground() }
        .onChange(of: settings.fontSize) { _, _ in synchronizeSettings(systemIsDark: colorScheme == .dark) }
        .onChange(of: settings.appearanceRaw) { _, _ in synchronizeSettings(systemIsDark: colorScheme == .dark) }
        .onChange(of: model.isAnimating) { _, active in
            if !active { synchronizeSettings(systemIsDark: colorScheme == .dark) }
        }
        .onChange(of: model.isLayingOut) { _, active in
            if !active { synchronizeSettings(systemIsDark: colorScheme == .dark) }
        }
        .onChange(of: backgrounds.revision) { _, _ in model.refreshBackground() }
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
            Text(model.source?.bookTitle ?? "阅读器")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if let accessory { accessory }
            Button {
                isShowingTOC = true
            } label: {
                Image(systemName: "list.bullet")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("目录")
            Button {
                draftStyle = model.style
                isShowingStyle = true
            } label: {
                Image(systemName: "textformat.size")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("阅读样式")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(.thinMaterial)
        .opacity(showChrome ? 1 : 0)
        .disabled(!showChrome)
    }

    private var chapterHeader: some View {
        Text(currentChapterTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .background(model.pageBackgroundColor.opacity(0.92))
            .allowsHitTesting(false)
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
        VStack(spacing: 8) {
            if showChrome {
                HStack {
                    Button {
                        model.commitTurn(forward: false)
                    } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canTurn(forward: false))
                    .accessibilityLabel("上一页")
                    Spacer()
                    Text(model.locationDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.commitTurn(forward: true)
                    } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canTurn(forward: true))
                    .accessibilityLabel("下一页")
                }
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
                    .disabled(model.status != .ready || model.isAnimating || model.isLayingOut)
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
            if showChrome {
                Rectangle().fill(.thinMaterial)
            } else {
                model.pageBackgroundColor.opacity(0.92)
            }
        }
    }

    private func updateBatteryLevel() {
        batteryLevel = UIDevice.current.batteryLevel
    }

    // MARK: 目录

    private var tocSheet: some View {
        NavigationStack {
            Group {
                if let diagnostic = model.tocDiagnosticText {
                    ContentUnavailableView {
                        Label("没有目录", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text(diagnostic)
                    }
                } else {
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
                            let tocEntries = model.source?.toc ?? []
                            // Computed once per render: rows are lazy, but each used to rescan the whole TOC.
                            let currentIndex = model.currentTOCIndex
                            ForEach(tocEntries.indices, id: \.self) { index in
                                let entry = tocEntries[index]
                                let isCurrent = currentIndex == index
                                Button {
                                    isShowingTOC = false
                                    model.jump(to: entry)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.title)
                                                .foregroundStyle(isCurrent
                                                    ? NoveliaStyle.brandGreen : .primary)
                                                .fontWeight(isCurrent ? .semibold : .regular)
                                            if model.container != nil, let spineIndex = entry.spineIndex {
                                                Text("spine \(spineIndex + 1)")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if isCurrent {
                                            Image(systemName: "book.fill")
                                                .font(.caption)
                                                .foregroundStyle(NoveliaStyle.brandGreen)
                                        }
                                    }
                                }
                                .id(index)
                            }
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

    private var tocDiagnosticsPrompt: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("本书有目录与排版说明", systemImage: "info.circle")
                    .font(.headline)
                Text("打开目录可以查看本书的目录解析和排版兼容性诊断。详情支持长按选择与复制。")
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
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("目录说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("知道了") { model.isShowingTOCDiagnosticsPrompt = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: 阅读样式（二级面板；点击应用后一次性重排）

    private func synchronizeSettings(systemIsDark: Bool) {
        model.synchronizeSharedSettings(systemIsDark: systemIsDark)
    }

    private var styleSheet: some View {
        NavigationStack {
            Form {
                Section("背景") { NavigationLink("阅读背景") { ReaderBackgroundSettingsView() } }
                Section("分页") {
                    Toggle("双页模式", isOn: Binding(get: { draftStyle.doublePage == true }, set: { draftStyle.doublePage = $0 }))
                    Text("每次显示两页；横屏或 iPad 上阅读更舒适。章节末尾不足两页时保留空白页。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text("恢复后点击右上角“应用”才会重新排版并保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("点击“应用”后重新分页，并按当前章节的页数比例恢复位置；文字位置可能略有变化。缩进选择“沿用书籍”可恢复原排版。")
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
                    .disabled(model.isAnimating || model.isLayingOut)
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

    // MARK: 注脚弹层

    private func noteSheet(_ note: EPUBNote) -> some View {
        NavigationStack {
            ScrollView {
                Text(note.text)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
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
                Text("已导入并选中：\(importedFamily)。返回阅读样式后点击“应用”生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if fonts.isEmpty {
                ContentUnavailableView("尚未导入字体", systemImage: "textformat",
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
    let initialURL: URL?
    @State private var resolvedURL: URL?
    /// 实验：EPUB 改由 Readium（WKWebView）排版；TXT 与在线章节不受影响。
    @AppStorage(SettingsKey.readerEPUBReadium) private var usesReadium = true

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
                if usesReadium {
                    ReadiumEPUBReaderView(bookURL: resolvedURL)
                } else {
                    EPUBReaderView(bookURL: resolvedURL)
                }
            } else {
                ProgressView("准备样例书…")
            }
        }
        .task {
            if resolvedURL == nil {
                if let debugBookURL {
                    resolvedURL = debugBookURL
                } else if let initialURL {
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

/// Chrome-only changes reuse the page surface. Model changes still invalidate
/// this observed view when pagination, reading position, or cached pages change.
private struct EPUBReaderPageSurface: View, Equatable {
    @ObservedObject var model: EPUBReaderModel
    @Environment(\.openURL) private var openURL
    @Binding var showChrome: Bool
    let size: CGSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.size == rhs.size
    }

    var body: some View {
        EPUBPagerView(
            canTurn: { forward in model.canTurn(forward: forward) },
            onCommit: { forward in
                model.commitTurn(forward: forward)
            },
            onAnimatingChange: { animating in model.setAnimating(animating) },
            linkHitTest: { point in model.linkHit(at: point) },
            onNoteTap: { text in model.activeNote = EPUBNote(text: text) },
            onPlainLinkTap: { href in
                // Generated (online) chapters link web addresses: open them the way the scroll
                // reader's links open. EPUB links keep resolving to chapters in the book.
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
            images: model.pagerImages()
        )
        .frame(width: size.width, height: size.height)
    }
}
