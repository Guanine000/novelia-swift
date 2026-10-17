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
    @EnvironmentObject private var cloudBooks: CloudBookStore
    @EnvironmentObject private var state: LibraryStateStore
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

    private var allBooks: [LibraryBook] { state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks) }
    private var sortOptions: LibrarySortOptions { state.sortOptions(scope: nil) }

    var body: some View {
        let sourceBooks = allBooks
        let books = state.displayBooks(from: sourceBooks).filter { sourceFilter.includes(isWenku: $0.isWenku) }
        // 多选的范围是当前列出的书：搜索结果，或“全部书籍”中未归入系列的书。
        let selectable: [LibraryBook] = isSearching && !LibraryOrganizer.normalized(query).isEmpty
            ? books.filter { LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) }
            : segment == .books ? books.filter { state.series.seriesID(forBook: $0.key) == nil } : []
        List {
            if sourceBooks.isEmpty {
                // 空状态放在 overlay 中显示；ContentUnavailableView 作为 List 行时操作按钮会被压成细长色条。
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
                            LibraryBookRow(book: book, actions: bookActions, open: open,
                                           isSelecting: bookActions.isSelecting,
                                           isSelected: bookActions.selectedKeys.contains(book.key))
                                .libraryListRow()
                        }
                    }
                case .series:
                    seriesList(books)
                }
            }
        }
        .libraryListStyle()
        .overlay { if sourceBooks.isEmpty { emptyLibrary } }
        .safeAreaInset(edge: .bottom) {
            if bookActions.isSelecting { LibrarySelectionBar(books: selectable, actions: bookActions) }
        }
        .onChange(of: segment) { _, _ in bookActions.endSelection() }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) { searchBar }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("书库")
        // 搜索时改为行内标题，避免大标题区域在搜索栏上方留下空白。
        .navigationBarTitleDisplayMode(isSearching ? .inline : .large)
        .toolbar {
            if bookActions.isSelecting {
                LibrarySelectionToolbar(books: selectable, actions: bookActions)
            } else {
                toolbarContent
            }
        }
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
            WebDAVSyncProgressPanel(onCancel: {
                syncTask?.cancel()
                webDAVSync.cancelAutomaticSync()
            }) {
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
        .onChange(of: bookActions.downloadedBookKey) { _, key in
            guard let key else { return }
            bookActions.downloadedBookKey = nil
            if let book = state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks).first(where: { $0.key == key }) {
                open(book)
            }
        }
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
                LibraryBookRow(book: book, actions: bookActions, open: open,
                               isSelecting: bookActions.isSelecting,
                               isSelected: bookActions.selectedKeys.contains(book.key))
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

    /// 云端书籍先询问是否下载，下载完成后由 `downloadedBookKey` 回到这里打开。
    private func open(_ book: LibraryBook) {
        guard !book.isCloudOnly else {
            if book.cloudFileMissing { bookActions.missingCloudBook = book } else { bookActions.pendingCloudDownload = book }
            return
        }
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
    @EnvironmentObject private var cloudBooks: CloudBookStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: LibraryStateStore
    @State private var query = ""
    @State private var isSearching = false
    @State private var readerTarget: LibraryBook?
    @State private var isAddingBooks = false
    @StateObject private var bookActions = LibraryBookActions()

    private var series: LibrarySeries? {
        state.series.series[seriesID].flatMap { $0.deleted ? nil : $0 }
    }

    var body: some View {
        let all = state.displayBooks(from: state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks))
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
                        LibraryBookRow(book: book, showsSeries: false, actions: bookActions, open: open,
                                       isSelecting: bookActions.isSelecting,
                                       isSelected: bookActions.selectedKeys.contains(book.key))
                            .libraryListRow()
                    }
                }
            }
        }
        .libraryListStyle()
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) { searchBar }
        .safeAreaInset(edge: .bottom) {
            if bookActions.isSelecting { LibrarySelectionBar(books: visible, actions: bookActions) }
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle(series?.name ?? "系列")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if bookActions.isSelecting {
                LibrarySelectionToolbar(books: visible, actions: bookActions)
            } else {
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
        .onChange(of: bookActions.downloadedBookKey) { _, key in
            guard let key else { return }
            bookActions.downloadedBookKey = nil
            if let book = state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks).first(where: { $0.key == key }) {
                open(book)
            }
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

    /// 云端书籍先询问是否下载，下载完成后由 `downloadedBookKey` 回到这里打开。
    private func open(_ book: LibraryBook) {
        guard !book.isCloudOnly else {
            if book.cloudFileMissing { bookActions.missingCloudBook = book } else { bookActions.pendingCloudDownload = book }
            return
        }
        state.markOpened(book)
        readerTarget = book
    }
}

/// 从全部书籍中多选加入系列；已在其他系列的书会改为属于本系列。
private struct LibraryAddToSeriesSheet: View {
    let seriesID: String
    let books: [LibraryBook]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: LibraryStateStore
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
    /// 等待确认删除的书；单本删除与多选批量删除共用。
    @Published var pendingDelete: [LibraryBook] = []
    /// 新建系列后要移入的书。
    @Published var newSeriesBooks: [LibraryBook] = []
    @Published var newSeriesName = ""
    @Published var actionError: String?
    @Published var renamingSeries: LibrarySeriesTarget?
    @Published var renameName = ""
    @Published var dissolvingSeries: LibrarySeriesTarget?
    /// 打开云端书籍时等待确认下载。
    @Published var pendingCloudDownload: LibraryBook?
    /// 文件已不在服务器上的云端书籍：打开时或下载失败后提示，可从云端删除。
    @Published var missingCloudBook: LibraryBook?
    /// 正在编辑书库信息的文库／导入书籍。
    @Published var editingBook: LibraryBook?
    /// 下载完成的书，页面据此打开阅读。
    @Published var downloadedBookKey: String?
    /// 多选：长按书籍进入，点击切换选择。
    @Published private(set) var isSelecting = false
    @Published private(set) var selectedKeys: Set<String> = []

    func beginSelection(with book: LibraryBook) {
        isSelecting = true
        selectedKeys = [book.key]
    }

    func toggleSelection(_ book: LibraryBook) {
        if selectedKeys.contains(book.key) { selectedKeys.remove(book.key) } else { selectedKeys.insert(book.key) }
    }

    func selectAll(_ books: [LibraryBook]) { selectedKeys = Set(books.map(\.key)) }

    func endSelection() {
        isSelecting = false
        selectedKeys = []
    }
}

/// 多选时替换页面的工具栏：全选／取消全选与完成。
struct LibrarySelectionToolbar: ToolbarContent {
    let books: [LibraryBook]
    let actions: LibraryBookActions
    /// 由页面按当前选择计算后传入；工具栏内容不观察 actions，传值才能随选择刷新标题。
    let allSelected: Bool

    init(books: [LibraryBook], actions: LibraryBookActions) {
        self.books = books
        self.actions = actions
        allSelected = !books.isEmpty && books.allSatisfy { actions.selectedKeys.contains($0.key) }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(allSelected ? "取消全选" : "全选") {
                if allSelected { actions.selectAll([]) } else { actions.selectAll(books) }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成") { actions.endSelection() }
                .fontWeight(.semibold)
        }
    }
}

/// 多选时显示在底部的批量操作：移入系列、移出系列、删除。只作用于当前列出且已选中的书。
struct LibrarySelectionBar: View {
    let books: [LibraryBook]
    @ObservedObject var actions: LibraryBookActions
    @EnvironmentObject private var state: LibraryStateStore

    private var selected: [LibraryBook] { books.filter { actions.selectedKeys.contains($0.key) } }

    var body: some View {
        let selected = selected
        let inSeries = selected.filter { state.series.seriesID(forBook: $0.key) != nil }
        HStack(spacing: 8) {
            Text("已选 \(selected.count) 本")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(NoveliaStyle.ink)
            Spacer(minLength: 4)
            Menu {
                ForEach(state.series.activeSeries) { series in
                    Button(series.name) {
                        selected.forEach { state.assign($0, to: series.id) }
                        actions.endSelection()
                    }
                }
                Divider()
                Button {
                    actions.newSeriesName = ""
                    actions.newSeriesBooks = selected
                } label: {
                    Label("新建系列…", systemImage: "plus")
                }
            } label: {
                barLabel("移入系列", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(selected.isEmpty)
            Button {
                inSeries.forEach { state.assign($0, to: nil) }
                actions.endSelection()
            } label: {
                barLabel("移出系列", systemImage: "rectangle.stack.badge.minus")
            }
            .disabled(inSeries.isEmpty)
            Button(role: .destructive) { actions.pendingDelete = selected } label: {
                barLabel("删除", systemImage: "trash")
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func barLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage).font(.system(size: 17))
            Text(title).font(.caption2)
        }
        .frame(minWidth: 56)
    }
}

struct LibrarySeriesTarget: Identifiable, Equatable {
    let id: String
    let name: String
}

/// 在页面层级挂载书籍操作的确认框与提示。
struct LibraryBookActionDialogs: ViewModifier {
    @EnvironmentObject private var state: LibraryStateStore
    @ObservedObject var actions: LibraryBookActions
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var syncStore: WebDAVSyncStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.editingBook) { book in
                if case .wenku(let record) = book.origin,
                   let current = wenkuDownloads.books.first(where: { $0.id == record.id }) {
                    LibraryBookInfoEditor(record: current, coverURL: wenkuDownloads.coverURL(for: current)) { title, author, description, cover in
                        try wenkuDownloads.updateMetadata(id: current.id, title: title, author: author,
                                                          description: description, cover: cover)
                    }
                }
            }
            .alert("《\(actions.missingCloudBook?.title ?? "")》的云端文件缺失",
                   isPresented: .init(get: { actions.missingCloudBook != nil },
                                      set: { if !$0 { actions.missingCloudBook = nil } }),
                   presenting: actions.missingCloudBook) { book in
                Button("从云端删除", role: .destructive) {
                    actions.missingCloudBook = nil
                    delete([book], fromCloud: true)
                }
                Button("仍然尝试下载") { download(book) }
                Button("取消", role: .cancel) { actions.missingCloudBook = nil }
            } message: { _ in
                Text("WebDAV 中已找不到这本书的文件，本机也没有。若其他设备仍有这本书，在那台设备上手动同步一次即可补传；不再需要时可从云端删除书目，阅读进度和统计会保留。")
            }
            .alert("下载《\(actions.pendingCloudDownload?.title ?? "")》？",
                   isPresented: .init(get: { actions.pendingCloudDownload != nil },
                                      set: { if !$0 { actions.pendingCloudDownload = nil } }),
                   presenting: actions.pendingCloudDownload) { book in
                Button("取消", role: .cancel) { actions.pendingCloudDownload = nil }
                Button("下载") { download(book) }
            } message: { book in
                let size = book.cloudDownloadSizeText.map { "大小约 \($0)。" } ?? "大小未知。"
                Text("这本书只保存在 WebDAV 中，需要先下载到本机才能阅读。\(size)下载会消耗 WebDAV 流量。")
            }
            .overlay {
                if let key = syncStore.downloadingCloudBook {
                    let title = state.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks)
                        .first { $0.key == key }?.title ?? ""
                    VStack(spacing: 12) {
                        ProgressView(value: syncStore.cloudDownloadProgress)
                            .tint(NoveliaStyle.brandGreen)
                        Text("正在下载《\(title)》…").font(.subheadline)
                    }
                    .padding(20)
                    .frame(maxWidth: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: .init(get: { !actions.pendingDelete.isEmpty }, set: { if !$0 { actions.pendingDelete = [] } }),
                titleVisibility: .visible,
                presenting: actions.pendingDelete
            ) { books in
                let localCount = books.filter { !$0.isCloudOnly }.count
                if localCount > 0 {
                    Button(localCount == books.count ? "仅删除本机" : "仅删除本机的 \(localCount) 本", role: .destructive) {
                        delete(books, fromCloud: false)
                    }
                }
                if syncStore.isEnabled {
                    Button(localCount == 0 ? "从云端删除" : "删除本机和云端副本", role: .destructive) {
                        delete(books, fromCloud: true)
                    }
                }
                Button("取消", role: .cancel) { actions.pendingDelete = [] }
            } message: { books in
                if syncStore.isEnabled {
                    Text(books.allSatisfy(\.isCloudOnly)
                         ? "将删除 WebDAV 中的副本。其他设备同步后也会删除各自已下载的这些书。"
                         : "仅删除本机时，WebDAV 中的副本会保留，之后显示为未下载。同时删除云端副本后，其他设备同步时也会删除各自已下载的这些书。")
                } else {
                    Text("将从本机删除书籍文件。")
                }
            }
            .alert("新建系列", isPresented: .init(get: { !actions.newSeriesBooks.isEmpty }, set: { if !$0 { actions.newSeriesBooks = [] } })) {
                TextField("系列名称", text: $actions.newSeriesName)
                Button("取消", role: .cancel) { actions.newSeriesBooks = [] }
                Button("创建并移入") {
                    let books = actions.newSeriesBooks
                    if let first = books.first {
                        let id = state.createSeries(named: actions.newSeriesName.isEmpty ? first.title : actions.newSeriesName)
                        books.forEach { state.assign($0, to: id) }
                    }
                    actions.newSeriesBooks = []
                    actions.endSelection()
                }
            }
            .alert("重命名系列", isPresented: .init(get: { actions.renamingSeries != nil }, set: { if !$0 { actions.renamingSeries = nil } })) {
                TextField("系列名称", text: $actions.renameName)
                Button("取消", role: .cancel) { actions.renamingSeries = nil }
                Button("保存") {
                    if let target = actions.renamingSeries {
                        state.renameSeries(target.id, to: actions.renameName)
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
                Button("解散系列", role: .destructive) { state.deleteSeries(target.id) }
            } message: { _ in
                Text("系列中的书会移出系列，书籍文件和阅读进度都会保留。")
            }
            .alert("操作失败", isPresented: .init(get: { actions.actionError != nil }, set: { if !$0 { actions.actionError = nil } })) {
                Button("好", role: .cancel) { actions.actionError = nil }
            } message: {
                Text(actions.actionError ?? "")
            }
    }

    private func download(_ book: LibraryBook) {
        actions.pendingCloudDownload = nil
        actions.missingCloudBook = nil
        Task {
            do {
                try await syncStore.downloadCloudBook(key: book.key, web: webDownloads, wenku: wenkuDownloads)
                actions.downloadedBookKey = book.key
            } catch WebDAVSyncError.missingBlob {
                actions.missingCloudBook = book
            } catch {
                actions.actionError = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    private var deleteTitle: String {
        let books = actions.pendingDelete
        return books.count == 1 ? "删除《\(books[0].title)》？" : "删除 \(books.count) 本书？"
    }

    /// 先删除本机文件，再按需删除云端副本；云端失败时本机删除不回滚，书会显示为云端书籍，可在其菜单中重试。
    /// 云端也删除成功后，书不会再出现，才清理系列归属与最近打开时间。
    private func delete(_ books: [LibraryBook], fromCloud: Bool) {
        actions.pendingDelete = []
        actions.endSelection()
        for book in books where !book.isCloudOnly {
            switch book.origin {
            case .webNovel(let record): webDownloads.remove(record)
            case .wenku(let record): wenkuDownloads.remove(record)
            }
        }
        guard fromCloud else { return }
        Task {
            do {
                let keys = Set(books.map(\.key))
                try await syncStore.deleteFromCloud(keys: keys)
                state.forget(keys: keys)
            } catch {
                actions.actionError = "云端删除失败：\(error.localizedDescription)。这些书会显示为未下载的云端书籍，可在其菜单中再次“从云端删除”。"
            }
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
    /// 多选状态由页面传入：多选时点击切换选择，长按进入多选。
    var isSelecting = false
    var isSelected = false

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var state: LibraryStateStore

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            LibraryBookRowContent(book: book, status: state.status(for: book), seriesName: showsSeries ? state.seriesName(for: book) : nil)
                .contentShape(Rectangle())
                // 长按优先于点击：普通状态点击打开、长按进入多选；多选时点击或长按都切换选择。
                // 在 List 行中分别挂 onTapGesture/onLongPressGesture 时点击会抢先触发，故显式组合。
                .gesture(LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture()).onEnded { value in
                    switch value {
                    case .first:
                        if isSelecting { actions.toggleSelection(book) } else { actions.beginSelection(with: book) }
                    case .second:
                        if isSelecting { actions.toggleSelection(book) } else { open(book) }
                    }
                })
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isSelecting ? "切换选择" : "打开阅读")
                .accessibilityAction(named: "多选") { actions.beginSelection(with: book) }
                .accessibilityIdentifier("library-book-\(book.key)")
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.toggleSelection(book) }
                    .accessibilityLabel(isSelected ? "已选择：\(book.title)" : "未选择：\(book.title)")
                    .accessibilityAddTraits(.isButton)
            } else {
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
        }
        .padding(.leading, 10)
        .padding(.vertical, 8)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func menuItems(for book: LibraryBook) -> some View {
        let currentSeries = state.series.seriesID(forBook: book.key)
        if book.isCloudOnly {
            Button { open(book) } label: {
                Label(book.cloudDownloadSizeText.map { "下载（\($0)）" } ?? "下载", systemImage: "icloud.and.arrow.down")
            }
        } else {
            Button { open(book) } label: { Label("阅读", systemImage: "book") }
        }
        Menu {
            ForEach(state.series.activeSeries.filter { $0.id != currentSeries }) { series in
                Button(series.name) { state.assign(book, to: series.id) }
            }
            Divider()
            Button {
                actions.newSeriesName = ""
                actions.newSeriesBooks = [book]
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
        // 云端书籍没有本机文件，只能下载、调整系列或从云端删除。
        if book.isCloudOnly {
            Divider()
            Button(role: .destructive) { actions.pendingDelete = [book] } label: {
                Label("从云端删除", systemImage: "icloud.slash")
            }
        } else {
            localFileItems(for: book)
        }
    }

    @ViewBuilder
    private func localFileItems(for book: LibraryBook) -> some View {
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
            Button { actions.editingBook = book } label: {
                Label("编辑信息", systemImage: "pencil")
            }
            Button {
                do { try LibraryMover.moveToNetwork(record, web: webDownloads, wenku: wenkuDownloads, state: state) }
                catch { actions.actionError = error.localizedDescription }
            } label: {
                Label("移至网络小说", systemImage: "arrow.right.arrow.left")
            }
        }
        Divider()
        Button(role: .destructive) { actions.pendingDelete = [book] } label: {
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
                    if book.cloudFileMissing {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("云端文件缺失")
                    } else if book.isCloudOnly {
                        Image(systemName: "icloud")
                            .foregroundStyle(NoveliaStyle.muted)
                            .accessibilityLabel("未下载")
                    }
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
    @EnvironmentObject private var state: LibraryStateStore

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
