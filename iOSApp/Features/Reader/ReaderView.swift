import SwiftUI

enum ReaderAppearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    func isDark(system scheme: ColorScheme) -> Bool {
        switch self {
        case .light: false
        case .dark: true
        case .system: scheme == .dark
        }
    }

    func background(system scheme: ColorScheme) -> Color {
        isDark(system: scheme) ? Color(red: 0.08, green: 0.08, blue: 0.09) : NoveliaStyle.paper
    }

    func card(system scheme: ColorScheme) -> Color {
        isDark(system: scheme) ? Color(red: 0.14, green: 0.14, blue: 0.15) : .white
    }

    func primaryText(system scheme: ColorScheme) -> Color {
        isDark(system: scheme) ? Color(red: 0.91, green: 0.91, blue: 0.92) : NoveliaStyle.ink
    }

    func secondaryText(system scheme: ColorScheme) -> Color {
        isDark(system: scheme) ? Color(red: 0.68, green: 0.68, blue: 0.71) : NoveliaStyle.muted
    }
}

struct ReaderView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var settings: ReaderSettings
    private var fontSize: Double { settings.fontSize }
    let novel: Novel
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var chapterIndex: Int
    @AppStorage(SettingsKey.readerMode) private var modeRaw = ReaderMode.bilingual.rawValue
    @AppStorage(SettingsKey.readerTranslationSource) private var translationSourceRaw = NovelTranslationSource.gpt.rawValue
    @AppStorage private var bookmarkIDsJSON: String
    @AppStorage private var savedChapterIndex: Int
    @State private var loadedChapters: [String: NovelChapter] = [:]
    @State private var isLoadingChapter = false
    @State private var chapterError: String?
    @State private var loadAttempt = 0
    @State private var isShowingBookPreferences = false
    /// 章节目录改为半屏卡片，便于边看正文边跳章。
    @State private var isShowingChapterDirectory = false
    @State private var isShowingSearch = false
    @State private var selectedSearchHit: BookTextSearch.Hit?
    @State private var readingReturnPoint: ScrollReadingReturnPoint?
    @State private var visibleAnchor: String?
    @State private var returnAnchor: String?

    init(novel: Novel, startingAt: Int) {
        self.novel = novel
        _chapterIndex = State(initialValue: min(max(0, startingAt), max(0, novel.chapters.count - 1)))
        _bookmarkIDsJSON = AppStorage(wrappedValue: "[]", SettingsKey.bookmarks(novelID: novel.id))
        _savedChapterIndex = AppStorage(wrappedValue: 0, ReadingProgressStore.chapterKey(novelID: novel.id))
    }

    private var chapter: NovelChapter {
        let listed = novel.chapters[chapterIndex]
        return loadedChapters[listed.id] ?? listed
    }
    private var mode: ReaderMode { ReaderMode(rawValue: modeRaw) ?? .bilingual }
    private var appearance: ReaderAppearance { settings.appearance }
    private var translationSource: NovelTranslationSource {
        NovelTranslationSource(rawValue: translationSourceRaw) ?? .gpt
    }
    private var readerBackground: Color { appearance.background(system: systemColorScheme) }
    private var readerPrimaryText: Color { appearance.primaryText(system: systemColorScheme) }
    private var readerSecondaryText: Color { appearance.secondaryText(system: systemColorScheme) }
    private var bookmarkIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(bookmarkIDsJSON.utf8))) ?? [])
    }
    private var isBookmarked: Bool { bookmarkIDs.contains(chapter.id) }
    private var selectedTranslationParagraphs: [String]? { chapter.projected(settings.projection).selectedTranslation(source: translationSource) }
    private var displayedTranslation: [String] { chapter.projected(settings.projection).displayedTranslation(source: translationSource) }
    private var bilingualParagraphs: [NovelBilingualParagraph] { chapter.projected(settings.projection).bilingualParagraphs(source: translationSource) }

    var body: some View {
        Group {
        if settings.pagedTextReading {
            OnlinePagedReader(novel: novel, chapterIndex: $chapterIndex)
        } else {
            scrollReader
                .trackReadingTime(ReadingBook(id: "online:\(novel.id)", title: novel.title, kind: .online),
                                  ready: !chapter.originalText.isEmpty)
        }
        }
        .onAppear { settings.activateBook("online:" + novel.id) }
        .onDisappear { settings.deactivateBook("online:" + novel.id) }
    }

    private var scrollReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("\(novel.title.uppercased())  ·  \(chapterIndex + 1) / \(novel.chapters.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .compatTracking(1.2)
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        Text(chapter.title)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .lineSpacing(4)
                            .foregroundStyle(readerPrimaryText)
                        Text("著 · \(novel.author)")
                            .font(NoveliaStyle.fontBody)
                            .foregroundStyle(readerSecondaryText)
                    }
                    .padding(.top, 14)

                    Rectangle()
                        .fill(NoveliaStyle.brandGreen.opacity(0.28))
                        .frame(width: 44, height: 3)
                        .clipShape(Capsule())

                    if isLoadingChapter && chapter.originalText.isEmpty {
                        HStack { Spacer(); ProgressView("加载章节…"); Spacer() }
                            .padding(.vertical, 28)
                    } else if let chapterError, chapter.originalText.isEmpty {
                        CompatUnavailable {
                            Label("章节加载失败", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(chapterError)
                        } actions: {
                            Button("重试") { loadAttempt += 1 }
                                .buttonStyle(.borderedProminent)
                                .tint(NoveliaStyle.brandGreen)
                        }
                    } else {
                        readerText.id(chapter.id)
                    }

                    if let chapterError, !chapter.originalText.isEmpty {
                        Text("章节内容已缓存；刷新失败：\(chapterError)")
                            .font(NoveliaStyle.fontFootnote)
                            .foregroundStyle(NoveliaStyle.muted)
                    }

                    HStack {
                        Button {
                            changeChapter(by: -1)
                        } label: {
                            Label("上一章", systemImage: "chevron.left")
                        }
                        .disabled(chapterIndex == 0)
                        Spacer()
                        Button {
                            changeChapter(by: 1)
                        } label: {
                            Label("下一章", systemImage: "chevron.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(chapterIndex >= novel.chapters.count - 1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .tint(NoveliaStyle.brandGreen)
                    .padding(.top, 10)
                    .padding(.bottom, 35)
                }
                .padding(.horizontal, 23)
                .frame(maxWidth: 660)
                .frame(maxWidth: .infinity)
            }
            .background(ReaderBackgroundView(dark: appearance.isDark(system: systemColorScheme), fallback: readerBackground).ignoresSafeArea())
            .onPreferenceChange(ReaderScrollFrames.self) { visibleAnchor = ReaderScrollFrames.visible($0) }
            .task(id: "\(selectedSearchHit?.id ?? "")|\(chapter.id)|\(isLoadingChapter)|\(returnAnchor ?? "")") {
                guard !isLoadingChapter else { return }
                await Task.yield()
                if let anchor = returnAnchor { proxy.scrollTo(anchor, anchor: .top); returnAnchor = nil }
                else if let hit = selectedSearchHit, hit.chapterIndex == chapterIndex { scrollToFind(proxy, offset: hit.utf16Offset) }
            }
            .onValueChange(of: chapterIndex) { _, newIndex in
                guard novel.chapters.indices.contains(newIndex) else { return }
                savedChapterIndex = newIndex
                settings.recordWebPosition(id: novel.id, chapterIndex: newIndex)
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(novel.chapters[newIndex].id, anchor: .top)
                }
            }
        .toolbar {
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Menu {
                    Button("书内搜索") { isShowingSearch = true }
                    if let point = readingReturnPoint {
                        Button("回到刚才阅读处") {
                            selectedSearchHit = nil; chapterIndex = point.chapter; returnAnchor = point.anchor; readingReturnPoint = nil
                        }
                    }
                    Button("本书文字处理") { isShowingBookPreferences = true }
                    NavigationLink("离线章节") { OfflineChapterManagementView(novel: novel) }
                    Button {
                        isShowingChapterDirectory = true
                    } label: {
                        Label("章节目录", systemImage: "list.bullet")
                            .foregroundStyle(readerPrimaryText)
                    }
                    .accessibilityLabel("章节目录")

                    Button { settings.pagedTextReading = true } label: {
                        Label("分页阅读", systemImage: "book.pages")
                            .foregroundStyle(readerPrimaryText)
                    }
                    .accessibilityLabel("分页阅读")

                    Button(action: toggleBookmark) {
                        Label(isBookmarked ? "移除书签" : "添加书签", systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    .accessibilityLabel(isBookmarked ? "移除书签" : "添加书签")

                    Menu {
                        Toggle("本书使用独立样式", isOn: Binding(get: { settings.usesBookPreferences }, set: { settings.setBookPreferencesEnabled($0) }))
                        Divider()
                        Picker("显示内容", selection: $modeRaw) {
                            ForEach(ReaderMode.allCases) { item in
                                Text(item.title).tag(item.rawValue)
                            }
                        }
                        Divider()
                        Picker("译文来源", selection: $translationSourceRaw) {
                            ForEach(NovelTranslationSource.allCases) { source in
                                Text(source.title).tag(source.rawValue)
                            }
                        }
                        Divider()
                        NavigationLink("阅读背景") { ReaderBackgroundSettingsView() }
                        Picker("阅读外观", selection: $settings.appearanceRaw) {
                            ForEach(ReaderAppearance.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        Divider()
                        Button("缩小字号", systemImage: "textformat.size.smaller") {
                            settings.adjustFontSize(by: -1)
                        }
                        Button("放大字号", systemImage: "textformat.size.larger") {
                            settings.adjustFontSize(by: 1)
                        }
                    } label: {
                        Label("阅读设置", systemImage: "textformat.size")
                            .foregroundStyle(readerPrimaryText)
                    }
                    .accessibilityLabel("阅读设置")
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("阅读菜单")
                }
            }
            .onAppear {
                savedChapterIndex = chapterIndex
                if !settings.isRestoringWebPosition(id: novel.id, chapterIndex: chapterIndex) {
                    settings.recordWebPosition(id: novel.id, chapterIndex: chapterIndex)
                }
            }
            .task(id: "\(chapter.id)-\(loadAttempt)-\(auth.username ?? "")") {
                let chapterID = chapter.id
                guard await loadChapter(), !Task.isCancelled else { return }
                await readingHistory.recordRead(novel: novel, chapterId: chapterID, account: auth.username)
            }
        }
        .sheet(isPresented: $isShowingSearch) {
            ReaderBookmarksSearchSheet(store: settings.bookmarks, bookKey: "online:" + novel.id,
                chapterCount: novel.chapters.count, chapterTitle: { novel.chapters[$0].title }, chapterText: { index in
                    let listed = novel.chapters[index]
                    let cached = await settings.offlineChapters.cached(book: novel, chapter: listed.id, account: auth.offlineAccountScope)
                    guard let chapter = loadedChapters[listed.id] ?? cached ?? (listed.originalText.isEmpty ? nil : listed) else { throw CocoaError(.fileReadNoSuchFile) }
                    return displayedText(chapter)
                }, onJump: { index, _ in chapterIndex = index }, scopeDescription: "仅搜索已加载和本机缓存章节，不会下载未缓存正文。",
                onSearchHit: { hit in
                    if readingReturnPoint == nil { readingReturnPoint = .init(chapter: chapterIndex, anchor: visibleAnchor) }
                    chapterIndex = hit.chapterIndex; selectedSearchHit = hit
                }, tab: .search)
        }
        .sheet(isPresented: $isShowingBookPreferences) { ReaderBookPreferencesView() }
        .sheet(isPresented: $isShowingChapterDirectory) {
            ChapterDirectoryView(novel: novel, selectedIndex: Binding(get: { chapterIndex }, set: { index in
                if index != chapterIndex, readingReturnPoint == nil { readingReturnPoint = .init(chapter: chapterIndex, anchor: visibleAnchor) }
                chapterIndex = index
            }), appearance: appearance)
        }
        .environment(\.readerSearchRange, selectedSearchHit.flatMap { $0.chapterIndex == chapterIndex ? $0.utf16Offset..<($0.utf16Offset + $0.match.utf16.count) : nil })
        .toolbar {
            // 与分页阅读器一致：顶栏同时显示书名与当前章节。
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(novel.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !chapter.title.isEmpty {
                        Text(chapter.title)
                            .font(NoveliaStyle.fontMicro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
        .compatToolbar(.hidden, for: .tabBar)
        .preferredColorScheme(appearance.preferredColorScheme)
    }

    @ViewBuilder
    private var readerText: some View {
        switch mode {
        case .original:
            Paragraphs(text: settings.projection.apply(chapter.originalText), fontSize: fontSize, color: readerPrimaryText)
        case .translated:
            if displayedTranslation.allSatisfy(\.isEmpty) {
                unavailableTranslationMessage
            } else {
                Paragraphs(paragraphs: displayedTranslation, fontSize: fontSize, color: readerPrimaryText)
            }
        case .bilingual:
            bilingualReaderText
        }
    }

    private var bilingualReaderText: some View {
        let paragraphs = bilingualParagraphs
        let ranges = ReaderTextRanges.sourceRanges(of: paragraphs.flatMap { [$0.original, $0.translation] }, in: displayedText(chapter))
        return LazyVStack(alignment: .leading, spacing: 35) {
            ForEach(paragraphs.indices, id: \.self) { index in
                let paragraph = paragraphs[index]
                VStack(alignment: .leading, spacing: 8) {
                    if !paragraph.original.isEmpty {
                        ReaderTextBlock(text: paragraph.original, fontSize: fontSize, color: readerPrimaryText,
                                        baseOffset: ranges[index * 2]?.lowerBound)
                            .id("text-block-\(ranges[index * 2]?.lowerBound ?? -1)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !paragraph.translation.isEmpty {
                        ReaderTextBlock(text: paragraph.translation, fontSize: fontSize, color: readerSecondaryText,
                                        baseOffset: ranges[index * 2 + 1]?.lowerBound)
                            .id("text-block-\(ranges[index * 2 + 1]?.lowerBound ?? -1)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if paragraphs.isEmpty || selectedTranslationParagraphs?.allSatisfy({ $0.isEmpty }) == true {
                unavailableTranslationMessage
            }
        }
    }

    private var unavailableTranslationMessage: some View {
        Text("当前章节暂无\(translationSource.title)译文。可在阅读设置中切换译源。")
            .font(NoveliaStyle.fontBody)
            .foregroundStyle(readerSecondaryText)
    }

    private func changeChapter(by offset: Int) {
        let next = chapterIndex + offset
        guard novel.chapters.indices.contains(next) else { return }
        chapterIndex = next
        savedChapterIndex = next
    }

    private func toggleBookmark() {
        var next = bookmarkIDs
        if !next.insert(chapter.id).inserted {
            next.remove(chapter.id)
        }
        bookmarkIDsJSON = String(data: (try? JSONEncoder().encode(Array(next).sorted())) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    /// 与当前显示模式/译源一致，字符偏移才能映射回正文。
    private func displayedText(_ raw: NovelChapter) -> String {
        let chapter = raw.projected(settings.projection)
        switch mode {
        case .original: return chapter.originalText
        case .translated: return chapter.displayedTranslation(source: translationSource).joined(separator: "\n\n")
        case .bilingual:
            return chapter.bilingualParagraphs(source: translationSource)
                .flatMap { [$0.original, $0.translation] }.joined(separator: "\n\n")
        }
    }

    private func scrollToFind(_ proxy: ScrollViewProxy, offset: Int) {
        let text = displayedText(chapter)
        let pieces: [String]
        switch mode {
        case .original: pieces = settings.projection.apply(chapter.originalText).components(separatedBy: "\n\n")
        case .translated: pieces = displayedTranslation
        case .bilingual: pieces = bilingualParagraphs.flatMap { [$0.original, $0.translation] }
        }
        let ranges = ReaderTextRanges.sourceRanges(of: pieces, in: text)
        guard let index = ranges.firstIndex(where: { $0?.contains(offset) == true }),
              let range = ranges[index] else { return }
        let chunks = ReaderTextChunker.chunks(pieces[index], maximumCharacters: 200)
        let localRanges = ReaderTextRanges.sourceRanges(of: chunks, in: pieces[index])
        guard let chunk = localRanges.compactMap({ $0 }).first(where: { $0.contains(offset - range.lowerBound) }) else { return }
        proxy.scrollTo("text-offset-\(range.lowerBound + chunk.lowerBound)", anchor: .center)
    }


    @MainActor
    private func loadChapter() async -> Bool {
        guard novel.isRemote,
              let providerId = novel.providerId,
              let novelId = novel.novelId else { return false }
        guard chapter.originalText.isEmpty else { return true }
        isLoadingChapter = true
        chapterError = nil
        defer { isLoadingChapter = false }
        do {
            let loaded = try await settings.offlineChapters.chapter(chapter, book: novel, account: auth.offlineAccountScope, service: services.api.content, refresh: loadAttempt > 0)
            loadedChapters[chapter.id] = loaded
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            chapterError = error.localizedDescription
            return false
        }
    }
}

extension NovelChapter {
    /// 章节列出翻译来源时，返回所选来源的段落；
    /// 仅包含单一译文的章节返回 nil。
    func selectedTranslation(source: NovelTranslationSource) -> [String]? {
        guard let translationsBySource else { return nil }
        return translationsBySource[source] ?? []
    }

    func displayedTranslation(source: NovelTranslationSource) -> [String] {
        selectedTranslation(source: source) ?? translatedText.components(separatedBy: "\n\n")
    }

    func bilingualParagraphs(source: NovelTranslationSource) -> [NovelBilingualParagraph] {
        if let selected = selectedTranslation(source: source) {
            return Self.pair(originalText.components(separatedBy: "\n\n"), selected)
        }
        if let bilingualParagraphs, !bilingualParagraphs.isEmpty { return bilingualParagraphs }
        return Self.pair(originalText.components(separatedBy: "\n\n"), translatedText.components(separatedBy: "\n\n"))
    }

    /// 阅读器是否显示“此来源没有译文”的提示。
    func lacksTranslation(mode: ReaderMode, source: NovelTranslationSource) -> Bool {
        switch mode {
        case .original: false
        case .translated: displayedTranslation(source: source).allSatisfy(\.isEmpty)
        case .bilingual:
            bilingualParagraphs(source: source).isEmpty
                || selectedTranslation(source: source)?.allSatisfy(\.isEmpty) == true
        }
    }

    private static func pair(_ originals: [String], _ translations: [String]) -> [NovelBilingualParagraph] {
        (0..<max(originals.count, translations.count)).compactMap { index in
            let original = originals.indices.contains(index) ? originals[index] : ""
            let translation = translations.indices.contains(index) ? translations[index] : ""
            guard !original.isEmpty || !translation.isEmpty else { return nil }
            return NovelBilingualParagraph(original: original, translation: translation)
        }
    }

    /// 所选显示模式下供分页阅读器使用的章节文本。
    func pagedContent(novelTitle: String, mode: ReaderMode, source: NovelTranslationSource) -> TextChapterContent {
        var paragraphs: [TextChapterParagraph] = []
        switch mode {
        case .original:
            paragraphs = TextChapterXHTML.paragraphs(fromLines: originalText)
        case .translated:
            paragraphs = displayedTranslation(source: source).flatMap { TextChapterXHTML.paragraphs(fromLines: $0) }
        case .bilingual:
            for pair in bilingualParagraphs(source: source) {
                paragraphs += TextChapterXHTML.paragraphs(fromLines: pair.original)
                paragraphs += TextChapterXHTML.paragraphs(fromLines: pair.translation, role: .secondary)
            }
        }
        if lacksTranslation(mode: mode, source: source) {
            paragraphs.append(TextChapterParagraph(text: "当前章节暂无\(source.title)译文。可在右上角菜单切换译源。", role: .note))
        }
        return TextChapterContent(title: title, subtitle: novelTitle, paragraphs: paragraphs, linksURLs: true)
    }
}

private struct ChapterDirectoryView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var auth: AccountAuthStore
    @State private var cachedIDs = Set<String>()
    @State private var query = ""
    @State private var isReversed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    let novel: Novel
    @Binding var selectedIndex: Int
    let appearance: ReaderAppearance

    /// 搜索过滤后的章节；倒序只影响显示顺序，跳转仍用原始序号。
    private var rows: [(index: Int, chapter: NovelChapter)] {
        let all = novel.chapters.enumerated().map { (index: $0.offset, chapter: $0.element) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty ? all : all.filter { $0.chapter.title.localizedCaseInsensitiveContains(trimmed) }
        return isReversed ? Array(filtered.reversed()) : filtered
    }

    var body: some View {
        let rows = self.rows
        CompatNavigationStack {
            ScrollViewReader { proxy in
                List(rows, id: \.chapter.id) { row in
                    let chapter = row.chapter
                    ReaderTOCRow(title: chapter.title, level: 0,
                                 subtitle: cachedIDs.contains(chapter.id) ? "已缓存，可离线阅读" : nil,
                                 isCurrent: row.index == selectedIndex,
                                 showsDisclosureColumn: false,
                                 titleColor: appearance.primaryText(system: systemColorScheme)) {
                        selectedIndex = row.index
                        dismiss()
                    }
                    .listRowBackground(appearance.card(system: systemColorScheme))
                }
                .compatScrollContentBackgroundHidden()
                .background(appearance.background(system: systemColorScheme).ignoresSafeArea())
                .task(id: selectedIndex) {
                    guard novel.chapters.indices.contains(selectedIndex) else { return }
                    let chapterID = novel.chapters[selectedIndex].id
                    // 等待新打开的 List 完成首次布局，再定位惰性加载的行。
                    do { try await Task.sleep(nanoseconds: 100_000_000) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(chapterID, anchor: .center)
                }
                .task { cachedIDs = Set((try? await settings.offlineChapters.entries(account: auth.offlineAccountScope))?.filter { $0.bookID == novel.id }.map { $0.chapter.id } ?? []) }
                .navigationTitle("章节目录")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索章节标题")
                .toolbar {
                    ToolbarItem(placement: .compatTopBarLeading) {
                        Button(isReversed ? "正序" : "倒序") { isReversed.toggle() }
                            .accessibilityLabel(isReversed ? "切换为从第一章开始" : "切换为从最后一章开始")
                    }
                    ToolbarItem(placement: .compatTopBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct Paragraphs: View {
    let paragraphs: [String]
    let fontSize: Double
    let color: Color

    init(text: String, fontSize: Double, color: Color) {
        self.init(paragraphs: text.components(separatedBy: "\n\n"), fontSize: fontSize, color: color)
    }

    init(paragraphs: [String], fontSize: Double, color: Color) {
        self.paragraphs = paragraphs
        self.fontSize = fontSize
        self.color = color
    }

    var body: some View {
        let ranges = ReaderTextRanges.sourceRanges(of: paragraphs, in: paragraphs.joined(separator: "\n\n"))
        LazyVStack(alignment: .leading, spacing: 15) {
            ForEach(paragraphs.indices, id: \.self) { index in
                ReaderTextBlock(text: paragraphs[index], fontSize: fontSize, color: color,
                                baseOffset: ranges[index]?.lowerBound)
                    .id("text-block-\(ranges[index]?.lowerBound ?? -1)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ReaderTextBlock: View {
    let text: String
    let fontSize: Double
    let color: Color
    /// 本块首字符在整章正文中的 UTF-16 偏移，用于把搜索命中换算到块内。
    var baseOffset: Int? = nil

    private var chunks: [String] { ReaderTextChunker.chunks(text, maximumCharacters: 200) }

    var body: some View {
        let ranges = ReaderTextRanges.sourceRanges(of: chunks, in: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chunks.indices, id: \.self) { index in
                let offset = (baseOffset ?? 0) + (ranges[index]?.lowerBound ?? 0)
                LinkedReaderText(text: chunks[index], color: color, baseOffset: offset)
                    .id("text-offset-\(offset)")
                    .background(GeometryReader { geometry in Color.clear.preference(key: ReaderScrollFrames.self, value: ["text-offset-\(offset)": geometry.frame(in: .global)]) })
                    .font(.system(size: CGFloat(fontSize), weight: .regular, design: .serif))
                    .lineSpacing(fontSize * 0.48)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 让章节正文中的 URL 显示为可交互链接，同时保留阅读器字体与搜索命中底色。
private struct LinkedReaderText: View {
    let text: String
    let color: Color
    var baseOffset: Int = 0
    @Environment(\.readerSearchRange) private var searchRange

    private var attributedText: AttributedString {
        var value = AttributedString(text)
        value.foregroundColor = color
        ReaderTextHighlight.apply(ReaderTextRanges.localRange(searchRange, in: baseOffset..<(baseOffset + text.utf16.count)), text: text, to: &value)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return value
        }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: value) else { continue }
            value[range].link = url
            value[range].foregroundColor = UIColor.link
            value[range].underlineStyle = .single
        }
        return value
    }

    var body: some View {
        Text(attributedText)
            .tint(.accentColor)
    }
}

/// 限制滚动时每个 SwiftUI Text 视图需要测量的文本量。
enum ReaderTextChunker {
    static func chunks(_ text: String, maximumCharacters: Int = 2_400) -> [String] {
        guard !text.isEmpty else { return [" "] }
        guard maximumCharacters > 0 else { return [text] }

        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: maximumCharacters, limitedBy: text.endIndex) ?? text.endIndex
            if limit == text.endIndex {
                result.append(String(text[start..<text.endIndex]))
                break
            }

            let preferredBreak = text[start..<limit].lastIndex(of: "\n")
            let minimumBreak = text.index(start, offsetBy: maximumCharacters / 2, limitedBy: limit) ?? limit
            let boundary: String.Index
            if let preferredBreak, preferredBreak >= minimumBreak {
                boundary = text.index(after: preferredBreak)
            } else {
                boundary = limit
            }
            result.append(String(text[start..<boundary]))
            start = boundary
        }
        return result
    }
}

/// 支持 YueduCoreText 和实验性 Readium 的在线章节。单元序号就是小说章节序号；
/// 阅读进度、服务器阅读历史和书签与滚动模式一样，仍按章节记录。
private struct OnlinePagedReader: View {
    @EnvironmentObject private var services: AppServices
    #if !NOVELIA_READIUM_ONLY
    @AppStorage(SettingsKey.readerEPUBReadium) private var usesReadium = false
    #endif
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore
    let novel: Novel
    @Binding var chapterIndex: Int
    @AppStorage(SettingsKey.readerMode) private var modeRaw = ReaderMode.bilingual.rawValue
    @AppStorage(SettingsKey.readerTranslationSource) private var translationSourceRaw = NovelTranslationSource.gpt.rawValue
    @AppStorage private var bookmarkIDsJSON: String
    @AppStorage private var savedChapterIndex: Int
    @State private var cache = OnlineChapterCache()

    init(novel: Novel, chapterIndex: Binding<Int>) {
        self.novel = novel
        _chapterIndex = chapterIndex
        _bookmarkIDsJSON = AppStorage(wrappedValue: "[]", SettingsKey.bookmarks(novelID: novel.id))
        _savedChapterIndex = AppStorage(wrappedValue: 0, ReadingProgressStore.chapterKey(novelID: novel.id))
    }

    private var mode: ReaderMode { ReaderMode(rawValue: modeRaw) ?? .bilingual }
    private var translationSource: NovelTranslationSource { NovelTranslationSource(rawValue: translationSourceRaw) ?? .gpt }
    private var bookmarkIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(bookmarkIDsJSON.utf8))) ?? [])
    }
    private var currentChapterID: String? {
        novel.chapters.indices.contains(chapterIndex) ? novel.chapters[chapterIndex].id : nil
    }

    var body: some View {
        // 显示模式或来源变化会重新生成所有章节：从章节开头重新打开。
        Group {
            #if NOVELIA_READIUM_ONLY
            ReadiumEPUBReaderView(bookURL: nil, textBook: makeBook(), accessory: AnyView(Group { scrollButton; menu; NavigationLink("离线章节") { OfflineChapterManagementView(novel: novel) } }),
                                  statisticsBook: ReadingBook(id: "online:\(novel.id)", title: novel.title, kind: .online))
            #else
            if usesReadium {
                ReadiumEPUBReaderView(bookURL: nil, textBook: makeBook(), accessory: AnyView(Group { scrollButton; menu; NavigationLink("离线章节") { OfflineChapterManagementView(novel: novel) } }),
                                      statisticsBook: ReadingBook(id: "online:\(novel.id)", title: novel.title, kind: .online))
            } else {
                EPUBReaderView(bookURL: nil, textBook: makeBook(), accessory: AnyView(Group { scrollButton; menu; NavigationLink("离线章节") { OfflineChapterManagementView(novel: novel) } }),
                               statisticsBook: ReadingBook(id: "online:\(novel.id)", title: novel.title, kind: .online))
            }
            #endif
        }
        .id("\(modeRaw)|\(translationSourceRaw)")
    }

    private func makeBook() -> PagedTextBook {
        let novel = novel, mode = mode, source = translationSource, cache = cache
        let units = novel.chapters.map { listed in
            TextChapterSource.Unit(tocTitle: listed.title) {
                try await settings.offlineChapters.chapter(listed, book: novel, account: auth.offlineAccountScope, service: services.api.content)
                    .pagedContent(novelTitle: novel.title, mode: mode, source: source)
            }
        }
        return PagedTextBook(
            source: TextChapterSource(bookTitle: novel.title, units: units),
            startUnit: chapterIndex, startOffset: nil,
            onPosition: { unit, _ in chapterChanged(to: unit) }, preferenceKey: "online:" + novel.id,
            searchChapterText: { index in
                let listed = novel.chapters[index]
                guard let chapter = await settings.offlineChapters.cached(book: novel, chapter: listed.id, account: auth.offlineAccountScope) else { throw CocoaError(.fileReadNoSuchFile) }
                let html = TextChapterXHTML.document(chapter.pagedContent(novelTitle: novel.title, mode: mode, source: source))
                return BookTextSearch.plainText(html: settings.projection.applyHTML(html))
            })
    }

    private func chapterChanged(to unit: Int) {
        // 每次翻页后调用；仅在章节变化时记录。打开后的第一次报告若只是恢复，不写入同步位置。
        guard novel.chapters.indices.contains(unit), unit != cache.lastRecordedChapter else { return }
        let isOpening = cache.lastRecordedChapter == nil
        chapterIndex = unit
        savedChapterIndex = unit
        if !(isOpening && settings.isRestoringWebPosition(id: novel.id, chapterIndex: unit)) {
            settings.recordWebPosition(id: novel.id, chapterIndex: unit)
        }
        cache.lastRecordedChapter = unit
        guard novel.isRemote else { return }
        let chapterID = novel.chapters[unit].id
        Task { await readingHistory.recordRead(novel: novel, chapterId: chapterID, account: auth.username) }
    }

    /// 与 TXT 分页阅读器使用相同的控件和位置。
    private var scrollButton: some View {
        Button { settings.pagedTextReading = false } label: {
            Label("滚动阅读", systemImage: "scroll")
        }
        .accessibilityLabel("滚动阅读")
    }

    private var menu: some View {
        Menu {
            Picker("显示内容", selection: $modeRaw) {
                ForEach(ReaderMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("译文来源", selection: $translationSourceRaw) {
                ForEach(NovelTranslationSource.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            if let currentChapterID {
                let marked = bookmarkIDs.contains(currentChapterID)
                Button(marked ? "移除书签" : "添加书签", systemImage: marked ? "bookmark.fill" : "bookmark") {
                    toggleBookmark(currentChapterID)
                }
            }
        } label: {
            Label("阅读选项", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("阅读选项")
    }

    private func toggleBookmark(_ id: String) {
        var next = bookmarkIDs
        if !next.insert(id).inserted { next.remove(id) }
        bookmarkIDsJSON = String(data: (try? JSONEncoder().encode(Array(next).sorted())) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
}

/// 分页模式获取的章节，在同一阅读器切换显示模式时共享。
@MainActor
private final class OnlineChapterCache {
    private var chapters: [String: NovelChapter] = [:]
    private var inFlight: [String: Task<NovelChapter, Error>] = [:]
    /// 最近保存进度的章节；章内翻页不重复记录。
    var lastRecordedChapter: Int?

    func chapter(_ listed: NovelChapter, in novel: Novel, service: any NovelContentService) async throws -> NovelChapter {
        if let cached = chapters[listed.id] { return cached }
        guard listed.originalText.isEmpty, novel.isRemote,
              let providerId = novel.providerId, let novelId = novel.novelId else { return listed }
        let task = inFlight[listed.id] ?? Task {
            try await service.chapter(providerId: providerId, novelId: novelId, chapterId: listed.id)
        }
        inFlight[listed.id] = task
        defer { inFlight[listed.id] = nil }
        let loaded = try await task.value
        chapters[listed.id] = loaded
        return loaded
    }
}

private extension NovelChapter {
    func projected(_ projection: ReadingTextProjection) -> NovelChapter {
        NovelChapter(id: id, title: title, originalText: projection.apply(originalText), translatedText: projection.apply(translatedText),
            bilingualParagraphs: bilingualParagraphs?.map { NovelBilingualParagraph(original: projection.apply($0.original), translation: projection.apply($0.translation)) },
            translationsBySource: translationsBySource?.mapValues { $0.map(projection.apply) }, originalTitle: originalTitle, volumeTitle: volumeTitle, originalVolumeTitle: originalVolumeTitle)
    }
}
