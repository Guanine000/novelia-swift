import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct DownloadedWebNovelTXTReader: View {
    @ObservedObject private var settings = ReaderSettings.shared
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
    @State private var isShowingContents = false
    @State private var errorMessage: String?

    private var appearance: ReaderAppearance {
        settings.appearance
    }

    var body: some View {
        if settings.pagedTextReading {
            TXTPagedReader(url: url, title: title, rules: rules, statisticsID: statisticsID)
        } else {
            scrollReader
                .trackReadingTime(ReadingBook(id: statisticsID ?? "txt:\(url.lastPathComponent)", title: title, kind: .txt),
                                  ready: chapters?.indices.contains(chapterIndex) == true && bodyChunksChapterIndex == chapterIndex)
        }
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
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(bodyChunks.indices, id: \.self) { index in
                                        Text(bodyChunks[index])
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
                    .onChange(of: chapterIndex) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("txt-reader-top", anchor: .top)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        chapterControls(count: chapters.count)
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("无法读取 TXT", systemImage: "doc.text.magnifyingglass", description: Text(errorMessage))
            } else {
                ProgressView("正在打开 TXT…")
            }
        }
        .background(ReaderBackgroundView(dark: appearance.isDark(system: systemColorScheme), fallback: appearance.background(system: systemColorScheme)).ignoresSafeArea())
        .preferredColorScheme(appearance.preferredColorScheme)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { settings.pagedTextReading = true } label: {
                    Image(systemName: "book.pages")
                }
                .accessibilityLabel("分页阅读")
                if chapters != nil {
                    Button { isShowingContents = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("章节目录")
                }
                Button { settings.adjustFontSize(by: -1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel("缩小字号")
                Button { settings.adjustFontSize(by: 1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel("放大字号")
                Menu {
                    Picker("阅读主题", selection: $settings.appearanceRaw) {
                        ForEach(ReaderAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .accessibilityLabel("阅读主题")
            }
        }
        .sheet(isPresented: $isShowingContents) {
            NavigationStack {
                List {
                    if let chapters {
                        ForEach(chapters.indices, id: \.self) { index in
                            Button {
                                chapterIndex = index
                                isShowingContents = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let volume = chapters[index].volumeTitle {
                                        Text(volume).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(chapters[index].title)
                                        .foregroundStyle(index == chapterIndex ? NoveliaStyle.brandGreen : .primary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("章节目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { isShowingContents = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: url) {
            do {
                // 每份文件内容只解码和划分章节一次（TXTBookCache）；
                // 重新打开、切换模式或重建此视图时复用结果。
                let trace = DiagnosticContext.newTraceID()
                TXTDiagnosticLog.logger.info("TXT open requested; trace=\(trace, privacy: .public), source=open, mode=scroll, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
                let book = try await TXTBookCache.shared.book(at: url, rules: rules, source: .open, trace: trace)
                guard !Task.isCancelled else { return }
                if let saved = ReadingPositionSync.txtPosition(hash: book.contentHash) {
                    chapterIndex = min(max(saved.chapter, 0), max(book.chapters.count - 1, 0))
                }
                contentHash = book.contentHash
                chapters = book.chapters
            } catch {
                guard !Task.isCancelled else { return }
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT reader load failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: chapterIndex) { _, newIndex in
            guard let contentHash else { return }
            let saved = ReadingPositionSync.txtPosition(hash: contentHash) ?? TXTReadingPosition(chapter: newIndex)
            guard saved.chapter != newIndex || ReadingPositionSync.all()["txt:\(contentHash)"] == nil else { return }
            ReadingPositionSync.recordTXT(hash: contentHash, position: saved.movingToChapter(newIndex))
        }
        .task(id: "\(url.path)|\(chapterIndex)|\(chapters?.count ?? 0)") {
            guard let chapters, chapters.indices.contains(chapterIndex) else { return }
            let body = chapters[chapterIndex].body
            let chunks = await Task.detached(priority: .userInitiated) {
                ReaderTextChunker.chunks(body)
            }.value
            guard !Task.isCancelled else { return }
            bodyChunks = chunks
            bodyChunksChapterIndex = chapterIndex
        }
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

/// 使用 YueduCoreText 排版的 TXT。长章节拆分为单元；阅读位置
/// 按文件内容（SHA-256）保存为单元序号 + 文本偏移量。
private struct TXTPagedReader: View {
    @ObservedObject private var settings = ReaderSettings.shared
    let url: URL
    let title: String
    let rules: TXTChapterRuleConfiguration
    var statisticsID: String? = nil
    @State private var book: PagedTextBook?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let book {
                EPUBReaderView(bookURL: nil, textBook: book, accessory: AnyView(scrollButton),
                               statisticsBook: ReadingBook(id: statisticsID ?? "txt:\(url.lastPathComponent)", title: title, kind: .txt))
            } else if let errorMessage {
                ContentUnavailableView("无法读取 TXT", systemImage: "doc.text.magnifyingglass", description: Text(errorMessage))
            } else {
                ProgressView("正在打开 TXT…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: url) { await load() }
    }

    private var scrollButton: some View {
        Button { settings.pagedTextReading = false } label: {
            Image(systemName: "scroll")
                .frame(width: 36, height: 36)
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
            let source = TextChapterSource(bookTitle: title, units: units, layoutIdentity: identity)
            let start = (ReadingPositionSync.txtPosition(hash: hash) ?? TXTReadingPosition(chapter: 0)).pagedStart(in: source)
            book = PagedTextBook(
                source: source, startUnit: start.unit, startOffset: start.offset,
                onPosition: { [weak source] unit, offset in
                    guard let source else { return }
                    let position = TXTReadingPosition(chapter: source.tocEntry(containingUnit: unit) ?? 0, unit: unit,
                                                      offset: offset, unitCount: source.chapterCount)
                    // 打开时会报告恢复的页面；若重新写入时间戳，下次同步时
                    // 此设备可能覆盖另一台设备较新的阅读位置。
                    guard position != ReadingPositionSync.txtPosition(hash: hash) else { return }
                    ReadingPositionSync.recordTXT(hash: hash, position: position)
                })
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
