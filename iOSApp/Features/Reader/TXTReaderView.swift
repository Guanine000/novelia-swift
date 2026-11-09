import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct DownloadedWebNovelTXTReader: View {
    @EnvironmentObject private var settings: ReaderSettings
    private var fontSize: Double { settings.fontSize }
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.speechHandoff) private var speechHandoff
    let url: URL
    let title: String
    let rules: TXTChapterRuleConfiguration
    var statisticsID: String? = nil
    @State private var readingTimePoint = ReadingTimePoint.start
    @State private var lastManualScroll: TimeInterval = -1
    @State private var adjustmentRevision = 0
    @State private var isShowingAdjustment = false
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
    @StateObject private var speech = SpeechPlaybackController()
    @State private var isShowingSpeech = false
    @State private var speechPosition: SpeechReadingPosition?

    private var appearance: ReaderAppearance {
        settings.appearance
    }

    var body: some View {
        Group {
        if preferenceID == nil { ProgressView("准备阅读偏好…") }
        else if settings.pagedTextReading {
            TXTPagedReader(url: url, title: title, rules: rules, statisticsID: statisticsID,
                           isAdjustmentActive: { isShowingAdjustment }, onAdjust: { isShowingAdjustment = true })
                .id(adjustmentRevision)
        } else {
            scrollReader
                .trackReadingTime(ReadingBook(id: statisticsID ?? "txt:\(url.lastPathComponent)", title: title, kind: .txt),
                                  ready: !isShowingAdjustment && chapters?.indices.contains(chapterIndex) == true && bodyChunksChapterIndex == chapterIndex)
        }
        }
        .sheet(isPresented: $isShowingAdjustment) {
            TXTChapterAdjustmentView(url: url, rules: rules) { adjustmentRevision += 1 }
        }
        .task(id: url) {
            let hash = try? await Task.detached { try FileContentHash.sha256(url) }.value
            guard !Task.isCancelled else { return }
            let id = "txt:" + (hash ?? url.lastPathComponent)
            settings.activateBook(id); preferenceID = id
            ReaderKeepScreenOn.activate()
        }
        .onDisappear {
            if let preferenceID { settings.deactivateBook(preferenceID) }
            ReaderKeepScreenOn.deactivate()
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
                                let ranges = ReaderTextRanges.sourceRanges(of: bodyChunks, in: settings.projection.apply(chapter.body))
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(bodyChunks.indices, id: \.self) { index in
                                        SpeechTXTChunk(value: highlightedChunk(bodyChunks[index], sourceRange: ranges[index]),
                                                       text: bodyChunks[index], baseOffset: ranges[index]?.lowerBound ?? 0,
                                                       chapter: chapterIndex)
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
                    .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in speech.suspendFollow(true); lastManualScroll = ProcessInfo.processInfo.systemUptime })
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
                    .onValueChange(of: speechPosition) { _, _ in scrollToSpeech(proxy) }
                    .onValueChange(of: bodyChunksChapterIndex) { _, _ in scrollToSpeech(proxy) }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 4) {
                            ReaderRemainingTimeView(store: settings.remainingTime, source: scrollTimeSource,
                                point: readingTimePoint, mode: "scroll|" + settings.projection.identity,
                                active: !speech.isActive && !isShowingContents && !isShowingSearch && !isShowingSpeech
                                    && !isShowingBookPreferences && !isShowingAdjustment && bodyChunksChapterIndex == chapterIndex,
                                isListening: speech.isActive)
                            chapterControls(count: chapters.count)
                        }
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
        .modifier(ReaderSpeechPresentation(controller: speech, isPresented: $isShowingSpeech,
                                          anchor: { SpeechAnchor(chapterIndex: chapterIndex, progression: 0,
                                                               chapterUTF16Length: 0, startIndexHint: nil) },
                                          title: title,
                                          bookKey: preferenceID,
                                          isReady: chapters != nil,
                                          chapterTitle: { index in
                                              guard let chapters, chapters.indices.contains(index) else { return nil }
                                              return chapters[index].title
                                          },
                                          jumpToSpoken: { scrollToSpeechForce() },
                                          onResumeSaved: { point in
                                              guard let chapters, chapters.indices.contains(point.chapterIndex) else { return }
                                              chapterIndex = point.chapterIndex
                                              speech.start(from: point.anchor)
                                          }, onProgressSave: { point in
                                              guard let contentHash, point.bookKey == "txt:" + contentHash,
                                                    let chapters, chapters.indices.contains(point.chapterIndex), !isShowingAdjustment,
                                                    parsedBook?.rulesFingerprint == settings.txtReaderIdentities[contentHash] else { return }
                                              settings.positions.recordTXT(hash: contentHash, position: TXTReadingPosition(chapter: point.chapterIndex))
                                          }) {
                        let current = chapters ?? []
                        return SystemSpeechEngine(chapterCount: current.count, onReadingPosition: { position, preferences in
                            speechPosition = position
                            if let position, preferences.followsReadingPosition { chapterIndex = position.chapterIndex }
                        }) { index in
                            guard current.indices.contains(index) else { return "" }
                            return settings.projection.apply(current[index].body)
                        }
                    })
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
                Button("TXT分章调整") { speech.stop(); isShowingAdjustment = true }
                Button("书内搜索") { isShowingSearch = true }
                if let point = readingReturnPoint {
                    Button("回到刚才阅读处") { selectedSearchHit = nil; chapterIndex = point.chapter; returnAnchor = point.anchor; readingReturnPoint = nil }
                }
                ReaderRemainingTimeMenu(store: settings.remainingTime)
                ReaderKeepScreenOnMenuItem()
                Button("本书文字处理") { isShowingBookPreferences = true }
                Button { settings.pagedTextReading = true } label: {
                    Label("分页阅读", systemImage: "book.pages")
                }
                .accessibilityLabel("分页阅读")
                if chapters != nil {
                    Button { isShowingSpeech = true } label: { Label("朗读", systemImage: "speaker.wave.2") }
                }
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
                    speech.pause(); chapterIndex = hit.chapterIndex; selectedSearchHit = hit
                }, tab: .search)
        }
        .sheet(isPresented: $isShowingBookPreferences) { ReaderBookPreferencesView() }
        .onValueChange(of: settings.projectionRevision) { _, _ in speech.stop() }
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
        .task(id: "\(url.path)|\(adjustmentRevision)") {
            do {
                // 每份文件内容只解码和划分章节一次（TXTBookCache）；
                // 重新打开、切换模式或重建此视图时复用结果。
                let trace = DiagnosticContext.newTraceID()
                TXTDiagnosticLog.logger.info("TXT open requested; trace=\(trace, privacy: .public), source=open, mode=scroll, mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
                let book = try await settings.txtBook(url: url, rules: rules, trace: trace)
                guard !Task.isCancelled else { return }
                if adjustmentRevision > 0 {
                    readingReturnPoint = nil; returnAnchor = nil; selectedSearchHit = nil
                    speechPosition = nil; visibleAnchor = nil; bodyChunksChapterIndex = nil
                }
                if let saved = settings.positions.txtPosition(hash: book.contentHash) {
                    chapterIndex = min(max(saved.chapter, 0), max(book.chapters.count - 1, 0))
                }
                let id = "txt:" + book.contentHash
                settings.activateBook(id); preferenceID = id
                contentHash = book.contentHash
                parsedBook = book
                tocWordCounts = nil
                chapters = book.chapters
                if adjustmentRevision > 0, !book.text.isEmpty,
                   let position = settings.positions.txtPosition(hash: book.contentHash), let unit = position.unit {
                    let projection = settings.projection
                    let map = try await Task.detached(priority: .userInitiated) {
                        try TXTAdjustmentCoordinates(text: book.text, chapters: book.chapters, projection: projection)
                    }.value
                    if map.units.indices.contains(unit), let raw = map.rawOffset(unit: unit, offset: position.offset ?? 0),
                       let first = map.units.first(where: { $0.chapter == chapterIndex })?.spans.first,
                       book.chapters.indices.contains(chapterIndex) {
                        let body = book.chapters[chapterIndex].body as NSString
                        let offset = min(body.length, max(0, raw - first.raw.lowerBound))
                        let visibleOffset = projection.apply(body.substring(to: offset)).utf16.count
                        selectedSearchHit = .init(chapterIndex: chapterIndex, progression: 0, before: "", match: "", after: "", utf16Offset: visibleOffset)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT reader load failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
        .task(id: "time|\(visibleAnchor ?? "")|\(bodyChunksChapterIndex ?? -1)|\(parsedBook?.rulesFingerprint ?? "")") {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let chapters, chapters.indices.contains(chapterIndex), bodyChunksChapterIndex == chapterIndex,
                  let anchor = visibleAnchor, let index = Int(anchor.replacingOccurrences(of: "text-chunk-", with: "")),
                  bodyChunks.indices.contains(index) else { return }
            let text = settings.projection.apply(chapters[chapterIndex].body)
            let ranges = ReaderTextRanges.sourceRanges(of: bodyChunks, in: text)
            guard let range = ranges[index] else { return }
            readingTimePoint = .init(resource: chapterIndex, fraction: Double(range.lowerBound) / Double(max(1, text.utf16.count)),
                reason: ProcessInfo.processInfo.systemUptime - lastManualScroll < 2 ? .forward : .reset)
        }
        .onValueChange(of: chapterIndex) { _, newIndex in
            lastManualScroll = -1
            readingTimePoint = .init(resource: newIndex, fraction: 0)
            if speechPosition?.chapterIndex != newIndex { speech.suspendFollow(true) }
            guard !isShowingAdjustment, let contentHash,
                  parsedBook?.rulesFingerprint == settings.txtReaderIdentities[contentHash] else { return }
            let saved = settings.positions.txtPosition(hash: contentHash) ?? TXTReadingPosition(chapter: newIndex)
            guard saved.chapter != newIndex || settings.positions.all()["txt:\(contentHash)"] == nil else { return }
            settings.positions.recordTXT(hash: contentHash, position: saved.movingToChapter(newIndex))
        }
        .task(id: "\(url.path)|\(parsedBook?.rulesFingerprint ?? "")|\(chapterIndex)|\(chapters?.count ?? 0)|\(settings.projection.identity)") {
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

    private var scrollTimeSource: LocalReadingTimeSource? {
        guard let parsedBook else { return nil }
        let projection = settings.projection
        return .init(id: "txt:" + parsedBook.contentHash + "|" + parsedBook.rulesFingerprint + "|" + projection.identity) {
            try await ReadingTimeMetrics.loadTXT(parsedBook, projection: projection, paged: false)
        }
    }

    private func highlightedChunk(_ text: String, sourceRange: Range<Int>?) -> AttributedString {
        var value = AttributedString(text)
        if speech.settings.highlightsSpokenText, speechPosition?.chapterIndex == chapterIndex, let sourceRange {
            SpeechTextHighlight.apply(ReaderTextRanges.localRange(speechPosition?.sentenceRange, in: sourceRange), text: text, to: &value)
        }
        if let hit = selectedSearchHit, hit.chapterIndex == chapterIndex, let sourceRange {
            ReaderTextHighlight.apply(ReaderTextRanges.localRange(hit.utf16Offset..<(hit.utf16Offset + hit.match.utf16.count), in: sourceRange), text: text, to: &value)
        }
        return value
    }

    /// 「回到朗读处」按钮：外层拿不到 ScrollViewProxy，通过锚点定位（与搜索命中同一套滚动键）。
    private func scrollToSpeechForce() {
        guard let position = speechPosition, position.chapterIndex == chapterIndex,
              bodyChunksChapterIndex == chapterIndex, let chapters,
              chapters.indices.contains(chapterIndex) else { return }
        let ranges = ReaderTextRanges.sourceRanges(of: bodyChunks, in: settings.projection.apply(chapters[chapterIndex].body))
        guard let index = ranges.firstIndex(where: { $0?.contains(position.currentOffset) == true }) else { return }
        // 复用「回到刚才阅读处」的锚点机制触发滚动，拿不到 proxy 也能定位。
        returnAnchor = "text-chunk-\(index)"
    }

    private func scrollToSpeech(_ proxy: ScrollViewProxy) {
        guard speech.settings.followsReadingPosition, let position = speechPosition,
              position.chapterIndex == chapterIndex, bodyChunksChapterIndex == chapterIndex,
              let chapters, chapters.indices.contains(chapterIndex) else { return }
        let ranges = ReaderTextRanges.sourceRanges(of: bodyChunks, in: settings.projection.apply(chapters[chapterIndex].body))
        guard let index = ranges.firstIndex(where: { $0?.contains(position.currentOffset) == true }) else { return }
        proxy.scrollTo("text-chunk-\(index)", anchor: .center)
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
    var isAdjustmentActive: () -> Bool
    var onAdjust: () -> Void
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
            let parsed = try await settings.txtBook(url: url, rules: rules, trace: trace)
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
                    guard !isAdjustmentActive(), settings.txtReaderIdentities[hash] == parsed.rulesFingerprint, let source else { return }
                    let position = TXTReadingPosition(chapter: source.tocEntry(containingUnit: unit) ?? 0, unit: unit,
                                                      offset: offset, unitCount: source.chapterCount)
                    // 打开时会报告恢复的页面；若重新写入时间戳，下次同步时
                    // 此设备可能覆盖另一台设备较新的阅读位置。
                    guard position != settings.positions.txtPosition(hash: hash) else { return }
                    settings.positions.recordTXT(hash: hash, position: position)
                }, readiumIdentity: identity,
                positionUpdatedAt: settings.positions.all()["txt:\(hash)"]?.updatedAt,
                bookmarkKey: "txt:\(hash)",
                tocWordCounts: { await BookWordCounter.txtTOCCounts(parsed) },
                adjustTXTChapters: onAdjust,
                localTimeMetrics: { projection in
                    try await ReadingTimeMetrics.loadTXT(parsed, projection: projection, paged: true)
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

private struct SpeechTXTChunk: View {
    let value: AttributedString
    let text: String
    let baseOffset: Int
    let chapter: Int
    @Environment(\.readerSpeechActions) private var actions
    var body: some View {
        Text(value)
            .contextMenu { SpeechSentenceMenu(text: text, baseOffset: baseOffset, chapter: chapter) }
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "novelia-speech" { actions.toggle(); return .handled }
                return .systemAction
            })
    }
}
