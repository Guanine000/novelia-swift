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
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
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
        .padding(13)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 19))
    }
}

struct NovelRow: View {
    let novel: Novel

    var body: some View {
        HStack(spacing: 13) {
            BookCover(novel: novel, width: 61, height: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(novel.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                Text(novel.author)
                    .font(NoveliaStyle.fontFootnote)
                    .foregroundStyle(NoveliaStyle.muted)
                Text(metadata(for: novel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.5))
        }
        .padding(11)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))
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
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium)
                .fill(LinearGradient(
                    colors: [NoveliaStyle.accent(for: novel.accent), NoveliaStyle.ink.opacity(0.95)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: width * 0.8)
                .offset(x: width * 0.42, y: -height * 0.48)
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: novel.accent == .ocean ? "water.waves" : "moon.stars.fill")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
                Text(novel.title)
                    .font(.system(size: max(9, width * 0.16), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
            }
            .padding(width * 0.12)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
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

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var wordCounts: LibraryWordCountStore

    var body: some View {
        let hash = state.hashByBook[book.key] ?? book.cloudFileHash
        HStack(alignment: .center, spacing: 4) {
            LibraryBookRowContent(book: book, status: state.status(for: book),
                                  wordCount: wordCounts.total(hash: hash))
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
                .onAppear { if let hash { wordCounts.request(book, hash: hash) } }
                .onValueChange(of: hash) { _, hash in if let hash { wordCounts.request(book, hash: hash) } }
                .onDisappear { if let hash { wordCounts.cancel(hash: hash) } }
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                    .frame(width: 44, height: 44)
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作：\(book.title)")
                .hoverEffect(.highlight)
            }
        }
        .padding(.leading, 10)
        .padding(.vertical, 8)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(!isSelecting && browseSelectedID == "library:" + book.key ? NoveliaStyle.brandGreen : .clear, lineWidth: 2)
            .allowsHitTesting(false))
        .pointerBookMenu { if !isSelecting { menuItems(for: book) } }
        .accessibilityAddTraits(!isSelecting && browseSelectedID == "library:" + book.key ? .isSelected : [])
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
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { geometry in
                    LibraryCoverView(book: book, width: geometry.size.width,
                                     height: geometry.size.height)
                }
                .aspectRatio(96.0 / 134.0, contentMode: .fit)
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 2)
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                        .background(Circle().fill(NoveliaStyle.paper))
                        .offset(x: 4, y: -4)
                } else if book.cloudFileMissing {
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(NoveliaStyle.warning)
                        .padding(4)
                        .background(Circle().fill(NoveliaStyle.paper))
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("云端文件缺失")
                } else if book.isCloudOnly {
                    Image(systemName: "icloud")
                        .foregroundStyle(NoveliaStyle.muted)
                        .padding(4)
                        .background(Circle().fill(NoveliaStyle.paper))
                        .offset(x: 4, y: -4)
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

private struct LibraryBookRowContent: View {
    let book: LibraryBook
    let status: LibraryReadingStatus
    /// 全书字数；尚未统计或无法统计时不显示。
    let wordCount: Int?

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
                    .font(NoveliaStyle.fontFootnote)
                    .foregroundStyle(NoveliaStyle.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if book.cloudFileMissing {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(NoveliaStyle.warning)
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
                    Text(wordCount.map(BookWordCount.format) ?? "")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status.detail)
                        .foregroundStyle(status.isUnread ? NoveliaStyle.muted : NoveliaStyle.brandGreen)
                }
                .font(NoveliaStyle.fontCaption)
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

struct LibraryContinueReadingCard: View {
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
                            .font(NoveliaStyle.fontFootnote)
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .frame(width: 44, height: 44)
                    .background(NoveliaStyle.brandGreen.opacity(0.10), in: Circle())
            }
            .padding(16)
            .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))
            .overlay(alignment: .leading) {
                Capsule().fill(NoveliaStyle.brandGreen)
                    .frame(width: 3).padding(.vertical, 18)
                    .accessibilityHidden(true)
            }
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

struct LibrarySeriesRow: View {
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
                    .font(NoveliaStyle.fontFootnote)
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
    var focusRequest = 0
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
                    .onSubmit { isFocused = false }
                    .focused($isFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(NoveliaStyle.muted)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
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
        .onAppear { isFocused = true }
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

// MARK: - 打开阅读

/// 沿用原有阅读器：TXT 使用 TXT 阅读器，EPUB 使用 EPUB 阅读器。
struct LibraryReaderDestination: View {
    let book: LibraryBook
    @StateObject private var rules = TXTChapterRuleStore.shared

    var body: some View {
        Group {
        if book.format == .txt {
            DownloadedWebNovelTXTReader(url: book.fileURL, title: book.title, rules: rules.configuration, statisticsID: book.key)
        } else if case .webNovel(let record) = book.origin, record.novel.isRemote {
            WebNovelEPUBReader(book: record)
        } else {
            EPUBReaderHost(initialURL: book.fileURL, statisticsID: book.key, statisticsTitle: book.title)
        }
        }
        .environment(\.speechBookRoute, .library(book.key))
    }
}

// MARK: - 书籍详细信息

/// 书库列表只保留书名、作者、格式与字数；来源、系列、文库分卷、阅读状态和文件信息集中在这里。
struct LibraryBookDetailView: View {
    let book: LibraryBook
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var wordCounts: LibraryWordCountStore

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var hash: String? { state.hashByBook[book.key] ?? book.cloudFileHash }

    var body: some View {
        if embedded { detailContent }
        else { CompatNavigationStack { detailContent } }
    }

    private var detailContent: some View {
        let status = state.status(for: book)
        return Form {
                if embedded {
                    Section {
                        BrowseReadingLink(destination: .library(book)) {
                            Label("阅读本书", systemImage: "book.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("library-detail-read")
                        .disabled(book.isCloudOnly)
                    }
                }
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        LibraryCoverView(book: book, width: 72, height: 100)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.title)
                                .font(.headline)
                                .foregroundStyle(NoveliaStyle.ink)
                            Text(book.author.isEmpty ? "未知作者" : book.author)
                                .font(.subheadline)
                                .foregroundStyle(NoveliaStyle.muted)
                            Text(book.format.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(NoveliaStyle.brandGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
                Section("书籍") {
                    CompatLabeledContent("来源", value: book.categoryTitle)
                    if case .wenku(let record) = book.origin {
                        CompatLabeledContent("文库作品", value: record.parentWenkuTitle ?? "未关联")
                        CompatLabeledContent("分卷", value: record.volumeID ?? "未关联")
                    }
                    CompatLabeledContent("系列", value: state.seriesName(for: book) ?? "未分组")
                    CompatLabeledContent("字数", value: wordCounts.total(hash: hash).map(BookWordCount.format) ?? "正在统计…")
                }
                Section("阅读") {
                    CompatLabeledContent("状态", value: status.detail)
                    CompatLabeledContent("最近阅读", value: status.lastReadAt.map { Self.dateFormatter.string(from: $0) } ?? "尚未阅读")
                }
                Section("文件") {
                    CompatLabeledContent("导入时间", value: Self.dateFormatter.string(from: book.importedAt))
                    CompatLabeledContent("本机文件", value: localFileText)
                    CompatLabeledContent("云端", value: cloudStateText)
                }
            }
            .navigationTitle(embedded ? "书籍详情" : "详细信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if !embedded { Button("完成") { dismiss() } }
                }
            }
            .task {
                if let hash { wordCounts.request(book, hash: hash) }
            }
    }

    private var localFileText: String {
        guard !book.isCloudOnly else { return "仅云端，未下载" }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: book.fileURL.path),
              let size = attributes[.size] as? Int64 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var cloudStateText: String {
        if book.cloudFileMissing { return "云端文件已移除" }
        if book.isCloudOnly { return "仅云端，未下载" }
        return book.cloudFileHash == nil ? "仅本机" : "本机与云端"
    }
}
