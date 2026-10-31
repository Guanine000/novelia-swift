import SwiftUI

/// 两种分页引擎共用的“书签／搜索”面板。引擎只提供章节数、章节标题、章节纯文本与跳转，
/// 书签列表来自同一个 `ReaderBookmarkStore`，搜索由 `BookTextSearch` 在本机逐章完成。
struct ReaderBookmarksSearchSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case bookmarks = "书签"
        case search = "搜索"
        var id: String { rawValue }
    }

    @ObservedObject var store: ReaderBookmarkStore
    let bookKey: String
    let chapterCount: Int
    let chapterTitle: (Int) -> String?
    let chapterText: (Int) async throws -> String
    let onJump: (Int, Double) -> Void
    var legacyBookKey: String? = nil
    var chapterIDAtIndex: (Int) -> String? = { _ in nil }
    var resolveChapter: ((ReaderBookmark) -> Int?)? = nil
    @State var tab: Tab = .bookmarks
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var query = ""
    @State private var hits: [BookTextSearch.Hit] = []
    @State private var searchedQuery: String?
    @State private var searchedChapters = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("内容", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                switch tab {
                case .bookmarks: bookmarkList
                case .search: searchPane
                }
            }
            .navigationTitle(tab.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear { searchTask?.cancel() }
        .alert("书签保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    // MARK: 书签

    private var bookmarkList: some View {
        let legacy = legacyBookKey.map { store.bookmarks(for: $0).filter { chapterIDAtIndex($0.chapterIndex) == nil } } ?? []
        let bookmarks = (store.bookmarks(for: bookKey) + legacy).sorted {
            let lhs = resolveChapter?($0) ?? ($0.chapterID == nil ? $0.chapterIndex : Int.max)
            let rhs = resolveChapter?($1) ?? ($1.chapterID == nil ? $1.chapterIndex : Int.max)
            return (lhs, $0.chapterProgression) < (rhs, $1.chapterProgression)
        }
        return List {
            if bookmarks.isEmpty {
                ContentUnavailableView("还没有书签", systemImage: "bookmark",
                                       description: Text("阅读时点右上角的书签按钮，可为当前页添加书签。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(bookmarks) { bookmark in
                Button {
                    if let index = resolveChapter?(bookmark) ?? (bookmark.chapterID == nil ? bookmark.chapterIndex : nil) {
                        jump(index, bookmark.chapterProgression)
                    } else { saveError = "本机尚未包含或核对这个章节，请在章节同步与更新中核对或更新 EPUB。" }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bookmark.chapterTitle ?? chapterTitle(bookmark.chapterIndex) ?? "第 \(bookmark.chapterIndex + 1) 章")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if bookmark.chapterID != nil, resolveChapter?(bookmark) == nil {
                            Text("本机章节未下载或未核对").font(.caption).foregroundStyle(.orange)
                        }
                        if !bookmark.snippet.isEmpty {
                            Text(bookmark.snippet)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        do { try store.remove(bookmark.id) } catch { saveError = "未能保存删除操作，请重试。" }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: 搜索

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索本书内容", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(startSearch)
                if searchTask != nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            List {
                if let searchedQuery {
                    Section {
                        ForEach(hits) { hit in
                            Button { jump(hit.chapterIndex, hit.progression) } label: { hitRow(hit) }
                        }
                    } header: {
                        Text(summary(for: searchedQuery))
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if searchedQuery != nil, hits.isEmpty, searchTask == nil {
                    ContentUnavailableView.search(text: searchedQuery ?? "")
                }
            }
        }
    }

    private func summary(for text: String) -> String {
        if searchTask != nil { return "正在搜索“\(text)”… \(searchedChapters)/\(chapterCount) 章" }
        let limited = hits.count >= BookTextSearch.maxHits ? "（只显示前 \(BookTextSearch.maxHits) 条）" : ""
        return "找到 \(hits.count) 处\(limited)"
    }

    private func hitRow(_ hit: BookTextSearch.Hit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chapterTitle(hit.chapterIndex) ?? "第 \(hit.chapterIndex + 1) 章")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            (Text(hit.before) + Text(hit.match).bold().foregroundColor(.accentColor) + Text(hit.after))
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
    }

    private func startSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        hits = []
        searchedQuery = text
        searchedChapters = 0
        searchTask = Task {
            let found = await BookTextSearch.search(query: text, chapterCount: chapterCount,
                                                    chapterText: chapterText) { done in searchedChapters = done }
            guard !Task.isCancelled else { return }
            hits = found
            searchTask = nil
        }
    }

    private func jump(_ chapter: Int, _ progression: Double) {
        onJump(chapter, progression)
        dismiss()
    }
}

/// 阅读器顶栏的书签按钮：当前页已有书签时显示实心并可移除，否则添加。
struct ReaderBookmarkButton: View {
    @ObservedObject var store: ReaderBookmarkStore
    let bookKey: String
    let pageRange: (chapter: Int, range: Range<Double>)?
    let chapterTitle: String?
    /// 书签摘要：Yuedu 直接取页内文本，Readium 需读取章节正文，因此为异步。
    let snippet: () async -> String
    var chapterID: String? = nil
    @State private var saveError: String?

    var body: some View {
        let existing = pageRange.map { page in store.bookmarks(for: bookKey).filter { bookmark in
            (chapterID.map { bookmark.chapterID == $0 } ?? (bookmark.chapterIndex == page.chapter))
                && (page.range.contains(bookmark.chapterProgression) || bookmark.chapterProgression == page.range.lowerBound)
        } } ?? []
        Button {
            if !existing.isEmpty {
                do { try store.remove(existing.map(\.id)) }
                catch { saveError = "未能保存删除操作，请重试。" }
            } else if let pageRange {
                // 先记下位置再取摘要，期间翻页不影响书签位置。
                let title = chapterTitle
                Task {
                    let text = await snippet()
                    do { try store.add(bookKey: bookKey, chapterIndex: pageRange.chapter, progression: pageRange.range.lowerBound,
                              chapterTitle: title, snippet: text, chapterID: chapterID) }
                    catch { saveError = "书签未能保存，请重试。" }
                }
            }
        } label: {
            Image(systemName: existing.isEmpty ? "bookmark" : "bookmark.fill")
                .frame(width: 36, height: 36)
        }
        .disabled(pageRange == nil)
        .accessibilityLabel(existing.isEmpty ? "添加书签" : "移除书签")
        .alert("书签保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}

/// 「阅读样式」面板末尾的「标记问题」：遇到跳页等异常时点一下，在诊断日志中写入标记与当前位置，
/// 之后从“我的 → 导出应用日志”分享时即可定位问题发生的时刻。日志不含书名或正文。
/// 面板打开期间阅读位置不变，记录的仍是打开面板前所在的页。
struct ReaderIssueMarkSection: View {
    let mark: () -> Void
    @State private var isShowingConfirmation = false

    var body: some View {
        Section {
            Button("标记问题", systemImage: "exclamationmark.bubble") {
                mark()
                isShowingConfirmation = true
            }
        } footer: {
            Text("遇到跳页、漏字等问题时点一下，会在诊断日志中记录此刻的阅读位置；之后可在“我的 → 导出应用日志”中分享。")
        }
        .alert("已标记", isPresented: $isShowingConfirmation) {
            Button("好", role: .cancel) {}
        } message: {
            Text("已在诊断日志中记录此刻的阅读位置。可在“我的 → 导出应用日志”中分享日志，并说明遇到的问题。")
        }
    }
}
