import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 原型阅读界面（全屏阅读页）
//
// 布局与交互参考 Yuedu-reader 的阅读器行为（仅参考布局/交互，不复制源码、
// 不使用其品牌素材）：全屏正文，点击中部显隐工具栏，左右侧点击翻页，
// 注脚点击底部弹层显示注释文本。工具栏为覆盖层，显隐不改变正文视口，
// 因此不会触发重排。
//
// 分页不变量见 PrototypePageBook：预览页与落页共用同一份排版结果。

struct PrototypeReaderView: View {
    @StateObject private var model = PrototypeReaderModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingTOC = false
    @State private var isShowingStyle = false
    @State private var isShowingImporter = false
    @State private var showChrome = true
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var draftStyle = PrototypeReaderStyle()
    @State private var batteryLevel: Float = -1
    @State private var wasBatteryMonitoringEnabled = false
    let bookURL: URL?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                model.pageBackgroundColor.ignoresSafeArea()
                switch model.status {
                case .idle, .opening:
                    ProgressView("正在解析 EPUB…")
                case .failed(let message):
                    ContentUnavailableView("无法排版", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready:
                    PrototypePagerView(
                        canTurn: { forward in model.canTurn(forward: forward) },
                        onCommit: { forward in
                            model.commitTurn(forward: forward)
                        },
                        onAnimatingChange: { animating in model.setAnimating(animating) },
                        linkHitTest: { point in model.linkHit(at: point) },
                        onNoteTap: { text in model.activeNote = PrototypeNote(text: text) },
                        onPlainLinkTap: { href in
                            model.openLink(href)
                        },
                        onCenterTap: { withAnimation(.easeInOut(duration: 0.15)) { showChrome.toggle() } },
                        images: model.pagerImages()
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
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
            .overlay(alignment: .bottom) { bottomBar }
            .overlay(alignment: .bottom) {
                // 常驻细进度条：工具栏隐藏时仍可见当前阅读进度。
                Rectangle()
                    .fill(Color(red: 0.91, green: 0.31, blue: 0.34).opacity(0.8))
                    .frame(width: max(4, geometry.size.width * model.overallProgress), height: 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            }
            .onChange(of: geometry.size) { _, newSize in
                model.viewportSize = newSize
            }
            .onChange(of: colorScheme) { _, newScheme in
                model.setDarkMode(newScheme == .dark)
            }
            .onAppear {
                wasBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
                UIDevice.current.isBatteryMonitoringEnabled = true
                updateBatteryLevel()
                model.setDarkMode(colorScheme == .dark)
                if model.viewportSize != geometry.size {
                    model.viewportSize = geometry.size
                }
                if model.status == .idle, let bookURL {
                    Task { await model.open(url: bookURL) }
                }
            }
            .onDisappear {
                if !wasBatteryMonitoringEnabled {
                    UIDevice.current.isBatteryMonitoringEnabled = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                updateBatteryLevel()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showChrome)
        .sheet(isPresented: $isShowingTOC) { tocSheet }
        .sheet(isPresented: $isShowingStyle) { styleSheet }
        .sheet(item: $model.activeNote) { note in noteSheet(note) }
        .fullScreenCover(isPresented: $isShowingImporter) {
            PrototypeFilePicker { url in
                Task { await model.importEPUB(from: url) }
            }
            .ignoresSafeArea()
        }
        .alert("导入", isPresented: .init(
            get: { model.importMessage != nil },
            set: { if !$0 { model.importMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.importMessage = nil }
        } message: {
            Text(model.importMessage ?? "")
        }
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
            Text(model.container?.bookTitle ?? "排版原型")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Button {
                isShowingImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("导入 EPUB")
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
        guard let container = model.container else { return "" }
        if let index = model.currentTOCIndex {
            return container.toc[index].title
        }
        return container.bookTitle
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
                    .tint(Color(red: 0.91, green: 0.31, blue: 0.34))
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
                            if let count = model.container?.strippedScriptCount, count > 0 {
                                Section {
                                    Text("本书包含 \(count) 处脚本内容，已忽略（脚本不参与显示）。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let count = model.container?.opacityRewriteCount, count > 0 {
                                Section {
                                    Text("本书包含 \(count) 处 opacity 透明度，已转换为等价文字颜色（当前排版引擎不支持 opacity 属性）。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let count = model.container?.mediaQueryRewriteCount, count > 0 {
                                Section {
                                    Text("本书包含 \(count) 个 @media 规则块，已按设备条件求值（当前排版引擎不支持媒体查询；不匹配的规则被忽略）。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let count = model.container?.tableDisplayStripCount, count > 0 {
                                Section {
                                    Text("本书包含 \(count) 处表格化垂直居中声明（display:table/vertical-align:middle），已剥离以正常显示图片，插图不再垂直居中。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let count = model.container?.textShadowRewriteCount, count > 0 {
                                Section {
                                    Text("本书包含 \(count) 处文字阴影（text-shadow），当前排版引擎不支持阴影，已改用阴影颜色作为文字颜色以保证可读。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            let tocEntries = model.container?.toc ?? []
                            ForEach(Array(tocEntries.enumerated()), id: \.offset) { index, entry in
                                let isCurrent = model.currentTOCIndex == index
                                Button {
                                    isShowingTOC = false
                                    model.jump(to: entry)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.title)
                                                .foregroundStyle(isCurrent
                                                    ? Color(red: 0.91, green: 0.31, blue: 0.34) : .primary)
                                                .fontWeight(isCurrent ? .semibold : .regular)
                                            if let spineIndex = entry.spineIndex {
                                                Text("spine \(spineIndex + 1)")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if isCurrent {
                                            Image(systemName: "book.fill")
                                                .font(.caption)
                                                .foregroundStyle(Color(red: 0.91, green: 0.31, blue: 0.34))
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

    // MARK: 阅读样式（二级面板；点击应用后一次性重排）

    private var styleSheet: some View {
        NavigationStack {
            Form {
                Section("字体") {
                    NavigationLink {
                        PrototypeFontPicker(selection: $draftStyle.fontFamily) { deletedFamily in
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
                        draftStyle = PrototypeReaderStyle()
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

    private func noteSheet(_ note: PrototypeNote) -> some View {
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
    }
}

/// UIFont 列出的字体族包含系统字体以及已安装且对本 App 可见的设备字体。
private struct PrototypeFontPicker: View {
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
                PrototypeImportedFontsView(selection: $selection,
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

private struct PrototypeImportedFontsView: View {
    @Binding var selection: String?
    var onDeleteImportedFamily: (String) -> Void
    @State private var fonts: [PrototypeLocalFonts.ImportedFont] = []
    @State private var isImportingFont = false
    @State private var importError: String?
    @State private var importedFamily: String?
    @State private var fontToDelete: PrototypeLocalFonts.ImportedFont?

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
            PrototypeFilePicker(contentTypes: [.item]) { url in
                isImportingFont = false
                do {
                    let family = try PrototypeLocalFonts.importFont(from: url)
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
        fonts = PrototypeLocalFonts.importedFonts()
    }

    private func delete(_ font: PrototypeLocalFonts.ImportedFont) {
        do {
            try PrototypeLocalFonts.deleteFont(font)
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

struct PrototypeFilePicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.data]
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // copy 导入模式：系统把所选文件复制进应用沙箱后回调，
        // 不受 open 模式的 UTI 启用规则与 iCloud 占位文件影响，条目总能点选。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - 打开入口（注入样例书或指定 EPUB；以全屏页方式呈现）

struct PrototypeReaderHost: View {
    let initialURL: URL?
    @State private var resolvedURL: URL?

    /// 调试：`-prototypeBookPath <路径>` 直接打开指定 EPUB（自动化/真机排查用）。
    private var debugBookURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-prototypeBookPath"),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    var body: some View {
        Group {
            if let resolvedURL {
                PrototypeReaderView(bookURL: resolvedURL)
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
                    resolvedURL = try? await PrototypeSampleBook.sampleURL()
                }
            }
        }
    }
}
