// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

/// EPUB 工具箱状态管理：持有当前选中源、深度体检报告、处理选项、后台任务与临时输出产物。
/// 属于单次工具箱页面生命周期，离开页面时自动取消在途任务并清理临时工作目录。
@MainActor
final class EPUBToolboxModel: ObservableObject {
    struct TargetSource: Equatable {
        let title: String
        let fileURL: URL
        let subtitle: String
        /// 若来自外部文件选择器，先复制到工作目录，离开时随目录清理。
        let isExternal: Bool
    }

    @Published var source: TargetSource?
    @Published var options = EPUBToolboxOptions.all
    @Published private(set) var isInspecting = false
    @Published private(set) var report: EPUBInspectionReport?
    @Published private(set) var isProcessing = false
    @Published private(set) var progress = EPUBToolboxProgress(fraction: 0, stage: "")
    @Published private(set) var result: EPUBToolboxResult?
    @Published private(set) var isSavingToLibrary = false
    @Published private(set) var isExportingTXT = false
    @Published var savedToLibraryTitle: String?
    @Published var errorMessage: String?

    private var inspectionTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var workspaceDirectory: URL?

    deinit {
        inspectionTask?.cancel()
        processTask?.cancel()
        if let dir = workspaceDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func selectLibraryBook(_ book: LibraryBook) {
        guard book.format == .epub, !book.isCloudOnly else {
            errorMessage = "只能对本机已下载的 EPUB 书籍使用工具箱。"
            return
        }
        guard FileManager.default.fileExists(atPath: book.fileURL.path) else {
            errorMessage = "找不到这本书的本机文件。"
            return
        }
        resetOutputAndTasks()
        let subtitle = book.author.isEmpty ? "书库书籍" : "书库 · \(book.author)"
        source = TargetSource(title: book.title, fileURL: book.fileURL, subtitle: subtitle, isExternal: false)
        runDeepInspection()
    }

    func selectExternalFile(url: URL) {
        resetOutputAndTasks()
        isInspecting = true
        let dir = ensureWorkspaceDirectory()
        let dest = dir.appendingPathComponent("input-\(UUID().uuidString).epub")
        let title = url.deletingPathExtension().lastPathComponent
        inspectionTask = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    var coordError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readableURL in
                        do {
                            try FileManager.default.copyItem(at: readableURL, to: dest)
                        } catch {
                            copyError = error
                        }
                    }
                    if let coordError { throw coordError }
                    if let copyError { throw copyError }
                }.value
                guard !Task.isCancelled else { return }
                source = TargetSource(title: title, fileURL: dest, subtitle: "外部文件 · \(url.lastPathComponent)", isExternal: true)
                isInspecting = false
                runDeepInspection()
            } catch is CancellationError {
                isInspecting = false
            } catch {
                isInspecting = false
                errorMessage = "读取外部 EPUB 失败：\(error.localizedDescription)"
            }
        }
    }

    func runDeepInspection() {
        guard let target = source else { return }
        inspectionTask?.cancel()
        isInspecting = true
        report = nil
        errorMessage = nil
        let url = target.fileURL
        inspectionTask = Task {
            defer { isInspecting = false }
            do {
                let inspected = try await Task.detached(priority: .userInitiated) {
                    try await EPUBToolboxInspector.inspect(url: url, mode: .deep)
                }.value
                guard !Task.isCancelled else { return }
                report = inspected
            } catch is CancellationError {
                // 已切换书籍或离开页面
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func runProcessing() {
        guard let target = source, !isProcessing else { return }
        guard options.hasAnyEnabled else {
            errorMessage = EPUBToolboxError.nothingSelected.localizedDescription
            return
        }
        processTask?.cancel()
        isProcessing = true
        result = nil
        savedToLibraryTitle = nil
        errorMessage = nil
        progress = EPUBToolboxProgress(fraction: 0.02, stage: "正在准备处理…")

        let dir = ensureWorkspaceDirectory()
        let outputName = EPUBToolboxPath.sanitizedFilename(target.title, fallback: "book") + "-standardized.epub"
        let destination = dir.appendingPathComponent("out-\(UUID().uuidString.prefix(8))-\(outputName)")
        let currentOptions = options
        let sourceURL = target.fileURL

        processTask = Task {
            defer { isProcessing = false }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try await EPUBToolboxProcessor.process(
                        source: sourceURL,
                        destination: destination,
                        options: currentOptions
                    ) { update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                        }
                    }
                }.value
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                result = outcome
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
            } catch EPUBToolboxError.cancelled {
                try? FileManager.default.removeItem(at: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelProcessing() {
        processTask?.cancel()
        processTask = nil
    }

    /// 将当前 EPUB 按阅读顺序导出为 UTF-8 纯文本 TXT（应用当前 Ruby 与简繁设置）。
    func exportAsTXT() async -> URL? {
        guard let target = source, !isExportingTXT else { return nil }
        isExportingTXT = true
        defer { isExportingTXT = false }
        let dir = ensureWorkspaceDirectory()
        let filename = EPUBToolboxPath.sanitizedFilename(target.title, fallback: "book") + ".txt"
        let dest = dir.appendingPathComponent("txt-\(UUID().uuidString.prefix(6))-\(filename)")
        let ruby = options.rubyHandling == .keep ? .removeAnnotations : options.rubyHandling
        let chinese = options.chineseConversion
        let src = target.fileURL
        do {
            let exported = try await Task.detached(priority: .userInitiated) {
                try await EPUBToolboxTXTExporter.exportToTXT(
                    source: src,
                    destination: dest,
                    rubyHandling: ruby,
                    chineseConversion: chinese
                )
            }.value
            return exported.outputURL
        } catch {
            errorMessage = "导出 TXT 失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 把处理后的 EPUB 另存为新书登记到本地书库，不修改原书。
    func saveResultToLibrary(using wenkuDownloads: WenkuLocalLibraryStore) async {
        guard let outcome = result, !isSavingToLibrary else { return }
        isSavingToLibrary = true
        defer { isSavingToLibrary = false }
        do {
            try await wenkuDownloads.loadIfNeeded()
            let baseTitle = outcome.suggestedTitle
            let newTitle = baseTitle.hasSuffix("（已标准化）") ? baseTitle : "\(baseTitle)（已标准化）"
            let destination = wenkuDownloads.downloadDestination(for: outcome.suggestedFilename)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            do {
                try await Task.detached(priority: .userInitiated) {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: outcome.outputURL, to: destination)
                }.value
                try await wenkuDownloads.registerDownloadedFile(at: destination, title: newTitle, source: .import)
                savedToLibraryTitle = newTitle
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } catch let duplicate as LocalLibraryDuplicateError {
            errorMessage = "书库中已存在内容完全相同的书籍《\(duplicate.existingTitle)》，未重复导入。"
        } catch {
            errorMessage = "保存到书库失败：\(error.localizedDescription)"
        }
    }

    func cleanup() {
        inspectionTask?.cancel()
        processTask?.cancel()
        inspectionTask = nil
        processTask = nil
        if let dir = workspaceDirectory {
            workspaceDirectory = nil
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func resetOutputAndTasks() {
        inspectionTask?.cancel()
        processTask?.cancel()
        inspectionTask = nil
        processTask = nil
        isInspecting = false
        isProcessing = false
        report = nil
        result = nil
        savedToLibraryTitle = nil
        errorMessage = nil
    }

    private func ensureWorkspaceDirectory() -> URL {
        if let existing = workspaceDirectory { return existing }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoveliaEPUBToolbox", isDirectory: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspaceDirectory = dir
        return dir
    }
}

// MARK: - 工具箱主界面

/// 独立的 EPUB 工具箱页面：提供深度体检、四项标准化/修复开关、处理报告、另存为新书入库与导出分享。
struct EPUBToolboxView: View {
    let initialBook: LibraryBook?
    let isPresentedInSheet: Bool

    @StateObject private var model = EPUBToolboxModel()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryState: LibraryStateStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var syncStore: WebDAVSyncStore

    @State private var isShowingLibraryPicker = false
    @State private var isShowingFileImporter = false
    @State private var isShowingMetadataEditor = false
    @State private var isShowingTOCEditor = false
    @State private var shareURL: URL?

    init(initialBook: LibraryBook? = nil, isPresentedInSheet: Bool = false) {
        self.initialBook = initialBook
        self.isPresentedInSheet = isPresentedInSheet
    }

    private var localEPUBBooks: [LibraryBook] {
        libraryState.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks)
            .filter { $0.format == .epub && !$0.isCloudOnly }
    }

    var body: some View {
        Form {
            sourceSection
            if let target = model.source {
                inspectionSection
                singleBookToolsSection(target)
                optionsSection
                slimAndStyleSection
                layoutAndFormatSection
                lightNovelAndNotesSection
                actionSection
            }
            if let outcome = model.result {
                resultSection(outcome)
            }
            multiBookToolsSection
        }
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("EPUB 工具箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatTopBarLeading) {
                Button("关闭") { dismiss() }
                    .opacity(isPresentedInSheet ? 1 : 0)
                    .disabled(!isPresentedInSheet)
            }
        }
        .onAppear {
            if model.source == nil, let initialBook {
                model.selectLibraryBook(initialBook)
            }
        }
        .onDisappear {
            model.cleanup()
        }
        .sheet(isPresented: $isShowingLibraryPicker) {
            CompatNavigationStack {
                EPUBToolboxLibraryPickerView(books: localEPUBBooks) { selected in
                    isShowingLibraryPicker = false
                    model.selectLibraryBook(selected)
                }
            }
        }
        .sheet(isPresented: $isShowingMetadataEditor) {
            if let target = model.source {
                EPUBMetadataEditorSheet(
                    sourceURL: target.fileURL,
                    initialOverride: model.options.metadataOverride
                ) { updated in
                    model.options.metadataOverride = updated
                }
            }
        }
        .sheet(isPresented: $isShowingTOCEditor) {
            if let target = model.source {
                EPUBTOCEditorSheet(
                    sourceURL: target.fileURL,
                    initialNodes: model.options.customTOC
                ) { updated in
                    model.options.customTOC = updated
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                LibraryArchiveShareSheet(url: url)
                    .ignoresSafeArea()
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [UTType.epub],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                model.selectExternalFile(url: first)
            } else if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - 选书区

    private var sourceSection: some View {
        Section {
            if let target = model.source {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.title)
                        .font(.headline)
                        .foregroundStyle(NoveliaStyle.ink)
                    Text(target.subtitle)
                        .font(.caption)
                        .foregroundStyle(NoveliaStyle.muted)
                    if let report = model.report {
                        let sizeText = ByteCountFormatter.string(fromByteCount: report.fileSizeBytes, countStyle: .file)
                        Text("EPUB \(report.epubVersion) · \(report.spineCount) 个正文文档 · \(sizeText)")
                            .font(.caption)
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }
                .padding(.vertical, 2)
            }
            Button {
                isShowingLibraryPicker = true
            } label: {
                Label(model.source == nil ? "从书库选择 EPUB" : "更换书库中的 EPUB", systemImage: "books.vertical")
            }
            .disabled(model.isProcessing || model.isSavingToLibrary)

            Button {
                isShowingFileImporter = true
            } label: {
                Label(model.source == nil ? "从「文件」选取外部 EPUB" : "更换外部 EPUB 文件", systemImage: "folder")
            }
            .disabled(model.isProcessing || model.isSavingToLibrary)
        } header: {
            Text("目标书籍")
        } footer: {
            Text("工具箱只读取原文件并生成新的标准化 EPUB，不会修改原书，也不会影响原书的阅读进度、书签或 WebDAV 同步。")
        }
    }

    // MARK: - 体检报告区

    private var inspectionSection: some View {
        Section("结构体检") {
            if model.isInspecting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在深度检查 EPUB 结构、XHTML 语法与资源引用…")
                        .font(.subheadline)
                        .foregroundStyle(NoveliaStyle.muted)
                }
                .padding(.vertical, 4)
            } else if let report = model.report {
                if report.issues.isEmpty {
                    Label("结构规范，未发现明显问题", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(NoveliaStyle.brandGreen)
                } else {
                    ForEach(report.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: iconName(for: issue.severity))
                                .foregroundStyle(color(for: issue.severity))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(issue.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(NoveliaStyle.ink)
                                    Text(issue.category.title)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(NoveliaStyle.hairline.opacity(0.6), in: Capsule())
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                                Text(issue.detail)
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Button {
                    model.runDeepInspection()
                } label: {
                    Label("重新检查", systemImage: "arrow.clockwise")
                }
                .disabled(model.isProcessing)
            }
        }
    }

    // MARK: - 单书专项工具区

    private func singleBookToolsSection(_ target: EPUBToolboxModel.TargetSource) -> some View {
        Section("单书专项工具") {
            Button {
                isShowingMetadataEditor = true
            } label: {
                HStack {
                    Label("编辑元数据与封面", systemImage: "doc.badge.gearshape")
                    Spacer()
                    if model.options.metadataOverride?.hasAnyOverride == true {
                        Text("已修改")
                            .font(.caption)
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                }
            }
            .disabled(model.isProcessing || (model.report?.isDRMProtected == true))

            Button {
                isShowingTOCEditor = true
            } label: {
                HStack {
                    Label("目录可视化编辑 / 正则重建", systemImage: "list.bullet.indent")
                    Spacer()
                    if let custom = model.options.customTOC {
                        Text("\(custom.count) 项")
                            .font(.caption)
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                }
            }
            .disabled(model.isProcessing || (model.report?.isDRMProtected == true))

            NavigationLink {
                EPUBArchiveBrowserView(sourceURL: target.fileURL, bookTitle: target.title)
            } label: {
                Label("内部文件浏览器（只读）", systemImage: "folder.badge.questionmark")
            }

            NavigationLink {
                EPUBToolboxSplitView(sourceURL: target.fileURL, bookTitle: target.title)
            } label: {
                Label("拆分合集 EPUB", systemImage: "rectangle.split.2x1")
            }
            .disabled(model.report?.isDRMProtected == true)

            Button {
                Task {
                    if let txtURL = await model.exportAsTXT() {
                        shareURL = txtURL
                    }
                }
            } label: {
                if model.isExportingTXT {
                    Label("正在提取纯文本 TXT…", systemImage: "hourglass")
                } else {
                    Label("导出为纯文本 TXT", systemImage: "doc.text")
                }
            }
            .disabled(model.isExportingTXT || model.isProcessing || (model.report?.isDRMProtected == true))
        }
    }

    // MARK: - 四项基础修复开关区

    private var optionsSection: some View {
        Section {
            Toggle(isOn: $model.options.standardizeStructure) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EPUB 目录结构标准化")
                    Text("按 Sigil 规范整理为 OEBPS/{Text,Styles,Images,Fonts,Misc}，修复 mimetype 顺序并同步重写 HTML/CSS/目录相对路径。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $model.options.mendXHTML) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("XHTML 良构修复")
                    Text("非 UTF-8 编码自动转 UTF-8，修复未闭合标签与非法实体，补齐标准 XML 与 XHTML 命名空间声明。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $model.options.repairOPFTOCCover) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OPF / 目录 / 封面修复")
                    Text("清理 OPF 失效条目并补录未注册文件；修复或从章节标题重建 NCX/Nav 目录；统一 EPUB 2/3 封面标记。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $model.options.removeUnusedResources) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("冗余资源清理")
                    Text("移除未被正文、目录、封面或样式表引用的图片、CSS、字体及 __MACOSX 等残留文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("基础标准化与修复")
        }
        .disabled(model.isProcessing || (model.report?.isDRMProtected == true))
    }

    private var slimAndStyleSection: some View {
        Section("瘦身与样式清洗") {
            Picker("图片瘦身压缩", selection: $model.options.imageCompression) {
                ForEach(EPUBImageCompressionOption.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $model.options.removeEmbeddedFonts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("移除内嵌字体")
                    Text("删除包内字体文件并移除 CSS 中的 @font-face，大幅减小体积并让阅读器字体设置生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $model.options.cleanForcedStyles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理强制排版样式")
                    Text("清除 CSS 与内联样式中写死的字色、底色、字号、行高与字体族，修复深色模式看不清等问题。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.isProcessing || (model.report?.isDRMProtected == true))
    }

    private var layoutAndFormatSection: some View {
        Section("排版与格式转换") {
            Picker("全书简繁转换", selection: $model.options.chineseConversion) {
                ForEach(EPUBChineseConversionOption.allCases) { Text($0.title).tag($0) }
            }
            Picker("横排 / 竖排转换", selection: $model.options.writingDirection) {
                ForEach(EPUBWritingDirectionTransform.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $model.options.upgradeToEPUB3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EPUB 2 → EPUB 3 升级")
                    Text("升级 OPF 版本至 3.0，补齐 dcterms:modified、nav.xhtml 导航目录与 HTML5 DOCTYPE。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.isProcessing || (model.report?.isDRMProtected == true))
    }

    private var lightNovelAndNotesSection: some View {
        Section("日轻与注释处理") {
            Picker("Ruby 注音处理", selection: $model.options.rubyHandling) {
                ForEach(EPUBRubyHandling.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $model.options.standardizeFootnotes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("注释标准化（EPUB 3）")
                    Text("将多看等常见非标准注释转换为标准 epub:type=\"noteref\" 与 <aside epub:type=\"footnote\">。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.isProcessing || (model.report?.isDRMProtected == true))
    }

    private var multiBookToolsSection: some View {
        Section("多书与效率工具") {
            NavigationLink {
                EPUBToolboxBatchView()
            } label: {
                Label("批量处理多本 EPUB", systemImage: "square.stack.3d.up")
            }
            NavigationLink {
                EPUBToolboxMergeView()
            } label: {
                Label("合并多卷 EPUB 为合集", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - 执行按钮区

    private var actionSection: some View {
        Section {
            if model.isProcessing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: model.progress.fraction)
                        .tint(NoveliaStyle.brandGreen)
                    HStack {
                        Text(model.progress.stage)
                            .font(.caption)
                            .foregroundStyle(NoveliaStyle.muted)
                        Spacer()
                        Button("取消", role: .destructive) {
                            model.cancelProcessing()
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    model.runProcessing()
                } label: {
                    HStack {
                        Spacer()
                        Label("开始处理 EPUB", systemImage: "wrench.and.screwdriver.fill")
                            .compatFontWeight(.semibold)
                        Spacer()
                    }
                }
                .tint(NoveliaStyle.brandGreen)
                .disabled(model.isInspecting || !model.options.hasAnyEnabled || (model.report?.isDRMProtected == true))
            }
        }
    }

    // MARK: - 处理结果与输出区

    private func resultSection(_ outcome: EPUBToolboxResult) -> some View {
        Section("处理结果") {
            let beforeText = ByteCountFormatter.string(fromByteCount: outcome.originalSizeBytes, countStyle: .file)
            let afterText = ByteCountFormatter.string(fromByteCount: outcome.outputSizeBytes, countStyle: .file)
            CompatLabeledContent("文件体积", value: "\(beforeText) → \(afterText)")
            if outcome.relocatedPathsCount > 0 {
                CompatLabeledContent("目录标准化重排", value: "\(outcome.relocatedPathsCount) 处路径")
            }
            if outcome.mendedXHTMLCount > 0 {
                CompatLabeledContent("XHTML 良构修复", value: "\(outcome.mendedXHTMLCount) 个文档")
            }
            if outcome.removedDeadManifestCount > 0 || outcome.registeredOrphanCount > 0 {
                CompatLabeledContent(
                    "OPF 清单修复",
                    value: "清理 \(outcome.removedDeadManifestCount) 处死链，补录 \(outcome.registeredOrphanCount) 项"
                )
            }
            if outcome.repairedTOC {
                CompatLabeledContent("目录修复", value: "已同步/重建 NCX 与导航目录")
            }
            if outcome.repairedCover {
                CompatLabeledContent("封面修复", value: "已规范化封面声明")
            }
            if outcome.removedUnusedCount > 0 {
                let saved = ByteCountFormatter.string(fromByteCount: outcome.removedUnusedBytes, countStyle: .file)
                CompatLabeledContent("清理冗余资源", value: "\(outcome.removedUnusedCount) 个（释放 \(saved)）")
            }
            if outcome.compressedImagesCount > 0 {
                let saved = ByteCountFormatter.string(fromByteCount: outcome.compressedImagesSavedBytes, countStyle: .file)
                CompatLabeledContent("图片瘦身", value: "\(outcome.compressedImagesCount) 张（节省 \(saved)）")
            }
            if outcome.removedFontsCount > 0 {
                let saved = ByteCountFormatter.string(fromByteCount: outcome.removedFontsBytes, countStyle: .file)
                CompatLabeledContent("移除内嵌字体", value: "\(outcome.removedFontsCount) 个（释放 \(saved)）")
            }
            if outcome.cleanedStyleCount > 0 {
                CompatLabeledContent("样式清洗", value: "\(outcome.cleanedStyleCount) 处样式表/文档")
            }
            if outcome.updatedMetadata {
                CompatLabeledContent("元数据与封面", value: "已写入新 EPUB")
            }
            if outcome.convertedChinese {
                CompatLabeledContent("简繁转换", value: "已转换全书正文与目录")
            }
            if outcome.convertedWritingDirection {
                CompatLabeledContent("排版方向", value: "已更新 OPF 与 CSS")
            }
            if outcome.upgradedToEPUB3 {
                CompatLabeledContent("版本升级", value: "已升级至 EPUB 3.0")
            }
            if outcome.processedRubyCount > 0 {
                CompatLabeledContent("Ruby 注音", value: "已处理 \(outcome.processedRubyCount) 处")
            }
            if outcome.standardizedFootnotesCount > 0 {
                CompatLabeledContent("注释标准化", value: "已规范化 \(outcome.standardizedFootnotesCount) 处")
            }
            if outcome.totalChangesCount == 0 {
                Text("已完成重新打包，原书未触发额外结构改动。")
                    .font(.caption)
                    .foregroundStyle(NoveliaStyle.muted)
            }
            ForEach(outcome.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(NoveliaStyle.muted)
            }

            if let savedTitle = model.savedToLibraryTitle {
                Label("已另存为新书《\(savedTitle)》", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(NoveliaStyle.brandGreen)
            } else {
                Button {
                    Task { await model.saveResultToLibrary(using: wenkuDownloads) }
                } label: {
                    if model.isSavingToLibrary {
                        Label("正在保存到书库…", systemImage: "hourglass")
                    } else {
                        Label("另存为新书入库", systemImage: "plus.rectangle.on.folder")
                    }
                }
                .tint(NoveliaStyle.brandGreen)
                .disabled(model.isSavingToLibrary)
            }

            Button {
                shareURL = outcome.outputURL
            } label: {
                Label("导出 / 分享 EPUB", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func iconName(for severity: EPUBIssueSeverity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func color(for severity: EPUBIssueSeverity) -> Color {
        switch severity {
        case .error: NoveliaStyle.danger
        case .warning: NoveliaStyle.warning
        case .info: NoveliaStyle.brandGreen
        }
    }
}

// MARK: - 书库 EPUB 选择器

struct EPUBToolboxLibraryPickerView: View {
    let books: [LibraryBook]
    let onSelect: (LibraryBook) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [LibraryBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.author.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Text(books.isEmpty ? "书库中暂无本机 EPUB 书籍。" : "没有匹配的 EPUB 书籍。")
                    .foregroundStyle(NoveliaStyle.muted)
            } else {
                ForEach(filtered) { book in
                    Button {
                        onSelect(book)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.title)
                                .font(.body)
                                .foregroundStyle(NoveliaStyle.ink)
                                .lineLimit(2)
                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.muted)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索书名或作者")
        .navigationTitle("选择书库 EPUB")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatTopBarLeading) {
                Button("取消") { dismiss() }
            }
        }
    }
}
