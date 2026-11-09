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
