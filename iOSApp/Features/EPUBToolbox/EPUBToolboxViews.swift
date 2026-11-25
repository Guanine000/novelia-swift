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

    @StateObject private var model = EPUBToolboxModel()
    @EnvironmentObject private var libraryState: LibraryStateStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var syncStore: WebDAVSyncStore

    @State private var isShowingLibraryPicker = false
    @State private var isShowingFileImporter = false
    @State private var isShowingMetadataEditor = false
    @State private var isShowingTOCEditor = false
    @State private var shareURL: URL?

    init(initialBook: LibraryBook? = nil) {
        self.initialBook = initialBook
    }

    private var localEPUBBooks: [LibraryBook] {
        libraryState.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks)
            .filter { $0.format == .epub && !$0.isCloudOnly }
    }

    /// 外部 EPUB 选取类型：覆盖标准 `org.idpf.epub-container` 与 Apple Books 的 `com.apple.ibooks.epub`。
    private var externalEPUBContentTypes: [UTType] {
        var types: [UTType] = []
        for candidate in [
            UTType(filenameExtension: "epub"),
            UTType.epub,
            UTType("com.apple.ibooks.epub")
        ].compactMap({ $0 }) where !types.contains(candidate) {
            types.append(candidate)
        }
        return types.isEmpty ? [.data] : types
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceCard
                if let target = model.source {
                    inspectionCard
                    singleBookToolsCard(target)
                    optionsCard
                    slimAndStyleCard
                    layoutAndFormatCard
                    lightNovelAndNotesCard
                    actionCard
                }
                if let outcome = model.result {
                    resultCard(outcome)
                }
                multiBookToolsCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("EPUB 工具箱")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model.source == nil, let initialBook {
                model.selectLibraryBook(initialBook)
            }
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
        .fullScreenCover(isPresented: $isShowingFileImporter) {
            EPUBFilePicker(contentTypes: externalEPUBContentTypes, allowsMultipleSelection: false) { urls in
                isShowingFileImporter = false
                if let first = urls.first {
                    model.selectExternalFile(url: first)
                }
            }
            .ignoresSafeArea()
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

    private var controlsDisabled: Bool {
        model.isProcessing || (model.report?.isDRMProtected == true)
    }

    // MARK: - 选书工作台主卡

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = model.source {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        toolboxBadge("book.closed.fill", tint: NoveliaStyle.brandGreen, size: 38, iconSize: 16)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.title)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.ink)
                                .lineLimit(2)
                            Text(target.subtitle)
                                .font(NoveliaStyle.fontCaption)
                                .foregroundStyle(NoveliaStyle.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }

                    if let report = model.report {
                        let sizeText = ByteCountFormatter.string(fromByteCount: report.fileSizeBytes, countStyle: .file)
                        HStack(spacing: 8) {
                            metaPill("EPUB \(report.epubVersion)")
                            metaPill("\(report.spineCount) 个正文")
                            metaPill(sizeText)
                        }
                    }

                    Rectangle()
                        .fill(NoveliaStyle.hairline)
                        .frame(height: 0.75)

                    HStack(spacing: 10) {
                        sourceActionButton(
                            title: "换书库 EPUB",
                            systemImage: "books.vertical",
                            tint: NoveliaStyle.brandGreen
                        ) { isShowingLibraryPicker = true }

                        sourceActionButton(
                            title: "换外部文件",
                            systemImage: "folder",
                            tint: Color.blue
                        ) { isShowingFileImporter = true }
                    }
                    .disabled(model.isProcessing || model.isSavingToLibrary)
                }
                .padding(16)
                .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.orange, Color.orange.opacity(0.72)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 46, height: 46)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("选择一本 EPUB 开始处理")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.ink)
                            Text("支持结构体检、标准化修复、瘦身与排版转换")
                                .font(NoveliaStyle.fontCaption)
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 10) {
                        sourceActionButton(
                            title: "从书库选择",
                            subtitle: "\(localEPUBBooks.count) 本可用",
                            systemImage: "books.vertical.fill",
                            tint: NoveliaStyle.brandGreen
                        ) { isShowingLibraryPicker = true }

                        sourceActionButton(
                            title: "从「文件」选取",
                            subtitle: "外部 EPUB",
                            systemImage: "folder.fill",
                            tint: Color.blue
                        ) { isShowingFileImporter = true }
                    }
                    .disabled(model.isProcessing || model.isSavingToLibrary)
                }
                .padding(16)
                .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
            }

            Text("工具箱只读取原文件并生成新的标准化 EPUB，不会修改原书，也不会影响原书的阅读进度、书签或 WebDAV 同步。")
                .font(NoveliaStyle.fontCaption)
                .foregroundStyle(NoveliaStyle.muted)
                .padding(.horizontal, 6)
        }
    }

    private func metaPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(NoveliaStyle.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NoveliaStyle.paper, in: Capsule())
    }

    private func sourceActionButton(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                toolboxBadge(systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(NoveliaStyle.fontMicro)
                            .foregroundStyle(NoveliaStyle.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                    .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 体检报告区

    private var inspectionCard: some View {
        toolboxSection("结构体检") {
            if model.isInspecting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在深度检查 EPUB 结构、XHTML 语法与资源引用…")
                        .font(NoveliaStyle.fontBody)
                        .foregroundStyle(NoveliaStyle.muted)
                }
                .padding(14)
            } else if let report = model.report {
                if report.issues.isEmpty {
                    HStack(spacing: 12) {
                        toolboxBadge("checkmark.seal.fill", tint: NoveliaStyle.brandGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("结构规范，未发现明显问题")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.ink)
                            Text("仍可按需执行瘦身、样式清洗或格式转换")
                                .font(NoveliaStyle.fontCaption)
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                        Spacer(minLength: 8)
                        Button {
                            model.runDeepInspection()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                                .frame(width: 30, height: 30)
                                .background(NoveliaStyle.brandGreen.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isProcessing)
                        .accessibilityLabel("重新检查")
                    }
                    .padding(14)
                } else {
                    ForEach(Array(report.issues.enumerated()), id: \.element.id) { index, issue in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: iconName(for: issue.severity))
                                .font(.system(size: 15))
                                .foregroundStyle(color(for: issue.severity))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(issue.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(NoveliaStyle.ink)
                                    Text(issue.category.title)
                                        .font(NoveliaStyle.fontMicro)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(NoveliaStyle.paper, in: Capsule())
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                                Text(issue.detail)
                                    .font(NoveliaStyle.fontCaption)
                                    .foregroundStyle(NoveliaStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        if index < report.issues.count - 1 {
                            toolboxDivider(leading: 40)
                        }
                    }

                    toolboxDivider(leading: 14)

                    Button {
                        model.runDeepInspection()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                            Text("重新检查")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(NoveliaStyle.brandGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isProcessing)
                }
            }
        }
    }

    // MARK: - 单书专项工具区

    private func singleBookToolsCard(_ target: EPUBToolboxModel.TargetSource) -> some View {
        toolboxSection("单书专项工具") {
            Button {
                isShowingMetadataEditor = true
            } label: {
                toolboxRow(
                    title: "编辑元数据与封面",
                    value: model.options.metadataOverride?.hasAnyOverride == true ? "已修改" : nil,
                    valueHighlighted: true,
                    systemImage: "doc.badge.gearshape",
                    tint: NoveliaStyle.brandGreen
                )
            }
            .buttonStyle(.plain)
            .disabled(controlsDisabled)

            toolboxDivider()

            Button {
                isShowingTOCEditor = true
            } label: {
                toolboxRow(
                    title: "目录可视化编辑 / 正则重建",
                    value: model.options.customTOC.map { "\($0.count) 项" },
                    valueHighlighted: true,
                    systemImage: "list.bullet.indent",
                    tint: Color.blue
                )
            }
            .buttonStyle(.plain)
            .disabled(controlsDisabled)

            toolboxDivider()

            NavigationLink {
                EPUBArchiveBrowserView(sourceURL: target.fileURL, bookTitle: target.title)
            } label: {
                toolboxRow(
                    title: "浏览内部文件",
                    systemImage: "folder",
                    tint: Color.teal
                )
            }
            .buttonStyle(.plain)

            toolboxDivider()

            NavigationLink {
                EPUBToolboxSplitView(sourceURL: target.fileURL, bookTitle: target.title)
            } label: {
                toolboxRow(
                    title: "拆分合集 EPUB",
                    systemImage: "rectangle.split.2x1",
                    tint: Color.purple
                )
            }
            .buttonStyle(.plain)
            .disabled(model.report?.isDRMProtected == true)

            toolboxDivider()

            Button {
                Task {
                    if let txtURL = await model.exportAsTXT() {
                        shareURL = txtURL
                    }
                }
            } label: {
                toolboxRow(
                    title: model.isExportingTXT ? "正在提取纯文本 TXT…" : "导出为纯文本 TXT",
                    systemImage: model.isExportingTXT ? "hourglass" : "doc.text",
                    tint: Color.orange,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isExportingTXT || controlsDisabled)
        }
    }

    // MARK: - 处理选项分组卡片

    private var optionsCard: some View {
        toolboxSection("基础标准化与修复") {
            toolboxToggleRow(
                title: "EPUB 目录结构标准化",
                subtitle: "按 Sigil 规范整理目录结构，修复 mimetype 顺序并同步重写 HTML/CSS/目录相对路径。",
                systemImage: "folder.badge.gearshape",
                tint: NoveliaStyle.brandGreen,
                isOn: $model.options.standardizeStructure
            )
            toolboxDivider()
            toolboxToggleRow(
                title: "XHTML 良构修复",
                subtitle: "非 UTF-8 编码自动转 UTF-8，修复未闭合标签与非法实体，补齐标准 XML 与 XHTML 声明。",
                systemImage: "chevron.left.forwardslash.chevron.right",
                tint: Color.blue,
                isOn: $model.options.mendXHTML
            )
            toolboxDivider()
            toolboxToggleRow(
                title: "OPF / 目录 / 封面修复",
                subtitle: "清理 OPF 失效条目并补录未注册文件；修复或重建 NCX/Nav 目录；统一封面标记。",
                systemImage: "book.closed",
                tint: Color.teal,
                isOn: $model.options.repairOPFTOCCover
            )
            toolboxDivider()
            toolboxToggleRow(
                title: "冗余资源清理",
                subtitle: "移除未被正文、目录、封面或样式表引用的图片、CSS、字体及 __MACOSX 残留。",
                systemImage: "trash",
                tint: Color.orange,
                isOn: $model.options.removeUnusedResources
            )
        }
        .disabled(controlsDisabled)
        .opacity(controlsDisabled ? 0.6 : 1)
    }

    private var slimAndStyleCard: some View {
        toolboxSection("瘦身与样式清洗") {
            toolboxMenuRow(
                title: "图片瘦身压缩",
                value: model.options.imageCompression.title,
                highlighted: model.options.imageCompression != .off,
                systemImage: "photo.stack",
                tint: Color.purple
            ) {
                Picker("图片瘦身压缩", selection: $model.options.imageCompression) {
                    ForEach(EPUBImageCompressionOption.allCases) { Text($0.title).tag($0) }
                }
            }
            toolboxDivider()
            toolboxToggleRow(
                title: "移除内嵌字体",
                subtitle: "删除包内字体文件并移除 CSS 中的 @font-face，减小体积并让阅读器字体设置生效。",
                systemImage: "textformat",
                tint: Color.indigo,
                isOn: $model.options.removeEmbeddedFonts
            )
            toolboxDivider()
            toolboxToggleRow(
                title: "清理强制排版样式",
                subtitle: "清除 CSS 与内联样式中写死的字色、底色、字号与行高，修复深色模式看不清等问题。",
                systemImage: "paintbrush",
                tint: NoveliaStyle.brandGreen,
                isOn: $model.options.cleanForcedStyles
            )
        }
        .disabled(controlsDisabled)
        .opacity(controlsDisabled ? 0.6 : 1)
    }

    private var layoutAndFormatCard: some View {
        toolboxSection("排版与格式转换") {
            toolboxMenuRow(
                title: "全书简繁转换",
                value: model.options.chineseConversion.title,
                highlighted: model.options.chineseConversion != .none,
                systemImage: "character.textbox",
                tint: Color.blue
            ) {
                Picker("全书简繁转换", selection: $model.options.chineseConversion) {
                    ForEach(EPUBChineseConversionOption.allCases) { Text($0.title).tag($0) }
                }
            }
            toolboxDivider()
            toolboxMenuRow(
                title: "横排 / 竖排转换",
                value: model.options.writingDirection.title,
                highlighted: model.options.writingDirection != .keep,
                systemImage: "arrow.left.and.right.text.vertical",
                tint: Color.teal
            ) {
                Picker("横排 / 竖排转换", selection: $model.options.writingDirection) {
                    ForEach(EPUBWritingDirectionTransform.allCases) { Text($0.title).tag($0) }
                }
            }
            toolboxDivider()
            toolboxToggleRow(
                title: "EPUB 2 → EPUB 3 升级",
                subtitle: "升级 OPF 版本至 3.0，补齐 dcterms:modified、nav.xhtml 导航目录与 HTML5 DOCTYPE。",
                systemImage: "arrow.up.doc",
                tint: NoveliaStyle.brandGreen,
                isOn: $model.options.upgradeToEPUB3
            )
        }
        .disabled(controlsDisabled)
        .opacity(controlsDisabled ? 0.6 : 1)
    }

    private var lightNovelAndNotesCard: some View {
        toolboxSection("日轻与注释处理") {
            toolboxMenuRow(
                title: "Ruby 注音处理",
                value: model.options.rubyHandling.title,
                highlighted: model.options.rubyHandling != .keep,
                systemImage: "character.ja",
                tint: Color.orange
            ) {
                Picker("Ruby 注音处理", selection: $model.options.rubyHandling) {
                    ForEach(EPUBRubyHandling.allCases) { Text($0.title).tag($0) }
                }
            }
            toolboxDivider()
            toolboxToggleRow(
                title: "注释标准化（EPUB 3）",
                subtitle: "将多看等常见非标准注释转换为标准 epub:type=\"noteref\" 与 <aside epub:type=\"footnote\">。",
                systemImage: "text.bubble",
                tint: Color.indigo,
                isOn: $model.options.standardizeFootnotes
            )
        }
        .disabled(controlsDisabled)
        .opacity(controlsDisabled ? 0.6 : 1)
    }

    private var multiBookToolsCard: some View {
        toolboxSection("多书与效率工具") {
            NavigationLink {
                EPUBToolboxBatchView()
            } label: {
                toolboxRow(
                    title: "批量处理多本 EPUB",
                    subtitle: "一次对多本本地 EPUB 应用统一修复与清洗",
                    systemImage: "square.stack.3d.up",
                    tint: NoveliaStyle.brandGreen
                )
            }
            .buttonStyle(.plain)

            toolboxDivider()

            NavigationLink {
                EPUBToolboxMergeView()
            } label: {
                toolboxRow(
                    title: "合并多卷 EPUB 为合集",
                    subtitle: "按自定义卷序合并章节、目录与资源",
                    systemImage: "doc.on.doc",
                    tint: Color.blue
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 执行按钮区

    private var actionCard: some View {
        Group {
            if model.isProcessing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.progress.stage.isEmpty ? "正在处理 EPUB…" : model.progress.stage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.ink)
                        Spacer()
                        Text("\(Int(round(model.progress.fraction * 100)))%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    ProgressView(value: model.progress.fraction)
                        .tint(NoveliaStyle.brandGreen)
                    HStack {
                        Spacer()
                        Button("取消处理", role: .destructive) {
                            model.cancelProcessing()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(NoveliaStyle.danger.opacity(0.10), in: Capsule())
                        .buttonStyle(.plain)
                        .foregroundStyle(NoveliaStyle.danger)
                    }
                }
                .padding(16)
                .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
            } else {
                let isDisabled = model.isInspecting || !model.options.hasAnyEnabled || (model.report?.isDRMProtected == true)
                Button {
                    model.runProcessing()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("开始处理 EPUB")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        isDisabled ? NoveliaStyle.muted.opacity(0.35) : NoveliaStyle.brandGreen,
                        in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
    }

    // MARK: - 处理结果与输出区

    private func resultCard(_ outcome: EPUBToolboxResult) -> some View {
        let beforeText = ByteCountFormatter.string(fromByteCount: outcome.originalSizeBytes, countStyle: .file)
        let afterText = ByteCountFormatter.string(fromByteCount: outcome.outputSizeBytes, countStyle: .file)
        let items = resultSummaryItems(outcome)

        return toolboxSection("处理结果") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    toolboxBadge("checkmark.circle.fill", tint: NoveliaStyle.brandGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("处理完成")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(NoveliaStyle.ink)
                        Text("体积：\(beforeText) → \(afterText)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    Spacer()
                }

                if !items.isEmpty {
                    Rectangle().fill(NoveliaStyle.hairline).frame(height: 0.75)
                    VStack(spacing: 8) {
                        ForEach(items, id: \.0) { label, value in
                            HStack(alignment: .top, spacing: 8) {
                                Text(label)
                                    .font(NoveliaStyle.fontBody)
                                    .foregroundStyle(NoveliaStyle.muted)
                                Spacer(minLength: 8)
                                Text(value)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(NoveliaStyle.ink)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                } else {
                    Text("已完成重新打包，原书未触发额外结构改动。")
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                }

                ForEach(outcome.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                }

                Rectangle().fill(NoveliaStyle.hairline).frame(height: 0.75)

                if let savedTitle = model.savedToLibraryTitle {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        Text("已另存为新书《\(savedTitle)》")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NoveliaStyle.brandGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
                } else {
                    Button {
                        Task { await model.saveResultToLibrary(using: wenkuDownloads) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: model.isSavingToLibrary ? "hourglass" : "plus.rectangle.on.folder.fill")
                            Text(model.isSavingToLibrary ? "正在保存到书库…" : "另存为新书入库")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(NoveliaStyle.brandGreen, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSavingToLibrary)
                }

                Button {
                    shareURL = outcome.outputURL
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出 / 分享 EPUB")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                            .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }

    private func resultSummaryItems(_ outcome: EPUBToolboxResult) -> [(String, String)] {
        var rows: [(String, String)] = []
        if outcome.relocatedPathsCount > 0 {
            rows.append(("目录标准化重排", "\(outcome.relocatedPathsCount) 处路径"))
        }
        if outcome.mendedXHTMLCount > 0 {
            rows.append(("XHTML 良构修复", "\(outcome.mendedXHTMLCount) 个文档"))
        }
        if outcome.removedDeadManifestCount > 0 || outcome.registeredOrphanCount > 0 {
            rows.append(("OPF 清单修复", "清理 \(outcome.removedDeadManifestCount) 处死链，补录 \(outcome.registeredOrphanCount) 项"))
        }
        if outcome.repairedTOC {
            rows.append(("目录修复", "已同步/重建 NCX 与导航目录"))
        }
        if outcome.repairedCover {
            rows.append(("封面修复", "已规范化封面声明"))
        }
        if outcome.removedUnusedCount > 0 {
            let saved = ByteCountFormatter.string(fromByteCount: outcome.removedUnusedBytes, countStyle: .file)
            rows.append(("清理冗余资源", "\(outcome.removedUnusedCount) 个（释放 \(saved)）"))
        }
        if outcome.compressedImagesCount > 0 {
            let saved = ByteCountFormatter.string(fromByteCount: outcome.compressedImagesSavedBytes, countStyle: .file)
            rows.append(("图片瘦身", "\(outcome.compressedImagesCount) 张（节省 \(saved)）"))
        }
        if outcome.removedFontsCount > 0 {
            let saved = ByteCountFormatter.string(fromByteCount: outcome.removedFontsBytes, countStyle: .file)
            rows.append(("移除内嵌字体", "\(outcome.removedFontsCount) 个（释放 \(saved)）"))
        }
        if outcome.cleanedStyleCount > 0 {
            rows.append(("样式清洗", "\(outcome.cleanedStyleCount) 处样式表/文档"))
        }
        if outcome.updatedMetadata {
            rows.append(("元数据与封面", "已写入新 EPUB"))
        }
        if outcome.convertedChinese {
            rows.append(("简繁转换", "已转换全书正文与目录"))
        }
        if outcome.convertedWritingDirection {
            rows.append(("排版方向", "已更新 OPF 与 CSS"))
        }
        if outcome.upgradedToEPUB3 {
            rows.append(("版本升级", "已升级至 EPUB 3.0"))
        }
        if outcome.processedRubyCount > 0 {
            rows.append(("Ruby 注音", "已处理 \(outcome.processedRubyCount) 处"))
        }
        if outcome.standardizedFootnotesCount > 0 {
            rows.append(("注释标准化", "已规范化 \(outcome.standardizedFootnotesCount) 处"))
        }
        return rows
    }

    // MARK: - 工具箱纸面组件

    private func toolboxSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NoveliaStyle.muted)
                .padding(.horizontal, 6)
            VStack(spacing: 0) {
                content()
            }
            .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
        }
    }

    private func toolboxBadge(_ systemImage: String, tint: Color, size: CGFloat = 28, iconSize: CGFloat = 13) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
            .accessibilityHidden(true)
    }

    private func toolboxDivider(leading: CGFloat = 54) -> some View {
        Rectangle()
            .fill(NoveliaStyle.hairline)
            .frame(height: 0.75)
            .padding(.leading, leading)
    }

    private func toolboxRow(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        valueHighlighted: Bool = false,
        systemImage: String,
        tint: Color,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            toolboxBadge(systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NoveliaStyle.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: valueHighlighted ? .semibold : .regular))
                    .foregroundStyle(valueHighlighted ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func toolboxToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            toolboxBadge(systemImage, tint: tint)
                .padding(.top, 1)
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                    Text(subtitle)
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(NoveliaStyle.brandGreen)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func toolboxMenuRow<MenuContent: View>(
        title: String,
        value: String,
        highlighted: Bool,
        systemImage: String,
        tint: Color,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        HStack(spacing: 12) {
            toolboxBadge(systemImage, tint: tint)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NoveliaStyle.ink)
            Spacer(minLength: 8)
            Menu {
                menu()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 13, weight: highlighted ? .semibold : .regular))
                        .foregroundStyle(highlighted ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.muted.opacity(0.7))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
