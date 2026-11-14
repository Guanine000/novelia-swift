import SwiftUI

// MARK: - 书籍列表与操作

/// 书籍操作触发的确认框与提示。由页面持有并只挂载一次，避免每一行各自附带弹窗修饰符而拖慢滚动。
@MainActor
final class LibraryBookActions: ObservableObject {
    /// 等待确认删除的书；单本删除与多选批量删除共用。
    @Published var pendingDelete: [LibraryBook] = [] {
        didSet { isShowingDeleteConfirmation = !pendingDelete.isEmpty }
    }
    /// 确认框收起只改变呈现状态，不能先清空按钮还需要读取的删除对象。
    @Published var isShowingDeleteConfirmation = false
    @Published var deletionProgress: String?
    /// 新建系列后要移入的书。
    @Published var newSeriesBooks: [LibraryBook] = []
    @Published var newSeriesName = ""
    @Published var actionError: String?
    @Published var pendingEPUBUpdate: DownloadedWebNovel?
    @Published var updateConfigurationBook: DownloadedWebNovel?
    @Published var pendingCloudEPUBUpdate: DownloadedWebNovel?
    @Published var updatingNovelID: String?
    @Published var epubUpdateMessage: String?
    var epubUpdateTask: Task<Void, Never>?
    /// 云端删除失败以非阻断提示保留重试入口；多次失败合并书籍键，避免丢掉较早的重试。
    @Published var cloudDeleteError: String?
    @Published var failedCloudDeleteKeys: Set<String> = []
    @Published var isRetryingCloudDelete = false
    @Published var renamingSeries: LibrarySeriesTarget?
    @Published var renameName = ""
    @Published var dissolvingSeries: LibrarySeriesTarget?
    /// 打开云端书籍时等待确认下载。
    @Published var pendingCloudDownload: LibraryBook?
    /// 文件已不在服务器上的云端书籍：打开时或下载失败后提示，可从云端删除。
    @Published var missingCloudBook: LibraryBook?
    /// 正在编辑书库信息的文库／导入书籍。
    @Published var chapterUpdateBook: DownloadedWebNovel?
    @Published var editingBook: LibraryBook?
    @Published var associatingBook: LibraryBook?
    @Published var wenkuDetail: WenkuNovelOutline?
    /// 列表行只保留核心信息，其余元数据在详细信息里查看。
    @Published var detailBook: LibraryBook?
    /// 书籍“更多”菜单发起的 AI 人物词条；未入系列的书以书键作为 work，移入系列时迁移数据。
    @Published var characterBook: LibraryBook?
    /// 下载完成的书，页面据此打开阅读。
    @Published var downloadedBookKey: String?
    /// 多选：长按书籍进入，点击切换选择。
    @Published private(set) var isSelecting = false
    @Published var isDraggingSelection = false
    @Published private(set) var selectedKeys: Set<String> = []
    /// 已生成的压缩包，非 nil 时弹出系统分享面板。
    @Published var shareArchive: LibraryArchiveShare?
    /// 正在打包压缩包；批量分享时用于禁用重复点击与显示进度。
    @Published private(set) var isPreparingArchive = false
    /// 已生成的 TXT→EPUB 导出文件；非 nil 时弹出系统分享面板。
    @Published var shareExport: LibraryFileShare?
    /// 正在导出 TXT 为 EPUB；用于禁用重复点击与显示进度。
    @Published private(set) var isExportingTXTAsEPUB = false

    private var archiveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    /// 顶部“选择”按钮进入多选，开始时未选中任何书。
    func beginSelection() {
        isSelecting = true
        selectedKeys = []
    }

    func beginSelection(with book: LibraryBook) {
        isSelecting = true
        selectedKeys = [book.key]
    }

    func toggleSelection(_ book: LibraryBook) {
        if selectedKeys.contains(book.key) { selectedKeys.remove(book.key) } else { selectedKeys.insert(book.key) }
    }

    func applyDragSelection(_ keys: Set<String>, selecting: Bool = true) {
        isSelecting = selecting; selectedKeys = keys
    }

    func selectAll(_ books: [LibraryBook]) { selectedKeys = Set(books.map(\.key)) }

    func endSelection() {
        isSelecting = false
        selectedKeys = []
    }

    /// 把选中的书压缩成 zip 后打开系统分享；系列长按菜单也复用这里。
    func prepareArchiveShare(books: [LibraryBook], title: String) {
        guard !isPreparingArchive else { return }
        archiveTask?.cancel()
        isPreparingArchive = true
        archiveTask = Task {
            defer { isPreparingArchive = false }
            do {
                let archive = try await LibraryArchiveExporter.makeArchive(books: books, title: title)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: archive.url)
                    return
                }
                shareArchive = archive
            } catch is CancellationError {
                // 用户离开页面或重新发起，忽略。
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// 把 TXT 按当前手工目录导出为 EPUB 后打开系统分享；不写回源文件或阅读状态。
    func exportTXTAsEPUB(_ book: LibraryBook, settings: ReaderSettings) {
        guard !isExportingTXTAsEPUB else { return }
        exportTask?.cancel()
        isExportingTXTAsEPUB = true
        exportTask = Task {
            defer { isExportingTXTAsEPUB = false }
            do {
                let share = try await TXTEPUBExportService.makeEPUB(book: book, settings: settings)
                guard !Task.isCancelled else {
                    if let directory = share.cleanupDirectory {
                        try? FileManager.default.removeItem(at: directory)
                    }
                    return
                }
                shareExport = share
            } catch is CancellationError {
                // 用户离开页面或重新发起，忽略。
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// 分享面板关闭后删除本次导出的临时目录。
    func dismissExportShare() {
        if let directory = shareExport?.cleanupDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        shareExport = nil
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
        ToolbarItem(placement: .compatTopBarLeading) {
            Button(allSelected ? "取消全选" : "全选") {
                if allSelected { actions.selectAll([]) } else { actions.selectAll(books) }
            }
        }
        ToolbarItem(placement: .compatTopBarTrailing) {
            Button("完成") { actions.endSelection() }
                .compatFontWeight(.semibold)
        }
    }
}

/// 多选时显示在底部的批量操作：移入系列、移出系列、删除。只作用于当前列出且已选中的书。
struct LibrarySelectionBar: View {
    let books: [LibraryBook]
    @ObservedObject var actions: LibraryBookActions
    /// 压缩包标题前缀：书库为“书库”，系列详情传入系列名。
    var archiveTitle = "书库"
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var readerSettings: ReaderSettings

    @State private var availableWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selected: [LibraryBook] { books.filter { actions.selectedKeys.contains($0.key) } }
    private var shareableCount: Int { selected.filter { !$0.isCloudOnly }.count }

    var body: some View {
        Group {
            if availableWidth < 560 || horizontalSizeClass != .regular || dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    selectionCount
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        actionButtons
                    }
                }
            } else {
                HStack(spacing: 12) {
                    selectionCount
                    Spacer(minLength: 4)
                    actionButtons
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 1152)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { availableWidth = geometry.size.width }
                .onValueChange(of: geometry.size.width) { _, width in availableWidth = width }
        })
        .background(.bar)
    }

    private var selectionCount: some View {
        Text("已选 \(selected.count) 本")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(NoveliaStyle.ink)
    }

    @ViewBuilder
    private var actionButtons: some View {
        let selected = selected
        let inSeries = selected.filter { state.series.seriesID(forBook: $0.key) != nil }
        Menu {
            ForEach(state.series.activeSeries) { series in
                Button(series.name) {
                    selected.forEach {
                        try? readerSettings.characters.migrateWork(from: $0.key, to: series.id)
                        state.assign($0, to: series.id)
                    }
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
        Button {
            actions.prepareArchiveShare(books: selected, title: "\(archiveTitle) \(selected.count) 本")
        } label: {
            barLabel("压缩分享", systemImage: "doc.zipper")
        }
        .disabled(shareableCount == 0 || actions.isPreparingArchive)
        .accessibilityHint(shareableCount < selected.count
                           ? "云端书籍没有本机文件，只会压缩已下载的书"
                           : "把选中的书打成一个压缩包后分享")
    }

    private func barLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage).font(.system(size: 17))
            Text(title).font(.caption2)
        }
        .frame(minWidth: 56, minHeight: 44)
        .frame(maxWidth: .infinity)
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
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var services: AppServices

    func body(content: Content) -> some View {
        content
            .compatNavigationDestination(item: $actions.wenkuDetail) { outline in WenkuDetailView(outline: outline) }
            .compatNavigationDestination(item: $actions.characterBook) { book in
                characterEntry(for: book)
            }
            .sheet(item: $actions.updateConfigurationBook) { book in
                WebNovelEPUBUpdateOptionsSheet(book: book) { configuration in
                    actions.updateConfigurationBook = nil
                    updateEPUB(book, configuration: configuration)
                }
            }
            .sheet(item: $actions.chapterUpdateBook) { book in
                WebNovelEPUBReader(book: book, managementOnly: true)
            }
            .sheet(item: $actions.editingBook) { book in
                if case .wenku(let record) = book.origin,
                   let current = wenkuDownloads.books.first(where: { $0.id == record.id }) {
                    LibraryBookInfoEditor(record: current, coverURL: wenkuDownloads.coverURL(for: current)) { title, author, description, cover in
                        try await wenkuDownloads.updateMetadata(id: current.id, title: title, author: author,
                                                          description: description, cover: cover)
                    }
                }
            }
            .sheet(item: $actions.associatingBook) { book in
                if case .wenku(let record) = book.origin {
                    LibraryWenkuAssociationEditor(book: book, record: record)
                }
            }
            .sheet(item: $actions.detailBook) { book in
                LibraryBookDetailView(book: book)
            }
            .sheet(item: $actions.shareArchive, onDismiss: { actions.shareArchive = nil }) { archive in
                LibraryArchiveShareSheet(url: archive.url)
                    .ignoresSafeArea()
            }
            .sheet(item: $actions.shareExport, onDismiss: { actions.dismissExportShare() }) { export in
                LibraryArchiveShareSheet(url: export.url)
                    .ignoresSafeArea()
            }
            .confirmationDialog("《\(actions.missingCloudBook?.title ?? "")》的云端文件缺失",
                                isPresented: .init(get: { actions.missingCloudBook != nil },
                                                   set: { if !$0 { actions.missingCloudBook = nil } }),
                                titleVisibility: .visible,
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
            .confirmationDialog("下载《\(actions.pendingCloudDownload?.title ?? "")》？",
                                isPresented: .init(get: { actions.pendingCloudDownload != nil },
                                                   set: { if !$0 { actions.pendingCloudDownload = nil } }),
                                titleVisibility: .visible,
                                presenting: actions.pendingCloudDownload) { book in
                Button("取消", role: .cancel) { actions.pendingCloudDownload = nil }
                Button("下载") { download(book) }
            } message: { book in
                let size = book.cloudDownloadSizeText.map { "大小约 \($0)。" } ?? "大小未知。"
                Text("这本书只保存在 WebDAV 中，需要先下载到本机才能阅读。\(size)下载会消耗 WebDAV 流量。")
            }
            .overlay {
                if actions.isPreparingArchive {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(NoveliaStyle.brandGreen)
                        Text("正在压缩书籍…").font(.subheadline)
                    }
                    .padding(20)
                    .frame(maxWidth: 240)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge))
                } else if actions.isExportingTXTAsEPUB {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(NoveliaStyle.brandGreen)
                        Text("正在导出 EPUB…").font(.subheadline)
                    }
                    .padding(20)
                    .frame(maxWidth: 240)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge))
                }
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
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge))
                }
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: $actions.isShowingDeleteConfirmation,
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
                let targets = state.booksForDeletion(books, from: state.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks))
                let hiddenCount = targets.count - books.count
                if hiddenCount > 0 {
                    Text("另有 \(hiddenCount) 个合并显示的同内容副本，将一并删除。")
                }
            }
            .alert("新建系列", isPresented: .init(get: { !actions.newSeriesBooks.isEmpty }, set: { if !$0 { actions.newSeriesBooks = [] } })) {
                TextField("系列名称", text: $actions.newSeriesName)
                Button("取消", role: .cancel) { actions.newSeriesBooks = [] }
                Button("创建并移入") {
                    let books = actions.newSeriesBooks
                    if let first = books.first {
                        let id = state.createSeries(named: actions.newSeriesName.isEmpty ? first.title : actions.newSeriesName)
                        books.forEach { assign($0, to: id) }
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
            .safeAreaInset(edge: .bottom) {
                if actions.updatingNovelID != nil {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在获取并更新 EPUB…").font(.subheadline)
                        Spacer()
                        Button("取消") { actions.epubUpdateTask?.cancel() }
                    }
                    .padding(12)
                    .background(.regularMaterial)
                } else if let progress = actions.deletionProgress {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(progress).font(.subheadline)
                        Spacer()
                    }
                    .padding(12)
                    .background(.regularMaterial)
                } else if let message = actions.cloudDeleteError {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("云端尚未删除").font(.subheadline.bold())
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("重试") {
                            let keys = actions.failedCloudDeleteKeys
                            actions.isRetryingCloudDelete = true
                            actions.deletionProgress = "正在删除云端书目…"
                            Task {
                                defer { actions.deletionProgress = nil; actions.isRetryingCloudDelete = false }
                                await deleteCloudCopies(keys)
                            }
                        }
                        .disabled(actions.isRetryingCloudDelete)
                        Button {
                            actions.cloudDeleteError = nil
                        } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭云端删除提示")
                    }
                    .padding(12)
                    .background(.regularMaterial)
                }
            }
            .confirmationDialog("更新到最新章节？", isPresented: .init(get: { actions.pendingEPUBUpdate != nil },
                set: { if !$0 { actions.pendingEPUBUpdate = nil } }), titleVisibility: .visible,
                presenting: actions.pendingEPUBUpdate) { book in
                Button(book.epubUpdateConfiguration == nil ? "选择语言和译源" : "重新获取并更新 EPUB") { updateEPUB(book) }
            } message: { book in
                if book.epubUpdateConfiguration == nil {
                    Text("这本书缺少历史下载设置，下一步请选择语言模式和译源。确认后才会下载，取消不会修改原书。")
                } else {
                Text("将按原来的\(book.resolvedDownloadMode.title)模式和译源重新获取整本 EPUB，成功后替换本机旧文件；失败或取消会保留旧文件。阅读位置和书签按章节路径尝试承接，目录被改动时可能需要重新定位。更新后可再进行 WebDAV 同步。")
                }
            }
            .confirmationDialog("从 WebDAV 获取新版 EPUB？", isPresented: .init(get: { actions.pendingCloudEPUBUpdate != nil },
                set: { if !$0 { actions.pendingCloudEPUBUpdate = nil } }), titleVisibility: .visible,
                presenting: actions.pendingCloudEPUBUpdate) { book in
                Button("取回云端 EPUB 并合并进度、书签") { updateEPUBFromCloud(book) }
            } message: { _ in
                Text("请先在持有新版的设备上同步。将使用 WebDAV 保存的 EPUB、译源及语言模式，成功后替换本机旧版，按章节路径承接本机状态并合并云端进度和书签。更新后再手动同步一次，把本机承接的状态传回其他设备。")
            }
            .alert("EPUB 更新", isPresented: .init(get: { actions.epubUpdateMessage != nil },
                set: { if !$0 { actions.epubUpdateMessage = nil } })) {
                Button("好", role: .cancel) { actions.epubUpdateMessage = nil }
            } message: { Text(actions.epubUpdateMessage ?? "") }
            .alert("操作失败", isPresented: .init(get: { actions.actionError != nil }, set: { if !$0 { actions.actionError = nil } })) {
                Button("好", role: .cancel) { actions.actionError = nil }
            } message: {
                Text(actions.actionError ?? "")
            }
    }

    /// 移入系列前把单书键下的人物卡迁移到系列 ID，避免“AI 人物词条”生成的卡片在移入系列后不可见。
    private func assign(_ book: LibraryBook, to seriesID: String) {
        try? readerSettings.characters.migrateWork(from: book.key, to: seriesID)
        state.assign(book, to: seriesID)
    }

    /// 书籍“更多”菜单发起的 AI 人物词条：已在系列中的书沿用系列 ID 与全部成员；未入系列的书以书键作 work。
    @ViewBuilder
    private func characterEntry(for book: LibraryBook) -> some View {
        if let series = state.series.seriesID(forBook: book.key) {
            let keys = state.series.bookKeys(inSeries: series)
            CharacterSeriesView(workID: series,
                books: state.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks).filter { keys.contains($0.key) },
                store: readerSettings.characters, ai: services.readingAI, initialBook: book.key)
        } else {
            CharacterSeriesView(workID: book.key, books: [book], store: readerSettings.characters, ai: services.readingAI, initialBook: book.key)
        }
    }

    private func updateEPUB(_ book: DownloadedWebNovel, configuration: WebNovelEPUBUpdateConfiguration? = nil) {
        actions.pendingEPUBUpdate = nil
        if configuration == nil && book.epubUpdateConfiguration == nil { actions.updateConfigurationBook = book; return }
        guard actions.updatingNovelID == nil else { return }
        actions.updatingNovelID = book.id
        actions.epubUpdateTask = Task {
            defer { actions.updatingNovelID = nil; actions.epubUpdateTask = nil }
            do {
                let changed = try await webDownloads.updateEPUB(book, configuration: configuration)
                actions.epubUpdateMessage = changed
                    ? "已获取网站当前可下载的 EPUB 并替换本机旧版。书库中的系列归属保留；已确认章节的阅读状态保留；未核对的旧书可在阅读器“章节同步与更新”中核对。可手动同步到 WebDAV。"
                    : "下载文件与本机内容完全相同，已保留原文件和下载时间。"
            } catch is CancellationError {
                actions.epubUpdateMessage = "已取消更新，原书籍文件保留。"
            } catch {
                actions.actionError = "EPUB 更新失败：\(error.localizedDescription) 原书籍未被本次更新替换。"
            }
        }
    }

    private func updateEPUBFromCloud(_ book: DownloadedWebNovel) {
        actions.pendingCloudEPUBUpdate = nil
        guard actions.updatingNovelID == nil else { return }
        actions.updatingNovelID = book.id
        actions.epubUpdateTask = Task {
            defer { actions.updatingNovelID = nil; actions.epubUpdateTask = nil }
            do {
                let result = try await syncStore.updateWebNovelEPUBFromCloud(book, web: webDownloads)
                switch result {
                case .updated:
                    actions.epubUpdateMessage = "已取回 WebDAV 保存的新版 EPUB，并合并云端进度、书签。已保留已确认章节的本机状态；打开后可核对新版章节。请再手动同步一次，把结果传回云端。"
                case .alreadyCurrent:
                    actions.epubUpdateMessage = "本机与 WebDAV 的 EPUB 内容一致，已合并云端进度和书签；可再手动同步本机的新修改。"
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    actions.epubUpdateMessage = "已取消取回云端 EPUB，未以本次下载替换旧书。"
                } else {
                    actions.actionError = "从 WebDAV 更新失败：\(error.localizedDescription) 未以本次下载替换旧书。"
                }
            }
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
        guard actions.deletionProgress == nil else { return }
        guard !books.isEmpty else {
            actions.actionError = "未能取得待删除的书籍，请重新选择。"
            return
        }
        let targets = state.booksForDeletion(books, from: state.books(web: webDownloads, wenku: wenkuDownloads, cloud: syncStore.cloudBooks))
        actions.deletionProgress = "正在删除本机书籍…"
        actions.pendingDelete = []
        actions.endSelection()
        Task {
            defer { actions.deletionProgress = nil }
            do {
                for book in targets where !book.isCloudOnly {
                    switch book.origin {
                    case .webNovel(let record): try await webDownloads.remove(record)
                    case .wenku(let record): try await wenkuDownloads.remove(record)
                    }
                }
            } catch {
                actions.actionError = "本机删除未完成，未成功删除的书目与文件已保留，请重试。"
                return
            }
            guard fromCloud else { return }
            actions.deletionProgress = "正在删除云端书目…"
            await deleteCloudCopies(Set(targets.map(\.key)))
        }
    }

    private func deleteCloudCopies(_ keys: Set<String>) async {
        guard !keys.isEmpty else { return }
        do {
            try await syncStore.deleteFromCloud(keys: keys)
            state.forget(keys: keys)
            actions.failedCloudDeleteKeys.subtract(keys)
            if actions.failedCloudDeleteKeys.isEmpty { actions.cloudDeleteError = nil }
        } catch {
            actions.failedCloudDeleteKeys.formUnion(keys)
            actions.cloudDeleteError = "\(error.localizedDescription) 云端书目仍保留，可重试或稍后在书籍菜单中删除。"
        }
    }
}
