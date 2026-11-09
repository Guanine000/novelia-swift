// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 只暴露本地已解析 TXT 或 ZIP 内此前章节；读取与分页视图完全隔离，不改写阅读位置。
struct LocalRecapSource {
    let bookKey: String
    let identity: String
    let title: String
    let currentChapter: Int
    let load: @Sendable (Range<Int>) async throws -> [RecapChapter]

    static func txt(_ book: TXTParsedBook, title: String, chapter: Int, projection: ReadingTextProjection, maximumChapterBytes: Int = 96 * 1_024) -> Self {
        .init(bookKey: "txt:" + book.contentHash, identity: FileContentHash.sha256(Data((book.contentHash + "|" + book.rulesFingerprint + "|" + projection.identity).utf8)),
              title: title, currentChapter: chapter) { range in
            guard range.lowerBound >= 0, range.upperBound <= chapter, range.upperBound <= book.chapters.count else { throw ReadingRecapError.invalidScope }
            let task = Task.detached(priority: .utility) {
                var totalBytes = 0
                return try range.map { index in
                    try Task.checkCancellation()
                    let item = book.chapters[index], text = projection.apply(book.chapters[index].body)
                    totalBytes += text.utf8.count
                    guard totalBytes <= maximumChapterBytes else { throw ReadingRecapError.tooLarge }
                    return RecapChapter(index: index, title: item.title, text: text)
                }
            }
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }
    @MainActor
    static func epub(_ container: EPUBContainer, hash: String, currentSpine: Int, projection: ReadingTextProjection, completeVolume: Bool = false, maximumChapterBytes: Int = 96 * 1_024) -> Self? {
        guard container.spine.indices.contains(currentSpine) else { return nil }
        let entries = container.toc.filter { $0.spineIndex != nil }
        var starts = Array(Set(entries.compactMap(\.spineIndex).filter { container.spine.indices.contains($0) } + [0])).sorted()
        if entries.isEmpty { starts = Array(container.spine.indices) }
        guard let current = starts.lastIndex(where: { $0 <= currentSpine }) else { return nil }
        let chapter = completeVolume ? starts.count : current
        let titles = starts.enumerated().map { index, start in entries.first { $0.spineIndex == start }?.title ?? "第 \(index + 1) 章" }
        let url = container.fileURL, count = container.spine.count, chapterStarts = starts
        return .init(bookKey: "epub:" + hash, identity: hash + projection.identity, title: container.bookTitle, currentChapter: chapter) { range in
            guard range.lowerBound >= 0, range.upperBound <= chapter else { throw ReadingRecapError.invalidScope }
            let task = Task.detached(priority: .utility) {
                guard try FileContentHash.sha256(url) == hash else { throw ReadingRecapError.invalidScope }
                let copy = try await EPUBContainer.open(fileURL: url)
                copy.displayProjection = projection
                var chapters = [RecapChapter](), totalBytes = 0
                for index in range {
                    try Task.checkCancellation()
                    let end = index + 1 < chapterStarts.count ? chapterStarts[index + 1] : count
                    var text = ""
                    for spine in chapterStarts[index]..<end {
                        try Task.checkCancellation()
                        text += BookTextSearch.plainText(html: try await copy.chapterHTML(at: spine)) + "\n"
                        guard text.utf8.count <= maximumChapterBytes else { throw ReadingRecapError.tooLarge }
                    }
                    totalBytes += text.utf8.count
                    guard totalBytes <= maximumChapterBytes else { throw ReadingRecapError.tooLarge }
                    chapters.append(.init(index: index, title: titles[index], text: text))
                }
                return chapters
            }
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }
}

private struct CharacterLookupKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
private struct ReadingRecapActionKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private struct CharacterCardsKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var characterLookup: ((String) -> Void)? {
        get { self[CharacterLookupKey.self] }
        set { self[CharacterLookupKey.self] = newValue }
    }
    var readingRecapAction: (() -> Void)? {
        get { self[ReadingRecapActionKey.self] }
        set { self[ReadingRecapActionKey.self] = newValue }
    }
    var characterCards: (() -> Void)? {
        get { self[CharacterCardsKey.self] }
        set { self[CharacterCardsKey.self] = newValue }
    }
}
@MainActor
struct ReaderRecapMenu: View {
    @ObservedObject var store: ReadingRecapStore
    @Environment(\.readingRecapAction) private var open
    @Environment(\.characterLookup) private var characters
    @Environment(\.characterCards) private var cards
    var body: some View {
        Menu {
            Button("查看角色卡") { cards?() }.disabled(cards == nil)
            Button("查询人物词条") { characters?("") }.disabled(characters == nil)
            Button("生成 AI 前情回顾") { open?() }.disabled(open == nil)
            Picker("久未阅读时询问", selection: $store.promptAfterDays) {
                Text("不自动询问").tag(0)
                ForEach([3, 7, 14, 30], id: \.self) { Text("\($0) 天后").tag($0) }
            }
        } label: { Label("AI 阅读辅助", systemImage: "sparkles") }
    }
}

/// 每次打开的提示决策在更新最后阅读时间之前完成；切章、后台恢复均不重复弹窗。
@MainActor
struct ReaderRecapPresentation: ViewModifier {
    @ObservedObject var store: ReadingRecapStore
    let source: LocalRecapSource?
    let active: Bool
    var libraryBookKey: String? = nil
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var visitedBook: String?
    @State private var prompts = false
    @State private var showing = false
    @State private var showingCharacters = false
    @State private var showingCards = false
    @State private var characterQuery = ""
    private var activityID: String { active && scenePhase == .active && !prompts && !showing && !showingCharacters ? source?.bookKey ?? "none" : "inactive" }
    private var openAction: (() -> Void)? {
        guard let source, source.currentChapter > 0 else { return nil }
        return { showing = true }
    }
    func body(content: Content) -> some View {
        content
            .environment(\.readingRecapAction, openAction)
            .environment(\.characterLookup, source == nil ? nil : { text in characterQuery = text; showingCharacters = true })
            .environment(\.characterCards, libraryBookKey == nil ? nil : { showingCards = true })
            .task(id: source?.bookKey) {
                guard let source, visitedBook != source.bookKey else { return }
                visitedBook = source.bookKey
                services.readingAI.refreshKeyStatus()
                prompts = services.readingAI.isReadyForGeneration && store.claimPrompt(book: source.bookKey, boundary: source.currentChapter)
            }
            .task(id: activityID) {
                guard activityID != "inactive", let source else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    store.recordReading(book: source.bookKey)
                }
            }
            .onValueChange(of: source?.identity) { _, _ in showing = false; showingCharacters = false; showingCards = false }
            .onValueChange(of: source?.currentChapter) { previous, _ in
                if previous != nil { showing = false; showingCharacters = false; showingCards = false; prompts = false }
            }
            .alert("要生成前情回顾吗？", isPresented: $prompts) {
                Button("继续阅读", role: .cancel) {}
                Button("生成回顾") { showing = true }
            } message: {
                Text("你已经有一段时间没读《\(source?.title ?? "这本书")》了。回顾只使用当前章之前的本地正文，发送范围将在生成前显示。")
            }
            .sheet(isPresented: $showingCharacters) {
                NavigationView {
                    if let source {
                        ReadingCharactersEntry(libraryBook: libraryBookKey, source: source, query: characterQuery)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回阅读") { showingCharacters = false } } }
                    }
                }
            }
            .sheet(isPresented: $showingCards) {
                NavigationView {
                    if let libraryBookKey {
                        ReadingCharacterCardsEntry(libraryBookKey: libraryBookKey)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回阅读") { showingCards = false } } }
                    }
                }
            }
            .sheet(isPresented: $showing) {
                if let source { ReadingRecapSheet(source: source, store: store, ai: services.readingAI) }
            }
    }
}

@MainActor
private struct ReadingRecapSheet: View {
    let source: LocalRecapSource
    @ObservedObject var store: ReadingRecapStore
    @ObservedObject var ai: ReadingAIStore
    @Environment(\.dismiss) private var dismiss
    @State private var count = 3
    @State private var chapters = [RecapChapter]()
    @State private var plan: ReadingRecapPlan?
    @State private var result: ReadingRecap?
    @State private var error: String?
    @State private var progress: String?
    @State private var task: Task<Void, Never>?
    @State private var run = UUID()
    /// 故事梗概的覆盖范围：整本已读部分，或只回看最近 30 章。
    @State private var storyScope: StoryScope = .whole
    @State private var story: BookStorySummary?
    @State private var storyProgress: String?
    @State private var storyTask: Task<Void, Never>?
    @State private var storyError: String?
    enum StoryScope: String, CaseIterable, Identifiable {
        case whole, recent
        var id: String { rawValue }
        var title: String { self == .whole ? "全书已读部分" : "最近 30 章" }
    }
    init(source: LocalRecapSource, store: ReadingRecapStore, ai: ReadingAIStore) {
        self.source = source; self.store = store; self.ai = ai
        _count = State(initialValue: max(1, min(3, source.currentChapter)))
    }
    private var modelIdentity: String {
        var config = ai.configuration; config.isEnabled = false
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return FileContentHash.sha256((try? encoder.encode(config)) ?? Data())
    }
    private var preparationID: String { "\(count)|\(modelIdentity)" }
    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(source.title)
                    Picker("梗概覆盖范围", selection: $storyScope) {
                        ForEach(StoryScope.allCases) { Text($0.title).tag($0) }
                    }.disabled(storyProgress != nil)
                    Text("当前第 \(source.currentChapter + 1) 章不纳入回顾；不检查此前章节是否逐章读过。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if let story {
                        Text(story.text)
                        Text("已覆盖到第 \(story.coveredThrough) 章")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if storyProgress == nil {
                        Text("还没有故事梗概。隔了很久回到这本书时，先看这里的整体梗概比逐章细节更有用。")
                            .foregroundStyle(.secondary)
                    }
                    if let storyProgress {
                        HStack { ProgressView(); Text(storyProgress) }
                        Button("取消") { cancelStory() }
                    } else {
                        Button(story == nil ? "生成故事梗概" : "更新故事梗概") { generateStory() }
                            .disabled(!ai.configuration.isEnabled || source.currentChapter == 0)
                        Text(storyHint)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let storyError { Text(storyError).foregroundStyle(NoveliaStyle.danger) }
                } header: { Text("故事梗概") } footer: {
                    Text("封面、版权页与当前章不纳入；首次会分章压缩再归并，之后只处理新增章节。")
                }
                if let result {
                    Section {
                        ForEach(result.events) { event in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(event.summary)
                                // 回顾不再要求模型抄原文，因此只有在拿到引文时才显示出处入口。
                                if event.quote.isEmpty {
                                    Text("第 \(event.chapter + 1) 章 · \(event.title)").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    DisclosureGroup("出处 · 第 \(event.chapter + 1) 章 · \(event.title)") {
                                        Text(event.quote).font(.footnote)
                                        if let chapter = chapters.first(where: { $0.index == event.chapter }) {
                                            NavigationLink("查看出处原文") { RecapEvidenceView(chapter: chapter, event: event) }
                                        }
                                    }
                                }
                            }
                        }
                    } header: { Text("AI 前情回顾") } footer: {
                        Text("回顾只依据已读章节正文，AI 概括仍可能有误；查阅出处不改变续读位置。")
                    }
                }
                Section {
                    Picker("回看章节数", selection: $count) {
                        ForEach(1...max(1, min(3, source.currentChapter)), id: \.self) { Text("最近 \($0) 章").tag($0) }
                    }.disabled(progress != nil)
                    if let progress {
                        HStack { ProgressView(); Text(progress) }
                        Button("取消并继续阅读") { cancel(); dismiss() }
                    } else if let plan {
                        Text("将向 \((try? ai.configuration.endpoint().host) ?? "所配置接口") 发送这 \(chapters.count) 章正文，共 \(plan.chunks.count) 个分块，可能产生模型费用。")
                            .font(.footnote)
                        Button(result == nil ? "发送并生成回顾" : "重新生成回顾") { generate(plan) }
                            .disabled(!ai.configuration.isEnabled)
                    }
                    if !ai.configuration.isEnabled { Text("请先在“我的 → 高级 → AI 阅读辅助”配置并启用 AI。已有匹配缓存仍可查看。").font(.footnote) }
                    if let error { Text(error).foregroundStyle(NoveliaStyle.danger) }
                } header: { Text("最近几章细节") } footer: {
                    Text("只覆盖最近几章的具体情节，用来接上“上次停在哪”。")
                }
            }
            .navigationTitle("前情回顾")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("继续阅读") { dismiss() } } }
            .task(id: preparationID) { await prepare() }
            .onDisappear { cancel(); cancelStory() }
        }
    }
    private func prepare() async {
        cancel(); error = nil; result = nil; plan = nil; chapters = []
        story = store.story(book: source.bookKey)
        let snapshot = run
        let selected = min(count, source.currentChapter)
        do {
            let values = try await source.load((source.currentChapter - selected)..<source.currentChapter)
            try Task.checkCancellation()
            guard snapshot == run else { return }
            let prepared = try ReadingRecapPlan(chapters: values, boundary: source.currentChapter, identity: source.identity, modelIdentity: modelIdentity)
            chapters = values; plan = prepared; result = store.cached(plan: prepared, book: source.bookKey)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    /// 梗概从哪一章开始算：整本从第 1 章，最近范围从倒数第 30 章。
    private var storyStart: Int { storyScope == .whole ? 0 : max(0, source.currentChapter - 30) }
    private var storyHint: String {
        guard source.currentChapter > 0 else { return "当前还没有可回顾的完整章节。" }
        let identity = (try? StorySummaryGenerator.fingerprint(identity: source.identity, configuration: ai.configuration)) ?? ""
        let reusable = story?.fingerprint == identity && (story?.coveredThrough ?? 0) > storyStart
        let covered = reusable ? max(storyStart, story?.coveredThrough ?? storyStart) : storyStart
        guard covered < source.currentChapter else { return "梗概已覆盖到最新位置；读到新章节后可再次更新。" }
        return "将处理第 \(covered + 1)–\(source.currentChapter) 章正文（\(source.currentChapter - covered) 章），可能产生模型费用。"
    }
    private func cancelStory() { storyTask?.cancel(); storyTask = nil; storyProgress = nil }
    private func generateStory() {
        guard ai.configuration.isEnabled else { return }
        guard let identity = try? StorySummaryGenerator.fingerprint(identity: source.identity, configuration: ai.configuration) else {
            storyError = "当前 AI 配置无法用于生成，请检查模型与输出上限。"; return
        }
        let start = storyStart
        let reusable = story.flatMap { $0.fingerprint == identity && $0.coveredThrough > start ? $0 : nil }
        let from = max(start, reusable?.coveredThrough ?? start)
        guard from < source.currentChapter else { storyError = "当前的梗概已经覆盖到最新章节。"; return }
        cancelStory(); storyError = nil; storyProgress = "准备载入正文…"
        let snapshot = run
        storyTask = Task {
            do {
                let values = try await source.load(from..<source.currentChapter)
                try Task.checkCancellation()
                guard snapshot == run else { return }
                let text = try await StorySummaryGenerator.generate(chapters: values, previous: from > start ? reusable : nil, ai: ai) { storyProgress = $0 }
                guard !Task.isCancelled, snapshot == run else { return }
                let value = BookStorySummary(coveredThrough: source.currentChapter, text: text, fingerprint: identity, updatedAt: Date())
                store.saveStory(value, book: source.bookKey); story = value
            } catch is CancellationError {} catch {
                guard snapshot == run, !Task.isCancelled else { return }
                storyError = error.localizedDescription
            }
            if snapshot == run { storyProgress = nil; storyTask = nil }
        }
    }
    private func cancel() { run = UUID(); task?.cancel(); task = nil; progress = nil }
    private func generate(_ plan: ReadingRecapPlan) {
        cancel(); error = nil; result = nil; progress = "准备生成…"
        let snapshot = run, identity = modelIdentity
        task = Task {
            do {
                let value = try await ReadingRecapGenerator.generate(plan: plan, ai: ai) { index, count in
                    progress = "正在生成 \(index)/\(count)…"
                }
                guard !Task.isCancelled, snapshot == run, identity == modelIdentity else { return }
                store.save(value, book: source.bookKey); result = value
            } catch is CancellationError {} catch {
                guard snapshot == run, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if snapshot == run { progress = nil; task = nil }
        }
    }
}

/// 独立只读出处页，不调用阅读器导航或持久进度写入；返回即回到原回顾卡。
@MainActor
struct RecapEvidenceView: View {
    let chapter: RecapChapter
    let event: RecapEvent
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let text = chapter.text as NSString
                    let start = min(text.length, max(0, event.offset))
                    let end = min(text.length, start + event.quote.utf16.count)
                    Text(text.substring(to: start))
                    Text(text.substring(with: NSRange(location: start, length: end - start)))
                        .foregroundStyle(NoveliaStyle.brandGreen).id("evidence")
                    Text(text.substring(from: end))
                }.padding().textSelection(.enabled)
            }.task { proxy.scrollTo("evidence", anchor: .center) }
        }.navigationTitle(chapter.title)
    }
}
