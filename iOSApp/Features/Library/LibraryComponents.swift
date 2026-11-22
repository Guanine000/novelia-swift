import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct FeaturedNovelCard: View {
    let novel: Novel

    var body: some View {
        HStack(spacing: 15) {
            BookCover(novel: novel, width: 82, height: 112)
            VStack(alignment: .leading, spacing: 7) {
                Text(novel.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineLimit(2)
                Text(novel.author)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted)
                Text(novel.summary)
                    .font(NoveliaStyle.fontFootnote)
                    .lineLimit(2)
                    .lineSpacing(3)
                    .foregroundStyle(NoveliaStyle.muted)
                Text(novel.genres.joined(separator: "  ·  "))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.accent(for: novel.accent))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
    }
}

struct NovelRow: View {
    let novel: Novel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCover(novel: novel, width: 56, height: 78)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(novel.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(novel.author)
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(metadata(for: novel))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(minHeight: 78, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.45))
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoveliaStyle.hairline)
                .frame(height: 0.5)
                .padding(.leading, 70)
                .allowsHitTesting(false)
        }
    }

    private func metadata(for novel: Novel) -> String {
        let detail: String
        if let totalCharacters = novel.totalCharacters, totalCharacters > 0 {
            detail = "\(totalCharacters.formatted()) 字"
        } else if !novel.chapters.isEmpty {
            detail = "\(novel.chapters.count) 章"
        } else {
            detail = novel.genres.first ?? "小说"
        }
        if let genre = novel.genres.first, detail != genre {
            return "\(detail)  ·  \(genre)"
        }
        return detail
    }
}

struct BookCover: View {
    let novel: Novel
    var width: CGFloat = 74
    var height: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [NoveliaStyle.accent(for: novel.accent), NoveliaStyle.accent(for: novel.accent).opacity(0.72), NoveliaStyle.ink.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(.white.opacity(0.11))
                .frame(width: width * 0.85)
                .offset(x: width * 0.42, y: -height * 0.48)
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: novel.accent == .ocean ? "water.waves" : "moon.stars.fill")
                    .font(.system(size: max(10, width * 0.16), weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 2)
                Text(novel.title)
                    .font(.system(size: max(9, width * 0.155), weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
            }
            .padding(.leading, max(8, width * 0.14))
            .padding(.trailing, max(6, width * 0.10))
            .padding(.vertical, max(7, height * 0.10))
        }
        .frame(width: width, height: height)
        .noveliaBookCoverStyle(cornerRadius: NoveliaStyle.radiusSmall, elevated: false)
        .accessibilityLabel("\(novel.title) 封面")
    }
}


// MARK: - 书库书籍行、网格与通用控件

/// 每个 ForEach 元素只返回一行，使 List 能按书籍标识复用行，避免遍历多行子视图。
/// 点击整行打开阅读；“更多”菜单提供系列、导出、移动和删除。
struct LibraryBookRow: View {
    @Environment(\.browseSelection) private var browseSelection
    @Environment(\.browseSelectedID) private var browseSelectedID
    @EnvironmentObject private var dragFrames: LibrarySelectionFrames
    let book: LibraryBook
    /// 只用于触发弹窗，不观察其变化，弹窗状态改变时列表行不必重算。
    let actions: LibraryBookActions
    let open: (LibraryBook) -> Void
    /// 多选状态由页面传入：多选时点击切换选择，长按进入多选。
    var isSelecting = false
    var isSelected = false
    /// 在「全部」或搜索结果中展示阅读状态小标签。
    var showStatusBadge = false

    @EnvironmentObject private var state: LibraryStateStore

    var body: some View {
        let hash = state.hashByBook[book.key] ?? book.cloudFileHash
        let isSplitSelected = !isSelecting && browseSelectedID == "library:" + book.key
        HStack(alignment: .top, spacing: 6) {
            LibraryBookRowContent(book: book, status: state.status(for: book),
                                  bookStatus: showStatusBadge ? state.bookStatus(for: book) : nil,
                                  coverFitMode: state.coverFitMode(for: book),
                                  hash: hash)
                .contentShape(Rectangle())
                // 点击负责打开或切换选择；页面的长按桥接负责连续拖选。
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { dragFrames.frames[book.key] = geometry.frame(in: .global) }
                        .onValueChange(of: geometry.frame(in: .global)) { _, frame in dragFrames.frames[book.key] = frame }
                        .onDisappear { dragFrames.frames[book.key] = nil }
                })
                .onTapGesture {
                    if isSelecting { actions.toggleSelection(book) }
                    else if let browseSelection, !book.isCloudOnly { browseSelection(.library(book)) }
                    else { open(book) }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isSelecting ? "切换选择" : (browseSelection == nil ? "打开阅读" : "查看书籍详情"))
                .accessibilityAction(named: "多选") { actions.beginSelection(with: book) }
                .accessibilityIdentifier("library-book-\(book.key)")
                .hoverEffect(.highlight)
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                    .frame(width: 40, height: 78)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.toggleSelection(book) }
                    .accessibilityLabel(isSelected ? "已选择：\(book.title)" : "未选择：\(book.title)")
                    .accessibilityAddTraits(.isButton)
            } else {
                Menu {
                    menuItems(for: book)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.muted.opacity(0.75))
                        .frame(width: 36, height: 34, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作：\(book.title)")
                .hoverEffect(.highlight)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isSplitSelected ? 10 : 0)
        .background {
            if isSplitSelected {
                RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                    .fill(NoveliaStyle.brandGreen.opacity(0.09))
            }
        }
        .overlay(alignment: .bottom) {
            if !isSplitSelected {
                Rectangle()
                    .fill(NoveliaStyle.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 72)
                    .allowsHitTesting(false)
            }
        }
        .pointerBookMenu { if !isSelecting { menuItems(for: book) } }
        .accessibilityAddTraits(isSplitSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func menuItems(for book: LibraryBook) -> some View {
        LibraryBookMenuItems(book: book, actions: actions, open: open)
    }
}

/// 书籍的“更多”操作：列表行的菜单与封面网格的长按菜单共用同一套项目。
struct LibraryBookMenuItems: View {
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var readerSettings: ReaderSettings
    let book: LibraryBook
    let actions: LibraryBookActions
    let open: (LibraryBook) -> Void

    var body: some View {
        let currentSeries = state.series.seriesID(forBook: book.key)
        let currentStatus = state.bookStatus(for: book)
        Button { actions.detailBook = book } label: {
            Label("显示详细信息", systemImage: "info.circle")
        }
        Divider()
        if case .wenku(let record) = book.origin, let parent = record.parentWenkuID {
            Button {
                actions.wenkuDetail = WenkuNovelOutline(id: parent, title: record.parentWenkuTitle ?? book.title)
            } label: { Label("查看文库详情", systemImage: "info.circle") }
        }
        if book.isCloudOnly {
            Button { open(book) } label: {
                Label(book.cloudDownloadSizeText.map { "下载（\($0)）" } ?? "下载", systemImage: "icloud.and.arrow.down")
            }
        } else {
            Button { open(book) } label: { Label("阅读", systemImage: "book") }
        }
        Button { actions.characterBook = book } label: {
            Label("AI 人物词条", systemImage: "person.text.rectangle")
        }
        Divider()
        Menu {
            ForEach(LibraryBookStatus.allCases) { status in
                Button {
                    state.setBookStatus(status, for: book)
                } label: {
                    if currentStatus == status {
                        Label(status.title, systemImage: "checkmark")
                    } else {
                        Label(status.title, systemImage: status.systemImage)
                    }
                }
            }
        } label: {
            Label("阅读状态：\(currentStatus.title)", systemImage: currentStatus.systemImage)
        }
        if case .wenku = book.origin, !book.isCloudOnly {
            Button { actions.editingBook = book } label: {
                Label("编辑信息", systemImage: "pencil")
            }
        }
        Menu {
            ForEach(state.series.activeSeries.filter { $0.id != currentSeries }) { series in
                Button(series.name) { assign(book, to: series.id) }
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
            Button { assign(book, to: nil) } label: {
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

    /// 移入系列前把单书键下的人物卡迁移到系列 ID；移出单书系列时回迁，避免卡片"消失"。
    private func assign(_ book: LibraryBook, to seriesID: String?) {
        if let seriesID {
            try? readerSettings.characters.migrateWork(from: book.key, to: seriesID)
        } else if let current = state.series.seriesID(forBook: book.key),
                  state.series.bookKeys(inSeries: current) == [book.key] {
            try? readerSettings.characters.migrateWork(from: current, to: book.key)
        }
        state.assign(book, to: seriesID)
    }

    @ViewBuilder
    private func localFileItems(for book: LibraryBook) -> some View {
        Divider()
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
            Button { actions.associatingBook = book } label: {
                Label("关联文库作品／分卷", systemImage: "link")
            }
            Button {
                Task {
                    do { try await LibraryMover.moveToNetwork(record, web: webDownloads, wenku: wenkuDownloads, state: state) }
                    catch { actions.actionError = error.localizedDescription }
                }
            } label: {
                Label("移至网络小说", systemImage: "arrow.right.arrow.left")
            }
        }
        if case .webNovel(let record) = book.origin, record.novel.isRemote, record.resolvedFileFormat == .epub {
            Divider()
            Menu {
                Button { actions.chapterUpdateBook = record } label: {
                    Label("章节同步与更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Button { actions.pendingEPUBUpdate = record } label: {
                    Label("更新到最新章节", systemImage: "arrow.clockwise")
                }
                .disabled(actions.updatingNovelID != nil || webDownloads.progress[record.id] != nil)
                Button { actions.pendingCloudEPUBUpdate = record } label: {
                    Label("从 WebDAV 获取新版 EPUB", systemImage: "icloud.and.arrow.down")
                }
                .disabled(actions.updatingNovelID != nil || webDownloads.progress[record.id] != nil)
            } label: {
                Label("同步与更新", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        if book.format == .txt {
            Button {
                actions.exportTXTAsEPUB(book, settings: readerSettings)
            } label: {
                Label("导出为 EPUB", systemImage: "doc.badge.plus")
            }
            .disabled(actions.isExportingTXTAsEPUB)
        }
        Divider()
        CompatShareLink(item: book.fileURL) {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) { actions.pendingDelete = [book] } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

/// 书库封面网格：三列自适应封面，点击打开（多选时切换选择），长按显示与列表相同的操作菜单。
struct LibraryBooksGrid: View {
    let books: [LibraryBook]
    let actions: LibraryBookActions
    let open: (LibraryBook) -> Void
    var isSelecting = false
    var selectedKeys = Set<String>()

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(books) { book in
                LibraryBookGridCell(book: book, actions: actions, open: open,
                                    isSelecting: isSelecting,
                                    isSelected: selectedKeys.contains(book.key))
                    .id(book.key)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct LibraryBookGridCell: View {
    @Environment(\.browseSelection) private var browseSelection
    @Environment(\.browseSelectedID) private var browseSelectedID
    @EnvironmentObject private var state: LibraryStateStore
    let book: LibraryBook
    let actions: LibraryBookActions
    let open: (LibraryBook) -> Void
    var isSelecting = false
    var isSelected = false

    var body: some View {
        // 使用无预览的菜单，长按只展开操作，不抬起封面或捕获网格快照。
        Menu {
            LibraryBookMenuItems(book: book, actions: actions, open: open)
        } label: {
            cellContent
                .contentShape(Rectangle())
        } primaryAction: {
            activate()
        }
        .overlay(RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall).stroke(
            !isSelecting && browseSelectedID == "library:" + book.key ? NoveliaStyle.brandGreen : .clear, lineWidth: 2))
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title)，\(book.author)，\(state.status(for: book).detail)")
        .accessibilityHint(isSelecting ? "切换选择" : (browseSelection == nil ? "打开阅读" : "查看书籍详情"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(!isSelecting && browseSelectedID == "library:" + book.key ? .isSelected : [])
        .accessibilityIdentifier("library-book-\(book.key)")
        .hoverEffect(.highlight)
    }

    private func activate() {
        if isSelecting { actions.toggleSelection(book) } else if let browseSelection, !book.isCloudOnly { browseSelection(.library(book)) }
        else { open(book) }
    }

    @ViewBuilder
    private var cellContent: some View {
        let status = state.status(for: book)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottom) {
                    LibraryCoverView(book: book, width: nil, height: nil, elevated: false, fitMode: state.coverFitMode(for: book))
                        .equatable()
                    if let fraction = status.fraction, fraction > 0.005 {
                        Capsule()
                            .fill(Color.black.opacity(0.28))
                            .overlay {
                                Capsule()
                                    .fill(NoveliaStyle.brandGreen)
                                    .scaleEffect(x: min(1, max(0, fraction)), y: 1, anchor: .leading)
                            }
                            .frame(height: 3.5)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                    }
                }
                .aspectRatio(96.0 / 134.0, contentMode: .fit)
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                        .background(Circle().fill(NoveliaStyle.paper))
                        .offset(x: 4, y: -4)
                } else if book.cloudFileMissing {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(NoveliaStyle.warning, in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .offset(x: 3, y: -3)
                        .accessibilityLabel("云端文件缺失")
                } else if book.isCloudOnly {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .offset(x: 3, y: -3)
                        .accessibilityLabel("未下载")
                }
            }
            .frame(maxWidth: .infinity)

            Text(book.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 34, alignment: .topLeading)
            Text(status.detail)
                .font(NoveliaStyle.fontMicro)
                .foregroundStyle(status.isUnread ? NoveliaStyle.muted : NoveliaStyle.brandGreen)
                .lineLimit(1)
        }
    }
}

/// 叶子视图独立订阅字数统计，避免单本书字数回填时触发整行封面与菜单重绘。
private struct LibraryBookMetaText: View {
    let book: LibraryBook
    let hash: String?
    @EnvironmentObject private var wordCounts: LibraryWordCountStore

    private var metaLine: String {
        var parts = [book.format.title]
        if let wordCount = wordCounts.total(hash: hash) {
            parts.append(BookWordCount.format(wordCount))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Text(metaLine)
            .lineLimit(1)
            .onAppear { if let hash { wordCounts.request(book, hash: hash) } }
            .onValueChange(of: hash) { _, hash in if let hash { wordCounts.request(book, hash: hash) } }
            .onDisappear { if let hash { wordCounts.cancel(hash: hash) } }
    }
}

private struct LibraryBookRowContent: View {
    let book: LibraryBook
    let status: LibraryReadingStatus
    /// 传入时在元信息栏展示阅读分类标签（用于“全部”视图与搜索结果）。
    var bookStatus: LibraryBookStatus? = nil
    var coverFitMode: LibraryBookCoverFitMode = .fill
    let hash: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LibraryCoverView(book: book, width: 56, height: 78, fitMode: coverFitMode)
                .equatable()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(book.author.isEmpty ? "未知作者" : book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        if book.cloudFileMissing {
                            Image(systemName: "exclamationmark.icloud.fill")
                                .foregroundStyle(NoveliaStyle.warning)
                                .accessibilityLabel("云端文件缺失")
                        } else if book.isCloudOnly {
                            Image(systemName: "icloud")
                                .foregroundStyle(NoveliaStyle.muted)
                                .accessibilityLabel("未下载")
                        }
                        LibraryBookMetaText(book: book, hash: hash)
                        if let bookStatus {
                            Text(bookStatus.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(bookStatus == .reading ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    (bookStatus == .reading ? NoveliaStyle.brandGreen : NoveliaStyle.muted).opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        Spacer(minLength: 6)
                        Text(status.detail)
                            .font(.system(size: 11, weight: status.isUnread ? .regular : .medium).monospacedDigit())
                            .foregroundStyle(status.isUnread ? NoveliaStyle.muted.opacity(0.8) : NoveliaStyle.brandGreen)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.9))

                    if let fraction = status.fraction, fraction > 0.005 {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .overlay {
                                Capsule()
                                    .fill(NoveliaStyle.brandGreen)
                                    .scaleEffect(x: min(1, max(0, fraction)), y: 1, anchor: .leading)
                            }
                            .frame(height: 2.5)
                    }
                }
            }
            .frame(minHeight: 78, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 封面；缺少封面时按书名哈希生成带书脊与衬线排版的纸质书封面，避免书架出现大片重复图标。
struct LibraryCoverView: View, Equatable {
    let book: LibraryBook
    /// 为 `nil` 时填满父容器，避免在封面网格内为每张卡片套 `GeometryReader`。
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var elevated = false
    var fitMode: LibraryBookCoverFitMode = .fill

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.book.key == rhs.book.key
            && lhs.book.title == rhs.book.title
            && lhs.book.author == rhs.book.author
            && lhs.book.coverURL == rhs.book.coverURL
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.elevated == rhs.elevated
            && lhs.fitMode == rhs.fitMode
    }

    private static let generatedPalettes: [(top: Color, bottom: Color, ink: Color)] = [
        (Color(red: 0.24, green: 0.34, blue: 0.31), Color(red: 0.14, green: 0.21, blue: 0.19), Color(white: 0.95)), // 青瓷深绿
        (Color(red: 0.25, green: 0.31, blue: 0.42), Color(red: 0.15, green: 0.19, blue: 0.28), Color(white: 0.95)), // 靛蓝纸
        (Color(red: 0.44, green: 0.30, blue: 0.27), Color(red: 0.28, green: 0.18, blue: 0.16), Color(white: 0.96)), // 陶土红棕
        (Color(red: 0.36, green: 0.29, blue: 0.40), Color(red: 0.22, green: 0.17, blue: 0.26), Color(white: 0.95)), // 暮紫
        (Color(red: 0.38, green: 0.35, blue: 0.29), Color(red: 0.24, green: 0.22, blue: 0.18), Color(white: 0.95)), // 羊皮褐
        (Color(red: 0.23, green: 0.26, blue: 0.29), Color(red: 0.14, green: 0.16, blue: 0.18), Color(white: 0.94)), // 墨灰
    ]

    private var palette: (top: Color, bottom: Color, ink: Color) {
        let hash = book.title.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Self.generatedPalettes[abs(hash) % Self.generatedPalettes.count]
    }

    private var referenceWidth: CGFloat { width ?? 108 }
    private var referenceHeight: CGFloat { height ?? 150 }

    var body: some View {
        Group {
            if let url = book.coverURL {
                CoverImage(url: url, contentMode: fitMode == .fit ? .fit : .fill) { placeholder }
                    .background(fitMode == .fit ? NoveliaStyle.card : Color.clear)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil)
        .noveliaBookCoverStyle(cornerRadius: NoveliaStyle.radiusSmall, elevated: elevated)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let theme = palette
        let w = referenceWidth
        let h = referenceHeight
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [theme.top, theme.bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 装订线装饰
            Rectangle()
                .fill(theme.ink.opacity(0.18))
                .frame(width: 1)
                .padding(.leading, max(6, w * 0.12))
            VStack(alignment: .leading, spacing: max(2, h * 0.03)) {
                Text(book.title)
                    .font(.system(size: max(8, min(14, w * 0.145)), weight: .semibold, design: .serif))
                    .foregroundStyle(theme.ink)
                    .lineLimit(w < 56 ? 2 : 3)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.75)
                if w >= 62, !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: max(7, min(10, w * 0.10)), weight: .regular))
                        .foregroundStyle(theme.ink.opacity(0.68))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(book.format.title)
                    .font(.system(size: max(7, min(9, w * 0.12)), weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.ink.opacity(0.82))
                    .padding(.horizontal, max(3, w * 0.05))
                    .padding(.vertical, 1.5)
                    .background(theme.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .padding(.leading, max(9, w * 0.18))
            .padding(.trailing, max(5, w * 0.10))
            .padding(.vertical, max(6, h * 0.10))
        }
    }
}

/// 顶部「继续阅读」横向大封面书架：直接展示最近阅读的书籍，与下方极简列表形成视觉层次。
struct LibraryRecentCarousel: View {
    let books: [LibraryBook]
    let open: (LibraryBook) -> Void
    @EnvironmentObject private var state: LibraryStateStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("继续阅读")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NoveliaStyle.ink)
                Spacer()
                if books.count > 1 {
                    Text("最近 \(books.count) 本")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(NoveliaStyle.muted)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(books) { book in
                        let status = state.status(for: book)
                        Button {
                            NoveliaHaptics.light()
                            open(book)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottom) {
                                    LibraryCoverView(book: book, width: 88, height: 124, elevated: false, fitMode: state.coverFitMode(for: book))
                                    if let fraction = status.fraction, fraction > 0.005 {
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.black.opacity(0.32))
                                                .frame(width: 76, height: 3.5)
                                            Capsule()
                                                .fill(NoveliaStyle.brandGreen)
                                                .frame(width: 76 * min(1, max(0, fraction)), height: 3.5)
                                        }
                                        .padding(.bottom, 6)
                                    }
                                }
                                .frame(width: 88, height: 124)

                                Text(book.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(NoveliaStyle.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 88, height: 34, alignment: .topLeading)

                                Text(status.detail)
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(status.isUnread ? NoveliaStyle.muted : NoveliaStyle.brandGreen)
                                    .lineLimit(1)
                                    .frame(width: 88, alignment: .leading)
                            }
                            .frame(width: 88, alignment: .topLeading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("继续阅读 \(book.title)，\(status.detail)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            .frame(height: 192)
        }
    }
}

/// 系列展示所需的只读摘要：共同作者、已读统计、整体进度与续读目标，供系列列表行与详情头卡共用。
struct LibrarySeriesSummary {
    let totalCount: Int
    let completedCount: Int
    let averageProgress: Double
    let primaryAuthor: String?
    let continueBook: LibraryBook?
    let hasStarted: Bool
    let statusLine: String

    @MainActor
    init(books: [LibraryBook], state: LibraryStateStore) {
        totalCount = books.count
        var completed = 0
        var progressSum = 0.0
        var latestBook: LibraryBook?
        var latestDate: Date?
        var latestDetail: String?
        var authorCounts: [String: Int] = [:]

        for book in books {
            let trimmedAuthor = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAuthor.isEmpty {
                authorCounts[trimmedAuthor, default: 0] += 1
            }
            let reading = state.status(for: book)
            let isDone = state.bookStatus(for: book) == .completed || (reading.fraction ?? 0) >= 0.98
            if isDone {
                completed += 1
                progressSum += 1.0
            } else if let fraction = reading.fraction {
                progressSum += min(max(fraction, 0), 1)
            }
            if let date = reading.lastReadAt, latestDate == nil || date > latestDate! {
                latestDate = date
                latestBook = book
                latestDetail = reading.detail
            }
        }

        completedCount = completed
        averageProgress = books.isEmpty ? 0 : progressSum / Double(books.count)
        if let top = authorCounts.max(by: { $0.value < $1.value }), top.value * 2 >= books.count {
            primaryAuthor = top.key
        } else {
            primaryAuthor = nil
        }
        continueBook = latestBook ?? books.first
        hasStarted = latestBook != nil || completed > 0 || progressSum > 0

        if books.isEmpty {
            statusLine = "暂无书籍"
        } else if completed == books.count {
            statusLine = "全部已读"
        } else if let latestBook, let latestDetail {
            statusLine = "最近：\(latestBook.title) · \(latestDetail)"
        } else {
            statusLine = "尚未开始阅读"
        }
    }
}

/// 整齐的阶梯式书封堆叠：底部对齐、向右依次错开，无离屏阴影，用于系列列表行与详情头卡。
struct LibrarySeriesCoverStack: View {
    let books: [LibraryBook]
    var coverWidth: CGFloat = 54
    var coverHeight: CGFloat = 76
    var fixedWidth: Bool = true

    private var extraWidth: CGFloat {
        if fixedWidth { return 16 }
        if books.count > 2 { return 16 }
        if books.count > 1 { return 8 }
        return 0
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if books.count > 2 {
                LibraryCoverView(book: books[2], width: coverWidth * 0.86, height: coverHeight * 0.86, elevated: false)
                    .opacity(0.65)
                    .offset(x: 16)
            }
            if books.count > 1 {
                LibraryCoverView(book: books[1], width: coverWidth * 0.93, height: coverHeight * 0.93, elevated: false)
                    .opacity(0.86)
                    .offset(x: 8)
            }
            if let first = books.first {
                LibraryCoverView(book: first, width: coverWidth, height: coverHeight, elevated: false)
            } else {
                RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                    .fill(NoveliaStyle.brandGreen.opacity(0.10))
                    .frame(width: coverWidth, height: coverHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                            .stroke(NoveliaStyle.hairline, lineWidth: 0.5)
                    )
                    .overlay(
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: coverWidth * 0.34, weight: .medium))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    )
            }
        }
        .frame(width: coverWidth + extraWidth, height: coverHeight, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }
}

struct LibrarySeriesRow: View {
    @EnvironmentObject private var state: LibraryStateStore
    let name: String
    let books: [LibraryBook]

    var body: some View {
        let summary = LibrarySeriesSummary(books: books, state: state)
        HStack(alignment: .center, spacing: 14) {
            LibrarySeriesCoverStack(books: books, coverWidth: 54, coverHeight: 76)
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Text("共 \(summary.totalCount) 本")
                    if summary.completedCount > 0 {
                        Text("·")
                        Text("已读 \(summary.completedCount) 本")
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    if let author = summary.primaryAuthor {
                        Text("·")
                        Text(author)
                            .lineLimit(1)
                    }
                }
                .font(NoveliaStyle.fontCaption)
                .foregroundStyle(NoveliaStyle.muted)

                Text(summary.statusLine)
                    .font(NoveliaStyle.fontMicro)
                    .foregroundStyle(summary.hasStarted ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                    .lineLimit(1)

                if summary.totalCount > 0 {
                    Capsule()
                        .fill(NoveliaStyle.hairline)
                        .frame(height: 3)
                        .overlay {
                            Capsule()
                                .fill(NoveliaStyle.brandGreen)
                                .scaleEffect(x: min(1, max(0, summary.averageProgress)), y: 1, anchor: .leading)
                        }
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.55))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoveliaStyle.hairline)
                .frame(height: 0.5)
                .padding(.leading, 84)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)，共 \(summary.totalCount) 本，\(summary.statusLine)")
    }
}

/// 系列详情顶部概览卡：展示堆叠封面、作者与进度统计，并提供一键续读、添加书籍与检查新卷快捷入口。
struct LibrarySeriesHeaderCard: View {
    @EnvironmentObject private var state: LibraryStateStore
    let name: String
    let books: [LibraryBook]
    let onContinue: (LibraryBook) -> Void
    let onAddBooks: () -> Void
    let onCheckNewVolumes: () -> Void

    var body: some View {
        let summary = LibrarySeriesSummary(books: books, state: state)
        let stackBooks: [LibraryBook] = {
            guard let lead = summary.continueBook else { return books }
            return [lead] + books.filter { $0.key != lead.key }
        }()
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                LibrarySeriesCoverStack(books: stackBooks, coverWidth: 68, coverHeight: 96, fixedWidth: false)
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(2)

                    if let author = summary.primaryAuthor {
                        Text(author)
                            .font(NoveliaStyle.fontBody)
                            .foregroundStyle(NoveliaStyle.muted)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Text("共 \(summary.totalCount) 本")
                        Text("·")
                        Text("已读 \(summary.completedCount) 本")
                        if summary.totalCount > 0 {
                            Text("·")
                            Text("\(Int((summary.averageProgress * 100).rounded()))%")
                                .foregroundStyle(summary.averageProgress > 0 ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                                .monospacedDigit()
                        }
                    }
                    .font(NoveliaStyle.fontCaption)
                    .foregroundStyle(NoveliaStyle.muted)

                    Capsule()
                        .fill(NoveliaStyle.hairline)
                        .frame(height: 4)
                        .overlay {
                            Capsule()
                                .fill(NoveliaStyle.brandGreen)
                                .scaleEffect(x: min(1, max(0, summary.averageProgress)), y: 1, anchor: .leading)
                        }
                        .padding(.top, 2)

                    Text(summary.statusLine)
                        .font(NoveliaStyle.fontMicro)
                        .foregroundStyle(summary.hasStarted ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                if let target = summary.continueBook {
                    Button { onContinue(target) } label: {
                        Label(summary.hasStarted ? "继续阅读" : "开始阅读", systemImage: "book.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(NoveliaStyle.brandGreen, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onAddBooks) {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onCheckNewVolumes) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .frame(width: 36, height: 36)
                        .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("检查新卷")
            }
        }
        .padding(14)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
        .padding(.vertical, 6)
    }
}

// MARK: - 搜索与排序控件

struct LibrarySearchField: View {
    @Binding var query: String
    let prompt: String
    var focusRequest = 0
    var autoFocus = true
    var isLoading = false
    var onSubmit: () -> Void = {}
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(NoveliaStyle.muted)
                TextField(prompt, text: $query)
                    .textInputAutocapitalization(.never)
                    .compatAutocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        isFocused = false
                        onSubmit()
                    }
                    .focused($isFocused)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(NoveliaStyle.muted)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 11)
            .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 13))
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .hoverEffect(.highlight)
                .frame(minWidth: 44, minHeight: 44)
                .tint(NoveliaStyle.brandGreen)
        }
        .onAppear {
            if autoFocus { isFocused = true }
        }
        .onValueChange(of: focusRequest) { _, _ in isFocused = true }
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
struct LibrarySortSummary: View {
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

extension View {
    /// 书库列表行：透明行背景、无分隔线，卡片间距由上下内边距形成。
    func libraryListRow() -> some View {
        frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    /// 使用 List 而非 ScrollView + LazyVStack：List 复用行视图，书多时滚动不再逐行重建。
    func libraryListStyle() -> some View {
        listStyle(.plain)
            .compatScrollContentBackgroundHidden()
    }
}

// MARK: - 书架更新检查状态与展示

/// 书架批量检查网络小说更新的界面状态对象；仅调用注入的 `NovelCatalogService`，
/// 不直接引用具体 API 客户端，并在本机持久化最近一次完成检查时间。
@MainActor
final class LibraryShelfUpdateStore: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var summary: ShelfUpdateSummary
    @Published var isBannerVisible = false
    @Published var isShowingDetails = false
    @Published private(set) var isBatchUpdating = false
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchCompleted = 0
    @Published private(set) var batchCurrentTitle: String?
    @Published private(set) var batchFailures: [String: String] = [:]
    @Published private(set) var batchNotice: String?

    private let defaults: UserDefaults
    private static let lastCheckedKey = "library.shelfUpdateLastCheckedAt.v1"
    private var checkTask: Task<Void, Never>?
    private var batchUpdateTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.lastCheckedKey) as? Date
        self.summary = ShelfUpdateSummary(checkedAt: saved)
    }

    func checkableBooks(from books: [DownloadedWebNovel]) -> [DownloadedWebNovel] {
        books.filter { $0.novel.providerId != nil && $0.novel.novelId != nil }
    }

    func startCheck(books: [DownloadedWebNovel], catalog: any NovelCatalogService) {
        let targets = checkableBooks(from: books)
        guard !targets.isEmpty else { return }
        checkTask?.cancel()
        isChecking = true
        isBannerVisible = true
        summary = ShelfUpdateSummary(totalCount: targets.count, completedCount: 0,
                                     updatedBooks: [], failedBooks: [], checkedAt: summary.checkedAt)
        runCheck(targets: targets, catalog: catalog, replacingFailuresOnly: false)
    }

    func retryFailed(books: [DownloadedWebNovel], catalog: any NovelCatalogService) {
        let failedIDs = Set(summary.failedBooks.map(\.bookID))
        let targets = checkableBooks(from: books).filter { failedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        checkTask?.cancel()
        isChecking = true
        isBannerVisible = true
        let keptUpdated = summary.updatedBooks
        summary = ShelfUpdateSummary(totalCount: targets.count, completedCount: 0,
                                     updatedBooks: keptUpdated, failedBooks: [], checkedAt: summary.checkedAt)
        runCheck(targets: targets, catalog: catalog, replacingFailuresOnly: true)
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
    }

    func dismissBanner() {
        isBannerVisible = false
    }

    /// 按既有下载配置顺序批量更新已检出有新章节的网络小说 EPUB；
    /// 缺少历史下载设置的旧书不会猜测配置，跳过并保留在列表中供单本确认。
    func startBatchUpdate(
        booksByID: [String: DownloadedWebNovel],
        updater: @escaping (DownloadedWebNovel) async throws -> Bool
    ) {
        guard !isBatchUpdating, !isChecking else { return }
        let items = summary.updatedBooks
        var runnable: [DownloadedWebNovel] = []
        var skippedMissingConfig = 0
        for item in items {
            guard let record = booksByID[item.bookID], record.resolvedFileFormat == .epub else { continue }
            if record.epubUpdateConfiguration == nil {
                skippedMissingConfig += 1
            } else {
                runnable.append(record)
            }
        }
        batchFailures = [:]
        if runnable.isEmpty {
            if skippedMissingConfig > 0 {
                batchNotice = "有 \(skippedMissingConfig) 本书缺少历史下载配置，请逐本点「更新」选择语言和译源。"
            }
            return
        }
        batchNotice = nil
        isBatchUpdating = true
        batchTotal = runnable.count
        batchCompleted = 0
        batchCurrentTitle = nil
        batchUpdateTask?.cancel()
        batchUpdateTask = Task { [weak self] in
            guard let self else { return }
            var updatedCount = 0
            var unchangedCount = 0
            var failedCount = 0
            var cancelled = false
            for record in runnable {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                self.batchCurrentTitle = record.novel.title
                do {
                    let changed = try await updater(record)
                    if changed { updatedCount += 1 } else { unchangedCount += 1 }
                    self.summary.updatedBooks.removeAll { $0.bookID == record.id }
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    failedCount += 1
                    self.batchFailures[record.id] = error.localizedDescription
                }
                self.batchCompleted += 1
            }
            self.isBatchUpdating = false
            self.batchCurrentTitle = nil
            self.batchUpdateTask = nil
            var parts: [String] = []
            if updatedCount > 0 { parts.append("已更新 \(updatedCount) 本") }
            if unchangedCount > 0 { parts.append("内容未变 \(unchangedCount) 本") }
            if skippedMissingConfig > 0 { parts.append("\(skippedMissingConfig) 本需单本确认下载配置") }
            if failedCount > 0 { parts.append("失败 \(failedCount) 本") }
            if cancelled { parts.append("已停止") }
            self.batchNotice = parts.isEmpty ? nil : parts.joined(separator: "，") + "。"
        }
    }

    func cancelBatchUpdate() {
        batchUpdateTask?.cancel()
        batchUpdateTask = nil
        isBatchUpdating = false
        batchCurrentTitle = nil
    }

    private enum ItemOutcome: Sendable {
        case updated(ShelfUpdateBookResult)
        case upToDate
        case failed(ShelfUpdateFailure)
    }

    private func runCheck(targets: [DownloadedWebNovel], catalog: any NovelCatalogService, replacingFailuresOnly: Bool) {
        let maxConcurrency = 3
        checkTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: ItemOutcome.self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<min(maxConcurrency, targets.count) {
                    if let next = iterator.next() {
                        group.addTask { await Self.checkSingle(next, catalog: catalog) }
                    }
                }
                for await outcome in group {
                    if Task.isCancelled { break }
                    self.summary.completedCount += 1
                    switch outcome {
                    case .updated(let result):
                        if let existingIndex = self.summary.updatedBooks.firstIndex(where: { $0.bookID == result.bookID }) {
                            self.summary.updatedBooks[existingIndex] = result
                        } else {
                            self.summary.updatedBooks.append(result)
                        }
                    case .upToDate:
                        break
                    case .failed(let failure):
                        self.summary.failedBooks.append(failure)
                    }
                    if let next = iterator.next() {
                        group.addTask { await Self.checkSingle(next, catalog: catalog) }
                    }
                }
            }
            let cancelled = Task.isCancelled
            self.isChecking = false
            self.checkTask = nil
            if !cancelled {
                let now = Date()
                self.summary.checkedAt = now
                self.defaults.set(now, forKey: Self.lastCheckedKey)
            }
        }
    }

    private static func checkSingle(_ book: DownloadedWebNovel, catalog: any NovelCatalogService) async -> ItemOutcome {
        guard let provider = book.novel.providerId, let novelID = book.novel.novelId else { return .upToDate }
        do {
            let remote = try await catalog.novel(providerId: provider, novelId: novelID)
            if let diff = ShelfUpdateSummary.diff(local: book, remote: remote) {
                return .updated(diff)
            }
            return .upToDate
        } catch is CancellationError {
            return .upToDate
        } catch {
            return .failed(ShelfUpdateFailure(bookID: book.id, title: book.novel.title, message: error.localizedDescription))
        }
    }
}

/// 书库顶部的更新检查聚合反馈条：展示检查进度、更新本数、失败本数和最近检查时间。
struct LibraryShelfUpdateBanner: View {
    @ObservedObject var store: LibraryShelfUpdateStore
    let onShowDetails: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if store.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: store.summary.updatedBooks.isEmpty
                      ? (store.summary.failedBooks.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                      : "arrow.down.circle.fill")
                    .foregroundStyle(store.summary.updatedBooks.isEmpty
                                     ? (store.summary.failedBooks.isEmpty ? NoveliaStyle.brandGreen : NoveliaStyle.warning)
                                     : NoveliaStyle.brandGreen)
            }
            VStack(alignment: .leading, spacing: 3) {
                if store.isChecking {
                    Text("正在检查书架更新 \(store.summary.completedCount)/\(store.summary.totalCount)")
                        .font(NoveliaStyle.fontBody.weight(.semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                    Text("已发现 \(store.summary.updatedBooks.count) 本更新 · \(store.summary.failedBooks.count) 本失败")
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                } else {
                    Text(completedHeadline)
                        .font(NoveliaStyle.fontBody.weight(.semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                    Text(completedSubtitle)
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                }
            }
            Spacer(minLength: 6)
            if store.isChecking {
                Button("取消") { store.cancel() }
                    .font(NoveliaStyle.fontFootnote.weight(.medium))
                    .buttonStyle(.borderless)
            } else {
                Button("详情") { onShowDetails() }
                    .font(NoveliaStyle.fontFootnote.weight(.semibold))
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .buttonStyle(.borderless)
                Button {
                    store.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭更新提示")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusMedium)
        .accessibilityIdentifier("library-shelf-update-banner")
    }

    private var completedHeadline: String {
        let updated = store.summary.updatedBooks.count
        let failed = store.summary.failedBooks.count
        if updated > 0 {
            return "发现 \(updated) 本书有更新" + (failed > 0 ? "（\(failed) 本失败）" : "")
        }
        if failed > 0 {
            return "检查完成，\(failed) 本失败"
        }
        return "书架已是最新（共检查 \(store.summary.totalCount) 本）"
    }

    private var completedSubtitle: String {
        var parts: [String] = []
        if store.summary.totalCount > 0 {
            parts.append("共 \(store.summary.totalCount) 本")
        }
        if let checkedAt = store.summary.checkedAt {
            parts.append("最近检查 \(Self.timeFormatter.string(from: checkedAt))")
        }
        return parts.joined(separator: " · ")
    }
}

/// 书架更新检查结果详情页：列出有更新的书与失败记录，支持重新检查或重试失败项。
struct LibraryShelfUpdateDetailSheet: View {
    @ObservedObject var store: LibraryShelfUpdateStore
    let booksByID: [String: LibraryBook]
    let onRecheckAll: () -> Void
    let onRetryFailed: () -> Void
    let onBatchUpdateAll: () -> Void
    let onOpenBook: (LibraryBook) -> Void
    let onUpdateBook: (DownloadedWebNovel) -> Void
    let onClose: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        CompatNavigationStack {
            List {
                Section("检查概览") {
                    CompatLabeledContent("检查进度", value: "\(store.summary.completedCount)/\(store.summary.totalCount)")
                    CompatLabeledContent("发现更新", value: "\(store.summary.updatedBooks.count) 本")
                    CompatLabeledContent("检查失败", value: "\(store.summary.failedBooks.count) 本")
                    if let checkedAt = store.summary.checkedAt {
                        CompatLabeledContent("最近检查", value: Self.timeFormatter.string(from: checkedAt))
                    }
                    Button {
                        onRecheckAll()
                    } label: {
                        Label(store.isChecking ? "正在检查…" : "重新检查全部", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isChecking || store.isBatchUpdating)
                }

                if store.isBatchUpdating || store.batchNotice != nil {
                    Section("批量更新") {
                        if store.isBatchUpdating {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("正在更新 \(store.batchCompleted)/\(store.batchTotal)")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                    Spacer()
                                    Button("停止", role: .destructive) {
                                        store.cancelBatchUpdate()
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                                if let title = store.batchCurrentTitle {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .lineLimit(1)
                                }
                                ProgressView(value: Double(store.batchCompleted), total: Double(max(1, store.batchTotal)))
                                    .tint(NoveliaStyle.brandGreen)
                            }
                            .padding(.vertical, 2)
                        }
                        if let notice = store.batchNotice {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                    }
                }

                if !store.summary.updatedBooks.isEmpty {
                    Section("有更新的书籍（\(store.summary.updatedBooks.count)）") {
                        Button {
                            onBatchUpdateAll()
                        } label: {
                            Label("一键更新全部（\(store.summary.updatedBooks.count) 本）", systemImage: "arrow.down.circle.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                        }
                        .disabled(store.isChecking || store.isBatchUpdating)
                        ForEach(store.summary.updatedBooks) { item in
                            HStack(spacing: 10) {
                                Button {
                                    if let book = booksByID[item.bookID] {
                                        onClose()
                                        onOpenBook(book)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(item.title)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(NoveliaStyle.ink)
                                                .lineLimit(1)
                                            Spacer()
                                            Text("+\(item.newChapterCount) 章")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(NoveliaStyle.brandGreen)
                                        }
                                        if let latest = item.latestChapterTitle, !latest.isEmpty {
                                            Text("最新：\(latest)")
                                                .font(.caption)
                                                .foregroundStyle(NoveliaStyle.muted)
                                                .lineLimit(1)
                                        }
                                        if let failure = store.batchFailures[item.bookID] {
                                            Text("更新失败：\(failure)")
                                                .font(.caption)
                                                .foregroundStyle(NoveliaStyle.danger)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                if let book = booksByID[item.bookID],
                                   case .webNovel(let record) = book.origin,
                                   !book.isCloudOnly {
                                    Button("更新") {
                                        onClose()
                                        onUpdateBook(record)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .tint(NoveliaStyle.brandGreen)
                                    .disabled(store.isBatchUpdating)
                                }
                            }
                        }
                    }
                }

                if !store.summary.failedBooks.isEmpty {
                    Section("检查失败（\(store.summary.failedBooks.count)）") {
                        Button {
                            onRetryFailed()
                        } label: {
                            Label("重试失败项", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isChecking)
                        ForEach(store.summary.failedBooks) { failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(NoveliaStyle.ink)
                                Text(failure.message)
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.danger)
                            }
                        }
                    }
                }
            }
            .navigationTitle("书架更新检查")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }
                }
            }
        }
    }
}

// MARK: - Bangumi 风格阅读状态筛选条

/// 书库顶部的五态阅读状态筛选胶囊栏（全部 / 在读 / 想读 / 读过 / 搁置 / 抛弃）。
struct LibraryReadingStatusBar: View {
    @Binding var selection: LibraryBookStatusFilter
    let counts: [LibraryBookStatusFilter: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryBookStatusFilter.allCases) { filter in
                    let isSelected = selection == filter
                    let count = counts[filter] ?? 0
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection = filter
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.title)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            Text("\(count)")
                                .font(.system(size: 11, weight: .medium))
                                .opacity(isSelected ? 0.9 : 0.7)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected ? Color.white : NoveliaStyle.ink)
                        .background(
                            Capsule()
                                .fill(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.paper)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? Color.clear : NoveliaStyle.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.title)，\(count) 本")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 打开阅读
