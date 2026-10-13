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
    @StateObject private var bookActions = LibraryBookActions()
    @State private var segment = Segment.books
    @State private var sourceFilter = LibrarySourceFilter.all
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
        let sourceBooks = allBooks
        let books = state.displayBooks(from: sourceBooks).filter { sourceFilter.includes(isWenku: $0.isWenku) }
        List {
            if sourceBooks.isEmpty {
                emptyLibrary.libraryListRow()
            } else if isSearching && !LibraryOrganizer.normalized(query).isEmpty {
                searchResults(books)
            } else {
                if let recent = recentBook(in: books) {
                    LibraryContinueReadingCard(book: recent) { open(recent) }
                        .libraryListRow()
                }
                // 已移入系列的书只在“系列”中显示，不在“全部书籍”中重复出现。
                let ungrouped = books.filter { state.series.seriesID(forBook: $0.key) == nil }
                Picker("书库内容", selection: $segment) {
                    Text("全部书籍 \(ungrouped.count)").tag(Segment.books)
                    Text("系列 \(visibleSeries(in: books).count)").tag(Segment.series)
                }
                .pickerStyle(.segmented)
                .libraryListRow()
                switch segment {
                case .books:
                    if ungrouped.isEmpty {
                        sourceFilterMenu.libraryListRow()
                        ContentUnavailableView {
                            Label("没有可显示的书籍", systemImage: "books.vertical")
                        } description: {
                            Text("可以切换来源筛选，或到“系列”中查看已归类的书籍。")
                        }
                        .padding(.top, 20)
                        .libraryListRow()
                    } else {
                        HStack {
                            sourceFilterMenu
                            Spacer()
                            LibrarySortSummary(options: sortOptions) { state.setSortOptions($0, scope: nil) }
                        }
                        .libraryListRow()
                        ForEach(sorted(ungrouped, options: sortOptions)) { book in
                            LibraryBookRow(book: book, actions: bookActions, open: open)
                                .libraryListRow()
                        }
                    }
                case .series:
                    seriesList(books)
                }
            }
        }
        .libraryListStyle()
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
        .task(id: sourceBooks) { await state.refreshHashes(for: sourceBooks) }
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
        .modifier(LibraryBookActionDialogs(actions: bookActions))
    }

    private var sourceFilterMenu: some View {
        Menu {
            Picker("书籍来源", selection: $sourceFilter) {
                ForEach(LibrarySourceFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sourceFilter.title)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(NoveliaStyle.brandGreen)
        }
        .accessibilityLabel("书籍来源：\(sourceFilter.title)")
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
        sourceFilterMenu.libraryListRow()
        let matches = books.filter { LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) }
        Text(matches.isEmpty ? "没有找到匹配的书" : "找到 \(matches.count) 本")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(NoveliaStyle.muted)
            .libraryListRow()
        if matches.isEmpty {
            ContentUnavailableView.search(text: query).libraryListRow()
        } else {
            ForEach(sorted(matches, options: sortOptions)) { book in
                LibraryBookRow(book: book, actions: bookActions, open: open)
                    .libraryListRow()
            }
        }
    }

    private func visibleSeries(in books: [LibraryBook]) -> [LibrarySeries] {
        state.series.activeSeries.filter { series in
            sourceFilter == .all || books.contains { state.series.seriesID(forBook: $0.key) == series.id }
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
                .foregroundStyle(NoveliaStyle.brandGreen)
        }
        .buttonStyle(.plain)
        .libraryListRow()
        sourceFilterMenu.libraryListRow()
        let allSeries = visibleSeries(in: books)
        if allSeries.isEmpty {
            ContentUnavailableView {
                Label("还没有系列", systemImage: "rectangle.stack")
            } description: {
                Text("新建系列后，在书籍的“更多”菜单中选择“移入系列”。导入和下载的书都可以加入。")
            }
            .padding(.top, 20)
            .libraryListRow()
        } else {
            ForEach(allSeries) { series in
                let keys = state.series.bookKeys(inSeries: series.id)
                let members = sorted(books.filter { keys.contains($0.key) }, options: state.sortOptions(scope: series.id))
                // 链接放在背景中，避免 List 为 NavigationLink 再加一个箭头。
                LibrarySeriesRow(name: series.name, books: members)
                    .background {
                        NavigationLink {
                            LibrarySeriesDetailView(seriesID: series.id, sourceFilter: sourceFilter)
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)
                    }
                    .libraryListRow()
                    .contextMenu { LibrarySeriesMenuItems(seriesID: series.id, name: series.name, actions: bookActions) }
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
    var sourceFilter = LibrarySourceFilter.all

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state = LibraryStateStore.shared
    @State private var query = ""
    @State private var isSearching = false
    @State private var readerTarget: LibraryBook?
    @State private var isAddingBooks = false
    @StateObject private var bookActions = LibraryBookActions()

    private var series: LibrarySeries? {
        state.series.series[seriesID].flatMap { $0.deleted ? nil : $0 }
    }

    var body: some View {
        let all = state.displayBooks(from: state.books(web: webDownloads, wenku: wenkuDownloads))
        let keys = state.series.bookKeys(inSeries: seriesID)
        let members = all.filter { keys.contains($0.key) && sourceFilter.includes(isWenku: $0.isWenku) }
        let options = state.sortOptions(scope: seriesID)
        let visible = LibraryOrganizer.sorted(
            members.filter { LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) },
            options: options
        ) { state.sortItem(for: $0) }

        List {
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
                .libraryListRow()
            } else {
                LibrarySortSummary(options: options, count: members.count) { state.setSortOptions($0, scope: seriesID) }
                    .libraryListRow()
                if visible.isEmpty {
                    ContentUnavailableView.search(text: query).libraryListRow()
                } else {
                    ForEach(visible) { book in
                        LibraryBookRow(book: book, showsSeries: false, actions: bookActions, open: open)
                            .libraryListRow()
                    }
                }
            }
        }
        .libraryListStyle()
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
                    LibrarySeriesMenuItems(seriesID: seriesID, name: series?.name ?? "", actions: bookActions)
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
        .modifier(LibraryBookActionDialogs(actions: bookActions))
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

/// 系列的重命名与解散菜单项；用于系列行的长按菜单和系列详情的“更多”菜单。
/// 菜单关闭后才能弹出对话框，所以对话框由页面上的 `LibraryBookActionDialogs` 统一显示。
private struct LibrarySeriesMenuItems: View {
    let seriesID: String
    let name: String
    let actions: LibraryBookActions

    var body: some View {
        Button {
            actions.renameName = name
            actions.renamingSeries = LibrarySeriesTarget(id: seriesID, name: name)
        } label: {
            Label("重命名系列", systemImage: "pencil")
        }
        Button(role: .destructive) {
            actions.dissolvingSeries = LibrarySeriesTarget(id: seriesID, name: name)
        } label: {
            Label("解散系列", systemImage: "rectangle.stack.badge.minus")
        }
    }
}

// MARK: - 书籍列表与操作

/// 书籍操作触发的确认框与提示。由页面持有并只挂载一次，避免每一行各自附带弹窗修饰符而拖慢滚动。
@MainActor
final class LibraryBookActions: ObservableObject {
    @Published var pendingDelete: LibraryBook?
    @Published var newSeriesBook: LibraryBook?
    @Published var newSeriesName = ""
    @Published var actionError: String?
    @Published var renamingSeries: LibrarySeriesTarget?
    @Published var renameName = ""
    @Published var dissolvingSeries: LibrarySeriesTarget?
}

struct LibrarySeriesTarget: Identifiable, Equatable {
    let id: String
    let name: String
}

/// 在页面层级挂载书籍操作的确认框与提示。
struct LibraryBookActionDialogs: ViewModifier {
    @ObservedObject var actions: LibraryBookActions
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "删除《\(actions.pendingDelete?.title ?? "")》？",
                isPresented: .init(get: { actions.pendingDelete != nil }, set: { if !$0 { actions.pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: actions.pendingDelete
            ) { book in
                Button("删除", role: .destructive) { delete(book) }
            } message: { _ in
                Text("将从本机删除书籍文件。WebDAV 中的副本不会删除，之后同步时可能恢复。")
            }
            .alert("新建系列", isPresented: .init(get: { actions.newSeriesBook != nil }, set: { if !$0 { actions.newSeriesBook = nil } })) {
                TextField("系列名称", text: $actions.newSeriesName)
                Button("取消", role: .cancel) { actions.newSeriesBook = nil }
                Button("创建并移入") {
                    if let book = actions.newSeriesBook {
                        let state = LibraryStateStore.shared
                        let id = state.createSeries(named: actions.newSeriesName.isEmpty ? book.title : actions.newSeriesName)
                        state.assign(book, to: id)
                    }
                    actions.newSeriesBook = nil
                }
            }
            .alert("重命名系列", isPresented: .init(get: { actions.renamingSeries != nil }, set: { if !$0 { actions.renamingSeries = nil } })) {
                TextField("系列名称", text: $actions.renameName)
                Button("取消", role: .cancel) { actions.renamingSeries = nil }
                Button("保存") {
                    if let target = actions.renamingSeries {
                        LibraryStateStore.shared.renameSeries(target.id, to: actions.renameName)
                    }
                    actions.renamingSeries = nil
                }
            }
            .confirmationDialog(
                "解散系列“\(actions.dissolvingSeries?.name ?? "")”？",
                isPresented: .init(get: { actions.dissolvingSeries != nil }, set: { if !$0 { actions.dissolvingSeries = nil } }),
                titleVisibility: .visible,
                presenting: actions.dissolvingSeries
            ) { target in
                Button("解散系列", role: .destructive) { LibraryStateStore.shared.deleteSeries(target.id) }
            } message: { _ in
                Text("系列中的书会移出系列，书籍文件和阅读进度都会保留。")
            }
            .alert("操作失败", isPresented: .init(get: { actions.actionError != nil }, set: { if !$0 { actions.actionError = nil } })) {
                Button("好", role: .cancel) { actions.actionError = nil }
            } message: {
                Text(actions.actionError ?? "")
            }
    }

    private func delete(_ book: LibraryBook) {
        switch book.origin {
        case .webNovel(let record): webDownloads.remove(record)
        case .wenku(let record): wenkuDownloads.remove(record)
        }
    }
}

/// 每个 ForEach 元素只返回一行，使 List 能按书籍标识复用行，避免遍历多行子视图。
/// 点击整行打开阅读；“更多”菜单提供系列、导出、移动和删除。
struct LibraryBookRow: View {
    let book: LibraryBook
    /// 系列详情中不重复显示系列名。
    var showsSeries = true
    /// 只用于触发弹窗，不观察其变化，弹窗状态改变时列表行不必重算。
    let actions: LibraryBookActions
    let open: (LibraryBook) -> Void

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @ObservedObject private var state = LibraryStateStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button { open(book) } label: {
                LibraryBookRowContent(book: book, status: state.status(for: book), seriesName: showsSeries ? state.seriesName(for: book) : nil)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开阅读")
            .accessibilityIdentifier("library-book-\(book.key)")
            Menu {
                menuItems(for: book)
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
    }

    @ViewBuilder
    private func menuItems(for book: LibraryBook) -> some View {
        let currentSeries = state.series.seriesID(forBook: book.key)
        Button { open(book) } label: { Label("阅读", systemImage: "book") }
        Menu {
            ForEach(state.series.activeSeries.filter { $0.id != currentSeries }) { series in
                Button(series.name) { state.assign(book, to: series.id) }
            }
            Divider()
            Button {
                actions.newSeriesName = ""
                actions.newSeriesBook = book
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
                    catch { actions.actionError = error.localizedDescription }
                }
            } label: {
                Label("移至文库", systemImage: "arrow.right.arrow.left")
            }
        case .wenku(let record):
            Button {
                do { try LibraryMover.moveToNetwork(record, web: webDownloads, wenku: wenkuDownloads, state: state) }
                catch { actions.actionError = error.localizedDescription }
            } label: {
                Label("移至网络小说", systemImage: "arrow.right.arrow.left")
            }
        }
        Divider()
        Button(role: .destructive) { actions.pendingDelete = book } label: {
            Label("删除", systemImage: "trash")
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

// MARK: - 列表样式

private extension View {
    /// 书库列表行：透明行背景、无分隔线，卡片间距由上下内边距形成。
    func libraryListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    /// 使用 List 而非 ScrollView + LazyVStack：List 复用行视图，书多时滚动不再逐行重建。
    func libraryListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
    }
}

// MARK: - 打开阅读

/// 沿用原有阅读器：TXT 使用 TXT 阅读器，EPUB 使用 EPUB 阅读器。
struct LibraryReaderDestination: View {
    let book: LibraryBook
    @StateObject private var rules = TXTChapterRuleStore.shared

    var body: some View {
        if book.format == .txt {
            DownloadedWebNovelTXTReader(url: book.fileURL, title: book.title, rules: rules.configuration, statisticsID: book.key)
        } else {
            EPUBReaderHost(initialURL: book.fileURL, statisticsID: book.key, statisticsTitle: book.title)
        }
    }
}
