// SPDX-License-Identifier: GPL-3.0-only
import ReadiumZIPFoundation
import SwiftUI

// MARK: - 1. 批量处理多本 EPUB

struct EPUBToolboxBatchView: View {
    @EnvironmentObject private var libraryState: LibraryStateStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var syncStore: WebDAVSyncStore

    struct ItemResult: Identifiable {
        let id = UUID()
        let title: String
        let outputURL: URL?
        let originalBytes: Int64
        let outputBytes: Int64
        let error: String?
    }

    @State private var selectedKeys = Set<String>()
    @State private var options = EPUBToolboxOptions.all
    @State private var isRunning = false
    @State private var completedCount = 0
    @State private var results: [ItemResult] = []
    @State private var workspaceDir: URL?
    @State private var isSavingAll = false
    @State private var savedSummary: String?
    @State private var shareZipURL: URL?
    @State private var errorMessage: String?
    @State private var runTask: Task<Void, Never>?

    private var localEPUBBooks: [LibraryBook] {
        libraryState.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks)
            .filter { $0.format == .epub && !$0.isCloudOnly }
    }

    private var selectedBooks: [LibraryBook] {
        localEPUBBooks.filter { selectedKeys.contains($0.key) }
    }

    var body: some View {
        Form {
            Section {
                if localEPUBBooks.isEmpty {
                    Text("书库中暂无本机 EPUB 书籍。")
                        .foregroundStyle(NoveliaStyle.muted)
                } else {
                    HStack {
                        Text("已选择 \(selectedBooks.count) / \(localEPUBBooks.count) 本")
                            .font(.subheadline)
                        Spacer()
                        Button(selectedBooks.count == localEPUBBooks.count ? "取消全选" : "全选") {
                            if selectedBooks.count == localEPUBBooks.count {
                                selectedKeys.removeAll()
                            } else {
                                selectedKeys = Set(localEPUBBooks.map(\.key))
                            }
                        }
                        .font(.subheadline)
                    }
                    ForEach(localEPUBBooks) { book in
                        Button {
                            if selectedKeys.contains(book.key) {
                                selectedKeys.remove(book.key)
                            } else {
                                selectedKeys.insert(book.key)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedKeys.contains(book.key) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedKeys.contains(book.key) ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .foregroundStyle(NoveliaStyle.ink)
                                        .lineLimit(1)
                                    if !book.author.isEmpty {
                                        Text(book.author)
                                            .font(.caption)
                                            .foregroundStyle(NoveliaStyle.muted)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("选择书库 EPUB")
            }
            .disabled(isRunning)

            Section("批量处理选项") {
                Toggle("EPUB 目录结构标准化", isOn: $options.standardizeStructure)
                Toggle("XHTML 良构修复", isOn: $options.mendXHTML)
                Toggle("OPF / 目录 / 封面修复", isOn: $options.repairOPFTOCCover)
                Toggle("冗余资源清理", isOn: $options.removeUnusedResources)
                Picker("图片瘦身", selection: $options.imageCompression) {
                    ForEach(EPUBImageCompressionOption.allCases) { Text($0.title).tag($0) }
                }
                Toggle("移除内嵌字体", isOn: $options.removeEmbeddedFonts)
                Toggle("清理强制样式", isOn: $options.cleanForcedStyles)
                Picker("全书简繁转换", selection: $options.chineseConversion) {
                    ForEach(EPUBChineseConversionOption.allCases) { Text($0.title).tag($0) }
                }
                Picker("横排 / 竖排", selection: $options.writingDirection) {
                    ForEach(EPUBWritingDirectionTransform.allCases) { Text($0.title).tag($0) }
                }
                Toggle("升级为 EPUB 3", isOn: $options.upgradeToEPUB3)
                Picker("Ruby 注音处理", selection: $options.rubyHandling) {
                    ForEach(EPUBRubyHandling.allCases) { Text($0.title).tag($0) }
                }
                Toggle("注释标准化（EPUB 3）", isOn: $options.standardizeFootnotes)
            }
            .disabled(isRunning)

            Section {
                if isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(completedCount), total: Double(max(selectedBooks.count, 1)))
                            .tint(NoveliaStyle.brandGreen)
                        HStack {
                            Text("正在批量处理（\(completedCount)/\(selectedBooks.count)）…")
                                .font(.caption)
                                .foregroundStyle(NoveliaStyle.muted)
                            Spacer()
                            Button("取消", role: .destructive) { runTask?.cancel() }
                                .font(.caption)
                        }
                    }
                } else {
                    Button {
                        startBatch()
                    } label: {
                        HStack {
                            Spacer()
                            Label("开始批量处理（\(selectedBooks.count) 本）", systemImage: "square.stack.3d.up.fill")
                                .compatFontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(selectedBooks.isEmpty || !options.hasAnyEnabled)
                }
            }

            if !results.isEmpty {
                let succeeded = results.filter { $0.outputURL != nil }
                Section("批量结果（成功 \(succeeded.count) / \(results.count)）") {
                    ForEach(results) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            if let err = item.error {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.danger)
                            } else {
                                let before = ByteCountFormatter.string(fromByteCount: item.originalBytes, countStyle: .file)
                                let after = ByteCountFormatter.string(fromByteCount: item.outputBytes, countStyle: .file)
                                Text("成功 · \(before) → \(after)")
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                            }
                        }
                    }
                    if !succeeded.isEmpty {
                        if let savedSummary {
                            Label(savedSummary, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(NoveliaStyle.brandGreen)
                        } else {
                            Button {
                                Task { await saveAllToLibrary(succeeded) }
                            } label: {
                                Label(isSavingAll ? "正在入库…" : "全部另存为新书入库（\(succeeded.count) 本）", systemImage: "plus.rectangle.on.folder")
                            }
                            .tint(NoveliaStyle.brandGreen)
                            .disabled(isSavingAll)
                        }
                        Button {
                            Task { await shareAsZip(succeeded) }
                        } label: {
                            Label("打包 ZIP 导出 / 分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("批量处理 EPUB")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            runTask?.cancel()
            if let dir = workspaceDir { try? FileManager.default.removeItem(at: dir) }
        }
        .sheet(isPresented: Binding(get: { shareZipURL != nil }, set: { if !$0 { shareZipURL = nil } })) {
            if let url = shareZipURL {
                LibraryArchiveShareSheet(url: url).ignoresSafeArea()
            }
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startBatch() {
        let targets = selectedBooks
        guard !targets.isEmpty else { return }
        if let old = workspaceDir { try? FileManager.default.removeItem(at: old) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NoveliaBatch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspaceDir = dir
        results = []
        savedSummary = nil
        completedCount = 0
        isRunning = true
        let opts = options

        runTask = Task {
            defer { isRunning = false }
            for (idx, book) in targets.enumerated() {
                if Task.isCancelled { break }
                let outName = String(format: "%02d_%@.epub", idx + 1, EPUBToolboxPath.sanitizedFilename(book.title, fallback: "book"))
                let dest = dir.appendingPathComponent(outName)
                do {
                    let res = try await Task.detached(priority: .userInitiated) {
                        try await EPUBToolboxProcessor.process(source: book.fileURL, destination: dest, options: opts)
                    }.value
                    results.append(ItemResult(title: book.title, outputURL: res.outputURL, originalBytes: res.originalSizeBytes, outputBytes: res.outputSizeBytes, error: nil))
                } catch {
                    results.append(ItemResult(title: book.title, outputURL: nil, originalBytes: 0, outputBytes: 0, error: error.localizedDescription))
                }
                completedCount = idx + 1
            }
        }
    }

    private func saveAllToLibrary(_ items: [ItemResult]) async {
        isSavingAll = true
        defer { isSavingAll = false }
        var ok = 0
        var dup = 0
        for item in items {
            guard let url = item.outputURL else { continue }
            do {
                try await wenkuDownloads.loadIfNeeded()
                let title = item.title.hasSuffix("（已标准化）") ? item.title : "\(item.title)（已标准化）"
                let dest = wenkuDownloads.downloadDestination(for: url.lastPathComponent)
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                        try FileManager.default.copyItem(at: url, to: dest)
                    }.value
                    try await wenkuDownloads.registerDownloadedFile(at: dest, title: title, source: .import)
                    ok += 1
                } catch {
                    try? FileManager.default.removeItem(at: dest)
                    throw error
                }
            } catch is LocalLibraryDuplicateError {
                dup += 1
            } catch {
                // 继续处理剩余书籍
            }
        }
        savedSummary = dup > 0 ? "已入库 \(ok) 本（\(dup) 本内容重复已跳过）" : "已全部另存为新书入库（\(ok) 本）"
    }

    private func shareAsZip(_ items: [ItemResult]) async {
        guard let dir = workspaceDir else { return }
        let zipURL = dir.appendingPathComponent("Novelia-EPUB-Batch.zip")
        do {
            try await Task.detached(priority: .userInitiated) {
                try await EPUBToolboxZipHelper.zipFiles(
                    items.compactMap { $0.outputURL },
                    to: zipURL
                )
            }.value
            shareZipURL = zipURL
        } catch {
            errorMessage = "打包 ZIP 失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 2. 合并多卷 EPUB

struct EPUBToolboxMergeView: View {
    @EnvironmentObject private var libraryState: LibraryStateStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var syncStore: WebDAVSyncStore

    @State private var selectedVolumes: [LibraryBook] = []
    @State private var mergedTitle = ""
    @State private var mergedAuthor = ""
    @State private var isShowingPicker = false
    @State private var isMerging = false
    @State private var progress = EPUBToolboxProgress(fraction: 0, stage: "")
    @State private var mergeResult: EPUBToolboxMerger.MergeResult?
    @State private var workspaceDir: URL?
    @State private var isSaving = false
    @State private var savedTitle: String?
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    private var localEPUBBooks: [LibraryBook] {
        libraryState.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks)
            .filter { $0.format == .epub && !$0.isCloudOnly }
    }

    var body: some View {
        Form {
            Section {
                TextField("合集书名", text: $mergedTitle)
                TextField("作者（可选）", text: $mergedAuthor)
            } header: {
                Text("合集信息")
            }

            Section {
                ForEach(Array(selectedVolumes.enumerated()), id: \.element.key) { index, book in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(book.title)")
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        Spacer()
                        if index > 0 {
                            Button {
                                selectedVolumes.swapAt(index, index - 1)
                            } label: { Image(systemName: "arrow.up.circle") }
                                .buttonStyle(.borderless)
                        }
                        if index + 1 < selectedVolumes.count {
                            Button {
                                selectedVolumes.swapAt(index, index + 1)
                            } label: { Image(systemName: "arrow.down.circle") }
                                .buttonStyle(.borderless)
                        }
                        Button(role: .destructive) {
                            selectedVolumes.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button {
                    isShowingPicker = true
                } label: {
                    Label("从书库添加分卷 EPUB", systemImage: "plus.circle")
                }
            } header: {
                Text("分卷顺序（至少 2 卷，当前 \(selectedVolumes.count) 卷）")
            } footer: {
                Text("合并后的 EPUB 会以各分卷作为一级目录，并保留第一卷的封面图片。")
            }
            .disabled(isMerging)

            Section {
                if isMerging {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress.fraction).tint(NoveliaStyle.brandGreen)
                        Text(progress.stage).font(.caption).foregroundStyle(NoveliaStyle.muted)
                    }
                } else {
                    Button {
                        startMerge()
                    } label: {
                        HStack {
                            Spacer()
                            Label("开始合并 EPUB", systemImage: "doc.on.doc.fill")
                                .compatFontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(selectedVolumes.count < 2)
                }
            }

            if let res = mergeResult {
                Section("合并结果") {
                    CompatLabeledContent("合并卷数", value: "\(res.volumeCount) 卷（共 \(res.totalSpineCount) 个章节文档）")
                    CompatLabeledContent("输出体积", value: ByteCountFormatter.string(fromByteCount: res.outputSizeBytes, countStyle: .file))
                    if let savedTitle {
                        Label("已入库《\(savedTitle)》", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    } else {
                        Button {
                            Task { await saveMergedToLibrary(res) }
                        } label: {
                            Label(isSaving ? "正在入库…" : "另存为新书入库", systemImage: "plus.rectangle.on.folder")
                        }
                        .tint(NoveliaStyle.brandGreen)
                        .disabled(isSaving)
                    }
                    Button {
                        shareURL = res.outputURL
                    } label: {
                        Label("导出 / 分享合集 EPUB", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("合并多卷 EPUB")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if let dir = workspaceDir { try? FileManager.default.removeItem(at: dir) }
        }
        .sheet(isPresented: $isShowingPicker) {
            CompatNavigationStack {
                EPUBToolboxLibraryPickerView(books: localEPUBBooks) { book in
                    if !selectedVolumes.contains(where: { $0.key == book.key }) {
                        selectedVolumes.append(book)
                        if mergedTitle.isEmpty { mergedTitle = book.title + "（合集）" }
                        if mergedAuthor.isEmpty { mergedAuthor = book.author }
                    }
                    isShowingPicker = false
                }
            }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { LibraryArchiveShareSheet(url: url).ignoresSafeArea() }
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func startMerge() {
        guard selectedVolumes.count >= 2 else { return }
        if let old = workspaceDir { try? FileManager.default.removeItem(at: old) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NoveliaMerge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspaceDir = dir
        let title = mergedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "合集" : mergedTitle
        let author = mergedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = dir.appendingPathComponent(EPUBToolboxPath.sanitizedFilename(title, fallback: "merged") + ".epub")
        let inputs = selectedVolumes.map { EPUBToolboxMerger.VolumeInput(title: $0.title, url: $0.fileURL) }

        isMerging = true
        mergeResult = nil
        savedTitle = nil
        Task {
            defer { isMerging = false }
            do {
                mergeResult = try await Task.detached(priority: .userInitiated) {
                    try await EPUBToolboxMerger.merge(volumes: inputs, title: title, author: author, destination: dest) { p in
                        Task { @MainActor in progress = p }
                    }
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveMergedToLibrary(_ res: EPUBToolboxMerger.MergeResult) async {
        isSaving = true
        defer { isSaving = false }
        let title = mergedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "合集" : mergedTitle
        do {
            try await wenkuDownloads.loadIfNeeded()
            let dest = wenkuDownloads.downloadDestination(for: res.outputURL.lastPathComponent)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            do {
                try await Task.detached(priority: .userInitiated) {
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.copyItem(at: res.outputURL, to: dest)
                }.value
                try await wenkuDownloads.registerDownloadedFile(at: dest, title: title, source: .import)
                savedTitle = title
            } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
        } catch {
            errorMessage = "保存到书库失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 3. 拆分合集 EPUB

struct EPUBToolboxSplitView: View {
    let sourceURL: URL
    let bookTitle: String

    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @State private var isLoading = true
    @State private var groups: [EPUBToolboxSplitter.SplitGroup] = []
    @State private var isSplitting = false
    @State private var progress = EPUBToolboxProgress(fraction: 0, stage: "")
    @State private var splitResults: [EPUBToolboxSplitter.SplitVolumeResult] = []
    @State private var workspaceDir: URL?
    @State private var isSavingAll = false
    @State private var savedSummary: String?
    @State private var shareZipURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在分析目录结构并规划拆分分组…").foregroundStyle(NoveliaStyle.muted)
                    }
                } else if groups.isEmpty {
                    Text("未能识别出可拆分的分册分组。").foregroundStyle(NoveliaStyle.muted)
                } else {
                    ForEach($groups) { $group in
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("分册书名", text: $group.title)
                                .font(.subheadline)
                            Text("章节范围：第 \(group.spineRange.lowerBound + 1)–\(group.spineRange.upperBound) 节（共 \(group.spineRange.count) 节）")
                                .font(.caption)
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                    }
                    .onDelete { groups.remove(atOffsets: $0) }
                }
            } header: {
                Text("拆分分组（共 \(groups.count) 册，左滑可移除）")
            } footer: {
                Text("每本拆出的 EPUB 仅保留本册引用的样式与图片资源，不修改原书。")
            }
            .disabled(isSplitting)

            Section {
                if isSplitting {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress.fraction).tint(NoveliaStyle.brandGreen)
                        Text(progress.stage).font(.caption).foregroundStyle(NoveliaStyle.muted)
                    }
                } else {
                    Button {
                        startSplit()
                    } label: {
                        HStack {
                            Spacer()
                            Label("开始拆分为 \(groups.count) 本 EPUB", systemImage: "rectangle.split.2x1.fill")
                                .compatFontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(groups.isEmpty || isLoading)
                }
            }

            if !splitResults.isEmpty {
                Section("拆分完成（\(splitResults.count) 本）") {
                    ForEach(splitResults) { item in
                        CompatLabeledContent(item.title, value: ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    }
                    if let savedSummary {
                        Label(savedSummary, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    } else {
                        Button {
                            Task { await saveAllToLibrary() }
                        } label: {
                            Label(isSavingAll ? "正在入库…" : "全部另存为新书入库", systemImage: "plus.rectangle.on.folder")
                        }
                        .tint(NoveliaStyle.brandGreen)
                        .disabled(isSavingAll)
                    }
                    Button {
                        Task { await shareAsZip() }
                    } label: {
                        Label("打包 ZIP 导出 / 分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("拆分合集 EPUB")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadGroups() }
        .onDisappear {
            if let dir = workspaceDir { try? FileManager.default.removeItem(at: dir) }
        }
        .sheet(isPresented: Binding(get: { shareZipURL != nil }, set: { if !$0 { shareZipURL = nil } })) {
            if let url = shareZipURL { LibraryArchiveShareSheet(url: url).ignoresSafeArea() }
        }
        .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func loadGroups() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await Task.detached(priority: .userInitiated) {
                try await EPUBToolboxSplitter.proposeGroups(url: sourceURL)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSplit() {
        if let old = workspaceDir { try? FileManager.default.removeItem(at: old) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NoveliaSplit-\(UUID().uuidString)", isDirectory: true)
        workspaceDir = dir
        let chosen = groups
        isSplitting = true
        splitResults = []
        savedSummary = nil
        Task {
            defer { isSplitting = false }
            do {
                splitResults = try await Task.detached(priority: .userInitiated) {
                    try await EPUBToolboxSplitter.split(source: sourceURL, groups: chosen, outputDirectory: dir) { p in
                        Task { @MainActor in progress = p }
                    }
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveAllToLibrary() async {
        isSavingAll = true
        defer { isSavingAll = false }
        var ok = 0
        for item in splitResults {
            do {
                try await wenkuDownloads.loadIfNeeded()
                let dest = wenkuDownloads.downloadDestination(for: item.outputURL.lastPathComponent)
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                        try FileManager.default.copyItem(at: item.outputURL, to: dest)
                    }.value
                    try await wenkuDownloads.registerDownloadedFile(at: dest, title: item.title, source: .import)
                    ok += 1
                } catch {
                    try? FileManager.default.removeItem(at: dest)
                    throw error
                }
            } catch {
                // 跳过重复或异常项
            }
        }
        savedSummary = "已入库 \(ok) / \(splitResults.count) 本分册"
    }

    private func shareAsZip() async {
        guard let dir = workspaceDir else { return }
        let zipURL = dir.appendingPathComponent("\(EPUBToolboxPath.sanitizedFilename(bookTitle, fallback: "split"))-split.zip")
        do {
            try await Task.detached(priority: .userInitiated) {
                try await EPUBToolboxZipHelper.zipFiles(splitResults.map(\.outputURL), to: zipURL)
            }.value
            shareZipURL = zipURL
        } catch {
            errorMessage = "打包 ZIP 失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 多文件打包 ZIP 辅助

private enum EPUBToolboxZipHelper {
    static func zipFiles(_ urls: [URL], to destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard let archive = try? await Archive(url: destination, accessMode: .create) else {
            throw EPUBToolboxError.writeFailed("无法创建 ZIP 文件")
        }
        for fileURL in urls {
            let data = try Data(contentsOf: fileURL)
            try await archive.addEntry(
                with: fileURL.lastPathComponent,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
    }
}
