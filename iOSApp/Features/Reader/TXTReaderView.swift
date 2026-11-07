import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct DownloadedWebNovelTXTReader: View {
    @EnvironmentObject private var settings: ReaderSettings
    private var fontSize: Double { settings.fontSize }
    @Environment(\.colorScheme) private var systemColorScheme
    let url: URL
    let title: String
    let rules: TXTChapterRuleConfiguration
    var statisticsID: String? = nil
    @State private var chapters: [TXTChapter]?
    @State private var chapterIndex = 0
    /// 加载后的内容哈希，用作阅读位置的键（与分页模式共享）。
    @State private var contentHash: String?
    @State private var bodyChunks: [String] = []
    @State private var bodyChunksChapterIndex: Int?
    @State private var isShowingBookPreferences = false
    @State private var isShowingSearch = false
    @State private var selectedSearchHit: BookTextSearch.Hit?
    @State private var readingReturnPoint: ScrollReadingReturnPoint?
    @State private var visibleAnchor: String?
    @State private var returnAnchor: String?
    @State private var preferenceID: String?
    @State private var isShowingContents = false
    @State private var errorMessage: String?
    /// 目录字数的来源（已解析的书），打开目录时才统计。
    @State private var parsedBook: TXTParsedBook?
    @State private var tocWordCounts: ReaderTOCWordCounts?

    private var appearance: ReaderAppearance {
        settings.appearance
    }

    var body: some View {
        Group {
        if preferenceID == nil { ProgressView("准备阅读偏好…") }
        else if settings.pagedTextReading {
            TXTPagedReader(url: url, title: title, rules: rules, statisticsID: statisticsID)
        } else {
            scrollReader
                .trackReadingTime(ReadingBook(id: statisticsID ?? "txt:\(url.lastPathComponent)", title: title, kind: .txt),
                                  ready: chapters?.indices.contains(chapterIndex) == true && bodyChunksChapterIndex == chapterIndex)
        }
        }
        .task(id: url) {
            let hash = try? await Task.detached { try FileContentHash.sha256(url) }.value
            guard !Task.isCancelled else { return }
            let id = "txt:" + (hash ?? url.lastPathComponent)
            settings.activateBook(id); preferenceID = id
        }
        .onDisappear { if let preferenceID { settings.deactivateBook(preferenceID) } }
    }

    private var scrollReader: some View {
        Group {
            if let chapters, chapters.indices.contains(chapterIndex) {
                let chapter = chapters[chapterIndex]
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Color.clear.frame(height: 1).id("txt-reader-top")
                            if let volumeTitle = chapter.volumeTitle {
                                Text(volumeTitle)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                            }
                            Text(chapter.title)
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .foregroundStyle(appearance.primaryText(system: systemColorScheme))
                            if bodyChunksChapterIndex == chapterIndex {
                                let ranges = ReaderTextRanges.sourceRanges(of: bodyChunks, in: settings.projection.apply(chapter.body))
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(bodyChunks.indices, id: \.self) { index in
                                        Text(highlightedChunk(bodyChunks[index], sourceRange: ranges[index]))
                                            .id("text-chunk-\(index)")
                                            .background(GeometryReader { geometry in Color.clear.preference(key: ReaderScrollFrames.self, value: ["text-chunk-\(index)": geometry.frame(in: .global)]) })
                                            .font(.system(size: fontSize, design: .serif))
                                            .lineSpacing(9)
                                            .foregroundStyle(appearance.primaryText(system: systemColorScheme))
                                            .textSelection(.enabled)
                                    }
                                }
                            } else {
                                ProgressView("正在排版章节…")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 36)
                    }
                    .onValueChange(of: chapterIndex) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("txt-reader-top", anchor: .top)
                        }
                    }
                    .onPreferenceChange(ReaderScrollFrames.self) { visibleAnchor = ReaderScrollFrames.visible($0) }
                    .task(id: "\(selectedSearchHit?.id ?? "")|\(bodyChunksChapterIndex ?? -1)|\(returnAnchor ?? "")") {
                        guard bodyChunksChapterIndex == chapterIndex else { return }
                        await Task.yield()
                        if let anchor = returnAnchor { proxy.scrollTo(anchor, anchor: .top); returnAnchor = nil }
                        else if let hit = selectedSearchHit, hit.chapterIndex == chapterIndex,
                            let index = ReaderTextRanges.sourceRanges(of: bodyChunks, in: settings.projection.apply(chapter.body)).firstIndex(where: { $0?.contains(hit.utf16Offset) == true }) {
                            proxy.scrollTo("text-chunk-\(index)", anchor: .center)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        chapterControls(count: chapters.count)
                    }
                }
            } else if let errorMessage {
                CompatUnavailable("无法读取 TXT", systemImage: "doc.text.magnifyingglass", description: Text(errorMessage))
            } else {
                ProgressView("正在打开 TXT…")
            }
        }
        .background(ReaderBackgroundView(dark: appearance.isDark(system: systemColorScheme), fallback: appearance.background(system: systemColorScheme)).ignoresSafeArea())
        .preferredColorScheme(appearance.preferredColorScheme)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .compatToolbar(.hidden, for: .tabBar)
        .toolbar {
            // 与分页阅读器一致：顶栏同时显示书名与当前章节。
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let chapterTitle = chapters?[chapterIndex].title, !chapterTitle.isEmpty {
                        Text(chapterTitle)
                            .font(NoveliaStyle.fontMicro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .compatTopBarTrailing) {
                Menu {
                Button("书内搜索") { isShowingSearch = true }
                if let point = readingReturnPoint {
                    Button("回到刚才阅读处") { selectedSearchHit = nil; chapterIndex = point.chapter; returnAnchor = point.anchor; readingReturnPoint = nil }
                }
                Button("本书文字处理") { isShowingBookPreferences = true }
                Button { settings.pagedTextReading = true } label: {
                    Label("分页阅读", systemImage: "book.pages")
                }
                .accessibilityLabel("分页阅读")
                if chapters != nil {
                    Button { isShowingContents = true } label: {
                        Label("章节目录", systemImage: "list.bullet")
                    }
                    .accessibilityLabel("章节目录")
                }
                Menu {
                    Toggle("本书使用独立样式", isOn: Binding(get: { settings.usesBookPreferences }, set: { settings.setBookPreferencesEnabled($0) }))
                    Button { settings.adjustFontSize(by: -1) } label: {
                        Label("缩小字号", systemImage: "textformat.size.smaller")
                    }
                    .accessibilityLabel("缩小字号")
                    Button { settings.adjustFontSize(by: 1) } label: {
                        Label("放大字号", systemImage: "textformat.size.larger")
                    }
                    .accessibilityLabel("放大字号")
                    Menu {
                        Picker("阅读主题", selection: $settings.appearanceRaw) {
                            ForEach(ReaderAppearance.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                    } label: {
                        Label("阅读主题", systemImage: "circle.lefthalf.filled")
                    }
                    .accessibilityLabel("阅读主题")
                } label: { Label("阅读设置", systemImage: "textformat.size") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("阅读菜单")
            }
        }
        .sheet(isPresented: $isShowingSearch) {
            ReaderBookmarksSearchSheet(store: settings.bookmarks, bookKey: preferenceID ?? "txt:unknown",
                chapterCount: chapters?.count ?? 0, chapterTitle: { chapters?[$0].title },
                chapterText: { settings.projection.apply(chapters?[$0].body ?? "") },
                onJump: { index, _ in chapterIndex = index }, onSearchHit: { hit in
                    if readingReturnPoint == nil { readingReturnPoint = .init(chapter: chapterIndex, anchor: visibleAnchor) }
                    chapterIndex = hit.chapterIndex; selectedSearchHit = hit
                }, tab: .search)
        }
        .sheet(isPresented: $isShowingBookPreferences) { ReaderBookPreferencesView() }
        .sheet(isPresented: $isShowingContents) {
            CompatNavigationStack {
                ScrollViewReader { proxy in
                    List {
                        if let tocWordCounts {
                            ReaderTOCWordCountHeader(total: tocWordCounts.total)
                        }
                        if let chapters {
                            ForEach(chapters.indices, id: \.self) { index in
                                ReaderTOCRow(title: chapters[index].title, level: 0,
                                             subtitle: ReaderTOCRow.subtitle(wordCount: tocWordCounts?.entry(index),
                                                                             detail: chapters[index].volumeTitle),
                                             isCurrent: index == chapterIndex,
                                             showsDisclosureColumn: false) {
                                    chapterIndex = index
                                    isShowingContents = false
                                }
                                .id(index)
                                .accessibilityAddTraits(index == chapterIndex ? .isSelected : [])
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(chapterIndex, anchor: .center) }
                }
                .navigationTitle("章节目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .compatTopBarTrailing) {
                        Button("完成") { isShowingContents = false }
                    }
                }
                .task {
                    if tocWordCounts == nil, let parsedBook { tocWordCounts = await BookWordCounter.txtTOCCounts(parsedBook) }
                }
            }
            .compatPresentationDetents(.medium, .large)
        }
        .task(id: url) {
            do {
                // 每份文件内容只解码和划分章节一次（TXTBookCache）；
                // 重新打开、切换模式或重建此视图时复用结果。
                let trace = DiagnosticContext.newTraceID()
                TXTDiagnosticLog.logger.info("TXT open requested; trace=\(trace, privacy: .public), source=open, mode=scroll, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
                let book = try await TXTBookCache.shared.book(at: url, rules: rules, source: .open, trace: trace)
                guard !Task.isCancelled else { return }
                if let saved = settings.positions.txtPosition(hash: book.contentHash) {
                    chapterIndex = min(max(saved.chapter, 0), max(book.chapters.count - 1, 0))
                }
                let id = "txt:" + book.contentHash
                settings.activateBook(id); preferenceID = id
                contentHash = book.contentHash
                parsedBook = book
                tocWordCounts = nil
                chapters = book.chapters
            } catch {
                guard !Task.isCancelled else { return }
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT reader load failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
        .onValueChange(of: chapterIndex) { _, newIndex in
            guard let contentHash else { return }
            let saved = settings.positions.txtPosition(hash: contentHash) ?? TXTReadingPosition(chapter: newIndex)
            guard saved.chapter != newIndex || settings.positions.all()["txt:\(contentHash)"] == nil else { return }
            settings.positions.recordTXT(hash: contentHash, position: saved.movingToChapter(newIndex))
        }
        .task(id: "\(url.path)|\(chapterIndex)|\(chapters?.count ?? 0)|\(settings.projection.identity)") {
            guard let chapters, chapters.indices.contains(chapterIndex) else { return }
            let body = settings.projection.apply(chapters[chapterIndex].body)
            let chunks = await Task.detached(priority: .userInitiated) {
                ReaderTextChunker.chunks(body, maximumCharacters: 200)
            }.value
            guard !Task.isCancelled else { return }
            bodyChunks = chunks
            bodyChunksChapterIndex = chapterIndex
        }
    }

    private func highlightedChunk(_ text: String, sourceRange: Range<Int>?) -> AttributedString {
        var value = AttributedString(text)
        if let hit = selectedSearchHit, hit.chapterIndex == chapterIndex, let sourceRange {
            ReaderTextHighlight.apply(ReaderTextRanges.localRange(hit.utf16Offset..<(hit.utf16Offset + hit.match.utf16.count), in: sourceRange), text: text, to: &value)
        }
        return value
    }

    private func chapterControls(count: Int) -> some View {
        HStack {
            Button {
                chapterIndex = max(0, chapterIndex - 1)
            } label: {
                Label("上一章", systemImage: "chevron.left")
            }
            .disabled(chapterIndex == 0)
            Spacer()
            Text("\(chapterIndex + 1) / \(count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(appearance.secondaryText(system: systemColorScheme))
            Spacer()
            Button {
                chapterIndex = min(count - 1, chapterIndex + 1)
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(chapterIndex >= count - 1)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}

/// 支持 YueduCoreText 和实验性 Readium 排版的 TXT。长章节拆分为单元；阅读位置
/// 按文件内容（SHA-256）保存为单元序号 + 文本偏移量。
private struct TXTPagedReader: View {
    @EnvironmentObject private var settings: ReaderSettings
    let url: URL
    let title: String
    let rules: TXTChapterRuleConfiguration
    var statisticsID: String? = nil
    #if !NOVELIA_READIUM_ONLY
    @AppStorage(SettingsKey.readerEPUBReadium) private var usesReadium = false
    #endif
    @State private var book: PagedTextBook?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let book {
                #if NOVELIA_READIUM_ONLY
                ReadiumEPUBReaderView(bookURL: nil, textBook: book, accessory: AnyView(scrollButton),
                                      statisticsBook: ReadingBook(id: statisticsID ?? "txt:\(url.lastPathComponent)", title: title, kind: .txt))
                #else
                if usesReadium {
                    ReadiumEPUBReaderView(bookURL: nil, textBook: book, accessory: AnyView(scrollButton),
                                          statisticsBook: ReadingBook(id: statisticsID ?? "txt:\(url.lastPathComponent)", title: title, kind: .txt))
                } else {
                    EPUBReaderView(bookURL: nil, textBook: book, accessory: AnyView(scrollButton),
                                   statisticsBook: ReadingBook(id: statisticsID ?? "txt:\(url.lastPathComponent)", title: title, kind: .txt))
                }
                #endif
            } else if let errorMessage {
                CompatUnavailable("无法读取 TXT", systemImage: "doc.text.magnifyingglass", description: Text(errorMessage))
            } else {
                ProgressView("正在打开 TXT…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .compatToolbar(.hidden, for: .tabBar)
        .task(id: url) { await load() }
    }

    private var scrollButton: some View {
        Button { settings.pagedTextReading = false } label: {
            Label("滚动阅读", systemImage: "scroll")
        }
        .accessibilityLabel("滚动阅读")
    }

    private func load() async {
        do {
            let trace = DiagnosticContext.newTraceID()
            TXTDiagnosticLog.logger.info("TXT open requested; trace=\(trace, privacy: .public), source=open, mode=paged, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            let parsed = try await TXTBookCache.shared.book(at: url, rules: rules, source: .open, trace: trace)
            let identity = "txt|\(parsed.contentHash)|\(parsed.rulesFingerprint)"
            let units = await TXTPagedUnits.shared.units(for: parsed, identity: identity)
            guard !Task.isCancelled else { return }
            let hash = parsed.contentHash
            settings.activateBook("txt:" + hash)
            let source = TextChapterSource(bookTitle: title, units: units, layoutIdentity: identity)
            let start = (settings.positions.txtPosition(hash: hash) ?? TXTReadingPosition(chapter: 0)).pagedStart(in: source)
            book = PagedTextBook(
                source: source, startUnit: start.unit, startOffset: start.offset,
                onPosition: { [weak source] unit, offset in
                    guard let source else { return }
                    let position = TXTReadingPosition(chapter: source.tocEntry(containingUnit: unit) ?? 0, unit: unit,
                                                      offset: offset, unitCount: source.chapterCount)
                    // 打开时会报告恢复的页面；若重新写入时间戳，下次同步时
                    // 此设备可能覆盖另一台设备较新的阅读位置。
                    guard position != settings.positions.txtPosition(hash: hash) else { return }
                    settings.positions.recordTXT(hash: hash, position: position)
                }, readiumIdentity: identity,
                positionUpdatedAt: settings.positions.all()["txt:\(hash)"]?.updatedAt,
                bookmarkKey: "txt:\(hash)",
                tocWordCounts: { await BookWordCounter.txtTOCCounts(parsed) })
        } catch {
            guard !Task.isCancelled else { return }
            let nsError = error as NSError
            TXTDiagnosticLog.logger.error("TXT reader load failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}

/// 最近一本 TXT 的分页单元，在主线程之外构建。打开时仅扫描
/// 单元边界（段落在单元排版时拆分）；保留最近一本书，
/// 使重新打开或从滚动切换到分页时能够立即复用。
private actor TXTPagedUnits {
    static let shared = TXTPagedUnits()
    private var last: (identity: String, units: [TextChapterSource.Unit])?

    func units(for book: TXTParsedBook, identity: String) -> [TextChapterSource.Unit] {
        if let last, last.identity == identity { return last.units }
        let units = TextChapterSource.units(lazilySplitting: book.chapters.map {
            TextChapterBody(title: $0.title, subtitle: $0.volumeTitle, body: $0.body)
        })
        last = (identity, units)
        return units
    }
}
