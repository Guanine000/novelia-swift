import SwiftUI

struct ReaderView: View {
    let novel: Novel
    @State private var chapterIndex: Int
    @AppStorage("readerMode") private var modeRaw = ReaderMode.bilingual.rawValue
    @AppStorage("readerFontSize") private var fontSize = 20.0
    @AppStorage private var bookmarkIDsJSON: String
    @AppStorage private var savedChapterIndex: Int
    @State private var loadedChapters: [String: NovelChapter] = [:]
    @State private var isLoadingChapter = false
    @State private var chapterError: String?
    @State private var loadAttempt = 0

    init(novel: Novel, startingAt: Int) {
        self.novel = novel
        _chapterIndex = State(initialValue: min(max(0, startingAt), max(0, novel.chapters.count - 1)))
        _bookmarkIDsJSON = AppStorage(wrappedValue: "[]", "bookmarks.\(novel.id)")
        _savedChapterIndex = AppStorage(wrappedValue: 0, "progress.\(novel.id)")
    }

    private var chapter: NovelChapter {
        let listed = novel.chapters[chapterIndex]
        return loadedChapters[listed.id] ?? listed
    }
    private var mode: ReaderMode { ReaderMode(rawValue: modeRaw) ?? .bilingual }
    private var bookmarkIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(bookmarkIDsJSON.utf8))) ?? [])
    }
    private var isBookmarked: Bool { bookmarkIDs.contains(chapter.id) }
    private var bilingualParagraphs: [NovelBilingualParagraph] {
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
                VStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("\(novel.title.uppercased())  ·  \(chapterIndex + 1) / \(novel.chapters.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(NoveliaStyle.coral)
                        Text(chapter.title)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .lineSpacing(4)
                            .foregroundStyle(NoveliaStyle.ink)
                        Text("著 · \(novel.author)")
                            .font(.system(size: 13))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    .padding(.top, 14)

                    Rectangle()
                        .fill(NoveliaStyle.coral.opacity(0.28))
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
                                .tint(NoveliaStyle.coral)
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
                            changeChapter(by: -1, proxy: proxy)
                        } label: {
                            Label("上一章", systemImage: "chevron.left")
                        }
                        .disabled(chapterIndex == 0)
                        Spacer()
                        Button {
                            changeChapter(by: 1, proxy: proxy)
                        } label: {
                            Label("下一章", systemImage: "chevron.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(chapterIndex >= novel.chapters.count - 1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .tint(NoveliaStyle.coral)
                    .padding(.top, 10)
                    .padding(.bottom, 35)
                }
                .padding(.horizontal, 23)
                .frame(maxWidth: 660)
                .frame(maxWidth: .infinity)
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .onChange(of: chapterIndex) { _, newIndex in
                guard novel.chapters.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(novel.chapters[newIndex].id, anchor: .top)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ChapterDirectoryView(novel: novel, selectedIndex: $chapterIndex)
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(NoveliaStyle.ink)
                    }
                    .accessibilityLabel("章节目录")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: toggleBookmark) {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(NoveliaStyle.coral)
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
                        Button("缩小字号", systemImage: "textformat.size.smaller") {
                            fontSize = max(16, fontSize - 1)
                        }
                        Button("放大字号", systemImage: "textformat.size.larger") {
                            fontSize = min(30, fontSize + 1)
                        }
                    } label: {
                        Image(systemName: "textformat.size")
                            .foregroundStyle(NoveliaStyle.ink)
                    }
                    .accessibilityLabel("阅读设置")
                }
            }
            .onAppear { savedChapterIndex = chapterIndex }
            .task(id: "\(chapter.id)-\(loadAttempt)") { await loadChapter() }
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var readerText: some View {
        switch mode {
        case .original:
            Paragraphs(text: chapter.originalText, fontSize: fontSize, color: NoveliaStyle.ink)
        case .translated:
            Paragraphs(text: chapter.translatedText, fontSize: fontSize, color: NoveliaStyle.ink)
        case .bilingual:
            VStack(alignment: .leading, spacing: 35) {
                ForEach(Array(bilingualParagraphs.enumerated()), id: \.offset) { _, paragraph in
                    VStack(alignment: .leading, spacing: 8) {
                        if !paragraph.original.isEmpty {
                            Paragraphs(text: paragraph.original, fontSize: fontSize, color: NoveliaStyle.ink)
                        }
                        if !paragraph.translation.isEmpty {
                            Paragraphs(text: paragraph.translation, fontSize: fontSize, color: NoveliaStyle.muted)
                        }
                    }
                }
                if bilingualParagraphs.isEmpty {
                    Text("当前章节暂无正文。")
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                }
            }
        }
    }

    private func changeChapter(by offset: Int, proxy: ScrollViewProxy) {
        let next = chapterIndex + offset
        guard novel.chapters.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            chapterIndex = next
            savedChapterIndex = next
        }
        proxy.scrollTo(novel.chapters[next].id, anchor: .top)
    }

    private func toggleBookmark() {
        var next = bookmarkIDs
        if !next.insert(chapter.id).inserted {
            next.remove(chapter.id)
        }
        bookmarkIDsJSON = String(data: (try? JSONEncoder().encode(Array(next).sorted())) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    @MainActor
    private func loadChapter() async {
        guard novel.isRemote,
              let providerId = novel.providerId,
              let novelId = novel.novelId,
              chapter.originalText.isEmpty else { return }
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
        } catch {
            guard !Task.isCancelled else { return }
            chapterError = error.localizedDescription
        }
    }
}

private struct ChapterDirectoryView: View {
    @Environment(\.dismiss) private var dismiss
    let novel: Novel
    @Binding var selectedIndex: Int

    var body: some View {
        List(Array(novel.chapters.enumerated()), id: \.element.id) { index, chapter in
            Button {
                selectedIndex = index
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(minWidth: 32, alignment: .trailing)
                    Text(chapter.title)
                        .font(.system(size: 14, weight: index == selectedIndex ? .semibold : .regular))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if index == selectedIndex {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NoveliaStyle.coral)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.white)
        }
        .scrollContentBackground(.hidden)
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("章节目录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Paragraphs: View {
    let text: String
    let fontSize: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: CGFloat(fontSize), weight: .regular, design: .serif))
                    .lineSpacing(fontSize * 0.48)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
