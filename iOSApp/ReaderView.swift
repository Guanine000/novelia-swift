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
    let novel: Novel
    private let isOffline: Bool
    private let offlineTranslationSource: NovelTranslationSource?
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var chapterIndex: Int
    @AppStorage("readerAppearance") private var appearanceRaw = ReaderAppearance.system.rawValue
    @AppStorage("readerMode") private var modeRaw = ReaderMode.bilingual.rawValue
    @AppStorage("readerTranslationSource") private var translationSourceRaw = NovelTranslationSource.gpt.rawValue
    @AppStorage("readerFontSize") private var fontSize = 20.0
    @AppStorage private var bookmarkIDsJSON: String
    @AppStorage private var savedChapterIndex: Int
    @State private var loadedChapters: [String: NovelChapter] = [:]
    @State private var isLoadingChapter = false
    @State private var chapterError: String?
    @State private var loadAttempt = 0

    init(
        novel: Novel,
        startingAt: Int,
        offlineChapters: [String: NovelChapter]? = nil,
        offlineTranslationSource: NovelTranslationSource? = nil
    ) {
        self.novel = novel
        isOffline = offlineChapters != nil
        self.offlineTranslationSource = offlineTranslationSource
        _chapterIndex = State(initialValue: min(max(0, startingAt), max(0, novel.chapters.count - 1)))
        _loadedChapters = State(initialValue: offlineChapters ?? [:])
        _bookmarkIDsJSON = AppStorage(wrappedValue: "[]", "bookmarks.\(novel.id)")
        _savedChapterIndex = AppStorage(wrappedValue: 0, "progress.\(novel.id)")
    }

    private var chapter: NovelChapter {
        let listed = novel.chapters[chapterIndex]
        return loadedChapters[listed.id] ?? listed
    }
    private var mode: ReaderMode { ReaderMode(rawValue: modeRaw) ?? .bilingual }
    private var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .system }
    private var translationSource: NovelTranslationSource {
        NovelTranslationSource(rawValue: translationSourceRaw) ?? .gpt
    }
    private var availableTranslationSources: [NovelTranslationSource] {
        guard isOffline else { return NovelTranslationSource.allCases }
        return offlineTranslationSource.map { [$0] } ?? []
    }
    private var readerBackground: Color { appearance.background(system: systemColorScheme) }
    private var readerPrimaryText: Color { appearance.primaryText(system: systemColorScheme) }
    private var readerSecondaryText: Color { appearance.secondaryText(system: systemColorScheme) }
    private var bookmarkIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(bookmarkIDsJSON.utf8))) ?? [])
    }
    private var isBookmarked: Bool { bookmarkIDs.contains(chapter.id) }
    private var selectedTranslationParagraphs: [String]? {
        guard let translations = chapter.translationsBySource else { return nil }
        return translations[translationSource] ?? []
    }
    private var displayedTranslation: [String] {
        selectedTranslationParagraphs ?? chapter.translatedText.components(separatedBy: "\n\n")
    }
    private var bilingualParagraphs: [NovelBilingualParagraph] {
        if let selectedTranslationParagraphs {
            let originals = chapter.originalText.components(separatedBy: "\n\n")
            let count = max(originals.count, selectedTranslationParagraphs.count)
            return (0..<count).compactMap { index in
                let original = originals.indices.contains(index) ? originals[index] : ""
                let translation = selectedTranslationParagraphs.indices.contains(index)
                    ? selectedTranslationParagraphs[index] : ""
                guard !original.isEmpty || !translation.isEmpty else { return nil }
                return NovelBilingualParagraph(original: original, translation: translation)
            }
        }
        if let paragraphs = chapter.bilingualParagraphs, !paragraphs.isEmpty { return paragraphs }
        let originals = chapter.originalText.components(separatedBy: "\n\n")
        let translations = chapter.translatedText.components(separatedBy: "\n\n")
        let count = max(originals.count, translations.count)
        return (0..<count).compactMap { index in
            let original = originals.indices.contains(index) ? originals[index] : ""
            let translation = translations.indices.contains(index) ? translations[index] : ""
            guard !original.isEmpty || !translation.isEmpty else { return nil }
            return NovelBilingualParagraph(original: original, translation: translation)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("\(novel.title.uppercased())  ·  \(chapterIndex + 1) / \(novel.chapters.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        Text(chapter.title)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .lineSpacing(4)
                            .foregroundStyle(readerPrimaryText)
                        Text("著 · \(novel.author)")
                            .font(.system(size: 13))
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
                        ContentUnavailableView {
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
                            .font(.system(size: 12))
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
            .onChange(of: chapterIndex) { _, newIndex in
                guard novel.chapters.indices.contains(newIndex) else { return }
                savedChapterIndex = newIndex
                ReadingPositionSync.recordWeb(id: novel.id, chapterIndex: newIndex)
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(novel.chapters[newIndex].id, anchor: .top)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ChapterDirectoryView(novel: novel, selectedIndex: $chapterIndex, appearance: appearance)
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(readerPrimaryText)
                    }
                    .accessibilityLabel("章节目录")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: toggleBookmark) {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    .accessibilityLabel(isBookmarked ? "移除书签" : "添加书签")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("显示内容", selection: $modeRaw) {
                            ForEach(ReaderMode.allCases) { item in
                                Text(item.title).tag(item.rawValue)
                            }
                        }
                        Divider()
                        if !availableTranslationSources.isEmpty {
                            Picker("译文来源", selection: $translationSourceRaw) {
                                ForEach(availableTranslationSources) { source in
                                    Text(source.title).tag(source.rawValue)
                                }
                            }
                        }
                        Divider()
                        NavigationLink("阅读背景") { ReaderBackgroundSettingsView() }
                        Picker("阅读外观", selection: $appearanceRaw) {
                            ForEach(ReaderAppearance.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        Divider()
                        Button("缩小字号", systemImage: "textformat.size.smaller") {
                            fontSize = max(16, fontSize - 1)
                        }
                        Button("放大字号", systemImage: "textformat.size.larger") {
                            fontSize = min(30, fontSize + 1)
                        }
                    } label: {
                        Image(systemName: "textformat.size")
                            .foregroundStyle(readerPrimaryText)
                    }
                    .accessibilityLabel("阅读设置")
                }
            }
            .onAppear {
                savedChapterIndex = chapterIndex
                ReadingPositionSync.recordWeb(id: novel.id, chapterIndex: chapterIndex)
                if let offlineTranslationSource { translationSourceRaw = offlineTranslationSource.rawValue }
            }
            .task(id: "\(chapter.id)-\(loadAttempt)-\(auth.username ?? "")") {
                let chapterID = chapter.id
                guard await loadChapter(), !Task.isCancelled else { return }
                await readingHistory.recordRead(novel: novel, chapterId: chapterID, account: auth.username)
            }
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(appearance.preferredColorScheme)
    }

    @ViewBuilder
    private var readerText: some View {
        switch mode {
        case .original:
            Paragraphs(text: chapter.originalText, fontSize: fontSize, color: readerPrimaryText)
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
        return LazyVStack(alignment: .leading, spacing: 35) {
            ForEach(paragraphs.indices, id: \.self) { index in
                let paragraph = paragraphs[index]
                VStack(alignment: .leading, spacing: 8) {
                    if !paragraph.original.isEmpty {
                        ReaderTextBlock(text: paragraph.original, fontSize: fontSize, color: readerPrimaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !paragraph.translation.isEmpty {
                        ReaderTextBlock(text: paragraph.translation, fontSize: fontSize, color: readerSecondaryText)
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
            .font(.system(size: 13))
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

    @MainActor
    private func loadChapter() async -> Bool {
        guard novel.isRemote,
              let providerId = novel.providerId,
              let novelId = novel.novelId else { return false }
        if isOffline { return !chapter.originalText.isEmpty || !chapter.translatedText.isEmpty }
        guard chapter.originalText.isEmpty else { return true }
        isLoadingChapter = true
        chapterError = nil
        defer { isLoadingChapter = false }
        do {
            let loaded = try await NoveliaAPIClient().chapter(
                providerId: providerId,
                novelId: novelId,
                chapterId: chapter.id
            )
            loadedChapters[chapter.id] = loaded
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            chapterError = error.localizedDescription
            return false
        }
    }
}

private struct ChapterDirectoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    let novel: Novel
    @Binding var selectedIndex: Int
    let appearance: ReaderAppearance

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(novel.chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    selectedIndex = index
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(appearance.secondaryText(system: systemColorScheme))
                            .frame(minWidth: 32, alignment: .trailing)
                        Text(chapter.title)
                            .font(.system(size: 14, weight: index == selectedIndex ? .semibold : .regular))
                            .foregroundStyle(appearance.primaryText(system: systemColorScheme))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if index == selectedIndex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .id(chapter.id)
                .buttonStyle(.plain)
                .listRowBackground(appearance.card(system: systemColorScheme))
            }
            .scrollContentBackground(.hidden)
            .background(appearance.background(system: systemColorScheme).ignoresSafeArea())
            .task(id: selectedIndex) {
                guard novel.chapters.indices.contains(selectedIndex) else { return }
                let chapterID = novel.chapters[selectedIndex].id
                // Wait for the pushed List's first layout before positioning a lazy row.
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                proxy.scrollTo(chapterID, anchor: .center)
            }
            .navigationTitle("章节目录")
            .navigationBarTitleDisplayMode(.inline)
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
        LazyVStack(alignment: .leading, spacing: 15) {
            ForEach(paragraphs.indices, id: \.self) { index in
                ReaderTextBlock(text: paragraphs[index], fontSize: fontSize, color: color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ReaderTextBlock: View {
    let text: String
    let fontSize: Double
    let color: Color

    private var chunks: [String] { ReaderTextChunker.chunks(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chunks.indices, id: \.self) { index in
                LinkedReaderText(text: chunks[index], color: color)
                    .font(.system(size: CGFloat(fontSize), weight: .regular, design: .serif))
                    .lineSpacing(fontSize * 0.48)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Makes URLs embedded in chapter prose visibly interactive while retaining the reader font.
private struct LinkedReaderText: View {
    let text: String
    let color: Color

    private var attributedText: AttributedString {
        var value = AttributedString(text)
        value.foregroundColor = color
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

/// Limits the amount of text each SwiftUI Text view has to measure during scrolling.
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
