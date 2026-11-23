// SPDX-License-Identifier: GPL-3.0-only
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 1. 元数据与封面编辑器

/// 编辑将写入新 EPUB 文件的元数据（书名、作者、语言、简介）与封面图；点击保存后暂存到工具箱选项，执行处理时写入新文件。
struct EPUBMetadataEditorSheet: View {
    let sourceURL: URL
    let initialOverride: EPUBMetadataOverride?
    let onSave: (EPUBMetadataOverride?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var title = ""
    @State private var author = ""
    @State private var language = "zh"
    @State private var descriptionText = ""
    @State private var originalCoverData: Data?
    @State private var customCoverData: Data?
    @State private var loadError: String?

    var body: some View {
        CompatNavigationStack {
            Form {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取原书元数据…")
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                } else {
                    Section("封面图片") {
                        HStack(spacing: 16) {
                            coverPreview
                                .frame(width: 66, height: 94)
                                .clipShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
                                .overlay(
                                    RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall)
                                        .stroke(NoveliaStyle.hairline, lineWidth: 1)
                                )
                            VStack(alignment: .leading, spacing: 10) {
                                CompatPhotosPickerButton(onData: { raw in
                                    if let image = UIImage(data: raw),
                                       let jpeg = image.jpegData(compressionQuality: 0.88) {
                                        customCoverData = jpeg
                                    } else {
                                        customCoverData = raw
                                    }
                                }) {
                                    Label("从相册更换封面", systemImage: "photo")
                                }
                                if customCoverData != nil {
                                    Button("恢复原书封面", role: .destructive) {
                                        customCoverData = nil
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section("基础信息") {
                        TextField("书名", text: $title)
                        TextField("作者", text: $author)
                        TextField("语言代码（如 zh-Hans / zh-Hant / ja）", text: $language)
                            .textInputAutocapitalization(.never)
                            .compatAutocorrectionDisabled()
                    }

                    Section("简介") {
                        CompatVerticalTextField(prompt: "书籍简介", text: $descriptionText, limit: 4...10)
                    }

                    if initialOverride != nil {
                        Section {
                            Button("清除已暂存的元数据修改", role: .destructive) {
                                onSave(nil)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .compatScrollContentBackgroundHidden()
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("元数据与封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("应用") {
                        let override = EPUBMetadataOverride(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            author: author.trimmingCharacters(in: .whitespacesAndNewlines),
                            language: language.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                            coverImageData: customCoverData,
                            coverMediaType: "image/jpeg"
                        )
                        onSave(override)
                        dismiss()
                    }
                    .compatFontWeight(.semibold)
                    .disabled(isLoading)
                }
            }
            .task { await loadSnapshot() }
            .alert("读取失败", isPresented: Binding(
                get: { loadError != nil },
                set: { if !$0 { loadError = nil } }
            )) {
                Button("好", role: .cancel) { loadError = nil }
            } message: {
                Text(loadError ?? "")
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        if let data = customCoverData ?? originalCoverData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                NoveliaStyle.card
                Image(systemName: "book.closed")
                    .foregroundStyle(NoveliaStyle.muted)
            }
        }
    }

    private func loadSnapshot() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try await EPUBArchiveBrowser.loadEditableSnapshot(url: sourceURL)
            }.value
            title = initialOverride?.title ?? snapshot.title
            author = initialOverride?.author ?? snapshot.author
            language = initialOverride?.language ?? snapshot.language
            descriptionText = initialOverride?.description ?? snapshot.description
            originalCoverData = snapshot.coverImageData
            customCoverData = initialOverride?.coverImageData
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - 2. 目录可视化编辑与正则重建

/// 可视化编辑 EPUB 目录条目（改名、删除、按自定义正则重新扫描正文标题），点击应用后暂存到工具箱选项。
struct EPUBTOCEditorSheet: View {
    let sourceURL: URL
    let initialNodes: [EPUBToolboxTOCNode]?
    let onSave: ([EPUBToolboxTOCNode]?) -> Void

    struct EditableRow: Identifiable {
        let id = UUID()
        var title: String
        let path: String
        let fragment: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var rows: [EditableRow] = []
    @State private var regexPattern = "^(?:序章|序幕|Prologue|第\\s*[0-9０-９一二三四五六七八九十百]+\\s*(?:章|话|話|节|節|回|幕)|终章|終章|尾声|后日谈|Epilogue)"
    @State private var isRebuilding = false
    @State private var errorMessage: String?

    var body: some View {
        CompatNavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("按正则表达式从正文重建目录")
                            .font(.subheadline.weight(.medium))
                        TextField("输入标题匹配正则", text: $regexPattern)
                            .font(.system(.caption, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .compatAutocorrectionDisabled()
                        Button {
                            Task { await rebuildByRegex() }
                        } label: {
                            if isRebuilding {
                                Label("正在扫描正文…", systemImage: "hourglass")
                            } else {
                                Label("按正则重新扫描章节", systemImage: "text.magnifyingglass")
                            }
                        }
                        .disabled(isRebuilding || regexPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 4)
                }

                Section("目录条目（共 \(rows.count) 项，左滑可删除）") {
                    if isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在读取原书目录…")
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                    } else if rows.isEmpty {
                        Text("当前目录为空，可尝试使用上方正则扫描正文生成目录。")
                            .font(.caption)
                            .foregroundStyle(NoveliaStyle.muted)
                    } else {
                        ForEach($rows) { $row in
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("章节标题", text: $row.title)
                                    .font(.body)
                                Text(EPUBToolboxPath.filename(of: row.path) + row.fragment)
                                    .font(.caption2)
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { offsets in
                            rows.remove(atOffsets: offsets)
                        }
                        .onMove { from, to in
                            rows.move(fromOffsets: from, toOffset: to)
                        }
                    }
                }

                if initialNodes != nil {
                    Section {
                        Button("恢复原书目录（取消自定义）", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .compatScrollContentBackgroundHidden()
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("目录编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("应用") {
                        let nodes = rows.compactMap { row -> EPUBToolboxTOCNode? in
                            let t = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return nil }
                            return EPUBToolboxTOCNode(title: t, path: row.path, fragment: row.fragment, children: [])
                        }
                        onSave(nodes)
                        dismiss()
                    }
                    .compatFontWeight(.semibold)
                    .disabled(isLoading || rows.isEmpty)
                }
            }
            .task { await loadInitial() }
            .alert("提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func loadInitial() async {
        isLoading = true
        defer { isLoading = false }
        if let initialNodes {
            rows = flatten(initialNodes)
            return
        }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try await EPUBArchiveBrowser.loadEditableSnapshot(url: sourceURL)
            }.value
            rows = flatten(snapshot.tocNodes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func flatten(_ nodes: [EPUBToolboxTOCNode]) -> [EditableRow] {
        var result: [EditableRow] = []
        for node in nodes {
            if !node.path.isEmpty {
                result.append(EditableRow(title: node.title, path: node.path, fragment: node.fragment))
            }
            result.append(contentsOf: flatten(node.children))
        }
        return result
    }

    private func rebuildByRegex() async {
        isRebuilding = true
        defer { isRebuilding = false }
        let pattern = regexPattern
        do {
            let rebuilt = try await Task.detached(priority: .userInitiated) {
                try await EPUBToolboxTransforms.rebuildTOC(url: sourceURL, regexPattern: pattern)
            }.value
            if rebuilt.isEmpty {
                errorMessage = "未匹配到符合该正则的章节标题，请尝试调整表达式。"
            } else {
                rows = flatten(rebuilt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 3. EPUB 内部文件浏览器（只读）

/// 浏览器持有一次扫描的目录索引，子页面共用它。打开预览时按原始键读取对应条目。
struct EPUBArchiveBrowserView: View {
    let sourceURL: URL
    let bookTitle: String

    @State private var listing: EPUBArchiveListing?
    @State private var errorMessage: String?
    @State private var sortOrder = EPUBArchiveSortOrder.name

    var body: some View {
        Group {
            if let listing {
                EPUBArchiveFolderView(sourceURL: sourceURL, title: bookTitle, folder: "", listing: listing, sortOrder: $sortOrder)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Label("无法打开 EPUB", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await loadEntries() } }
                }
                .padding()
            } else {
                ProgressView("正在读取文件目录…")
            }
        }
        .task {
            if listing == nil, errorMessage == nil { await loadEntries() }
        }
    }

    private func loadEntries() async {
        errorMessage = nil
        do {
            listing = try await EPUBArchiveBrowser.listEntries(url: sourceURL)
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

private enum EPUBArchiveSortOrder: String, CaseIterable, Identifiable {
    case name = "名称"
    case size = "大小"

    var id: Self { self }
}

private struct EPUBArchiveFolderView: View {
    let sourceURL: URL
    let title: String
    let folder: String
    let listing: EPUBArchiveListing
    @Binding var sortOrder: EPUBArchiveSortOrder

    @State private var query = ""
    @State private var previewEntry: EPUBArchiveEntryInfo?
    @State private var loadingImage: EPUBArchiveEntryInfo?
    @State private var imagePreviewFile: EPUBArchivePreviewFile?
    @State private var imagePreviewURL: URL?
    @State private var imagePreviewError: String?
    @State private var showsStatistics = false

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !searchTerm.isEmpty }
    private var folders: [String] {
        guard isSearching else { return listing.foldersByParent[folder] ?? [] }
        let prefix = folder.isEmpty ? "" : folder + "/"
        return listing.foldersByParent.values.joined().filter {
            $0.hasPrefix(prefix) && $0 != folder && EPUBToolboxPath.filename(of: $0).localizedCaseInsensitiveContains(searchTerm)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var files: [EPUBArchiveEntryInfo] {
        let entries: [EPUBArchiveEntryInfo]
        if isSearching {
            let prefix = folder.isEmpty ? "" : folder + "/"
            entries = listing.entries.filter {
                $0.path.hasPrefix(prefix) && ($0.path.localizedCaseInsensitiveContains(searchTerm)
                    || $0.category.localizedCaseInsensitiveContains(searchTerm))
            }
        } else {
            entries = listing.filesByFolder[folder] ?? []
        }
        return entries.sorted {
            if sortOrder == .size, $0.uncompressedBytes != $1.uncompressedBytes {
                return $0.uncompressedBytes > $1.uncompressedBytes
            }
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.path < $1.path : byName == .orderedAscending
        }
    }

    var body: some View {
        let visibleFolders = folders
        let visibleFiles = files
        List {
            ForEach(visibleFolders, id: \.self) { path in
                folderRow(path)
            }
            ForEach(visibleFiles) { entry in
                if entry.isTextPreviewable || imageType(for: entry) != nil {
                    Button { open(entry) } label: {
                        fileRow(entry, opensPreview: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("epub-archive-file-\(entry.path)")
                } else {
                    fileRow(entry, opensPreview: false)
                }
            }
            if visibleFolders.isEmpty, visibleFiles.isEmpty {
                Label(isSearching ? "未找到匹配项" : "此文件夹为空", systemImage: isSearching ? "magnifyingglass" : "folder")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索文件与文件夹")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(folder.isEmpty ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .compatTopBarTrailing) {
                Menu {
                    Picker("排序方式", selection: $sortOrder) {
                        ForEach(EPUBArchiveSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    if folder.isEmpty {
                        Button { showsStatistics = true } label: {
                            Label("文件统计", systemImage: "chart.bar")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("浏览选项")
            }
        }
        .sheet(item: $previewEntry) {
            EPUBArchiveTextPreviewSheet(sourceURL: sourceURL, entry: $0)
        }
        .sheet(isPresented: $showsStatistics) {
            EPUBArchiveStatisticsSheet(entries: listing.entries)
        }
        .quickLookPreview($imagePreviewURL)
        .onValueChange(of: imagePreviewURL) { _, url in
            if url == nil { imagePreviewFile = nil }
        }
        .task(id: loadingImage) { await loadImagePreview() }
        .alert("无法预览图片", isPresented: Binding(
            get: { imagePreviewError != nil },
            set: { if !$0 { imagePreviewError = nil } }
        )) {
            Button("好", role: .cancel) { imagePreviewError = nil }
        } message: {
            Text(imagePreviewError ?? "")
        }
    }

    private func open(_ entry: EPUBArchiveEntryInfo) {
        if imageType(for: entry) != nil {
            loadingImage = entry
        } else {
            loadingImage = nil
            previewEntry = entry
        }
    }

    private func loadImagePreview() async {
        guard let entry = loadingImage, let type = imageType(for: entry) else { return }
        defer {
            if !Task.isCancelled { loadingImage = nil }
        }
        do {
            let file = try await EPUBArchivePreviewFile.load(sourceURL: sourceURL, entry: entry, type: type)
            try Task.checkCancellation()
            guard QLPreviewController.canPreview(file.url as NSURL) else {
                imagePreviewError = "当前系统不支持预览这个图片格式。"
                return
            }
            imagePreviewFile = file
            imagePreviewURL = file.url
        } catch {
            if !Task.isCancelled { imagePreviewError = error.localizedDescription }
        }
    }

    private func folderRow(_ path: String) -> some View {
        let name = EPUBToolboxPath.filename(of: path)
        let count = (listing.foldersByParent[path]?.count ?? 0) + (listing.filesByFolder[path]?.count ?? 0)
        return NavigationLink {
            EPUBArchiveFolderView(sourceURL: sourceURL, title: name, folder: path, listing: listing, sortOrder: $sortOrder)
        } label: {
            HStack(spacing: 12) {
                rowIcon("folder.fill", tint: .blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name)
                        .foregroundStyle(.primary)
                    Text(isSearching ? path : "\(count) 项")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 5)
        }
        .accessibilityIdentifier("epub-archive-folder-\(path)")
    }

    private func fileRow(_ entry: EPUBArchiveEntryInfo, opensPreview: Bool) -> some View {
        let isImage = imageType(for: entry) != nil
        return HStack(spacing: 12) {
            rowIcon(isImage ? "photo" : (entry.isTextPreviewable ? "doc.text" : "doc"), tint: isImage ? .purple : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if isSearching {
                    Text(verbatim: entry.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: entry.uncompressedBytes, countStyle: .file))
                    if !entry.isReferenced {
                        Text("未引用")
                            .foregroundStyle(NoveliaStyle.warning)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if loadingImage?.id == entry.id {
                ProgressView()
                    .accessibilityLabel("正在读取图片")
            } else if opensPreview {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func rowIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 23))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }
}

private struct EPUBArchiveStatisticsSheet: View {
    let entries: [EPUBArchiveEntryInfo]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let groups = Dictionary(grouping: entries, by: \.category).map { category, files in
            (category: category, count: files.count, bytes: files.reduce(Int64(0)) { $0 + $1.uncompressedBytes })
        }.sorted { $0.bytes > $1.bytes }
        let total = groups.reduce(Int64(0)) { $0 + $1.bytes }
        CompatNavigationStack {
            List {
                ForEach(groups, id: \.category) { group in
                    let ratio = total == 0 ? 0 : Double(group.bytes) / Double(total)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(group.category)（\(group.count)）")
                            Spacer()
                            Text("\(ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file)) · \(Int(ratio * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        ProgressView(value: ratio)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("文件统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private func imageType(for entry: EPUBArchiveEntryInfo) -> UTType? {
    // SVG 继续以源码查看，避免把 EPUB 自带的标记作为可执行页面呈现。
    guard !entry.isTextPreviewable,
          let type = UTType(filenameExtension: EPUBToolboxPath.pathExtension(of: entry.path)),
          type.conforms(to: .image) else { return nil }
    return type
}

private struct EPUBArchiveTextPreviewSheet: View {
    let sourceURL: URL
    let entry: EPUBArchiveEntryInfo

    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var errorMessage: String?

    var body: some View {
        CompatNavigationStack {
            Group {
                if let text {
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: text)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .textSelection(.enabled)
                    }
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Label("无法预览", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    ProgressView("正在读取文件…")
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            let preview = try await EPUBArchiveBrowser.readTextPreview(url: sourceURL, entryPath: entry.archivePath)
            try Task.checkCancellation()
            text = preview
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

/// Quick Look 只获得独立临时目录中的单张图片。浏览页面在 Quick Look 打开期间持有临时文件，关闭预览后释放。
private final class EPUBArchivePreviewFile: Sendable {
    let url: URL
    private let directory: URL

    private init(directory: URL, url: URL) {
        self.directory = directory
        self.url = url
    }

    static func load(sourceURL: URL, entry: EPUBArchiveEntryInfo, type: UTType) async throws -> EPUBArchivePreviewFile {
        let data = try await EPUBArchiveBrowser.readPreviewData(url: sourceURL, entryPath: entry.archivePath)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let original = entry.name as NSString
        let basename = EPUBToolboxPath.sanitizedFilename(original.deletingPathExtension, fallback: "image")
        let url = directory.appendingPathComponent(basename)
            .appendingPathExtension(type.preferredFilenameExtension ?? original.pathExtension)
        let file = EPUBArchivePreviewFile(directory: directory, url: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try data.write(to: url, options: .atomic)
        return file
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
