// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 只暴露本地已解析 TXT 或 ZIP 内此前章节及当前章已读前缀；读取与分页视图完全隔离，不改写阅读位置。
struct LocalRecapSource {
    let bookKey: String
    let identity: String
    let title: String
    let currentChapter: Int
    let load: @Sendable (Range<Int>) async throws -> [RecapChapter]
    var hasCurrentChapterReadText = false
    var loadCurrentChapterReadText: (@Sendable () async throws -> RecapChapter?)? = nil

    private static let minimumPartialChapterCharacters = 30

    /// 按当前页/可视位置比例截取已读前缀，确保落在合法字符边界且不泄露未读后文。
    static func readPrefix(of text: String, fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        guard clamped > 0, !text.isEmpty else { return "" }
        if clamped >= 1 { return text }
        let utf16 = text.utf16
        let target = min(utf16.count, max(0, Int((Double(utf16.count) * clamped).rounded(.down))))
        guard target > 0 else { return "" }
        var utf16Index = utf16.index(utf16.startIndex, offsetBy: target)
        if utf16Index.samePosition(in: text) == nil, utf16Index > utf16.startIndex {
            utf16Index = utf16.index(before: utf16Index)
        }
        guard let end = utf16Index.samePosition(in: text) else { return "" }
        return String(text[..<end])
    }

    private static func makePartialRecapChapter(index: Int, title: String, text: String, maximumBytes: Int) -> RecapChapter? {
        var slice = text
        if slice.utf8.count > maximumBytes {
            var kept = ""
            var bytes = 0
            for character in slice.reversed() {
                let size = String(character).utf8.count
                if bytes + size > maximumBytes { break }
                kept.append(character)
                bytes += size
            }
            slice = String(kept.reversed())
        }
        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumPartialChapterCharacters else { return nil }
        let displayTitle = title.isEmpty ? "第 \(index + 1) 章（本章已读部分）" : "\(title)（本章已读部分）"
        return RecapChapter(index: index, title: displayTitle, text: slice)
    }

    static func txt(_ book: TXTParsedBook, title: String, chapter: Int,
                    currentUnitInChapter: Int = 0, currentUnitFraction: Double = 0, pagedUnits: Bool = false,
                    projection: ReadingTextProjection, maximumChapterBytes: Int = 96 * 1_024) -> Self {
        let hasCurrent = book.chapters.indices.contains(chapter) && (currentUnitInChapter > 0 || currentUnitFraction > 0)
        let currentLoader: (@Sendable () async throws -> RecapChapter?)?
        if hasCurrent {
            currentLoader = {
                let task = Task.detached(priority: .utility) { () -> RecapChapter? in
                    guard book.chapters.indices.contains(chapter) else { return nil }
                    try Task.checkCancellation()
                    let item = book.chapters[chapter]
                    var readText = ""
                    if pagedUnits {
                        let cuts = TXTTextUnitCuts.cuts(utf8: item.body.utf8, maximumUTF8: 36_000)
                        let unitCount = max(0, cuts.count - 1)
                        let fullUnits = min(max(0, currentUnitInChapter), unitCount)
                        let bytes = item.body.utf8
                        for unit in 0..<fullUnits {
                            try Task.checkCancellation()
                            let lower = bytes.index(bytes.startIndex, offsetBy: cuts[unit])
                            let upper = bytes.index(bytes.startIndex, offsetBy: cuts[unit + 1])
                            let rawUnit = String(decoding: bytes[lower..<upper], as: UTF8.self)
                            readText += projection.apply(rawUnit) + "\n"
                        }
                        if fullUnits < unitCount, currentUnitFraction > 0 {
                            let lower = bytes.index(bytes.startIndex, offsetBy: cuts[fullUnits])
                            let upper = bytes.index(bytes.startIndex, offsetBy: cuts[fullUnits + 1])
                            let rawUnit = String(decoding: bytes[lower..<upper], as: UTF8.self)
                            readText += Self.readPrefix(of: projection.apply(rawUnit), fraction: currentUnitFraction)
                        }
                    } else {
                        readText = Self.readPrefix(of: projection.apply(item.body), fraction: currentUnitFraction)
                    }
                    return Self.makePartialRecapChapter(index: chapter, title: item.title, text: readText, maximumBytes: maximumChapterBytes)
                }
                return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            }
        } else {
            currentLoader = nil
        }
        return LocalRecapSource(
            bookKey: "txt:" + book.contentHash,
            identity: FileContentHash.sha256(Data((book.contentHash + "|" + book.rulesFingerprint + "|" + projection.identity).utf8)),
            title: title,
            currentChapter: chapter,
            load: { range in
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
            },
            hasCurrentChapterReadText: hasCurrent,
            loadCurrentChapterReadText: currentLoader
        )
    }
    @MainActor
    static func epub(_ container: EPUBContainer, hash: String, currentSpine: Int,
                     currentSpineProgression: Double = 0,
                     projection: ReadingTextProjection, completeVolume: Bool = false, maximumChapterBytes: Int = 96 * 1_024) -> Self? {
        guard container.spine.indices.contains(currentSpine) else { return nil }
        let entries = container.toc.filter { $0.spineIndex != nil }
        var starts = Array(Set(entries.compactMap(\.spineIndex).filter { container.spine.indices.contains($0) } + [0])).sorted()
        if entries.isEmpty { starts = Array(container.spine.indices) }
        guard let current = starts.lastIndex(where: { $0 <= currentSpine }) else { return nil }
        let chapter = completeVolume ? starts.count : current
        let titles = starts.enumerated().map { index, start in entries.first { $0.spineIndex == start }?.title ?? "第 \(index + 1) 章" }
        let url = container.fileURL, count = container.spine.count, chapterStarts = starts
        let chapterStart = starts[current]
        let chapterEnd = current + 1 < starts.count ? starts[current + 1] : count
        let hasCurrent = !completeVolume && (currentSpine > chapterStart || currentSpineProgression > 0)
        let currentTitle = titles[current]
        let currentLoader: (@Sendable () async throws -> RecapChapter?)?
        if hasCurrent {
            currentLoader = {
                let task = Task.detached(priority: .utility) { () -> RecapChapter? in
                    guard try FileContentHash.sha256(url) == hash else { throw ReadingRecapError.invalidScope }
                    let copy = try await EPUBContainer.open(fileURL: url)
                    copy.displayProjection = projection
                    let clampedSpine = min(max(chapterStart, currentSpine), max(chapterStart, chapterEnd - 1))
                    var readText = ""
                    if clampedSpine > chapterStart {
                        for spine in chapterStart..<clampedSpine {
                            try Task.checkCancellation()
                            readText += BookTextSearch.plainText(html: try await copy.chapterHTML(at: spine)) + "\n"
                        }
                    }
                    if currentSpineProgression > 0, clampedSpine < chapterEnd {
                        try Task.checkCancellation()
                        let spineText = BookTextSearch.plainText(html: try await copy.chapterHTML(at: clampedSpine))
                        readText += Self.readPrefix(of: spineText, fraction: currentSpineProgression)
                    }
                    return Self.makePartialRecapChapter(index: current, title: currentTitle, text: readText, maximumBytes: maximumChapterBytes)
                }
                return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            }
        } else {
            currentLoader = nil
        }
        return LocalRecapSource(
            bookKey: "epub:" + hash,
            identity: hash + projection.identity,
            title: container.bookTitle,
            currentChapter: chapter,
            load: { range in
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
            },
            hasCurrentChapterReadText: hasCurrent,
            loadCurrentChapterReadText: currentLoader
        )
    }
}

private struct CharacterLookupKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
private struct AIContextExplainKey: EnvironmentKey { static let defaultValue: ((String, String?) -> Void)? = nil }
private struct ReadingRecapActionKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private struct CharacterCardsKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private struct CharacterCardsReadOnlyKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var characterLookup: ((String) -> Void)? {
        get { self[CharacterLookupKey.self] }
        set { self[CharacterLookupKey.self] = newValue }
    }
    /// 选中正文后调用的 AI 语境解析动作：(选中文本, 前后上下文)。
    var aiContextExplain: ((String, String?) -> Void)? {
        get { self[AIContextExplainKey.self] }
        set { self[AIContextExplainKey.self] = newValue }
    }
    var readingRecapAction: (() -> Void)? {
        get { self[ReadingRecapActionKey.self] }
        set { self[ReadingRecapActionKey.self] = newValue }
    }
    var characterCards: (() -> Void)? {
        get { self[CharacterCardsKey.self] }
        set { self[CharacterCardsKey.self] = newValue }
    }
    /// 浏览人物卡：隐藏生成与绑定菜单，人物详情仍可修改。
    var characterCardsReadOnly: (() -> Void)? {
        get { self[CharacterCardsReadOnlyKey.self] }
        set { self[CharacterCardsReadOnlyKey.self] = newValue }
    }
}
@MainActor
struct ReaderRecapMenu: View {
    @ObservedObject var store: ReadingRecapStore
    @Environment(\.readingRecapAction) private var open
    @Environment(\.characterCards) private var cards
    @Environment(\.characterCardsReadOnly) private var readOnlyCards
    var body: some View {
        Menu {
            Button("更新人物卡") { cards?() }.disabled(cards == nil)
            Button("查看人物卡") { readOnlyCards?() }.disabled(readOnlyCards == nil)
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
    @State private var showingCardsReadOnly = false
    @State private var characterQuery = ""
    @State private var explainRequest: AIContextExplainRequest?
    private var activityID: String { active && scenePhase == .active && !prompts && !showing && !showingCharacters && explainRequest == nil ? source?.bookKey ?? "none" : "inactive" }
    private var openAction: (() -> Void)? {
        guard let source, source.currentChapter > 0 || source.hasCurrentChapterReadText else { return nil }
        return { showing = true }
    }
    func body(content: Content) -> some View {
        content
            .environment(\.readingRecapAction, openAction)
            .environment(\.characterLookup, source == nil ? nil : { text in characterQuery = text; showingCharacters = true })
            .environment(\.aiContextExplain, services.readingAI.configuration.isEnabled ? { selection, context in
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                explainRequest = AIContextExplainRequest(selection: trimmed, context: context, bookTitle: source?.title)
            } : nil)
            .environment(\.characterCards, libraryBookKey == nil ? nil : { showingCards = true })
            .environment(\.characterCardsReadOnly, libraryBookKey == nil ? nil : { showingCardsReadOnly = true })
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
            .onValueChange(of: source?.identity) { _, _ in showing = false; showingCharacters = false; showingCards = false; explainRequest = nil }
            .onValueChange(of: source?.currentChapter) { previous, _ in
                if previous != nil { showing = false; showingCharacters = false; showingCards = false; prompts = false; explainRequest = nil }
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
            .sheet(isPresented: $showingCardsReadOnly) {
                NavigationView {
                    if let libraryBookKey {
                        ReadingCharacterCardsEntry(libraryBookKey: libraryBookKey, readOnly: true)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回阅读") { showingCardsReadOnly = false } } }
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
            .sheet(item: $explainRequest) { request in
                ReaderAIExplainSheet(request: request, ai: services.readingAI)
            }
    }
}

private struct AIContextExplainRequest: Identifiable, Equatable {
    let id = UUID()
    let selection: String
    let context: String?
    let bookTitle: String?
}

/// 选中正文后的 AI 语境解析对话面板：沿用阅读助手对话式气泡风格，
/// 仅发送当前选区、前后少量上下文与本面板内的追问记录，关闭即清除。
@MainActor
private struct ReaderAIExplainSheet: View {
    let request: AIContextExplainRequest
    @ObservedObject var ai: ReadingAIStore
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [ReadingAIExplainTurn] = []
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var failedFollowUp: String?
    @State private var isLoading = false
    @State private var copiedTurnID: UUID?
    @State private var activeTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private var revision: String {
        "\(turns.count)|\(isLoading ? 1 : 0)|\(ai.streamedCharacters)|\(errorMessage ?? "")"
    }
    private var canSendFollowUp: Bool {
        !isLoading && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            bubble(request.selection, label: "你 · 选中片段", user: true)

                            ForEach(turns) { turn in
                                if turn.role == .user {
                                    bubble(turn.text, label: "你", user: true)
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        bubble(turn.text, label: "阅读助手", user: false)
                                        Button {
                                            UIPasteboard.general.string = turn.text
                                            copiedTurnID = turn.id
                                        } label: {
                                            Label(copiedTurnID == turn.id ? "已复制" : "复制",
                                                  systemImage: copiedTurnID == turn.id ? "checkmark" : "doc.on.doc")
                                                .font(.caption)
                                        }
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .padding(.leading, 14)
                                    }
                                }
                            }

                            if isLoading {
                                VStack(alignment: .leading, spacing: 8) {
                                    bubble(ai.streamedPreview.isEmpty ? "正在结合上下文解析…" : ai.streamedPreview,
                                           label: "阅读助手", user: false)
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text(ai.streamedCharacters > 0 ? "正在解析（已收到 \(ai.streamedCharacters) 字）…" : "等待模型回复…")
                                            .font(.caption)
                                            .foregroundStyle(NoveliaStyle.muted)
                                    }
                                    .padding(.leading, 14)
                                }
                            }

                            if let errorMessage {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                    Button("重试") { retryLastRequest() }
                                        .buttonStyle(.bordered)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(NoveliaStyle.card)
                                .clipShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
                            }

                            Color.clear.frame(height: 1).id("latest")
                        }
                        .padding(16)
                    }
                    .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                    .onValueChange(of: revision) { _, _ in
                        withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                }

                Divider()

                HStack(alignment: .bottom, spacing: 10) {
                    followUpInputField
                        .focused($inputFocused)
                        .submitLabel(.send)
                        .onSubmit { sendFollowUp() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                                .stroke(NoveliaStyle.hairline, lineWidth: 1)
                        )
                    Button {
                        sendFollowUp()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSendFollowUp ? NoveliaStyle.brandGreen : NoveliaStyle.muted.opacity(0.45))
                    }
                    .disabled(!canSendFollowUp)
                    .accessibilityLabel("发送补充问题")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(NoveliaStyle.paper)
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("AI 语境解析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("重新解析") { restartExplain() }
                        .disabled(isLoading)
                }
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if turns.isEmpty && !isLoading && errorMessage == nil {
                    startInitialExplain()
                }
            }
            .onDisappear {
                activeTask?.cancel()
                activeTask = nil
            }
        }
    }

    @ViewBuilder
    private var followUpInputField: some View {
        if #available(iOS 16.0, *) {
            TextField("补充想了解的点或继续追问…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.body)
        } else {
            TextField("补充想了解的点或继续追问…", text: $draft)
                .font(.body)
        }
    }

    private func bubble(_ text: String, label: String, user: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(NoveliaStyle.muted)
                Text(text)
                    .font(.body)
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineSpacing(user ? 3 : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(14)
            .background(user ? NoveliaStyle.brandGreen.opacity(0.12) : NoveliaStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
            if !user { Spacer(minLength: 16) }
        }
    }

    private func restartExplain() {
        activeTask?.cancel()
        turns = []
        draft = ""
        errorMessage = nil
        failedFollowUp = nil
        copiedTurnID = nil
        startInitialExplain()
    }

    private func startInitialExplain() {
        let aiRequest = ReadingAIExplainPrompt.makeRequest(
            bookTitle: request.bookTitle,
            selection: request.selection,
            context: request.context
        )
        runRequest(aiRequest, followUpForRetry: nil)
    }

    private func sendFollowUp() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLoading, !trimmed.isEmpty else { return }
        let historySnapshot = turns
        draft = ""
        inputFocused = false
        turns.append(ReadingAIExplainTurn(role: .user, text: trimmed))
        let aiRequest = ReadingAIExplainPrompt.makeRequest(
            bookTitle: request.bookTitle,
            selection: request.selection,
            context: request.context,
            history: historySnapshot,
            followUp: trimmed
        )
        runRequest(aiRequest, followUpForRetry: trimmed)
    }

    private func retryLastRequest() {
        if let failedFollowUp {
            // 历史中最后一条就是失败时追加的用户追问，取其之前的对话作为上下文。
            let historyBeforeLast = turns.last?.role == .user ? Array(turns.dropLast()) : turns
            let aiRequest = ReadingAIExplainPrompt.makeRequest(
                bookTitle: request.bookTitle,
                selection: request.selection,
                context: request.context,
                history: historyBeforeLast,
                followUp: failedFollowUp
            )
            runRequest(aiRequest, followUpForRetry: failedFollowUp)
        } else {
            startInitialExplain()
        }
    }

    private func runRequest(_ aiRequest: ReadingAIRequest, followUpForRetry: String?) {
        activeTask?.cancel()
        errorMessage = nil
        failedFollowUp = followUpForRetry
        ai.refreshKeyStatus()
        guard ai.isReadyForGeneration else {
            errorMessage = "请先在「设置 → AI 阅读辅助」启用并配置模型与 API 密钥。"
            return
        }
        isLoading = true
        activeTask = Task { @MainActor in
            defer { isLoading = false }
            do {
                let response = try await ai.generate(aiRequest)
                guard !Task.isCancelled else { return }
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    errorMessage = "模型返回了空白内容，请重试。"
                } else {
                    failedFollowUp = nil
                    turns.append(ReadingAIExplainTurn(role: .assistant, text: text))
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
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
    @State private var currentPartialChapter: RecapChapter?
    @State private var plan: ReadingRecapPlan?
    @State private var result: ReadingRecap?
    @State private var error: String?
    @State private var progress: String?
    @State private var task: Task<Void, Never>?
    @State private var run = UUID()
    /// 故事梗概的覆盖范围：整本已读部分，或只回看最近 30 章。
    @State private var storyScope: StoryScope = .whole
    /// 直接读 Store，保存后界面立即刷新；不再用本地快照。
    private var story: BookStorySummary? { store.story(book: source.bookKey) }
    /// 生成任务由 store 持有，关闭面板不会中断；这里只读它的进度与错误。
    private var storyProgress: String? { store.storyProgress[storyKey] }
    private var storyError: String? { store.storyErrors[storyKey] }
    private var storyKey: String { FileContentHash.sha256(Data(source.bookKey.utf8)) }
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
                    Text(currentPartialChapter != nil || source.hasCurrentChapterReadText
                         ? "已纳入当前第 \(source.currentChapter + 1) 章的已读部分（未读后文不发送）；不检查此前章节是否逐章读过。"
                         : "当前第 \(source.currentChapter + 1) 章尚无已读正文，仅纳入此前章节；不检查此前章节是否逐章读过。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if let story {
                        Text(story.text)
                        Text(storyCoverageDescription(story))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if storyProgress == nil {
                        Text("还没有故事梗概。隔了很久回到这本书时，先看这里的整体梗概比逐章细节更有用。")
                            .foregroundStyle(.secondary)
                    }
                    if let storyProgress {
                        HStack { ProgressView(); Text(storyProgress) }
                        Button("取消") { store.cancelStory(book: source.bookKey) }
                    } else {
                        Button(story == nil ? "生成故事梗概" : "更新故事梗概") { generateStory() }
                            .disabled(!ai.configuration.isEnabled || (source.currentChapter == 0 && !source.hasCurrentChapterReadText && currentPartialChapter == nil))
                        Text(storyHint)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let storyError { Text(storyError).foregroundStyle(NoveliaStyle.danger) }
                } header: { Text("故事梗概") } footer: {
                    Text("封面、版权页与当前章未读后文不纳入；首次会分章压缩再归并，之后只处理新增已读部分。")
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
                        Text("回顾只依据已读章节与本章已读正文，AI 概括仍可能有误；查阅出处不改变续读位置。")
                    }
                }
                Section {
                    if source.currentChapter > 0 {
                        Picker("回看此前章节数", selection: $count) {
                            ForEach(1...max(1, min(3, source.currentChapter)), id: \.self) {
                                Text(currentPartialChapter != nil ? "最近 \($0) 章 + 本章已读" : "最近 \($0) 章").tag($0)
                            }
                        }.disabled(progress != nil)
                    }
                    if let progress {
                        HStack { ProgressView(); Text(progress) }
                        Button("取消并继续阅读") { cancel(); dismiss() }
                    } else if let plan {
                        Text("将向 \((try? ai.configuration.endpoint().host) ?? "所配置接口") 发送这 \(chapters.count) 段已读正文，共 \(plan.chunks.count) 个分块，可能产生模型费用。")
                            .font(.footnote)
                        Button(result == nil ? "发送并生成回顾" : "重新生成回顾") { generate(plan) }
                            .disabled(!ai.configuration.isEnabled)
                    }
                    if !ai.configuration.isEnabled { Text("请先在“我的 → 高级 → AI 阅读辅助”配置并启用 AI。已有匹配缓存仍可查看。").font(.footnote) }
                    if let error { Text(error).foregroundStyle(NoveliaStyle.danger) }
                } header: { Text("最近几章细节") } footer: {
                    Text("覆盖最近几章及本章已读部分的具体情节，用来接上“上次停在哪”。")
                }
            }
            .navigationTitle("前情回顾")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("继续阅读") { dismiss() } } }
            .task(id: preparationID) { await prepare() }
            .onDisappear { cancel() }
        }
    }
    private func storyCoverageDescription(_ story: BookStorySummary) -> String {
        if let partial = story.partialChapterUTF16, partial > 0 {
            return story.coveredThrough > 0
                ? "已覆盖到第 \(story.coveredThrough) 章及第 \(story.coveredThrough + 1) 章已读部分"
                : "已覆盖第 1 章已读部分"
        }
        return "已覆盖到第 \(story.coveredThrough) 章"
    }
    private func prepare() async {
        cancel(); error = nil; result = nil; plan = nil; chapters = []
        let snapshot = run
        let selected = min(count, source.currentChapter)
        do {
            let previousValues = selected > 0
                ? try await source.load((source.currentChapter - selected)..<source.currentChapter)
                : []
            let currentPartial = try await source.loadCurrentChapterReadText?()
            try Task.checkCancellation()
            guard snapshot == run else { return }
            currentPartialChapter = currentPartial
            // 前言、人物表、目录、后记不是剧情，混进去只会让回顾变成书评；
            // 但这几章之外没有内容时仍要能用，所以过滤后为空就退回原样。
            let filtered = previousValues.filter { !CharacterExtractionPlan.isNonStoryTitle($0.title) }
            var story = filtered.isEmpty ? previousValues : filtered
            if let currentPartial {
                story.append(currentPartial)
                while story.count > 1,
                      story.reduce(0, { $0 + $1.text.utf8.count }) > 96 * 1_024
                        || story.reduce(0, { $0 + max(1, ($1.text.utf8.count + 9_999) / 10_000) }) > 12 {
                    story.removeFirst()
                }
            }
            let effectiveBoundary = currentPartial != nil ? source.currentChapter + 1 : source.currentChapter
            let prepared = try ReadingRecapPlan(chapters: story, boundary: effectiveBoundary, identity: source.identity, modelIdentity: modelIdentity)
            chapters = story; plan = prepared; result = store.cached(plan: prepared, book: source.bookKey)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    /// 梗概从哪一章开始算：整本从第 1 章，最近范围从倒数第 30 章。
    private var storyStart: Int { storyScope == .whole ? 0 : max(0, source.currentChapter - 30) }
    private var storyHint: String {
        let completedBoundary = max(0, source.currentChapter)
        let partialUTF16 = currentPartialChapter?.text.utf16.count ?? 0
        guard completedBoundary > 0 || partialUTF16 > 0 || source.hasCurrentChapterReadText else {
            return "当前还没有可回顾的已读正文。"
        }
        let identity = (try? StorySummaryGenerator.fingerprint(identity: source.identity, configuration: ai.configuration)) ?? ""
        let reusable = story.flatMap {
            $0.fingerprint == identity && ($0.coveredThrough > storyStart || ($0.coveredThrough == storyStart && ($0.partialChapterUTF16 ?? 0) > 0)) ? $0 : nil
        }
        let covered = reusable != nil ? max(storyStart, reusable!.coveredThrough) : storyStart
        let hasNewCompleted = covered < completedBoundary
        let hasNewPartial = partialUTF16 > 0 && (reusable == nil || reusable!.coveredThrough < completedBoundary || (reusable!.partialChapterUTF16 ?? 0) < partialUTF16)
        guard hasNewCompleted || hasNewPartial else {
            return "梗概已覆盖到最新位置；继续阅读后可再次更新。"
        }
        if hasNewCompleted && partialUTF16 > 0 {
            return "将处理第 \(covered + 1)–\(completedBoundary) 章及第 \(completedBoundary + 1) 章已读部分，可能产生模型费用。"
        } else if hasNewCompleted {
            return "将处理第 \(covered + 1)–\(completedBoundary) 章正文（\(completedBoundary - covered) 章），可能产生模型费用。"
        } else {
            return "将处理第 \(completedBoundary + 1) 章已读部分，可能产生模型费用。"
        }
    }
    /// 只负责挑出要处理的章节并把任务交给 Store；中断由 Store 管理。
    private func generateStory() {
        let boundary = max(0, source.currentChapter)
        guard ai.configuration.isEnabled else {
            store.reportStoryError("请先在“我的 → 高级 → AI 阅读辅助”配置并启用 AI。", book: source.bookKey)
            return
        }
        guard !store.isBuildingStory(book: source.bookKey) else { return }
        guard let identity = try? StorySummaryGenerator.fingerprint(identity: source.identity, configuration: ai.configuration) else {
            store.reportStoryError("当前 AI 配置无法用于生成，请检查模型与输出上限。", book: source.bookKey)
            return
        }
        let start = storyScope == .whole ? 0 : max(0, boundary - 30)
        let reusable = story.flatMap {
            $0.fingerprint == identity && ($0.coveredThrough > start || ($0.coveredThrough == start && ($0.partialChapterUTF16 ?? 0) > 0)) ? $0 : nil
        }
        let from = max(start, reusable?.coveredThrough ?? start)
        Task {
            do {
                var values = from < boundary ? try await source.load(from..<boundary) : []
                let partial = try await source.loadCurrentChapterReadText?()
                let partialUTF16 = partial?.text.utf16.count ?? 0
                let hasNewPartial = partialUTF16 > 0 && (reusable == nil || reusable!.coveredThrough < boundary || (reusable!.partialChapterUTF16 ?? 0) < partialUTF16)
                guard !values.isEmpty || hasNewPartial else {
                    store.reportStoryError("梗概已经覆盖到当前阅读位置；继续阅读后再更新。", book: source.bookKey)
                    return
                }
                if let partial {
                    values.append(partial)
                    while values.count > 1, values.reduce(0, { $0 + $1.text.utf8.count }) > 512 * 1_024 {
                        values.removeFirst()
                    }
                }
                guard !values.isEmpty else {
                    store.reportStoryError("这一范围内没有可取用的正文。", book: source.bookKey)
                    return
                }
                // 生成任务交给 Store 持有：关闭面板、离开阅读器都不会中断。
                store.startStory(book: source.bookKey, chapters: values, previous: from > start ? reusable : nil,
                                 identity: source.identity, coveredThrough: boundary,
                                 partialChapterUTF16: partial?.text.utf16.count, ai: ai)
            } catch {
                store.reportStoryError(error.localizedDescription, book: source.bookKey)
            }
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
