// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
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

/// 按分类与体积展示 EPUB 内部全部文件，标出未引用条目，支持点击查看文本/OPF/CSS/XHTML 源码预览。
struct EPUBArchiveBrowserView: View {
    let sourceURL: URL
    let bookTitle: String

    @State private var isLoading = true
    @State private var entries: [EPUBArchiveEntryInfo] = []
    @State private var sortBySize = true
    @State private var query = ""
    @State private var previewEntry: EPUBArchiveEntryInfo?
    @State private var errorMessage: String?

    private var totalUncompressed: Int64 {
        max(entries.reduce(0) { $0 + $1.uncompressedBytes }, 1)
    }

    private var filteredEntries: [EPUBArchiveEntryInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty
            ? entries
            : entries.filter {
                $0.path.localizedCaseInsensitiveContains(trimmed)
                    || $0.category.localizedCaseInsensitiveContains(trimmed)
            }
        if sortBySize {
            return base.sorted { $0.uncompressedBytes > $1.uncompressedBytes }
        }
        return base.sorted { $0.path < $1.path }
    }

    private var categorySummary: [(category: String, count: Int, bytes: Int64)] {
        let grouped = Dictionary(grouping: entries, by: \.category)
        return grouped.map { key, list in
            (key, list.count, list.reduce(0) { $0 + $1.uncompressedBytes })
        }.sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在扫描压缩包内部文件…")
                        .foregroundStyle(NoveliaStyle.muted)
                }
            } else {
                Section("分类体积占比") {
                    ForEach(categorySummary, id: \.category) { item in
                        let ratio = Double(item.bytes) / Double(totalUncompressed)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(item.category)（\(item.count)）")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)) · \(Int(ratio * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                            ProgressView(value: ratio)
                                .tint(NoveliaStyle.brandGreen)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("全部条目（\(filteredEntries.count)）") {
                    ForEach(filteredEntries) { entry in
                        Button {
                            if entry.isTextPreviewable {
                                previewEntry = entry
                            }
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.path)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(NoveliaStyle.ink)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(entry.category)
                                            .font(.caption2)
                                            .foregroundStyle(NoveliaStyle.muted)
                                        if !entry.isReferenced {
                                            Text("未引用")
                                                .font(.caption2)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(NoveliaStyle.warning.opacity(0.18), in: Capsule())
                                                .foregroundStyle(NoveliaStyle.warning)
                                        }
                                        if !entry.isCompressed {
                                            Text("无压缩")
                                                .font(.caption2)
                                                .foregroundStyle(NoveliaStyle.muted)
                                        }
                                    }
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: entry.uncompressedBytes, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.muted)
                                if entry.isTextPreviewable {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                            }
                        }
                        .disabled(!entry.isTextPreviewable)
                    }
                }
            }
        }
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .searchable(text: $query, prompt: "筛选路径或分类")
        .navigationTitle("内部文件浏览器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatTopBarTrailing) {
                Button(sortBySize ? "按路径排" : "按体积排") {
                    sortBySize.toggle()
                }
            }
        }
        .sheet(item: $previewEntry) { entry in
            EPUBArchiveTextPreviewSheet(sourceURL: sourceURL, entry: entry)
        }
        .task { await loadEntries() }
        .alert("读取失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadEntries() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await Task.detached(priority: .userInitiated) {
                try await EPUBArchiveBrowser.listEntries(url: sourceURL)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EPUBArchiveTextPreviewSheet: View {
    let sourceURL: URL
    let entry: EPUBArchiveEntryInfo

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isLoading = true

    var body: some View {
        CompatNavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在读取源码…")
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(NoveliaStyle.ink)
                            .padding()
                            .textSelection(.enabled)
                    }
                }
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle(EPUBToolboxPath.filename(of: entry.path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                isLoading = true
                defer { isLoading = false }
                text = (try? await Task.detached(priority: .userInitiated) {
                    try await EPUBArchiveBrowser.readTextPreview(url: sourceURL, entryPath: entry.path)
                }.value) ?? "无法读取该条目。"
            }
        }
    }
}
