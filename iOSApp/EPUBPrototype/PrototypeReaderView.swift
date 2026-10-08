import SwiftUI
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
    @State private var isShowingImporter = false
    @State private var showChrome = true
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
            .overlay(alignment: .top) { topBar }
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
                model.setDarkMode(colorScheme == .dark)
                if model.viewportSize != geometry.size {
                    model.viewportSize = geometry.size
                }
                if model.status == .idle, let bookURL {
                    Task { await model.open(url: bookURL) }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showChrome)
        .sheet(isPresented: $isShowingTOC) { tocSheet }
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
                model.setFontSize(model.fontSize + 1)
            } label: {
                Image(systemName: "textformat.size")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("放大字号")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(.thinMaterial)
        .opacity(showChrome ? 1 : 0)
        .disabled(!showChrome)
    }

    // MARK: 底部状态栏（页码 + 进度条）

    private var bottomBar: some View {
        VStack(spacing: 8) {
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
            HStack(spacing: 10) {
                ProgressView(value: model.overallProgress)
                    .tint(Color(red: 0.91, green: 0.31, blue: 0.34))
                Text("\(Int(model.overallProgress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .opacity(showChrome ? 1 : 0)
        .disabled(!showChrome)
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

// MARK: - 文件选择（UIKit 文档选择器：iCloud 按需下载可靠，任意文件可选）

struct PrototypeFilePicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // copy 导入模式：系统把所选文件复制进应用沙箱后回调，
        // 不受 open 模式的 UTI 启用规则与 iCloud 占位文件影响，条目总能点选。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
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
