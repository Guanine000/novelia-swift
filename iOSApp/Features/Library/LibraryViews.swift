import SwiftUI
import UniformTypeIdentifiers

/// 书库书籍的呈现方式。列表是默认视图（支持拖动多选），网格只改变浏览方式。
enum LibraryBooksLayout: String, CaseIterable {
    case list
    case grid
}

// MARK: - 书库（底部导航第一项）

/// 书库：导入和下载的书、系列、统一搜索与排序；点击整行打开阅读。
struct LibraryView: View {
    @Environment(\.browseSelection) private var keyboardSelect
    @Environment(\.browseSelectedID) private var keyboardSelectedID
    @Environment(\.browseReadingReturn) private var browseReadingReturn
    @Environment(\.browseReading) private var browseReading
    private enum Segment: String, CaseIterable, Identifiable {
        case all, books, series
        var id: String { rawValue }
    }

    private enum ActiveSheet: Identifiable {
        case syncProgress
        case shelfUpdates
        var id: Int {
            switch self {
            case .syncProgress: 1
            case .shelfUpdates: 2
            }
        }
    }

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var webDAVSync: WebDAVSyncStore
    @EnvironmentObject private var cloudBooks: CloudBookStore
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var incomingDocuments: IncomingDocumentCoordinator
    @StateObject private var importer = LibraryImportModel()
    @StateObject private var bookActions = LibraryBookActions()
    @StateObject private var shelfUpdates = LibraryShelfUpdateStore()
    @StateObject private var searchHistory = SearchHistoryStore(scope: .library)
    @State private var segment = Segment.all
    @State private var sourceFilter = LibrarySourceFilter.all
    @State private var query = ""
    @State private var isSearching = false
    @State private var searchFocusRequest = 0
    @State private var readerTarget: LibraryBook?
    @State private var onlineSpeechTarget: SpeechHandoffStore.OpenRequest?
    @State private var isCreatingSeries = false
    @State private var newSeriesName = ""
    @State private var pendingAutoOrganize: [String: LibraryBookStatus]?
    @State private var isShowingAutoOrganizeUpToDate = false
    @State private var syncTask: Task<Void, Never>?
    @State private var hasTriggeredSync = false
    @State private var isShowingSyncProgress = false
    @State private var isDropTargeted = false
    /// 列表与封面网格之间切换；选择记在偏好里，下次打开书库沿用。
    @AppStorage("library.booksLayout") private var booksLayout: LibraryBooksLayout = .list
    /// 阅读状态筛选；首次默认选中「在读」，之后记住上次选择。
    @AppStorage("library.readingStatusFilter") private var statusFilter: LibraryBookStatusFilter = .reading

    private var allBooks: [LibraryBook] {
        // 只给哈希／孤立状态清理完整书库，不能把尚未读取的另一库误判为已删除。
        guard webDownloads.isReady, wenkuDownloads.isReady else { return [] }
        return state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks)
    }
    /// 系统“用 Novelia 打开”的文件先进入书库导入队列；导入期间到达的文件保留到本轮结束。
    private func handleIncomingDocuments() {
        guard !importer.isBusy, !incomingDocuments.pending.isEmpty else { return }
        let urls = incomingDocuments.take()
        importer.attach(wenkuDownloads)
        Task { await importer.handlePickedFiles(urls) }
    }

    /// 请求在书库加载完成前保留；导航键不再与文件哈希或在线位置键混用。
    private func openSpeechBook(_ request: SpeechHandoffStore.OpenRequest?) {
        guard let request else { return }
        switch request.route {
        case .online(let novel):
            if let browseReading {
                browseReading(.online(novel, services.speechHandoff.pendingResume?.chapterIndex ?? 0))
            } else { onlineSpeechTarget = request }
        case .library(let key):
            guard let book = allBooks.first(where: { $0.key == key }) else { return }
            if let browseReading { browseReading(.library(book)) } else { readerTarget = book }
        case nil:
            guard let book = allBooks.first(where: {
                guard let hash = state.hashByBook[$0.key] ?? $0.cloudFileHash else { return false }
                return $0.positionPrefix + hash == request.bookKey
            }) else { return }
            if let browseReading { browseReading(.library(book)) } else { readerTarget = book }
        }
    }
    private var sortOptions: LibrarySortOptions { state.sortOptions(scope: nil) }

    /// 导入文件类型，包含 TXT、EPUB 与 AZW3／MOBI。
    private var importContentTypes: [UTType] {
        var types = [
            UTType(filenameExtension: "txt") ?? .plainText,
            UTType(filenameExtension: "epub") ?? .data
        ]
        types += KindleEPUBConverter.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        return types
    }

    /// 多选范围与当前列表一致：全部、未分组，或统一搜索结果。
    private var selectableBooks: [LibraryBook] {
        let sourceFiltered = state.displayBooks(from: allBooks).filter { sourceFilter.includes(isWenku: $0.isWenku) }
        if isSearching, !LibraryOrganizer.normalized(query).isEmpty {
            return sourceFiltered.filter { LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) }
        }
        let books = sourceFiltered.filter { statusFilter.includes(state.bookStatus(for: $0)) }
        switch segment {
        case .all: return books
        case .books: return books.filter { state.series.seriesID(forBook: $0.key) == nil }
        case .series: return []
        }
    }

    private func readingStatusCounts(in books: [LibraryBook]) -> [LibraryBookStatusFilter: Int] {
        var counts: [LibraryBookStatusFilter: Int] = [.all: books.count]
        for book in books {
            switch state.bookStatus(for: book) {
            case .reading: counts[.reading, default: 0] += 1
            case .wantToRead: counts[.wantToRead, default: 0] += 1
            case .completed: counts[.completed, default: 0] += 1
            case .onHold: counts[.onHold, default: 0] += 1
            case .dropped: counts[.dropped, default: 0] += 1
            }
        }
        return counts
    }

    private var activeLibrarySheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if isShowingSyncProgress { return .syncProgress }
                if shelfUpdates.isShowingDetails { return .shelfUpdates }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if isShowingSyncProgress { isShowingSyncProgress = false }
                else if shelfUpdates.isShowingDetails { shelfUpdates.isShowingDetails = false }
            }
        )
    }

    var body: some View {
        let sourceBooks = allBooks
        let sourceFiltered = state.displayBooks(from: sourceBooks).filter { sourceFilter.includes(isWenku: $0.isWenku) }
        let books = sourceFiltered.filter { statusFilter.includes(state.bookStatus(for: $0)) }
        let selectable = selectableBooks
        ScrollViewReader { browserScroll in
            List {
                libraryListContent(sourceBooks: sourceBooks, sourceFiltered: sourceFiltered, books: books)
            }
            .libraryListStyle()
            .modifier(LibraryDragSelectionModifier(books: sorted(selectable, options: sortOptions), actions: bookActions))
            .pageKeyboardActions(enabled: !bookActions.isSelecting && !bookActions.isDraggingSelection,
                browseKeyboardActions(destinations: sorted(selectable, options: sortOptions).map(BrowseDestination.library),
                    selectedID: keyboardSelectedID, select: keyboardSelect, read: browseReading,
                    search: { isSearching = true; searchFocusRequest += 1 },
                    scrollTo: { id in withAnimation { browserScroll.scrollTo(String(id.dropFirst("library:".count)), anchor: .center) } }))
            .overlay { libraryEmptyOrLoadingOverlay(sourceBooks: sourceBooks) }
            .safeAreaInset(edge: .bottom) {
                if bookActions.isSelecting || bookActions.isDraggingSelection { LibrarySelectionBar(books: selectable, actions: bookActions) }
            }
            .onValueChange(of: segment) { _, _ in bookActions.endSelection() }
            .compatScrollDismissesKeyboardInteractively()
            .safeAreaInset(edge: .top) { searchBar }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("书库")
            // 搜索时改为行内标题，避免大标题区域在搜索栏上方留下空白。
            .navigationBarTitleDisplayMode(isSearching ? .inline : .large)
            .modifier(ExclusiveToolbar(
                useFirst: bookActions.isSelecting,
                first: LibrarySelectionToolbar(books: selectable, actions: bookActions),
                second: toolbarContent
            ))
            .compatNavigationDestination(item: $readerTarget) { book in
                LibraryReaderDestination(book: book)
            }
            .onValueChange(of: readerTarget) { _, target in
                if target == nil { state.reloadPositions(books: sourceBooks) }
            }
            // 迷你条请求回到朗读处：按书籍身份找到书并打开，阅读器起来后从该位置继续朗读。
            .onReceive(services.speechHandoff.$openRequest) { request in openSpeechBook(request) }
            .onValueChange(of: sourceBooks) { _, _ in openSpeechBook(services.speechHandoff.openRequest) }
            .onValueChange(of: state.hashByBook) { _, _ in openSpeechBook(services.speechHandoff.openRequest) }
            .compatNavigationDestination(item: $onlineSpeechTarget) { request in
                if case .online(let novel) = request.route {
                    ReaderView(novel: novel, startingAt: services.speechHandoff.pendingResume?.chapterIndex ?? 0)
                }
            }
            .onValueChange(of: webDAVSync.isSyncing) { _, syncing in
                if !syncing { state.reloadPositions(books: sourceBooks) }
            }
            .onValueChange(of: webDAVSync.isEnabled) { _, isEnabled in
                if !isEnabled { syncTask?.cancel() }
            }
            .onAppear {
                state.reloadPositions(books: sourceBooks)
                handleIncomingDocuments()
            }
            .onValueChange(of: incomingDocuments.pending) { _, _ in handleIncomingDocuments() }
            .onValueChange(of: importer.isBusy) { _, importing in
                if !importing { handleIncomingDocuments() }
            }
            .task { importer.attach(wenkuDownloads) }
            .task { await wenkuDownloads.refreshMissingMetadata() }
            .task(id: sourceBooks) {
                state.associateVolumes(sourceBooks)
                await state.refreshHashes(for: sourceBooks, librariesReady: webDownloads.isReady && wenkuDownloads.isReady)
                if webDownloads.isReady && wenkuDownloads.isReady {
                    state.reconcileAutoStatuses(for: sourceBooks)
                }
            }
            .fullScreenCover(isPresented: $importer.isShowingFileImporter) {
                EPUBFilePicker(contentTypes: importContentTypes, allowsMultipleSelection: true) { urls in
                    Task { await importer.handlePickedFiles(urls) }
                }
                .ignoresSafeArea()
            }
            .sheet(item: activeLibrarySheet) { sheet in
                switch sheet {
                case .syncProgress:
                    WebDAVSyncProgressPanel(onCancel: {
                        syncTask?.cancel()
                        webDAVSync.cancelAutomaticSync()
                    }) {
                        syncTask = Task { await webDAVSync.sync(web: webDownloads, wenku: wenkuDownloads) }
                    }
                    .compatPresentationDetents(.height(280))
                    .compatPresentationDragIndicatorVisible()
                case .shelfUpdates:
                    shelfUpdateDetailSheet(sourceBooks: sourceBooks)
                }
            }
            .alert("导入", isPresented: .init(
                get: { importer.importError != nil },
                set: { if !$0 { importer.importError = nil } }
            )) {
                Button("好", role: .cancel) { importer.importError = nil }
            } message: {
                Text(importer.importError ?? "")
            }
            .alert("转换为 EPUB 后导入", isPresented: .init(
                get: { importer.pendingKindleImport != nil },
                // 提示框只能通过按钮关闭，由按钮处理待确认的文件。
                set: { _ in }
            ), presenting: importer.pendingKindleImport) { _ in
                Button("转换并导入") { Task { await importer.resolvePendingKindleImport(convert: true) } }
                Button("取消", role: .cancel) { Task { await importer.resolvePendingKindleImport(convert: false) } }
            } message: { pending in
                Text(LibraryImportModel.kindleConversionNotice(for: pending.kindleFilenames))
            }
            .alert("检测到 EPUB 结构问题", isPresented: .init(
                get: { importer.pendingEPUBRepair != nil },
                set: { _ in }
            ), presenting: importer.pendingEPUBRepair) { _ in
                Button("修复并标准化后导入") { Task { await importer.resolvePendingEPUBRepair(decision: .repairAndImport) } }
                Button("按原样直接导入") { Task { await importer.resolvePendingEPUBRepair(decision: .importOriginal) } }
                Button("跳过问题文件", role: .cancel) { Task { await importer.resolvePendingEPUBRepair(decision: .skipProblematic) } }
            } message: { pending in
                Text(LibraryImportModel.epubRepairNotice(for: pending.problematicItems))
            }
            .alert("新建系列", isPresented: $isCreatingSeries) {
                TextField("系列名称", text: $newSeriesName)
                Button("取消", role: .cancel) {}
                Button("创建") { state.createSeries(named: newSeriesName) }
            } message: {
                Text("创建后，可在书籍的“更多”菜单中移入系列。")
            }
            .alert(
                "按进度整理阅读状态",
                isPresented: Binding(
                    get: { pendingAutoOrganize != nil },
                    set: { if !$0 { pendingAutoOrganize = nil } }
                ),
                presenting: pendingAutoOrganize
            ) { changes in
                Button("取消", role: .cancel) { pendingAutoOrganize = nil }
                Button("应用（\(changes.count) 本）") {
                    state.applyAutoOrganize(changes)
                    pendingAutoOrganize = nil
                }
            } message: { changes in
                Text(autoOrganizeSummary(changes))
            }
            .alert("按进度整理阅读状态", isPresented: $isShowingAutoOrganizeUpToDate) {
                Button("好", role: .cancel) {}
            } message: {
                Text("当前所有书籍的阅读状态已与阅读进度一致。")
            }
            .overlay { LibraryImportProgressOverlay(model: importer) }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                        .stroke(NoveliaStyle.brandGreen, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: importContentTypes + [.fileURL], isTargeted: $isDropTargeted) { providers in
                importer.attach(wenkuDownloads)
                return importer.handleDroppedProviders(providers, contentTypes: importContentTypes)
            }
            .modifier(LibraryBookActionDialogs(actions: bookActions))
            .onValueChange(of: bookActions.downloadedBookKey) { _, key in
                guard let key else { return }
                bookActions.downloadedBookKey = nil
                if let book = state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks).first(where: { $0.key == key }) {
                    open(book)
                }
            }
            .onValueChange(of: browseReadingReturn) { _, request in
                guard let request, selectable.contains(where: { $0.key == request.bookKey }) else { return }
                browserScroll.scrollTo(request.bookKey, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func libraryListContent(sourceBooks: [LibraryBook], sourceFiltered: [LibraryBook], books: [LibraryBook]) -> some View {
        if shelfUpdates.isChecking || shelfUpdates.isBannerVisible {
            LibraryShelfUpdateBanner(store: shelfUpdates) {
                shelfUpdates.isShowingDetails = true
            }
            .libraryListRow()
        }
        if !sourceBooks.isEmpty, let error = webDownloads.storageError ?? wenkuDownloads.storageError {
            VStack(alignment: .leading) {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("重试读取") { Task { try? await webDownloads.loadIfNeeded(); await wenkuDownloads.refreshMissingMetadata() } }
            }
        }
        if sourceBooks.isEmpty {
            // 空状态放在 overlay 中显示；CompatUnavailable 作为 List 行时操作按钮会被压成细长色条。
        } else if isSearching && !LibraryOrganizer.normalized(query).isEmpty {
            searchResults(sourceFiltered)
        } else {
            if statusFilter == .all || statusFilter == .reading {
                let recent = recentBooks(in: books)
                if !recent.isEmpty {
                    LibraryRecentCarousel(books: recent) { open($0) }
                        .frame(maxWidth: 1120)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                }
            }
            LibraryReadingStatusBar(selection: $statusFilter, counts: readingStatusCounts(in: sourceFiltered))
                .libraryListRow()
            // 全部包含已归入系列的书；未分组只列出没有系列归属的书。
            let ungrouped = books.filter { state.series.seriesID(forBook: $0.key) == nil }
            Picker("书库内容", selection: $segment) {
                Text("全部 \(books.count)").tag(Segment.all)
                Text("未分组 \(ungrouped.count)").tag(Segment.books)
                Text("系列 \(visibleSeries(in: books).count)").tag(Segment.series)
            }
            .pickerStyle(.segmented)
            .libraryListRow()
            librarySegmentContent(books: books, ungrouped: ungrouped)
        }
    }

    @ViewBuilder
    private func librarySegmentContent(books: [LibraryBook], ungrouped: [LibraryBook]) -> some View {
        switch segment {
        case .all, .books:
            let listedBooks = segment == .all ? books : ungrouped
            if listedBooks.isEmpty {
                sourceFilterMenu.libraryListRow()
                emptyFilteredState
                    .padding(.top, 20)
                    .libraryListRow()
            } else {
                HStack {
                    sourceFilterMenu
                    Spacer()
                    LibrarySortSummary(options: sortOptions) { state.setSortOptions($0, scope: nil) }
                }
                .libraryListRow()
                let booksToShow = sorted(listedBooks, options: sortOptions)
                if booksLayout == .grid {
                    LibraryBooksGrid(books: booksToShow, actions: bookActions, open: open,
                                     isSelecting: bookActions.isSelecting || bookActions.isDraggingSelection,
                                     selectedKeys: bookActions.selectedKeys)
                        .libraryListRow()
                } else {
                    ForEach(booksToShow) { book in
                        LibraryBookRow(book: book, actions: bookActions, open: open,
                                       isSelecting: bookActions.isSelecting || bookActions.isDraggingSelection,
                                       isSelected: bookActions.selectedKeys.contains(book.key),
                                       showStatusBadge: statusFilter == .all)
                            .libraryListRow()
                    }
                }
            }
        case .series:
            seriesList(books)
        }
    }

    @ViewBuilder
    private func libraryEmptyOrLoadingOverlay(sourceBooks: [LibraryBook]) -> some View {
        if webDownloads.isLoading || wenkuDownloads.isLoading {
            ProgressView("正在读取书库…")
        } else if sourceBooks.isEmpty, let error = webDownloads.storageError ?? wenkuDownloads.storageError {
            CompatUnavailable {
                Label("无法读取书库", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("重试") { Task { try? await webDownloads.loadIfNeeded(); await wenkuDownloads.refreshMissingMetadata() } }
            }
        } else if sourceBooks.isEmpty {
            emptyLibrary
        }
    }

    private func shelfUpdateDetailSheet(sourceBooks: [LibraryBook]) -> some View {
        let webBooksByID = Dictionary(
            sourceBooks.compactMap { book -> (String, LibraryBook)? in
                guard case .webNovel(let record) = book.origin else { return nil }
                return (record.id, book)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let webRecordsByID = Dictionary(
            webDownloads.books.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return LibraryShelfUpdateDetailSheet(
            store: shelfUpdates,
            booksByID: webBooksByID,
            onRecheckAll: { shelfUpdates.startCheck(books: webDownloads.books, catalog: services.api.catalog) },
            onRetryFailed: { shelfUpdates.retryFailed(books: webDownloads.books, catalog: services.api.catalog) },
            onBatchUpdateAll: {
                shelfUpdates.startBatchUpdate(booksByID: webRecordsByID) { record in
                    try await webDownloads.updateEPUB(record)
                }
            },
            onOpenBook: { open($0) },
            onUpdateBook: { bookActions.pendingEPUBUpdate = $0 },
            onClose: { shelfUpdates.isShowingDetails = false }
        )
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
            VStack(spacing: 8) {
                LibrarySearchField(
                    query: $query,
                    prompt: "搜索书名、作者、摘录或书签",
                    focusRequest: searchFocusRequest,
                    onSubmit: { searchHistory.record(query) },
                    onCancel: {
                        isSearching = false
                        query = ""
                    }
                )
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SearchHistoryStrip(store: searchHistory) { term in
                        query = term
                        searchHistory.record(term)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 1152)
            .frame(maxWidth: .infinity)
            .background(NoveliaStyle.paper)
        }
    }

    /// 工具栏构建器本身不能写 if/else（iOS 16 才有 buildEither）。是否显示同步按钮在 ToolbarItem 的视图里判断。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        syncToolbarItem
        libraryTrailingToolbar
    }

    @ToolbarContentBuilder
    private var syncToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .compatTopBarLeading) {
            if webDAVSync.isEnabled {
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
    }

    @ToolbarContentBuilder
    private var libraryTrailingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .compatTopBarTrailing) {
            Button {
                withAnimation { isSearching.toggle() }
                if !isSearching { query = "" }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索书库")
            Button {
                importer.isShowingFileImporter = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("导入 TXT 或 EPUB")
            .disabled(importer.isBusy)
            Menu {
                if !selectableBooks.isEmpty {
                    Button { bookActions.beginSelection() } label: {
                        Label("选择书籍", systemImage: "checklist")
                    }
                }
                Button { isCreatingSeries = true; newSeriesName = "" } label: {
                    Label("新建系列", systemImage: "rectangle.stack.badge.plus")
                }
                if !allBooks.isEmpty {
                    Button {
                        let changes = state.previewAutoOrganize(books: allBooks)
                        if changes.isEmpty {
                            isShowingAutoOrganizeUpToDate = true
                        } else {
                            pendingAutoOrganize = changes
                        }
                    } label: {
                        Label("按进度整理阅读状态", systemImage: "wand.and.stars")
                    }
                }
                if !shelfUpdates.checkableBooks(from: webDownloads.books).isEmpty {
                    Button {
                        shelfUpdates.startCheck(books: webDownloads.books, catalog: services.api.catalog)
                    } label: {
                        Label(shelfUpdates.isChecking ? "正在检查书架更新…" : "检查书架更新",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(shelfUpdates.isChecking)
                    if shelfUpdates.summary.hasResults, !shelfUpdates.isBannerVisible, !shelfUpdates.isChecking {
                        Button {
                            shelfUpdates.isShowingDetails = true
                        } label: {
                            Label("查看上次更新检查", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
                Divider()
                Picker("书库布局", selection: $booksLayout) {
                    Label("列表视图", systemImage: "list.bullet").tag(LibraryBooksLayout.list)
                    Label("封面网格", systemImage: "square.grid.3x3").tag(LibraryBooksLayout.grid)
                }
                Divider()
                LibrarySortMenu(options: sortOptions) { state.setSortOptions($0, scope: nil) }.menuContent
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("书库菜单")
        }
    }

    private var emptyLibrary: some View {
        CompatUnavailable {
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
        let storageMap = storageKeyBookMap(for: books)
        let titlesByStorageKey = storageMap.mapValues(\.title)
        let annotationHits = LibraryGlobalSearch.searchAnnotations(
            query: query,
            annotations: Array(readerSettings.annotations.records.values),
            bookTitlesByKey: titlesByStorageKey
        )
        let bookmarkHits = LibraryGlobalSearch.searchBookmarks(
            query: query,
            bookmarks: Array(readerSettings.bookmarks.records.values),
            bookTitlesByKey: titlesByStorageKey
        )
        let summaryParts = [
            matches.isEmpty ? nil : "书籍 \(matches.count)",
            annotationHits.isEmpty ? nil : "摘录与笔记 \(annotationHits.count)",
            bookmarkHits.isEmpty ? nil : "书签 \(bookmarkHits.count)",
        ].compactMap { $0 }

        Text(summaryParts.isEmpty ? "没有找到匹配内容" : "找到 " + summaryParts.joined(separator: " · "))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(NoveliaStyle.muted)
            .libraryListRow()

        if summaryParts.isEmpty {
            CompatSearchUnavailable(text: query).libraryListRow()
        } else {
            if !matches.isEmpty {
                ForEach(sorted(matches, options: sortOptions)) { book in
                    LibraryBookRow(book: book, actions: bookActions, open: open,
                                   isSelecting: bookActions.isSelecting || bookActions.isDraggingSelection,
                                   isSelected: bookActions.selectedKeys.contains(book.key),
                                   showStatusBadge: true)
                        .libraryListRow()
                }
            }
            if !annotationHits.isEmpty {
                Text("摘录与笔记")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .padding(.top, matches.isEmpty ? 4 : 14)
                    .libraryListRow()
                ForEach(annotationHits) { hit in
                    Button {
                        if let book = storageMap[hit.bookKey] { open(book) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(annotationSwatchColor(hit.color))
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(hit.bookTitle)
                                        .font(NoveliaStyle.fontCaption.weight(.semibold))
                                        .foregroundStyle(NoveliaStyle.brandGreen)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("第 \(hit.chapterIndex + 1) 章")
                                        .font(NoveliaStyle.fontMicro)
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                                Text(hit.quote)
                                    .font(NoveliaStyle.fontBody)
                                    .foregroundStyle(NoveliaStyle.ink)
                                    .lineLimit(3)
                                if !hit.note.isEmpty {
                                    Text("笔记：\(hit.note)")
                                        .font(NoveliaStyle.fontCaption)
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(10)
                        .noveliaCard(cornerRadius: NoveliaStyle.radiusSmall)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .libraryListRow()
                }
            }
            if !bookmarkHits.isEmpty {
                Text("书签")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .padding(.top, (matches.isEmpty && annotationHits.isEmpty) ? 4 : 14)
                    .libraryListRow()
                ForEach(bookmarkHits) { hit in
                    Button {
                        if let book = storageMap[hit.bookKey] { open(book) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(hit.bookTitle)
                                        .font(NoveliaStyle.fontCaption.weight(.semibold))
                                        .foregroundStyle(NoveliaStyle.brandGreen)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(hit.chapterTitle ?? "第 \(hit.chapterIndex + 1) 章")
                                        .font(NoveliaStyle.fontMicro)
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .lineLimit(1)
                                }
                                if !hit.snippet.isEmpty {
                                    Text(hit.snippet)
                                        .font(NoveliaStyle.fontBody)
                                        .foregroundStyle(NoveliaStyle.ink)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(10)
                        .noveliaCard(cornerRadius: NoveliaStyle.radiusSmall)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .libraryListRow()
                }
            }
        }
    }

    private func storageKeyBookMap(for books: [LibraryBook]) -> [String: LibraryBook] {
        var map: [String: LibraryBook] = [:]
        for book in books {
            map[book.key] = book
            if let hash = state.hashByBook[book.key] ?? book.cloudFileHash {
                map[book.positionPrefix + hash] = book
            }
            if case .webNovel(let record) = book.origin, record.novel.isRemote,
               let provider = record.novel.providerId, let novel = record.novel.novelId {
                map[WebNovelEPUBContext.key(provider: provider, novel: novel)] = book
            }
        }
        return map
    }

    private func annotationSwatchColor(_ color: ReaderAnnotation.Color) -> Color {
        switch color {
        case .yellow: Color(red: 0.92, green: 0.72, blue: 0.16)
        case .green: NoveliaStyle.brandGreen
        case .blue: Color(red: 0.25, green: 0.54, blue: 0.88)
        case .pink: Color(red: 0.88, green: 0.36, blue: 0.52)
        case .purple: Color(red: 0.58, green: 0.40, blue: 0.84)
        }
    }

    private var emptyFilteredState: some View {
        CompatUnavailable {
            Label(
                statusFilter == .all ? "没有可显示的书籍" : "“\(statusFilter.title)”中暂无书籍",
                systemImage: statusFilter.status?.systemImage ?? "books.vertical"
            )
        } description: {
            Text(
                statusFilter == .all
                    ? (segment == .books ? "可以切换来源筛选，或到“全部”中查看已归类的书籍。" : "可以切换来源筛选，查看其他来源的书籍。")
                    : "可在书籍菜单或长按封面中切换阅读状态，或切回“全部”查看所有书籍。"
            )
        } actions: {
            if statusFilter != .all {
                Button("查看全部书籍") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        statusFilter = .all
                    }
                }
                .buttonStyle(.bordered)
                .tint(NoveliaStyle.brandGreen)
            }
        }
    }

    private func visibleSeries(in books: [LibraryBook]) -> [LibrarySeries] {
        state.series.activeSeries.filter { series in
            (sourceFilter == .all && statusFilter == .all) || books.contains { state.series.seriesID(forBook: $0.key) == series.id }
        }
    }

    @ViewBuilder
    private func seriesList(_ books: [LibraryBook]) -> some View {
        HStack(spacing: 12) {
            sourceFilterMenu
            Spacer()
            Button {
                newSeriesName = ""
                isCreatingSeries = true
            } label: {
                Label("新建系列", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NoveliaStyle.brandGreen.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .libraryListRow()
        let allSeries = visibleSeries(in: books)
        if allSeries.isEmpty {
            CompatUnavailable {
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
                        BrowseListLink {
                            LibrarySeriesDetailView(seriesID: series.id, sourceFilter: sourceFilter)
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)
                    }
                    .libraryListRow()
                    .contextMenu { LibrarySeriesMenuItems(seriesID: series.id, name: series.name, books: members, actions: bookActions) }
            }
        }
    }

    private func recentBooks(in books: [LibraryBook], limit: Int = 8) -> [LibraryBook] {
        books.compactMap { book in state.status(for: book).lastReadAt.map { (book, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private func sorted(_ books: [LibraryBook], options: LibrarySortOptions) -> [LibraryBook] {
        LibraryOrganizer.sorted(books, options: options) { state.sortItem(for: $0) }
    }

    private func autoOrganizeSummary(_ changes: [String: LibraryBookStatus]) -> String {
        let grouped = Dictionary(grouping: changes.values, by: { $0 })
        let parts = LibraryBookStatus.allCases.compactMap { status -> String? in
            guard let count = grouped[status]?.count, count > 0 else { return nil }
            return "\(status.title) \(count) 本"
        }
        let breakdown = parts.joined(separator: "、")
        return "将按当前阅读进度更新 \(changes.count) 本书（\(breakdown)）。手动标为「抛弃」的书保持不变。"
    }

    /// 云端书籍先询问是否下载，下载完成后由 `downloadedBookKey` 回到这里打开。
    private func open(_ book: LibraryBook) {
        guard !book.isCloudOnly else {
            if book.cloudFileMissing { bookActions.missingCloudBook = book } else { bookActions.pendingCloudDownload = book }
            return
        }
        if let browseReading { browseReading(.library(book)) }
        else { state.markOpened(book); readerTarget = book }
    }
}

// MARK: - 系列详情

struct LibrarySeriesDetailView: View {
    @Environment(\.browseSelection) private var keyboardSelect
    @Environment(\.browseSelectedID) private var keyboardSelectedID
    @Environment(\.browseReadingReturn) private var browseReadingReturn
    @Environment(\.browseReading) private var browseReading
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    let seriesID: String
    var sourceFilter = LibrarySourceFilter.all

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var cloudBooks: CloudBookStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: LibraryStateStore
    @State private var isCheckingNewVolumes = false
    @State private var query = ""
    @State private var isSearching = false
    @State private var searchFocusRequest = 0
    @State private var readerTarget: LibraryBook?
    @State private var isAddingBooks = false
    @State private var previousVolumeRecapTarget: (previous: LibraryBook, currentTitle: String)?
    @AppStorage("library.booksLayout") private var booksLayout: LibraryBooksLayout = .list
    @StateObject private var bookActions = LibraryBookActions()

    private var series: LibrarySeries? {
        state.series.series[seriesID].flatMap { $0.deleted ? nil : $0 }
    }

    /// 列表和工具栏共用。原先是 body 里的局部常量，抽到属性后工具栏才能读到。
    private var allBooks: [LibraryBook] {
        state.displayBooks(from: state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks))
    }

    private var members: [LibraryBook] {
        let keys = state.series.bookKeys(inSeries: seriesID)
        return allBooks.filter { keys.contains($0.key) && sourceFilter.includes(isWenku: $0.isWenku) }
    }

    private var unfilteredMembers: [LibraryBook] {
        let keys = state.series.bookKeys(inSeries: seriesID)
        return state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks).filter { keys.contains($0.key) }
    }

    private var options: LibrarySortOptions { state.sortOptions(scope: seriesID) }

    private var visible: [LibraryBook] {
        LibraryOrganizer.sorted(
            members.filter { LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) },
            options: options
        ) { state.sortItem(for: $0) }
    }

    var body: some View {
        ScrollViewReader { browserScroll in
        List {
            if members.isEmpty {
                CompatUnavailable {
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
                if !isSearching || query.isEmpty {
                    LibrarySeriesHeaderCard(
                        name: series?.name ?? "系列",
                        books: members,
                        onContinue: open,
                        onAddBooks: { isAddingBooks = true },
                        onCheckNewVolumes: { isCheckingNewVolumes = true }
                    )
                    .libraryListRow()
                }
                HStack(spacing: 12) {
                    LibrarySortSummary(options: options, count: members.count) { state.setSortOptions($0, scope: seriesID) }
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            booksLayout = booksLayout == .list ? .grid : .list
                        }
                    } label: {
                        Image(systemName: booksLayout == .list ? "square.grid.3x3" : "list.bullet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(booksLayout == .list ? "切换为封面网格" : "切换为列表视图")
                }
                .libraryListRow()
                if visible.isEmpty {
                    CompatSearchUnavailable(text: query).libraryListRow()
                } else if booksLayout == .grid {
                    LibraryBooksGrid(
                        books: visible,
                        actions: bookActions,
                        open: open,
                        isSelecting: bookActions.isSelecting || bookActions.isDraggingSelection,
                        selectedKeys: bookActions.selectedKeys
                    )
                    .libraryListRow()
                } else {
                    ForEach(visible) { book in
                        LibraryBookRow(book: book, actions: bookActions, open: open,
                                       isSelecting: bookActions.isSelecting || bookActions.isDraggingSelection,
                                       isSelected: bookActions.selectedKeys.contains(book.key))
                            .libraryListRow()
                    }
                }
            }
        }
        .libraryListStyle()
        .modifier(LibraryDragSelectionModifier(books: visible, actions: bookActions))
        .pageKeyboardActions(enabled: !bookActions.isSelecting && !bookActions.isDraggingSelection,
            browseKeyboardActions(destinations: visible.map(BrowseDestination.library),
                selectedID: keyboardSelectedID, select: keyboardSelect, read: browseReading,
                search: { isSearching = true; searchFocusRequest += 1 },
                scrollTo: { id in withAnimation { browserScroll.scrollTo(String(id.dropFirst("library:".count)), anchor: .center) } }))
        .compatScrollDismissesKeyboardInteractively()
        .safeAreaInset(edge: .top) { searchBar }
        .safeAreaInset(edge: .bottom) {
            if bookActions.isSelecting || bookActions.isDraggingSelection {
                LibrarySelectionBar(books: visible, actions: bookActions, archiveTitle: series?.name ?? "系列")
            }
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle(series?.name ?? "系列")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ExclusiveToolbar(
            useFirst: bookActions.isSelecting,
            first: LibrarySelectionToolbar(books: visible, actions: bookActions),
            second: seriesToolbar
        ))
        .compatNavigationDestination(item: $readerTarget) { book in
            LibraryReaderDestination(book: book)
        }
        .onValueChange(of: readerTarget) { _, target in
            if target == nil { state.reloadPositions(books: allBooks) }
        }
        .onValueChange(of: series == nil) { _, removed in
            if removed { dismiss() }
        }
        .sheet(isPresented: $isCheckingNewVolumes) {
            WenkuSeriesNewVolumesView(books: unfilteredMembers,
                libraryBooks: state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks))
        }
        .sheet(isPresented: $isAddingBooks) {
            LibraryAddToSeriesSheet(seriesID: seriesID, books: allBooks)
        }
        .modifier(LibraryBookActionDialogs(actions: bookActions))
        .onValueChange(of: bookActions.downloadedBookKey) { _, key in
            guard let key else { return }
            bookActions.downloadedBookKey = nil
            if let book = state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks).first(where: { $0.key == key }) {
                open(book)
            }
        }
        .onValueChange(of: browseReadingReturn) { _, request in
            guard let request, visible.contains(where: { $0.key == request.bookKey }) else { return }
            browserScroll.scrollTo(request.bookKey, anchor: .center)
        }
        .sheet(isPresented: Binding(
            get: { previousVolumeRecapTarget != nil },
            set: { if !$0 { previousVolumeRecapTarget = nil } }
        )) {
            if let target = previousVolumeRecapTarget {
                PreviousVolumeRecapSheet(
                    previousBook: target.previous,
                    currentBookTitle: target.currentTitle,
                    store: readerSettings.recaps,
                    ai: services.readingAI
                )
            }
        }
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearching {
            LibrarySearchField(query: $query, prompt: "在系列中搜索书名或作者", focusRequest: searchFocusRequest) {
                isSearching = false
                query = ""
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 1152)
            .frame(maxWidth: .infinity)
            .background(NoveliaStyle.paper)
        }
    }

    @ToolbarContentBuilder
    private var seriesToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .compatTopBarTrailing) {
            Button {
                withAnimation { isSearching.toggle() }
                if !isSearching { query = "" }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("在系列中搜索")
            LibrarySortMenu(options: options) { state.setSortOptions($0, scope: seriesID) }
            if !visible.isEmpty {
                Button { bookActions.beginSelection() } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel("选择")
                .accessibilityHint("进入多选，可批量移出系列、删除或压缩分享")
            }
            Menu {
                NavigationLink {
                    CharacterSeriesView(workID: seriesID, books: unfilteredMembers, store: readerSettings.characters, ai: services.readingAI,
                        initialBook: unfilteredMembers.max { (state.lastOpened[$0.key] ?? .distantPast) < (state.lastOpened[$1.key] ?? .distantPast) }?.key)
                } label: { Label("AI 人物词条", systemImage: "person.text.rectangle") }
                NavigationLink {
                    WorldviewLexiconView(
                        workID: seriesID,
                        workTitle: series?.name ?? "系列",
                        books: unfilteredMembers,
                        initialBookKey: unfilteredMembers.max { (state.lastOpened[$0.key] ?? .distantPast) < (state.lastOpened[$1.key] ?? .distantPast) }?.key,
                        store: readerSettings.worldview,
                        ai: services.readingAI
                    )
                } label: { Label("世界观词条", systemImage: "globe.asia.australia") }
                if let pair = seriesPreviousVolumePair {
                    Button {
                        previousVolumeRecapTarget = pair
                    } label: {
                        Label("回顾上一卷（\(pair.previous.title)）", systemImage: "clock.arrow.circlepath")
                    }
                }
                Button { isCheckingNewVolumes = true } label: { Label("检查新卷", systemImage: "arrow.clockwise") }
                Button { isAddingBooks = true } label: { Label("添加书籍", systemImage: "plus") }
                LibrarySeriesMenuItems(seriesID: seriesID, name: series?.name ?? "", books: members, actions: bookActions)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("系列操作")
        }
    }

    /// 为系列当前待续读卷找到上一卷，供系列菜单一键「回顾上一卷」。
    private var seriesPreviousVolumePair: (previous: LibraryBook, currentTitle: String)? {
        let all = unfilteredMembers
        guard all.count >= 2 else { return nil }
        let confirmed = readerSettings.characters.order(work: seriesID)
        let latest = all.max { (state.lastOpened[$0.key] ?? .distantPast) < (state.lastOpened[$1.key] ?? .distantPast) }
        guard let current = latest,
              let prevKey = LibrarySeriesVolumeResolver.previousBookKey(
                  for: current.key,
                  confirmedOrder: confirmed,
                  members: all.map { .init(key: $0.key, title: $0.title) }
              ),
              let previous = all.first(where: { $0.key == prevKey }) else { return nil }
        return (previous, current.title)
    }

    /// 云端书籍先询问是否下载，下载完成后由 `downloadedBookKey` 回到这里打开。
    private func open(_ book: LibraryBook) {
        guard !book.isCloudOnly else {
            if book.cloudFileMissing { bookActions.missingCloudBook = book } else { bookActions.pendingCloudDownload = book }
            return
        }
        if let browseReading { browseReading(.library(book)) }
        else { state.markOpened(book); readerTarget = book }
    }
}

/// 从全部书籍中多选加入系列；已在其他系列的书会改为属于本系列。
private struct LibraryAddToSeriesSheet: View {
    let seriesID: String
    let books: [LibraryBook]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var readerSettings: ReaderSettings
    @State private var selection = Set<String>()
    @State private var query = ""

    var body: some View {
        let candidates = LibraryOrganizer.sorted(
            books.filter { state.series.seriesID(forBook: $0.key) != seriesID
                && LibraryOrganizer.matches(title: $0.title, author: $0.author, query: query) },
            options: LibrarySortOptions(field: .title, ascending: true)
        ) { state.sortItem(for: $0) }
        CompatNavigationStack {
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
                                .font(NoveliaStyle.fontFootnote)
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
                    CompatUnavailable(query.isEmpty ? "没有可添加的书" : "没有找到匹配的书", systemImage: "books.vertical")
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
                            try? readerSettings.characters.migrateWork(from: book.key, to: seriesID)
                            readerSettings.worldview.migrateWork(from: book.key, to: seriesID)
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
    @EnvironmentObject private var state: LibraryStateStore
    let seriesID: String
    let name: String
    /// 系列中的书；压缩后分享整卷时使用。
    let books: [LibraryBook]
    let actions: LibraryBookActions

    private var shareableCount: Int { books.filter { !$0.isCloudOnly }.count }

    var body: some View {
        if !books.isEmpty {
            Menu {
                ForEach(LibraryBookStatus.allCases) { status in
                    Button {
                        state.setBookStatus(status, for: books)
                    } label: {
                        Label(status.title, systemImage: status.systemImage)
                    }
                }
            } label: {
                Label("批量设置阅读状态", systemImage: "bookmark")
            }
        }
        Button {
            actions.prepareArchiveShare(books: books, title: "\(name) \(books.count) 本")
        } label: {
            Label("压缩后分享", systemImage: "doc.zipper")
        }
        .disabled(shareableCount == 0 || actions.isPreparingArchive)
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

/// 在视图层切换两套工具栏。ToolbarContentBuilder 的 if/else 从 iOS 16 起才有。
private struct ExclusiveToolbar<First: ToolbarContent, Second: ToolbarContent>: ViewModifier {
    let useFirst: Bool
    let first: First
    let second: Second

    @ViewBuilder
    func body(content: Content) -> some View {
        if useFirst {
            content.toolbar { first }
        } else {
            content.toolbar { second }
        }
    }
}
