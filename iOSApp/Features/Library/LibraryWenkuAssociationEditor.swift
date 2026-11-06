import SwiftUI

/// 从注入的文库目录选择真实作品和分卷，只更新本地书库索引。
struct LibraryWenkuAssociationEditor: View {
    let book: LibraryBook
    let record: LocalWenkuEPUB
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var library: WenkuLocalLibraryStore
    @EnvironmentObject private var state: LibraryStateStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var submitted = ""
    @State private var results: [WenkuNovelOutline] = []
    @State private var page = 0
    @State private var pageCount = 1
    @State private var detail: WenkuNovelDetail?
    @State private var selectedVolume: String?
    @State private var groupWithWork = true
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmsUnlink = false

    private var volumes: [String] {
        guard let detail else { return [] }
        return Array(Set(detail.volumeJp.map(\.volumeId) + detail.volumeZh)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var current: LocalWenkuEPUB { library.books.first { $0.id == record.id } ?? record }
    var body: some View {
        CompatNavigationStack {
            Form {
                Section("当前关联") {
                    Text(book.title)
                    if let parent = current.parentWenkuID {
                        Text(current.parentWenkuTitle ?? parent)
                        Text(current.volumeID ?? "未指定分卷").foregroundStyle(.secondary)
                        Button("解除关联", role: .destructive) { confirmsUnlink = true }.disabled(isSaving)
                    } else { Text("尚未关联文库作品和分卷").foregroundStyle(.secondary) }
                    Text("关联后可从作品详情打开本地卷；不会修改书籍文件或阅读位置，也不会自动检查更新或提醒新卷。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("搜索文库作品") {
                    TextField("作品名", text: $query).focused($queryFocused).submitLabel(.search).onSubmit { search(page: 0) }
                    Button("搜索作品") { search(page: 0) }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    if isLoading { ProgressView("正在查询…") }
                    if let error { Text(error).foregroundStyle(.red) }
                    ForEach(results) { item in
                        Button { load(item) } label: {
                            VStack(alignment: .leading) {
                                Text(item.displayTitle)
                                Text(item.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(isSaving)
                    }
                    if !submitted.isEmpty && !isLoading && results.isEmpty { Text("没有找到作品，请调整关键词后重试。") }
                    if pageCount > 1 {
                        HStack {
                            Button("上一页") { search(page: page - 1, query: submitted) }.disabled(page == 0 || isLoading)
                            Spacer(); Text("\(page + 1) / \(pageCount)"); Spacer()
                            Button("下一页") { search(page: page + 1, query: submitted) }.disabled(page + 1 >= pageCount || isLoading)
                        }.disabled(isSaving)
                    }
                }
                if let detail {
                    Section("选择《\(detail.displayTitle)》的分卷") {
                        if volumes.isEmpty { Text("此作品暂无可关联的分卷。") }
                        ForEach(volumes, id: \.self) { volume in
                            Button { selectedVolume = volume } label: {
                                HStack { Text(volume); Spacer(); if selectedVolume == volume { Image(systemName: "checkmark") } }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(isSaving)
                                .accessibilityValue(selectedVolume == volume ? "已选择" : "未选择")
                        }
                    }
                    if let selectedVolume {
                        Section("确认关联") {
                            Text(detail.displayTitle)
                            Text(selectedVolume)
                            Toggle("同时归入作品系列", isOn: $groupWithWork)
                            Text(groupWithWork ? "会将这本书移入对应作品系列。" : "保留当前系列归属，仅保存作品与分卷关联。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.disabled(isSaving)
                    }
                }
            }
            .navigationTitle("关联文库作品／分卷").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("关闭") { task?.cancel(); dismiss() }.disabled(isSaving)
                    Spacer()
                    Button(isSaving ? "正在保存…" : "保存关联") { save() }
                        .buttonStyle(.borderedProminent).disabled(detail == nil || selectedVolume == nil || isLoading || isSaving)
                }.padding().background(.regularMaterial)
            }
            .onAppear {
                query = current.parentWenkuTitle ?? book.title
                let existing = state.series.seriesID(forBook: book.key)
                groupWithWork = existing == nil || existing == current.parentWenkuID.map { "wenku-work:" + $0 }
            }
            .onDisappear { task?.cancel() }
            .confirmationDialog("解除作品与分卷关联？", isPresented: $confirmsUnlink, titleVisibility: .visible) {
                Button("确认解除关联", role: .destructive) { unlink() }
                Button("取消", role: .cancel) {}
            } message: { Text("保留本地文件和阅读进度；若仍在对应作品系列中，会将这本书移出该系列。") }
        }
    }
    private func search(page target: Int, query requested: String? = nil) {
        let value = (requested ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSaving else { return }
        queryFocused = false
        task?.cancel(); isLoading = true; error = nil; detail = nil; selectedVolume = nil
        submitted = value; page = max(0, target); results = []
        task = Task {
            do {
                let result = try await services.api.wenku.searchWenku(query: value, page: max(0, target), pageSize: 20, level: 0)
                guard !Task.isCancelled else { return }
                results = result.novels; pageCount = max(1, result.pageCount); isLoading = false
            } catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; isLoading = false }
        }
    }
    private func load(_ item: WenkuNovelOutline) {
        task?.cancel(); isLoading = true; error = nil; detail = nil; selectedVolume = nil
        task = Task {
            do {
                let value = try await services.api.wenku.wenkuNovel(id: item.id)
                guard !Task.isCancelled else { return }
                detail = value; isLoading = false
            } catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; isLoading = false }
        }
    }
    private func save() {
        guard let detail, let volume = selectedVolume, volumes.contains(volume), !isSaving else { return }
        isSaving = true; error = nil
        let previousSeries = state.series.seriesID(forBook: book.key)
        task = Task {
            do {
                try await library.updateWenkuAssociation(id: record.id, parentID: detail.id, parentTitle: detail.displayTitle, volumeID: volume)
                if groupWithWork { state.assignToWenkuSeries(book, parentID: detail.id, title: detail.displayTitle) }
                else {
                    // 显式保留未分组时也写入成员记录，避免自动归组任务重新移入。
                    state.assign(book, to: previousSeries)
                }
                isSaving = false; dismiss()
            } catch { self.error = error.localizedDescription; isSaving = false }
        }
    }
    private func unlink() {
        guard !isSaving else { return }
        task?.cancel(); isLoading = false; isSaving = true; error = nil
        let parent = current.parentWenkuID
        task = Task {
            do {
                try await library.updateWenkuAssociation(id: record.id, parentID: nil, parentTitle: nil, volumeID: nil)
                if let parent, state.series.seriesID(forBook: book.key) == "wenku-work:" + parent { state.assign(book, to: nil) }
                isSaving = false; dismiss()
            } catch { self.error = error.localizedDescription; isSaving = false }
        }
    }
}
