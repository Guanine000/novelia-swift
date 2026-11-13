import SwiftUI

/// 只通过已注入的正文服务取章；缓存按账号隔离，离开页面取消尚未处理的批次。
struct OfflineChapterManagementView: View {
    var novel: Novel? = nil
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var auth: AccountAuthStore
    @State private var entries: [OnlineChapterOfflineStore.Entry] = []
    @State private var first = "1"
    @State private var last = "20"
    @State private var message: String?
    @State private var completed = 0
    @State private var total = 0
    @State private var job: Task<Void, Never>?
    @State private var running = false
    @State private var confirmingClearAll = false
    @State private var clearingAll = false
    @State private var confirmingDelete: String?
    private var account: String { auth.offlineAccountScope }
    private var groups: [String: [OnlineChapterOfflineStore.Entry]] { Dictionary(grouping: entries, by: \.bookID) }
    private var range: ClosedRange<Int>? {
        guard let novel, let a = Int(first), let b = Int(last), a >= 1, b >= a, b <= novel.chapters.count, b - a < 200 else { return nil }
        return (a - 1)...(b - 1)
    }
    var body: some View {
        List {
            if let novel {
                Section("缓存章节（共\(novel.chapters.count)章）") {
                    HStack { Text("从"); TextField("起章", text: $first).keyboardType(.numberPad); Text("到"); TextField("末章", text: $last).keyboardType(.numberPad) }
                    Button("下载所选章节") { download() }.disabled(range == nil || running)
                    Text("每批最多200章。已缓存章节直接复用；清理后可重新下载最新正文。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if running {
                Section { ProgressView(value: Double(completed), total: Double(max(1, total))); Button("取消剩余下载") { job?.cancel() } }
            }
            if let message { Text(message).font(.footnote) }
            ForEach(groups.keys.sorted(), id: \.self) { id in
                let chapters = groups[id] ?? []
                Section(chapters.first?.bookTitle ?? "缓存书籍") {
                    Text("\(chapters.count) 章 · \(ByteCountFormatter.string(fromByteCount: Int64(chapters.reduce(0) { $0 + $1.bytes }), countStyle: .file))")
                    if novel != nil {
                        ForEach(chapters) { Text($0.chapter.title).font(.subheadline) }
                    }
                    Button("清理本书缓存", role: .destructive) { confirmingDelete = id }
                }
            }
            if entries.isEmpty { Text("当前账号还没有离线章节。可在网络小说详情或阅读菜单中缓存章节。") }
        }
        .navigationTitle("离线章节")
        .toolbar {
            if novel == nil {
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("清除所有", role: .destructive) { confirmingClearAll = true }
                        .disabled(entries.isEmpty || clearingAll || running)
                }
            }
        }
        .alert("清除所有离线章节？", isPresented: $confirmingClearAll) {
            Button("取消", role: .cancel) {}
            Button("清除所有", role: .destructive) { clearAll() }
        } message: {
            Text("将清除当前账号所有书籍的离线章节缓存。已下载的 EPUB、阅读进度和书签会保留，之后可以重新缓存章节。")
        }
        .task(id: account) { job?.cancel(); await reload() }
        .onDisappear { job?.cancel() }
        .confirmationDialog("清理本书离线章节？进度、书签和已下载文件会保留。", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
            Button("清理缓存", role: .destructive) {
                let id = confirmingDelete; confirmingDelete = nil
                Task { do { try await settings.offlineChapters.remove(account: account, bookID: id); await reload() } catch { message = error.localizedDescription } }
            }
        }
    }
    private func clearAll() {
        guard !clearingAll else { return }
        let owner = account
        clearingAll = true
        Task {
            defer { clearingAll = false }
            do {
                try await settings.offlineChapters.remove(account: owner)
                guard owner == account else { return }
                await reload()
                message = "已清除当前账号的所有离线章节。"
            } catch {
                guard owner == account else { return }
                await reload()
                message = error.localizedDescription
            }
        }
    }

    private func reload() async {
        do { entries = try await settings.offlineChapters.entries(account: account).filter { novel == nil || $0.bookID == novel?.id } }
        catch { message = error.localizedDescription }
    }
    private func download() {
        guard let novel, let range else { return }
        let owner = account
        running = true; completed = 0; total = range.count; message = nil
        job = Task {
            defer { running = false; job = nil }
            var failed = 0
            for index in range {
                if Task.isCancelled || account != owner { break }
                do { _ = try await settings.offlineChapters.chapter(novel.chapters[index], book: novel, account: owner, service: services.api.content) }
                catch is CancellationError { break }
                catch { failed += 1; message = error.localizedDescription }
                completed += 1
            }
            await reload()
            message = "已处理\(completed)/\(total)章，失败\(failed)章。" + (message.map { " \($0)" } ?? "")
        }
    }
}

extension AccountAuthStore {
    var offlineAccountScope: String { username.map { "account:" + $0 } ?? "anonymous" }
}
