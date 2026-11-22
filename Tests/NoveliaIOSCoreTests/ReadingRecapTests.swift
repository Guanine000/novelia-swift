// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NoveliaIOSCore

final class ReadingRecapTests: XCTestCase {
    private let text = "小明找到了丢失的钥匙，回到了朋友身边。大家决定明天继续寻找地图。"
    private func plan(boundary: Int = 2, identity: String = "book", model: String = "model") throws -> ReadingRecapPlan {
        try .init(chapters: [.init(index: boundary - 1, title: "此前一章", text: text)], boundary: boundary, identity: identity, modelIdentity: model)
    }
    private func response(chapter: Int = 1, quote: String? = nil) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["events": [["chapter": chapter, "summary": "小明找到钥匙并回到朋友身边。", "quote": quote ?? text]]])
        return String(decoding: data, as: UTF8.self)
    }
    func testOnlyContiguousPrecedingChaptersCanEnterModel() throws {
        XCTAssertThrowsError(try ReadingRecapPlan(chapters: [.init(index: 2, title: "当前章", text: "隐藏身份揭露")], boundary: 2, identity: "b", modelIdentity: "m"))
        XCTAssertThrowsError(try ReadingRecapPlan(chapters: [], boundary: 0, identity: "b", modelIdentity: "m"))
        XCTAssertThrowsError(try ReadingRecapPlan(chapters: [], boundary: -1, identity: "b", modelIdentity: "m"))
        let value = try plan()
        XCTAssertEqual(value.chunks.map(\.chapter), [1])
        XCTAssertFalse(value.chunks[0].request.input.contains("隐藏身份揭露"))
        let firstChapterPartial = try ReadingRecapPlan(
            chapters: [.init(index: 0, title: "第一章（本章已读部分）", text: text)],
            boundary: 1, identity: "b", modelIdentity: "m"
        )
        XCTAssertEqual(firstChapterPartial.chunks.map(\.chapter), [0])
        let withCurrentChapterPartial = try ReadingRecapPlan(
            chapters: [
                .init(index: 0, title: "第一章", text: text),
                .init(index: 1, title: "第二章", text: text),
                .init(index: 2, title: "第三章", text: text),
                .init(index: 3, title: "第四章（本章已读部分）", text: text)
            ],
            boundary: 4, identity: "b", modelIdentity: "m"
        )
        XCTAssertEqual(withCurrentChapterPartial.chunks.map(\.chapter), [0, 1, 2, 3])
    }
    func testChunkBoundariesPreserveUnicodeAndEvidenceOffsets() throws {
        let original = String(repeating: "😀前文。", count: 1_000) + text
        let value = try ReadingRecapPlan(chapters: [.init(index: 0, title: "首章", text: original)], boundary: 1, identity: "b", modelIdentity: "m")
        XCTAssertGreaterThan(value.chunks.count, 1)
        XCTAssertEqual(value.chunks.map(\.text).joined(), original)
        let last = try XCTUnwrap(value.chunks.last)
        let events = try ReadingRecapPlan.validate(response(chapter: 0), chunk: last)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual((original as NSString).substring(with: NSRange(location: event.offset, length: event.quote.utf16.count)), text)
    }
    func testFutureChaptersFabricatedQuotesAndWrongShapesAreRejected() throws {
        let chunk = try XCTUnwrap(plan().chunks.first)
        XCTAssertThrowsError(try ReadingRecapPlan.validate(response(chapter: 2), chunk: chunk))
        XCTAssertThrowsError(try ReadingRecapPlan.validate(response(quote: "这是原文中不存在的未来剧情。"), chunk: chunk))
        XCTAssertThrowsError(try ReadingRecapPlan.validate("```json\n{}\n```", chunk: chunk))
        XCTAssertThrowsError(try ReadingRecapPlan.validate("{\"events\":\"bad\"}", chunk: chunk))
        let value = try plan()
        XCTAssertThrowsError(try value.result(events: [.init(chapter: 1, title: "此前一章", summary: "坏偏移", quote: text, offset: Int.min)]))
    }
    func testInputBudgetFailsExplicitlyRatherThanTruncating() {
        let large = String(repeating: "中", count: 33_000)
        XCTAssertThrowsError(try ReadingRecapPlan(chapters: [.init(index: 0, title: "超长章", text: large)], boundary: 1, identity: "b", modelIdentity: "m"))
    }
    @MainActor
    func testReminderUsesPreviousActualReadingAndIsIndependentOfQueries() throws {
        let suite = "RecapDates-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingRecapStore(defaults: defaults), now = Date()
        XCTAssertFalse(store.shouldPrompt(book: "a", boundary: 2, now: now))
        store.recordReading(book: "a", now: now.addingTimeInterval(-8 * 86_400))
        XCTAssertTrue(store.shouldPrompt(book: "a", boundary: 2, now: now))
        XCTAssertTrue(store.shouldPrompt(book: "a", boundary: 2, now: now))
        XCTAssertTrue(store.claimPrompt(book: "a", boundary: 2, now: now))
        XCTAssertFalse(store.claimPrompt(book: "a", boundary: 2, now: now.addingTimeInterval(1)))
        XCTAssertFalse(store.shouldPrompt(book: "a", boundary: 0, now: now))
        XCTAssertFalse(store.shouldPrompt(book: "b", boundary: 2, now: now))
        store.promptAfterDays = 0
        XCTAssertFalse(store.shouldPrompt(book: "a", boundary: 2, now: now))
        store.promptAfterDays = 7; store.recordReading(book: "a", now: now)
        XCTAssertFalse(store.shouldPrompt(book: "a", boundary: 2, now: now))
    }
    @MainActor
    func testCacheCannotCrossBoundaryContentModelOrDirectoryRevision() throws {
        let suite = "RecapCache-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingRecapStore(defaults: defaults), plan = try self.plan()
        let events = try ReadingRecapPlan.validate(response(), chunk: plan.chunks[0])
        let result = try plan.result(events: events)
        store.save(result, book: "b")
        XCTAssertEqual(store.cached(plan: plan, book: "b"), result)
        XCTAssertNil(store.cached(plan: try self.plan(boundary: 1), book: "b"))
        XCTAssertNil(store.cached(plan: try self.plan(identity: "revised"), book: "b"))
        XCTAssertNil(store.cached(plan: try self.plan(model: "changed"), book: "b"))
        let changed = try ReadingRecapPlan(chapters: [.init(index: 1, title: "此前一章", text: text + "变更")], boundary: 2, identity: "book", modelIdentity: "model")
        XCTAssertNil(store.cached(plan: changed, book: "b"))
        XCTAssertEqual(ReadingRecapStore(defaults: defaults).cached(plan: plan, book: "b"), result)
    }
    @MainActor
    func testGeneratorNeverDeliversFabricatedEvidence() async throws {
        let suite = "RecapInvalidGeneration-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = RecapTestAI(output: try response(quote: "原文里没有的剧情与引文。"))
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fake"
        try ai.save(config, newKey: "fake")
        do { _ = try await ReadingRecapGenerator.generate(plan: plan(), ai: ai) { _, _ in }; XCTFail() }
        catch { XCTAssertTrue(error is ReadingRecapError) }
    }

    @MainActor
    func testGeneratorSendsOnlyPreparedText() async throws {
        let suite = "RecapGeneration-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = RecapTestAI(output: try response()), keys = MemoryReadingAIKeys()
        let ai = ReadingAIStore(defaults: defaults, keys: keys, client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fake"
        try ai.save(config, newKey: "fake")
        let prepared = try plan()
        let recap = try await ReadingRecapGenerator.generate(plan: prepared, ai: ai) { _, _ in }
        XCTAssertEqual(recap.events.count, 1)
        let inputs = await client.inputs
        XCTAssertEqual(inputs, prepared.chunks.map { $0.request.input })
    }
}
private actor RecapTestAI: ReadingAICompleting {
    let output: String
    var inputs = [String]()
    init(output: String) { self.output = output }
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        inputs.append(request.input)
        return .init(text: output, inputTokens: nil, outputTokens: nil)
    }
}

final class StorySummaryTests: XCTestCase {
    private let chapter = "小明在旧宅里找到一把锈钥匙，钥匙上刻着祖父的名字。他把钥匙收好，决定第二天去仓库看看。"
    func testPlanPacksConsecutiveChaptersAndRejectsEmptyInput() throws {
        let chapters = (0..<5).map { RecapChapter(index: $0, title: "第\($0 + 1)章", text: chapter) }
        let plan = try StorySummaryPlan(chapters: chapters)
        XCTAssertEqual(plan.packs.count, 1)
        XCTAssertEqual(plan.packs[0].firstChapter, 0)
        XCTAssertEqual(plan.packs[0].lastChapter, 4)
        XCTAssertThrowsError(try StorySummaryPlan(chapters: []))
        XCTAssertThrowsError(try StorySummaryPlan(chapters: [.init(index: 0, title: "空", text: "   ")]))
    }
    func testPlanSplitsWhenPacksExceedTheByteBudget() throws {
        let long = String(repeating: chapter, count: 120)
        let chapters = (0..<4).map { RecapChapter(index: $0, title: "第\($0 + 1)章", text: long) }
        let plan = try StorySummaryPlan(chapters: chapters)
        XCTAssertGreaterThan(plan.packs.count, 1)
        XCTAssertEqual(plan.packs.flatMap { $0.firstChapter...$0.lastChapter }.count, 4)
    }
    func testSummaryParsingRejectsProseAndOutOfRangeText() throws {
        XCTAssertEqual(try StorySummaryPlan.parseSummary("{\"summary\":\"\(String(repeating: "事", count: 200))\"}", allowed: 120...1_600).count, 200)
        XCTAssertThrowsError(try StorySummaryPlan.parseSummary("这是一个很长但没有 JSON 的回复。", allowed: 120...1_600))
        XCTAssertThrowsError(try StorySummaryPlan.parseSummary("{\"summary\":\"太短\"}", allowed: 120...1_600))
    }
    @MainActor
    func testGeneratorMapsEveryPackThenReducesOnce() async throws {
        let suite = "StorySummary-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = StorySummaryAI()
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        // 每章约 3.8KB：两章塞得进一个 10KB 的包，三章塞不进，所以拆成 2 包。
        let chapters = (0..<3).map { RecapChapter(index: $0, title: "第\($0 + 1)章", text: String(repeating: chapter, count: 30)) }
        XCTAssertEqual(try StorySummaryPlan(chapters: chapters).packs.count, 2)
        let text = try await StorySummaryGenerator.generate(chapters: chapters, previous: nil, ai: ai) { _ in }
        XCTAssertTrue(text.contains("【一句话回顾】"))
        XCTAssertTrue(text.contains("【主要人物】"))
        XCTAssertTrue(text.contains("【主线进展】"))
        XCTAssertTrue(text.contains("【当前处境与悬念】"))
        let calls = await client.calls
        XCTAssertEqual(calls, 3)   // 2 次分段概括 + 1 次归并
        // 装得下一包时只需概括一次再归并一次。
        let small = (0..<3).map { RecapChapter(index: $0, title: "第\($0 + 1)章", text: String(repeating: chapter, count: 20)) }
        XCTAssertEqual(try StorySummaryPlan(chapters: small).packs.count, 1)
        let callsBefore = await client.calls
        _ = try await StorySummaryGenerator.generate(chapters: small, previous: nil, ai: ai) { _ in }
        let callsAfter = await client.calls
        XCTAssertEqual(callsAfter - callsBefore, 2)   // 1 次概括 + 1 次归并
    }
}

private actor StorySummaryAI: ReadingAICompleting {
    private(set) var calls = 0
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        calls += 1
        let data = try JSONSerialization.data(withJSONObject: [
            "overview": String(repeating: "主角追查旧宅钥匙的来历，", count: 5),
            "characters": ["小明：主角，持钥匙的人"],
            "plot": ["在旧宅找到刻着祖父名字的钥匙", "决定次日去仓库查看"],
            "open": ["钥匙能打开什么"]
        ])
        return .init(text: String(decoding: data, as: UTF8.self), inputTokens: nil, outputTokens: nil)
    }
}

final class FrontMatterFilterTests: XCTestCase {
    private let body = "江南孝明冒雨赶到公寓，遇见了光明寺美琴，两人一起等待鹿谷门实。"
    func testFrontMatterTitlesAreRecognised() {
        for title in ["序言", "前言", "人物表", "主要人物", "目录", "版权信息", "译后记", "解说", "参考文献", "序", "出版说明"] {
            XCTAssertTrue(CharacterExtractionPlan.isNonStoryTitle(title), title)
        }
        for title in ["序章", "楔子", "第一章 没有指针的钟塔", "“旧馆”其一", "尾声"] {
            XCTAssertFalse(CharacterExtractionPlan.isNonStoryTitle(title), title)
        }
    }
    func testStoryPlanSkipsFrontMatterAndKeepsPlotChapters() throws {
        let chapters = [
            RecapChapter(index: 0, title: "序言", text: String(repeating: body, count: 40)),
            RecapChapter(index: 1, title: "人物表", text: String(repeating: body, count: 40)),
            RecapChapter(index: 2, title: "第一章 没有指针的钟塔", text: body),
            RecapChapter(index: 3, title: "第二章 迟来的二人", text: body)
        ]
        let plan = try StorySummaryPlan(chapters: chapters)
        XCTAssertEqual(plan.packs.count, 1)
        XCTAssertEqual(plan.packs[0].firstChapter, 2)
        XCTAssertEqual(plan.packs[0].lastChapter, 3)
        // 全部是前置页时退回不过滤，避免“生成”按钮点了毫无反应。
        let fallback = try StorySummaryPlan(chapters: Array(chapters.prefix(2)))
        XCTAssertEqual(fallback.packs.count, 1)
        XCTAssertEqual(fallback.packs[0].firstChapter, 0)
    }
}

final class FrontMatterFallbackTests: XCTestCase {
    func testPlanFallsBackWhenOnlyFrontMatterWasRead() throws {
        let preface = String(repeating: "本书收录作者历年短篇，并附译后记。", count: 30)
        let chapters = [RecapChapter(index: 0, title: "序言", text: preface),
                        RecapChapter(index: 1, title: "人物表", text: preface)]
        // 全是前置页时不能抛错，否则“生成故事梗概”按钮点了没有任何反应。
        let plan = try StorySummaryPlan(chapters: chapters)
        XCTAssertEqual(plan.packs.count, 1)
        XCTAssertEqual(plan.packs[0].firstChapter, 0)
        XCTAssertEqual(plan.packs[0].lastChapter, 1)
    }
}

final class StoryStoreFlowTests: XCTestCase {
    @MainActor
    func testStoreGeneratesAndPersistsAFirstSummary() async throws {
        let suite = "StoryStore-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingRecapStore(defaults: defaults)
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: StorySummaryAI())
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        let chapters = (0..<3).map { RecapChapter(index: $0, title: "第\($0 + 1)章",
            text: String(repeating: "江南冒雨赶到公寓，遇见了光明寺美琴。", count: 60)) }
        store.startStory(book: "epub:test", chapters: chapters, previous: nil,
                         identity: "identity", coveredThrough: 3, ai: ai)
        XCTAssertTrue(store.isBuildingStory(book: "epub:test"))
        for _ in 0..<200 {
            if !store.isBuildingStory(book: "epub:test") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(store.isBuildingStory(book: "epub:test"))
        let saved = try XCTUnwrap(store.story(book: "epub:test"), "生成完成却没有保存")
        XCTAssertEqual(saved.coveredThrough, 3)
        XCTAssertNil(saved.partialChapterUTF16)
        XCTAssertTrue(saved.text.contains("【一句话回顾】"))
        XCTAssertNil(store.storyErrors[FileContentHash.sha256(Data("epub:test".utf8))])

        // 第一章尚在阅读途中（coveredThrough == 0，仅含本章已读前缀）也可生成并保存梗概。
        let partialFirstChapter = [RecapChapter(index: 0, title: "第1章（本章已读部分）",
            text: String(repeating: "江南冒雨赶到公寓，遇见了光明寺美琴。", count: 30))]
        store.startStory(book: "epub:partial", chapters: partialFirstChapter, previous: nil,
                         identity: "identity", coveredThrough: 0,
                         partialChapterUTF16: partialFirstChapter[0].text.utf16.count, ai: ai)
        for _ in 0..<200 {
            if !store.isBuildingStory(book: "epub:partial") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let savedPartial = try XCTUnwrap(store.story(book: "epub:partial"))
        XCTAssertEqual(savedPartial.coveredThrough, 0)
        XCTAssertEqual(savedPartial.partialChapterUTF16, partialFirstChapter[0].text.utf16.count)
    }
}

final class ReadingAIExplainPromptTests: XCTestCase {
    func testInitialRequestIncludesBookSelectionAndContext() throws {
        let request = ReadingAIExplainPrompt.makeRequest(
            bookTitle: "测试轻小说",
            selection: "一石二鳥",
            context: "前文提要。这是一石二鳥的策略。后文继续。"
        )
        try request.validate()
        XCTAssertEqual(request.instruction, ReadingAIExplainPrompt.initialInstruction)
        XCTAssertTrue(request.input.contains("书名：测试轻小说"))
        XCTAssertTrue(request.input.contains("选中片段：\n一石二鳥"))
        XCTAssertTrue(request.input.contains("所在上下文："))
        XCTAssertFalse(request.input.contains("已有对话："))
    }

    func testFollowUpRequestPreservesDialogueOrderAndStaysWithinBudget() throws {
        let history = [
            ReadingAIExplainTurn(role: .user, text: "选区摘要", isSelectionHeader: true),
            ReadingAIExplainTurn(role: .assistant, text: "这是“一举两得”的意思。"),
            ReadingAIExplainTurn(role: .user, text: "为什么这里带有一点讽刺语气？"),
            ReadingAIExplainTurn(role: .assistant, text: "因为说话人明知对方会吃亏。")
        ]
        let request = ReadingAIExplainPrompt.makeRequest(
            bookTitle: "测试轻小说",
            selection: "一石二鳥",
            context: "上下文内容",
            history: history,
            followUp: "能举一个更贴合中文口语的译法吗？"
        )
        try request.validate()
        XCTAssertEqual(request.instruction, ReadingAIExplainPrompt.followUpInstruction)
        XCTAssertFalse(request.input.contains("选区摘要"))
        XCTAssertTrue(request.input.contains("已有对话："))
        XCTAssertTrue(request.input.contains("用户本次补充／追问：\n能举一个更贴合中文口语的译法吗？"))
        let firstPos = try XCTUnwrap(request.input.range(of: "阅读助手：这是“一举两得”的意思。"))
        let secondPos = try XCTUnwrap(request.input.range(of: "用户：为什么这里带有一点讽刺语气？"))
        let thirdPos = try XCTUnwrap(request.input.range(of: "阅读助手：因为说话人明知对方会吃亏。"))
        XCTAssertLessThan(firstPos.lowerBound, secondPos.lowerBound)
        XCTAssertLessThan(secondPos.lowerBound, thirdPos.lowerBound)

        // 超长历史应按字节上限裁剪最旧对话，确保请求始终合法。
        let hugeHistory = (0..<30).map { index in
            ReadingAIExplainTurn(role: index.isMultiple(of: 2) ? .assistant : .user,
                                 text: "第\(index)轮：" + String(repeating: "解析内容", count: 600))
        }
        let bounded = ReadingAIExplainPrompt.makeRequest(
            bookTitle: nil,
            selection: "一石二鳥",
            context: nil,
            history: hugeHistory,
            followUp: "继续解释"
        )
        try bounded.validate()
        XCTAssertTrue(bounded.input.contains("第29轮："))
        XCTAssertFalse(bounded.input.contains("第0轮："))
    }

    func testStorySummaryFitChaptersToBudgetKeepsTailAndOpening() {
        let chapters = (0..<10).map { idx in
            RecapChapter(index: idx, title: "第\(idx + 1)章", text: String(repeating: "正", count: 200))
        }
        // 每章约 600 UTF-8 字节，总计约 6000 字节；预算 2500 字节应截断并保留末章与开篇
        let fitted = StorySummaryPlan.fitChaptersToBudget(chapters, maxBytes: 2_500)
        XCTAssertTrue(fitted.truncated)
        XCTAssertLessThan(fitted.chapters.count, chapters.count)
        XCTAssertEqual(fitted.chapters.last?.index, 9, "应优先保留末章以衔接下一卷")
        XCTAssertEqual(fitted.chapters.first?.index, 0, "剩余预算应保留开篇")

        let unfitted = StorySummaryPlan.fitChaptersToBudget(chapters, maxBytes: 20_000)
        XCTAssertFalse(unfitted.truncated)
        XCTAssertEqual(unfitted.chapters.count, 10)
    }

    @MainActor
    func testWorldviewExtractionParseAndStoreMergeProtectsManualEntries() throws {
        let raw = """
        ```json
        {"entries":[
          {"term":"固有结界","aliases":["Reality Marble"],"category":"设定","summary":"将心象风景具现化并侵蚀现实世界的大魔术。"},
          {"term":"时钟塔","aliases":["魔术协会总部"],"category":"势力","summary":"魔术协会在伦敦设立的核心学府与权力机构。"},
          {"term":"固有结界","aliases":[],"category":"设定","summary":"重复项应被去重。"}
        ]}
        ```
        """
        let parsed = try WorldviewExtractionPlan.parse(
            raw,
            workID: "book-1",
            sourceBookKey: "book-1",
            sourceBookTitle: "Fate/stay night",
            chapterIndex: 3,
            chapterTitle: "第四章"
        )
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].category, .concept)
        XCTAssertEqual(parsed[1].category, .organization)

        let suite = "novelia.test.worldview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WorldviewLexiconStore(defaults: defaults)
        let manual = WorldviewEntry(
            id: UUID(),
            workID: "book-1",
            term: "固有结界",
            aliases: ["心象世界"],
            category: .concept,
            summary: "手工笔记：只有极少数魔术师或英灵能展开。",
            sourceBookKey: "book-1",
            sourceBookTitle: "Fate/stay night",
            sourceChapterIndex: 1,
            sourceChapterTitle: nil,
            isManual: true,
            createdAt: Date(),
            updatedAt: Date()
        )
        store.upsert(manual)

        let changed = store.mergeExtracted(parsed, workID: "book-1")
        XCTAssertEqual(changed, 1, "手工词条不被覆盖，只新增时钟塔")
        let items = store.entries(for: "book-1")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first(where: { $0.term == "固有结界" })?.summary, manual.summary)

        // 移入系列后词条自动迁移
        store.migrateWork(from: "book-1", to: "series-fate")
        XCTAssertEqual(store.count(for: "book-1"), 0)
        XCTAssertEqual(store.count(for: "series-fate"), 2)
    }
}
