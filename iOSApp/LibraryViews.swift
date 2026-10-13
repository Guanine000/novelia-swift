import SwiftUI
import UniformTypeIdentifiers

// MARK: - 书库（底部导航第一项）

/// 书库：导入和下载的书、系列、统一搜索与排序；点击整行打开阅读。
struct LibraryView: View {
    private enum Segment: String, CaseIterable, Identifiable {
        case books, series
        var id: String { rawValue }
    }

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var webDAVSync: WebDAVSyncStore
    @ObservedObject private var state = LibraryStateStore.shared
    @StateObject private var importer = LibraryImportModel()
    @State private var segment = Segment.books
    @State private var query = ""
    @State private var isSearching = false
    @State private var readerTarget: LibraryBook?
    @State private var isCreatingSeries = false
    @State private var newSeriesName = ""
    @State private var syncTask: Task<Void, Never>?
    @State private var hasTriggeredSync = false
    @State private var isShowingSyncProgress = false

    private var allBooks: [LibraryBook] { state.books(web: webDownloads, wenku: wenkuDownloads) }
    private var sortOptions: LibrarySortOptions { state.sortOptions(scope: nil) }

    var body: some View {
        let books = allBooks
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if books.isEmpty {
                    emptyLibrary
                } else if isSearching && !LibraryOrganizer.normalized(query).isEmpty {
                    searchResults(books)
                } else {
                    if let recent = recentBook(in: books) {
                        LibraryContinueReadingCard(book: recent) { open(recent) }
                    }
                    // 已移入系列的书只在“系列”中显示，不在“全部书籍”中重复出现。
                    let ungrouped = books.filter { state.series.seriesID(forBook: $0.key) == nil }
                    Picker("书库内容", selection: $segment) {
                        Text("全部书籍 \(ungrouped.count)").tag(Segment.books)
                        Text("系列 \(state.series.activeSeries.count)").tag(Segment.series)
                    }
                    .pickerStyle(.segmented)
                    switch segment {
                    case .books:
                        if ungrouped.isEmpty {
                            ContentUnavailableView {
                                Label("书籍都已在系列中", systemImage: "rectangle.stack")
                            } description: {
                                Text("在“系列”中查看，或从系列移出后回到这里。")
                            }
                            .padding(.top, 20)
                        } else {
                            LibrarySortSummary(options: sortOptions) { state.setSortOptions($0, scope: nil) }
                            LibraryBookList(books: sorted(ungrouped, options: sortOptions), open: open)
                        }
                    case .series:
                        seriesList(books)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) { searchBar }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("书库")
        // 搜索时改为行内标题，避免大标题区域在搜索栏上方留下空白。
        .navigationBarTitleDisplayMode(isSearching ? .inline : .large)
        .toolbar { toolbarContent }
        .navigationDestination(item: $readerTarget) { book in
            LibraryReaderDestination(book: book)
        }
        .onChange(of: readerTarget) { _, target in
            if target == nil { state.reloadPositions() }
        }
        .onChange(of: webDAVSync.isSyncing) { _, syncing in
            if !syncing { state.reloadPositions() }
        }
        .onChange(of: webDAVSync.isEnabled) { _, isEnabled in
            if !isEnabled { syncTask?.cancel() }
        }
        .onAppear { state.reloadPositions() }
        .task { importer.attach(wenkuDownloads) }
        .task { await wenkuDownloads.refreshMissingMetadata() }
        .task(id: books.map(\.key)) { await state.refreshHashes(for: books) }
        .fullScreenCover(isPresented: $importer.isShowingFileImporter) {
            EPUBFilePicker(contentTypes: [
                UTType(filenameExtension: "txt") ?? .plainText,
                UTType(filenameExtension: "epub") ?? .data
            ], allowsMultipleSelection: true) { urls in
                Task { await importer.importFiles(urls) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingSyncProgress) {
            WebDAVSyncProgressPanel(onCancel: { syncTask?.cancel() }) {
                syncTask = Task { await webDAVSync.sync(web: webDownloads, wenku: wenkuDownloads) }
            }
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .alert("导入", isPresented: .init(
            get: { importer.importError != nil },
            set: { if !$0 { importer.importError = nil } }
        )) {
            Button("好", role: .cancel) { importer.importError = nil }
        } message: {
            Text(importer.importError ?? "")
        }
        .alert("新建系列", isPresented: $isCreatingSeries) {
            TextField("系列名称", text: $newSeriesName)
            Button("取消", role: .cancel) {}
            Button("创建") { state.createSeries(named: newSeriesName) }
        } message: {
            Text("创建后，可在书籍的“更多”菜单中移入系列。")
        }
        .overlay { LibraryImportProgressOverlay(model: importer) }
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearching {
            LibrarySearchField(query: $query, prompt: "搜索书名或作者") {
                isSearching = false
                query = ""
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(NoveliaStyle.paper)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if webDAVSync.isEnabled {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if hasTriggeredSync || webDAVSync.isSyncing {
                        isShowingSyncProgress = true
                    } else {
                        hasTriggeredSync = true
                        syncTask = Task { await webDAVSync.sync(web: webDownloads, wenku: wenkuDownloads) }
                    }
                } label: {
                    if webDAVSync.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .accessibilityLabel(webDAVSync.isSyncing ? "查看同步进度" : "WebDAV 同步")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation { isSearching.toggle() }
                if !isSearching { query = "" }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索书库")
            LibrarySortMenu(options: sortOptions) { state.setSortOptions($0, scope: nil) }
            Button {
                importer.isShowingFileImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("导入 TXT 或 EPUB")
            .disabled(importer.isImporting)
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("书库还没有书", systemImage: "books.vertical")
        } description: {
            Text("导入 TXT 或 EPUB 文件；在发现页下载的网络小说和文库 EPUB 也会显示在这里。")
        } actions: {
            Button {
                importer.isShowingFileImporter = true
            } label: {
                Label("导入 TXT / EPUB", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(NoveliaStyle.brandGreen)
        }
        .padding(.top, 60)
    }

    @ViewBuilder
    private func searchResults(_ books: [LibraryBook]) -> some View {
        let matches = books.filter { LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) }
        Text(matches.isEmpty ? "没有找到匹配的书" : "找到 \(matches.count) 本")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(NoveliaStyle.muted)
        if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            LibraryBookList(books: sorted(matches, options: sortOptions), open: open)
        }
    }

    @ViewBuilder
    private func seriesList(_ books: [LibraryBook]) -> some View {
        Button {
            newSeriesName = ""
            isCreatingSeries = true
        } label: {
            Label("新建系列", systemImage: "plus.rectangle.on.rectangle")
                .font(.system(size: 14, weight: .semibold))
        }
        .tint(NoveliaStyle.brandGreen)
        let allSeries = state.series.activeSeries
        if allSeries.isEmpty {
            ContentUnavailableView {
                Label("还没有系列", systemImage: "rectangle.stack")
            } description: {
                Text("新建系列后，在书籍的“更多”菜单中选择“移入系列”。导入和下载的书都可以加入。")
            }
            .padding(.top, 20)
        } else {
            ForEach(allSeries) { series in
                let keys = state.series.bookKeys(inSeries: series.id)
                let members = sorted(books.filter { keys.contains($0.key) }, options: state.sortOptions(scope: series.id))
                NavigationLink {
                    LibrarySeriesDetailView(seriesID: series.id)
                } label: {
                    LibrarySeriesRow(name: series.name, books: members)
                }
                .buttonStyle(.plain)
                .contextMenu { LibrarySeriesMenuItems(seriesID: series.id, name: series.name) }
            }
        }
    }

    private func recentBook(in books: [LibraryBook]) -> LibraryBook? {
        books.compactMap { book in state.status(for: book).lastReadAt.map { (book, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    private func sorted(_ books: [LibraryBook], options: LibrarySortOptions) -> [LibraryBook] {
        LibraryOrganizer.sorted(books, options: options) { state.sortItem(for: $0) }
    }

    private func open(_ book: LibraryBook) {
        state.markOpened(book)
        readerTarget = book
    }
}

// MARK: - 系列详情

struct LibrarySeriesDetailView: View {
    let seriesID: String

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state = LibraryStateStore.shared
    @State private var query = ""
    @State private var isSearching = false
    @State private var readerTarget: LibraryBook?
    @State private var isAddingBooks = false

    private var series: LibrarySeries? {
        state.series.series[seriesID].flatMap { $0.deleted ? nil : $0 }
    }

    var body: some View {
        let all = state.books(web: webDownloads, wenku: wenkuDownloads)
        let keys = state.series.bookKeys(inSeries: seriesID)
        let members = all.filter { keys.contains($0.key) }
        let options = state.sortOptions(scope: seriesID)
        let visible = LibraryOrganizer.sorted(
            members.filter { LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) },
            options: options
        ) { state.sortItem(for: $0) }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if members.isEmpty {
                    ContentUnavailableView {
                        Label("系列中还没有书", systemImage: "rectangle.stack")
                    } description: {
                        Text("把导入或下载的书移入这个系列。移出后书籍和阅读进度都会保留。")
                    } actions: {
                        Button("添加书籍") { isAddingBooks = true }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                    .padding(.top, 40)
                } else {
                    LibrarySortSummary(options: options, count: members.count) { state.setSortOptions($0, scope: seriesID) }
                    if visible.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        LibraryBookList(books: visible, showsSeries: false, open: open)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) { searchBar }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle(series?.name ?? "系列")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation { isSearching.toggle() }
                    if !isSearching { query = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("在系列中搜索")
                LibrarySortMenu(options: options) { state.setSortOptions($0, scope: seriesID) }
                Menu {
                    Button { isAddingBooks = true } label: { Label("添加书籍", systemImage: "plus") }
                    LibrarySeriesMenuItems(seriesID: seriesID, name: series?.name ?? "")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("系列操作")
            }
        }
        .navigationDestination(item: $readerTarget) { book in
            LibraryReaderDestination(book: book)
        }
        .onChange(of: readerTarget) { _, target in
            if target == nil { state.reloadPositions() }
        }
        .onChange(of: series == nil) { _, removed in
            if removed { dismiss() }
        }
        .sheet(isPresented: $isAddingBooks) {
            LibraryAddToSeriesSheet(seriesID: seriesID, books: all)
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearching {
            LibrarySearchField(query: $query, prompt: "在系列中搜索书名或作者") {
                isSearching = false
                query = ""
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(NoveliaStyle.paper)
        }
    }

    private func open(_ book: LibraryBook) {
        state.markOpened(book)
        readerTarget = book
    }
}

/// 从全部书籍中多选加入系列；已在其他系列的书会改为属于本系列。
private struct LibraryAddToSeriesSheet: View {
    let seriesID: String
    let books: [LibraryBook]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state = LibraryStateStore.shared
    @State private var selection = Set<String>()
    @State private var query = ""

    var body: some View {
        let candidates = LibraryOrganizer.sorted(
            books.filter { state.series.seriesID(forBook: $0.key) != seriesID
                && LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) },
            options: LibrarySortOptions(field: .title, ascending: true)
        ) { state.sortItem(for: $0) }
        NavigationStack {
            List(candidates) { book in
                Button {
                    if selection.contains(book.key) { selection.remove(book.key) } else { selection.insert(book.key) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selection.contains(book.key) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(book.key) ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                        LibraryCoverView(book: book, width: 34, height: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                            Text([book.author, state.seriesName(for: book).map { "当前系列：\($0)" }]
                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(NoveliaStyle.muted)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "没有可添加的书" : "没有找到匹配的书", systemImage: "books.vertical")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名或作者")
            .navigationTitle("添加书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加 \(selection.count)") {
                        for book in books where selection.contains(book.key) {
                            state.assign(book, to: seriesID)
                        }
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }
}

/// 系列的重命名与解散；用于系列行的长按菜单和系列详情的“更多”菜单。
private struct LibrarySeriesMenuItems: View {
    let seriesID: String
    let name: String
    @ObservedObject private var state = LibraryStateStore.shared
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @State private var newName = ""

    var body: some View {
        Button {
            newName = name
            isRenaming = true
        } label: {
            Label("重命名系列", systemImage: "pencil")
        }
        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label("解散系列", systemImage: "rectangle.stack.badge.minus")
        }
        .alert("重命名系列", isPresented: $isRenaming) {
            TextField("系列名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") { state.renameSeries(seriesID, to: newName) }
        }
        .confirmationDialog("解散系列“\(name)”？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("解散系列", role: .destructive) { state.deleteSeries(seriesID) }
        } message: {
            Text("系列中的书会移出系列，书籍文件和阅读进度都会保留。")
        }
    }
}

// MARK: - 书籍列表与操作

/// 书籍列表：点击整行打开阅读；“更多”按钮与长按菜单提供系列、导出、移动和删除。
struct LibraryBookList: View {
    let books: [LibraryBook]
    /// 系列详情中不重复显示系列名。
    var showsSeries = true
    let open: (LibraryBook) -> Void

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @ObservedObject private var state = LibraryStateStore.shared
    @State private var pendingDelete: LibraryBook?
    @State private var newSeriesBook: LibraryBook?
    @State private var newSeriesName = ""
    @State private var actionError: String?

    var body: some View {
        ForEach(books) { book in
            HStack(alignment: .center, spacing: 4) {
                Button { open(book) } label: {
                    LibraryBookRowContent(book: book, status: state.status(for: book), seriesName: showsSeries ? state.seriesName(for: book) : nil)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开阅读")
                Menu {
                    actions(for: book)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作：\(book.title)")
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)
            .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .contextMenu { actions(for: book) }
        }
        .confirmationDialog(
            "删除《\(pendingDelete?.title ?? "")》？",
            isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { book in
            Button("删除", role: .destructive) { delete(book) }
        } message: { _ in
            Text("将从本机删除书籍文件。WebDAV 中的副本不会删除，之后同步时可能恢复。")
        }
        .alert("新建系列", isPresented: .init(get: { newSeriesBook != nil }, set: { if !$0 { newSeriesBook = nil } })) {
            TextField("系列名称", text: $newSeriesName)
            Button("取消", role: .cancel) { newSeriesBook = nil }
            Button("创建并移入") {
                if let book = newSeriesBook {
                    let id = state.createSeries(named: newSeriesName.isEmpty ? book.title : newSeriesName)
                    state.assign(book, to: id)
                }
                newSeriesBook = nil
            }
        }
        .alert("操作失败", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private func actions(for book: LibraryBook) -> some View {
        let currentSeries = state.series.seriesID(forBook: book.key)
        Button { open(book) } label: { Label("阅读", systemImage: "book") }
        Menu {
            ForEach(state.series.activeSeries.filter { $0.id != currentSeries }) { series in
                Button(series.name) { state.assign(book, to: series.id) }
            }
            Divider()
            Button {
                newSeriesName = ""
                newSeriesBook = book
            } label: {
                Label("新建系列…", systemImage: "plus")
            }
        } label: {
            Label(currentSeries == nil ? "移入系列" : "移到其他系列", systemImage: "rectangle.stack.badge.plus")
        }
        if currentSeries != nil {
            Button { state.assign(book, to: nil) } label: {
                Label("移出系列", systemImage: "rectangle.stack.badge.minus")
            }
        }
        ShareLink(item: book.fileURL) {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        switch book.origin {
        case .webNovel(let record):
            Button {
                Task {
                    do { try await LibraryMover.moveToWenku(record, web: webDownloads, wenku: wenkuDownloads, state: state) }
                    catch { actionError = error.localizedDescription }
                }
            } label: {
                Label("移至文库", systemImage: "arrow.right.arrow.left")
            }
        case .wenku(let record):
            Button {
                do { try LibraryMover.moveToNetwork(record, web: webDownloads, wenku: wenkuDownloads, state: state) }
                catch { actionError = error.localizedDescription }
            } label: {
                Label("移至网络小说", systemImage: "arrow.right.arrow.left")
            }
        }
        Divider()
        Button(role: .destructive) { pendingDelete = book } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func delete(_ book: LibraryBook) {
        switch book.origin {
        case .webNovel(let record): webDownloads.remove(record)
        case .wenku(let record): wenkuDownloads.remove(record)
        }
    }
}

private struct LibraryBookRowContent: View {
    let book: LibraryBook
    let status: LibraryReadingStatus
    let seriesName: String?

    var body: some View {
        HStack(spacing: 12) {
            LibraryCoverView(book: book, width: 50, height: 70)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.system(size: 12))
                    .foregroundStyle(NoveliaStyle.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(book.format.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.brandGreen)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(NoveliaStyle.brandGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    Text(([book.categoryTitle] + (seriesName.map { ["系列：\($0)"] } ?? [])).joined(separator: " · "))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status.detail)
                        .foregroundStyle(status.isUnread ? NoveliaStyle.muted : NoveliaStyle.brandGreen)
                }
                .font(.system(size: 11))
                .foregroundStyle(NoveliaStyle.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 封面；缺少封面时所有书使用同一种占位样式。
struct LibraryCoverView: View {
    let book: LibraryBook
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        Group {
            if let url = book.coverURL {
                CoverImage(url: url) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            // 先铺不透明底色，系列封面叠放时不会透出后面的封面。
            RoundedRectangle(cornerRadius: 7).fill(NoveliaStyle.card)
            RoundedRectangle(cornerRadius: 7).fill(NoveliaStyle.brandGreen.opacity(0.12))
            VStack(spacing: 3) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: width * 0.34))
                Text(book.format.title)
                    .font(.system(size: max(8, width * 0.17), weight: .semibold))
            }
            .foregroundStyle(NoveliaStyle.brandGreen)
        }
    }
}

private struct LibraryContinueReadingCard: View {
    let book: LibraryBook
    let open: () -> Void
    @ObservedObject private var state = LibraryStateStore.shared

    var body: some View {
        let status = state.status(for: book)
        Button(action: open) {
            HStack(spacing: 14) {
                LibraryCoverView(book: book, width: 62, height: 86)
                VStack(alignment: .leading, spacing: 5) {
                    Text("继续阅读")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Text(book.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.system(size: 12))
                            .foregroundStyle(NoveliaStyle.muted)
                            .lineLimit(1)
                    }
                    if let fraction = status.fraction {
                        ProgressView(value: min(1, max(0, fraction)))
                            .tint(NoveliaStyle.brandGreen)
                    }
                    Text([status.detail, status.lastReadAt.map(Self.relative)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(NoveliaStyle.brandGreen)
            }
            .padding(12)
            .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("继续阅读 \(book.title)，\(status.detail)")
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct LibrarySeriesRow: View {
    let name: String
    let books: [LibraryBook]

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                if books.count > 1 {
                    LibraryCoverView(book: books[1], width: 46, height: 64)
                        .opacity(0.5)
                        .offset(x: 10, y: -8)
                }
                if let first = books.first {
                    LibraryCoverView(book: first, width: 46, height: 64)
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(NoveliaStyle.brandGreen.opacity(0.12))
                        .frame(width: 46, height: 64)
                        .overlay(Image(systemName: "rectangle.stack").foregroundStyle(NoveliaStyle.brandGreen))
                }
            }
            .frame(width: 58, height: 72, alignment: .bottomLeading)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineLimit(2)
                Text("\(books.count) 本")
                    .font(.system(size: 12))
                    .foregroundStyle(NoveliaStyle.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.6))
        }
        .padding(12)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 搜索与排序控件

struct LibrarySearchField: View {
    @Binding var query: String
    let prompt: String
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(NoveliaStyle.muted)
                TextField(prompt, text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(NoveliaStyle.muted)
                    }
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(11)
            .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 13))
            Button("取消", action: onCancel)
                .tint(NoveliaStyle.brandGreen)
        }
        .onAppear { isFocused = true }
    }
}

struct LibrarySortMenu: View {
    let options: LibrarySortOptions
    let onChange: (LibrarySortOptions) -> Void

    var body: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("排序：\(options.summary)")
    }
}

/// 列表上方的当前排序说明，点按同样可切换。
private struct LibrarySortSummary: View {
    let options: LibrarySortOptions
    var count: Int? = nil
    let onChange: (LibrarySortOptions) -> Void

    var body: some View {
        HStack {
            if let count {
                Text("\(count) 本")
            }
            Spacer()
            Menu {
                LibrarySortMenu(options: options, onChange: onChange).menuContent
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(options.summary)
                }
            }
            .tint(NoveliaStyle.brandGreen)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(NoveliaStyle.muted)
    }
}

extension LibrarySortMenu {
    @ViewBuilder
    var menuContent: some View {
        Picker("排序方式", selection: Binding(get: { options.field }, set: { field in
            var updated = options
            updated.field = field
            onChange(updated)
        })) {
            ForEach(LibrarySortField.allCases) { Text($0.title).tag($0) }
        }
        Picker("顺序", selection: Binding(get: { options.ascending }, set: { ascending in
            var updated = options
            updated.ascending = ascending
            onChange(updated)
        })) {
            Text("倒序").tag(false)
            Text("正序").tag(true)
        }
    }
}

// MARK: - 打开阅读

/// 沿用原有阅读器：TXT 使用 TXT 阅读器，EPUB 使用 EPUB 阅读器。
struct LibraryReaderDestination: View {
    let book: LibraryBook
    @StateObject private var rules = TXTChapterRuleStore.shared

    var body: some View {
        if book.format == .txt {
            DownloadedWebNovelTXTReader(url: book.fileURL, title: book.title, rules: rules.configuration)
        } else {
            EPUBReaderHost(initialURL: book.fileURL)
        }
    }
}
