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
        HStack(spacing: 13) {
            BookCover(novel: novel, width: 61, height: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(novel.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineLimit(2)
                Text(novel.author)
                    .font(NoveliaStyle.fontFootnote)
                    .foregroundStyle(NoveliaStyle.muted)
                Text(metadata(for: novel))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.5))
        }
        .padding(12)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
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

    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var wordCounts: LibraryWordCountStore

    var body: some View {
        let hash = state.hashByBook[book.key] ?? book.cloudFileHash
        let isSplitSelected = !isSelecting && browseSelectedID == "library:" + book.key
        HStack(alignment: .top, spacing: 6) {
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
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        LibraryCoverView(book: book, width: geometry.size.width,
                                         height: geometry.size.height, elevated: false)
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

private struct LibraryBookRowContent: View {
    let book: LibraryBook
    let status: LibraryReadingStatus
    /// 全书字数；尚未统计或无法统计时不显示。
    let wordCount: Int?

    private var metaLine: String {
        var parts = [book.format.title]
        if let wordCount { parts.append(BookWordCount.format(wordCount)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LibraryCoverView(book: book, width: 56, height: 78)
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
                        Text(metaLine)
                            .lineLimit(1)
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
struct LibraryCoverView: View {
    let book: LibraryBook
    var width: CGFloat
    var height: CGFloat
    var elevated = false

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

    var body: some View {
        Group {
            if let url = book.coverURL {
                CoverImage(url: url) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .noveliaBookCoverStyle(cornerRadius: NoveliaStyle.radiusSmall, elevated: elevated)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let theme = palette
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
                .padding(.leading, max(6, width * 0.12))
            VStack(alignment: .leading, spacing: max(2, height * 0.03)) {
                Text(book.title)
                    .font(.system(size: max(8, min(14, width * 0.145)), weight: .semibold, design: .serif))
                    .foregroundStyle(theme.ink)
                    .lineLimit(width < 56 ? 2 : 3)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.75)
                if width >= 62, !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: max(7, min(10, width * 0.10)), weight: .regular))
                        .foregroundStyle(theme.ink.opacity(0.68))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(book.format.title)
                    .font(.system(size: max(7, min(9, width * 0.12)), weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.ink.opacity(0.82))
                    .padding(.horizontal, max(3, width * 0.05))
                    .padding(.vertical, 1.5)
                    .background(theme.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .padding(.leading, max(9, width * 0.18))
            .padding(.trailing, max(5, width * 0.10))
            .padding(.vertical, max(6, height * 0.10))
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
                                    LibraryCoverView(book: book, width: 88, height: 124, elevated: false)
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

struct LibraryContinueReadingCard: View {
    let book: LibraryBook
    let open: () -> Void
    @EnvironmentObject private var state: LibraryStateStore

    var body: some View {
        let status = state.status(for: book)
        let shape = RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
        Button {
            NoveliaHaptics.light()
            open()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                LibraryCoverView(book: book, width: 60, height: 84, elevated: false)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("继续阅读")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        Spacer(minLength: 4)
                        if let lastReadAt = status.lastReadAt {
                            Text(Self.relative(lastReadAt))
                                .font(.system(size: 11))
                                .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.muted.opacity(0.55))
                    }
                    Text(book.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.system(size: 12))
                            .foregroundStyle(NoveliaStyle.muted)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        if let fraction = status.fraction {
                            GeometryReader { bar in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule()
                                        .fill(NoveliaStyle.brandGreen)
                                        .frame(width: bar.size.width * min(1, max(0, fraction)))
                                }
                            }
                            .frame(height: 3)
                        }
                        Text(status.detail)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(NoveliaStyle.muted)
                            .fixedSize()
                    }
                }
                .frame(minHeight: 84, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
            .contentShape(shape)
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
            ZStack(alignment: .bottomLeading) {
                if books.count > 2 {
                    LibraryCoverView(book: books[2], width: 44, height: 62)
                        .rotationEffect(.degrees(7))
                        .opacity(0.55)
                        .offset(x: 16, y: -10)
                }
                if books.count > 1 {
                    LibraryCoverView(book: books[1], width: 46, height: 64)
                        .rotationEffect(.degrees(3.5))
                        .opacity(0.78)
                        .offset(x: 8, y: -5)
                }
                if let first = books.first {
                    LibraryCoverView(book: first, width: 48, height: 66, elevated: false)
                } else {
                    RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                        .fill(NoveliaStyle.brandGreen.opacity(0.12))
                        .frame(width: 48, height: 66)
                        .overlay(Image(systemName: "rectangle.stack").foregroundStyle(NoveliaStyle.brandGreen))
                }
            }
            .frame(width: 68, height: 76, alignment: .bottomLeading)
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
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoveliaStyle.hairline)
                .frame(height: 0.5)
                .padding(.leading, 82)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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

// MARK: - 打开阅读
