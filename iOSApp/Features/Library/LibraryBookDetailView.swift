import SwiftUI
import UIKit

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
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var statisticsStore: ReadingStatisticsStore
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var cloudBooks: CloudBookStore
    @State private var isShowingCompletionCard = false
    @State private var isShowingPreviousVolumeRecap = false

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
        let bookStatus = state.bookStatus(for: book)
        return Form {
                Section {
                    bookHeroCard(status: status, bookStatus: bookStatus)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                Section("书籍") {
                    CompatLabeledContent("来源", value: book.categoryTitle)
                    if case .wenku(let record) = book.origin {
                        CompatLabeledContent("文库作品", value: record.parentWenkuTitle ?? "未关联")
                        CompatLabeledContent("分卷", value: record.volumeID ?? "未关联")
                    }
                    CompatLabeledContent("系列", value: state.seriesName(for: book) ?? "未分组")
                    if book.coverURL != nil {
                        Picker("封面显示", selection: Binding(
                            get: { state.coverFitMode(for: book) },
                            set: { state.setCoverFitMode($0, for: book) }
                        )) {
                            ForEach(LibraryBookCoverFitMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    CompatLabeledContent("字数", value: wordCounts.total(hash: hash).map(BookWordCount.format) ?? "正在统计…")
                }
                Section("阅读") {
                    Picker("阅读分类", selection: Binding(
                        get: { state.bookStatus(for: book) },
                        set: { state.setBookStatus($0, for: book) }
                    )) {
                        ForEach(LibraryBookStatus.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                    CompatLabeledContent("进度", value: status.detail)
                    CompatLabeledContent("最近阅读", value: status.lastReadAt.map { Self.dateFormatter.string(from: $0) } ?? "尚未阅读")
                    Button {
                        isShowingCompletionCard = true
                    } label: {
                        Label("生成阅读完读卡", systemImage: "sparkles.rectangle.stack")
                    }
                    if let previousVolume {
                        Button {
                            isShowingPreviousVolumeRecap = true
                        } label: {
                            HStack(spacing: 8) {
                                Label("回顾上一卷", systemImage: "clock.arrow.circlepath")
                                Spacer()
                                Text(previousVolume.title)
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    NavigationLink {
                        WorldviewLexiconView(
                            workID: worldviewWorkID,
                            workTitle: worldviewWorkTitle,
                            books: worldviewBooks,
                            initialBookKey: book.key,
                            store: readerSettings.worldview,
                            ai: services.readingAI
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Label("世界观词条", systemImage: "globe.asia.australia")
                            Spacer()
                            let entryCount = readerSettings.worldview.count(for: worldviewWorkID)
                            if entryCount > 0 {
                                Text("\(entryCount) 条")
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                        }
                    }
                }
                Section("文件") {
                    CompatLabeledContent("导入时间", value: Self.dateFormatter.string(from: book.importedAt))
                    CompatLabeledContent("本机文件", value: localFileText)
                    CompatLabeledContent("云端", value: cloudStateText)
                }
            }
            .compatScrollContentBackgroundHidden()
            .background(NoveliaStyle.paper.ignoresSafeArea())
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
            .sheet(isPresented: $isShowingCompletionCard) {
                LibraryCompletionCardSheet(
                    book: book,
                    hash: hash,
                    readingStatus: status,
                    bookStatus: state.bookStatus(for: book),
                    coverFitMode: state.coverFitMode(for: book),
                    wordCount: wordCounts.total(hash: hash),
                    statistics: statisticsStore.statistics.books[book.key],
                    annotations: bookAnnotations
                )
            }
            .sheet(isPresented: $isShowingPreviousVolumeRecap) {
                if let previousVolume {
                    PreviousVolumeRecapSheet(
                        previousBook: previousVolume,
                        currentBookTitle: book.title,
                        store: readerSettings.recaps,
                        ai: services.readingAI
                    )
                }
            }
    }

    private func bookHeroCard(status: LibraryReadingStatus, bookStatus: LibraryBookStatus) -> some View {
        let shape = RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                LibraryCoverView(
                    book: book,
                    width: 88,
                    height: 122,
                    elevated: true,
                    fitMode: state.coverFitMode(for: book)
                )
                VStack(alignment: .leading, spacing: 7) {
                    Text(book.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(book.author.isEmpty ? "未知作者" : book.author)
                        .font(.subheadline)
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(book.format.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                        Label(bookStatus.title, systemImage: bookStatus.systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(NoveliaStyle.muted.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.detail)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(NoveliaStyle.muted)
                        if let fraction = status.fraction {
                            let clamped = min(1.0, max(0.0, fraction))
                            GeometryReader { bar in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(NoveliaStyle.muted.opacity(0.16))
                                    if clamped > 0 {
                                        Capsule()
                                            .fill(NoveliaStyle.brandGreen)
                                            .frame(width: max(4, bar.size.width * clamped))
                                    }
                                }
                            }
                            .frame(height: 4)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if embedded {
                BrowseReadingLink(destination: .library(book)) {
                    HStack(spacing: 8) {
                        Image(systemName: "book.fill")
                        Text(status.isUnread ? "开始阅读" : "继续阅读")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        (book.isCloudOnly ? NoveliaStyle.muted.opacity(0.45) : NoveliaStyle.brandGreen),
                        in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-detail-read")
                .disabled(book.isCloudOnly)
            }
        }
        .padding(16)
        .background {
            ZStack {
                NoveliaStyle.card
                if let url = book.coverURL {
                    CoverImage(url: url) { Color.clear }
                        .scaledToFill()
                        .blur(radius: 36)
                        .opacity(0.20)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(.ultraThinMaterial).opacity(0.68)
            }
        }
        .clipShape(shape)
        .overlay(
            shape.stroke(NoveliaStyle.hairline, lineWidth: 0.75)
                .allowsHitTesting(false)
        )
        .shadow(color: NoveliaStyle.cardShadowColor, radius: 8, x: 0, y: 3)
    }

    private var seriesID: String? { state.series.seriesID(forBook: book.key) }

    private var seriesMembers: [LibraryBook] {
        guard let seriesID else { return [book] }
        let keys = state.series.bookKeys(inSeries: seriesID)
        return state.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks)
            .filter { keys.contains($0.key) }
    }

    private var previousVolume: LibraryBook? {
        guard let seriesID else { return nil }
        let members = seriesMembers
        let confirmed = readerSettings.characters.order(work: seriesID)
        guard let prevKey = LibrarySeriesVolumeResolver.previousBookKey(
            for: book.key,
            confirmedOrder: confirmed,
            members: members.map { .init(key: $0.key, title: $0.title) }
        ) else { return nil }
        return members.first { $0.key == prevKey }
    }

    private var worldviewWorkID: String { seriesID ?? book.key }
    private var worldviewWorkTitle: String { state.seriesName(for: book) ?? book.title }
    private var worldviewBooks: [LibraryBook] { seriesID == nil ? [book] : seriesMembers }

    private var bookAnnotations: [ReaderAnnotation] {
        var keys = [book.key]
        if let hash { keys.append(book.positionPrefix + hash) }
        if case .webNovel(let record) = book.origin, record.novel.isRemote,
           let provider = record.novel.providerId, let novel = record.novel.novelId {
            keys.append(WebNovelEPUBContext.key(provider: provider, novel: novel))
        }
        var seen = Set<UUID>()
        var result: [ReaderAnnotation] = []
        for key in keys {
            for item in readerSettings.annotations.annotations(for: key) where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
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

// MARK: - 全书阅读完读卡片

/// 完读分享卡预览与导出：支持浅色书纸／深色墨纸切换与可选摘录，使用 UIGraphicsImageRenderer 跨 iOS 15+ 渲染高清图。
private struct LibraryCompletionCardSheet: View {
    enum CardTheme: String, CaseIterable, Identifiable {
        case paper
        case ink
        var id: String { rawValue }
        var title: String { self == .paper ? "米白书纸" : "夜读墨纸" }
    }

    let book: LibraryBook
    let hash: String?
    let readingStatus: LibraryReadingStatus
    let bookStatus: LibraryBookStatus
    let coverFitMode: LibraryBookCoverFitMode
    let wordCount: Int?
    let statistics: ReadingBookStatistics?
    let annotations: [ReaderAnnotation]

    @Environment(\.dismiss) private var dismiss
    @State private var theme: CardTheme = .paper
    @State private var selectedQuoteID: UUID?
    @State private var loadedCover: UIImage?
    @State private var exportedImage: UIImage?

    private var isCompleted: Bool {
        bookStatus == .completed || (readingStatus.fraction ?? 0) >= 0.98
    }

    private var selectedQuote: String? {
        guard let selectedQuoteID else { return nil }
        return annotations.first(where: { $0.id == selectedQuoteID })?.quote
    }

    private var readingTimeSummary: String? {
        guard let statistics else { return nil }
        let total = statistics.seconds
        guard total >= 60 else { return nil }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let days = statistics.days.values.filter { $0 >= 60 }.count
        let durationText = hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
        return days > 1 ? "\(durationText) · \(days) 天" : durationText
    }

    private var recordDateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let date = readingStatus.lastReadAt ?? Date()
        return formatter.string(from: date)
    }

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    cardPreview
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    Picker("卡片风格", selection: $theme) {
                        ForEach(CardTheme.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)

                    if !annotations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("附带一条本书摘录")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(NoveliaStyle.muted)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    quoteChip(title: "不附带", isSelected: selectedQuoteID == nil) {
                                        selectedQuoteID = nil
                                    }
                                    ForEach(Array(annotations.prefix(12))) { item in
                                        quoteChip(title: quoteChipTitle(item.quote), isSelected: selectedQuoteID == item.id) {
                                            selectedQuoteID = item.id
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    Button {
                        exportedImage = renderCardImage()
                    } label: {
                        Label("分享或保存完读卡", systemImage: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(NoveliaStyle.brandGreen, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("阅读完读卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if selectedQuoteID == nil { selectedQuoteID = annotations.first?.id }
                if let url = book.coverURL {
                    loadedCover = await CoverImageLoader.shared.image(for: url)
                }
            }
            .sheet(isPresented: Binding(get: { exportedImage != nil }, set: { if !$0 { exportedImage = nil } })) {
                if let exportedImage {
                    LibraryShareActivityView(items: [exportedImage])
                }
            }
        }
    }

    private func quoteChipTitle(_ quote: String) -> String {
        guard quote.count > 18 else { return quote }
        return String(quote.prefix(18)) + "…"
    }

    private func quoteChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : NoveliaStyle.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.card)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : NoveliaStyle.hairline, lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
    }

    private var cardPreview: some View {
        let isDark = theme == .ink
        let bg = isDark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.97, green: 0.95, blue: 0.91)
        let fg = isDark ? Color(white: 0.94) : Color(red: 0.14, green: 0.13, blue: 0.12)
        let muted = isDark ? Color(white: 0.62) : Color(red: 0.45, green: 0.43, blue: 0.40)
        let accent = NoveliaStyle.brandGreen

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isCompleted ? "FINISHED READING · 已读完" : "READING RECORD · 阅读记录")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                Spacer()
                Text(recordDateText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(muted)
            }

            HStack(alignment: .top, spacing: 16) {
                LibraryCoverView(book: book, width: 88, height: 124, elevated: false, fitMode: coverFitMode)
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(fg)
                        .lineLimit(3)
                    Text(book.author.isEmpty ? "未知作者" : book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(isCompleted ? "已读完 · 100%" : readingStatus.detail)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(isDark ? 0.22 : 0.12), in: Capsule())
                }
            }

            if let quote = selectedQuote {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(quote)”")
                        .font(.system(size: 13, design: .serif))
                        .foregroundStyle(fg.opacity(0.9))
                        .lineSpacing(4)
                        .lineLimit(4)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fg.opacity(isDark ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 14) {
                if let wordCount {
                    statBadge(label: "全书字数", value: BookWordCount.format(wordCount), fg: fg, muted: muted)
                }
                if let readingTimeSummary {
                    statBadge(label: "阅读时长", value: readingTimeSummary, fg: fg, muted: muted)
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(muted.opacity(0.22))
                .frame(height: 0.5)

            HStack {
                Text("Novelia")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(muted)
                Spacer()
                Text(book.categoryTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(muted.opacity(0.8))
            }
        }
        .padding(22)
        .background(bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(muted.opacity(0.18), lineWidth: 1)
        )
    }

    private func statBadge(label: String, value: String, fg: Color, muted: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(muted)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(fg)
        }
    }

    /// 使用 CoreGraphics / UIKit 渲染高清分享图，iOS 15 与 iOS 17 输出一致。
    private func renderCardImage() -> UIImage {
        let width: CGFloat = 1080
        let hasQuote = selectedQuote != nil
        let height: CGFloat = hasQuote ? 1420 : 1140
        let isDark = theme == .ink
        let bgColor = isDark ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) : UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1)
        let fgColor = isDark ? UIColor(white: 0.94, alpha: 1) : UIColor(red: 0.14, green: 0.13, blue: 0.12, alpha: 1)
        let mutedColor = isDark ? UIColor(white: 0.62, alpha: 1) : UIColor(red: 0.45, green: 0.43, blue: 0.40, alpha: 1)
        let accentColor = UIColor(red: 0.22, green: 0.56, blue: 0.42, alpha: 1)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            bgColor.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let margin: CGFloat = 48
            let borderRect = CGRect(x: margin, y: margin, width: width - margin * 2, height: height - margin * 2)
            let borderPath = UIBezierPath(roundedRect: borderRect, cornerRadius: 36)
            mutedColor.withAlphaComponent(0.22).setStroke()
            borderPath.lineWidth = 2
            borderPath.stroke()

            let pad: CGFloat = 96
            var y: CGFloat = 104

            let badgeText = isCompleted ? "FINISHED READING · 已读完" : "READING RECORD · 阅读记录"
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: accentColor,
                .kern: 2.0,
            ]
            (badgeText as NSString).draw(at: CGPoint(x: pad, y: y), withAttributes: badgeAttrs)

            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium),
                .foregroundColor: mutedColor,
            ]
            let dateSize = (recordDateText as NSString).size(withAttributes: dateAttrs)
            (recordDateText as NSString).draw(at: CGPoint(x: width - pad - dateSize.width, y: y), withAttributes: dateAttrs)
            y += 96

            let coverRect = CGRect(x: pad, y: y, width: 260, height: 364)
            cg.saveGState()
            UIBezierPath(roundedRect: coverRect, cornerRadius: 20).addClip()
            if let cover = loadedCover {
                let cardFill = isDark ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.93, alpha: 1)
                cardFill.setFill()
                cg.fill(coverRect)
                let drawRect = aspectRect(imageSize: cover.size, in: coverRect, fit: coverFitMode == .fit)
                cover.draw(in: drawRect)
            } else {
                accentColor.withAlphaComponent(0.22).setFill()
                cg.fill(coverRect)
                let fallbackStyle = NSMutableParagraphStyle()
                fallbackStyle.lineBreakMode = .byTruncatingTail
                (book.title as NSString).draw(
                    in: coverRect.insetBy(dx: 24, dy: 30),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                        .foregroundColor: fgColor,
                        .paragraphStyle: fallbackStyle,
                    ]
                )
            }
            cg.restoreGState()

            let textX = coverRect.maxX + 44
            let textW = width - pad - textX
            let titlePara = NSMutableParagraphStyle()
            titlePara.lineSpacing = 8
            titlePara.lineBreakMode = .byTruncatingTail
            let titleRect = CGRect(x: textX, y: y + 8, width: textW, height: 190)
            (book.title as NSString).draw(in: titleRect, withAttributes: [
                .font: UIFont.systemFont(ofSize: 48, weight: .bold),
                .foregroundColor: fgColor,
                .paragraphStyle: titlePara,
            ])

            let author = book.author.isEmpty ? "未知作者" : book.author
            (author as NSString).draw(in: CGRect(x: textX, y: y + 206, width: textW, height: 50), withAttributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .regular),
                .foregroundColor: mutedColor,
            ])

            let statusText = isCompleted ? "已读完 · 100%" : readingStatus.detail
            let statusAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: accentColor,
            ]
            let statusSize = (statusText as NSString).size(withAttributes: statusAttrs)
            let pillRect = CGRect(x: textX, y: y + 290, width: statusSize.width + 44, height: 58)
            accentColor.withAlphaComponent(isDark ? 0.24 : 0.13).setFill()
            UIBezierPath(roundedRect: pillRect, cornerRadius: 29).fill()
            (statusText as NSString).draw(at: CGPoint(x: pillRect.minX + 22, y: pillRect.minY + 11), withAttributes: statusAttrs)

            y = coverRect.maxY + 64

            if let quote = selectedQuote {
                let quoteBox = CGRect(x: pad, y: y, width: width - pad * 2, height: 240)
                fgColor.withAlphaComponent(isDark ? 0.07 : 0.045).setFill()
                UIBezierPath(roundedRect: quoteBox, cornerRadius: 24).fill()
                let quotePara = NSMutableParagraphStyle()
                quotePara.lineSpacing = 12
                quotePara.lineBreakMode = .byTruncatingTail
                ("“\(quote)”" as NSString).draw(in: quoteBox.insetBy(dx: 34, dy: 28), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 34, weight: .regular),
                    .foregroundColor: fgColor.withAlphaComponent(0.92),
                    .paragraphStyle: quotePara,
                ])
                y = quoteBox.maxY + 56
            }

            var statX = pad
            if let wordCount {
                statX = drawStat(label: "全书字数", value: BookWordCount.format(wordCount), at: CGPoint(x: statX, y: y), fg: fgColor, muted: mutedColor)
            }
            if let readingTimeSummary {
                _ = drawStat(label: "阅读时长", value: readingTimeSummary, at: CGPoint(x: statX, y: y), fg: fgColor, muted: mutedColor)
            }

            let footerY = height - 150
            mutedColor.withAlphaComponent(0.24).setFill()
            cg.fill(CGRect(x: pad, y: footerY, width: width - pad * 2, height: 2))
            ("Novelia" as NSString).draw(at: CGPoint(x: pad, y: footerY + 28), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: mutedColor,
            ])
            let catAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                .foregroundColor: mutedColor.withAlphaComponent(0.8),
            ]
            let catSize = (book.categoryTitle as NSString).size(withAttributes: catAttrs)
            (book.categoryTitle as NSString).draw(at: CGPoint(x: width - pad - catSize.width, y: footerY + 30), withAttributes: catAttrs)
        }
    }

    private func drawStat(label: String, value: String, at origin: CGPoint, fg: UIColor, muted: UIColor) -> CGFloat {
        (label as NSString).draw(at: origin, withAttributes: [
            .font: UIFont.systemFont(ofSize: 26, weight: .regular),
            .foregroundColor: muted,
        ])
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: fg,
        ]
        (value as NSString).draw(at: CGPoint(x: origin.x, y: origin.y + 38), withAttributes: valAttrs)
        let width = max((label as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 26)]).width,
                        (value as NSString).size(withAttributes: valAttrs).width)
        return origin.x + width + 72
    }

    private func aspectRect(imageSize: CGSize, in container: CGRect, fit: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let sx = container.width / imageSize.width
        let sy = container.height / imageSize.height
        let scale = fit ? min(sx, sy) : max(sx, sy)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(
            x: container.midX - w / 2,
            y: container.midY - h / 2,
            width: w,
            height: h
        )
    }
}

private struct LibraryShareActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
