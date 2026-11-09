// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NoveliaIOSCore

final class CharacterLexiconTests: XCTestCase {
    private let earlyQuote = "面具人将地图交给同伴，随后独自离开了村子。"
    private let lateQuote = "张三摘下面具，向同伴解释了事情的经过。"
    private func scope(chapter: Int = 2, book: String = "v2", identities: [String: String] = ["v1": "i1", "v2": "i2"]) -> CharacterScope {
        .init(work: "stable-work", volumes: ["v1", "v2", "v3"], currentBook: book, currentChapter: chapter, identities: identities)
    }
    private func early() -> CharacterFact {
        .init(book: "v1", identity: "i1", chapter: 0, offset: 0, name: "面具人", text: "面具人交出地图后离开村子。", quote: earlyQuote)
    }
    private func late() -> CharacterFact {
        .init(book: "v2", identity: "i2", chapter: 3, offset: 0, name: "张三", text: "张三摘下面具并解释经过。", quote: lateQuote)
    }
    func testAliasesAndFactsDisappearWhenRewinding() {
        let person = CharacterEntity(id: "p", work: "stable-work", facts: [late(), early()])
        let earlier = scope().visible([person])
        XCTAssertEqual(earlier.first?.name, "面具人")
        XCTAssertEqual(earlier.first?.aliases, [])
        XCTAssertEqual(earlier.first?.facts.count, 1)
        XCTAssertTrue(scope().visible([person], query: "张三").isEmpty)
        XCTAssertEqual(scope(chapter: 4).visible([person]).first?.aliases, ["张三"])
        XCTAssertTrue(scope(chapter: 0, book: "v1").visible([person]).isEmpty)
    }
    func testMissingOrChangedVolumeIdentityCannotSupplyFacts() {
        let person = CharacterEntity(id: "p", work: "stable-work", facts: [early()])
        XCTAssertTrue(scope(identities: ["v1": "changed"]).visible([person]).isEmpty)
        XCTAssertTrue(scope(identities: [:]).visible([person]).isEmpty)
        let other = CharacterScope(work: "unrelated-work", volumes: ["v1", "v2"], currentBook: "v2", currentChapter: 2, identities: ["v1": "i1"])
        XCTAssertTrue(other.visible([person]).isEmpty)
        XCTAssertFalse(scope().permits(book: "v3", chapter: 0))
        XCTAssertFalse(scope().permits(book: "v2", chapter: 2))
        XCTAssertFalse(scope().permits(book: "v2", chapter: -1))
    }
    func testExtractionRejectsCurrentFutureAndFabricatedEvidence() throws {
        let value = scope(chapter: 2)
        XCTAssertThrowsError(try CharacterExtractionPlan(scope: value, book: "v2", identity: "i2", chapters: [.init(index: 2, title: "当前", text: lateQuote)]))
        let plan = try CharacterExtractionPlan(scope: value, book: "v1", identity: "i1", chapters: [.init(index: 0, title: "开头", text: earlyQuote)])
        func response(name: String, quote: String, chapter: Int = 0) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": [["name": name, "facts": [["chapter": chapter, "text": "交出地图后离开。", "quote": quote]]]]]), as: UTF8.self)
        }
        let candidates = try plan.validate(response(name: "面具人", quote: earlyQuote), chunk: plan.chunks[0])
        XCTAssertEqual(candidates.first?.facts.first?.offset, 0)
        XCTAssertThrowsError(try plan.validate(response(name: "张三", quote: earlyQuote), chunk: plan.chunks[0]))
        XCTAssertThrowsError(try plan.validate(response(name: "面具人", quote: "面具人实际上是未来章节才揭晓的另一人。"), chunk: plan.chunks[0]))
        XCTAssertThrowsError(try plan.validate(response(name: "面具人", quote: earlyQuote, chapter: 2), chunk: plan.chunks[0]))
    }
    @MainActor
    func testSameNamesRemainSeparateAndExplicitMergeStillFiltersFutureAlias() throws {
        let suite = "CharacterMerge-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults), later = scope(chapter: 4)
        try store.confirmOrder(work: later.work, volumes: later.volumes)
        let a = try store.accept(.init(facts: [early()]), scope: later)
        let b = try store.accept(.init(facts: [early()]), scope: later)
        let c = try store.accept(.init(facts: [late()]), scope: later)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(store.entities.count, 3)
        try store.merge(c, into: a, scope: later)
        XCTAssertEqual(store.entities.count, 2)
        XCTAssertTrue(scope().visible(store.entities, query: "张三").isEmpty)
        XCTAssertEqual(later.visible(store.entities).first { $0.id == a }?.aliases, ["张三"])
        let reopened = CharacterLexiconStore(defaults: defaults)
        XCTAssertEqual(reopened.order(work: later.work), later.volumes)
        XCTAssertEqual(reopened.entities, store.entities)
    }
    @MainActor
    func testSplitAndCorrectionPreserveEvidenceAndHiddenFacts() throws {
        let suite = "CharacterEdit-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults), later = scope(chapter: 4), early = self.early(), late = self.late()
        try store.confirmOrder(work: later.work, volumes: later.volumes)
        let id = try store.accept(.init(facts: [early, late]), scope: later)
        XCTAssertThrowsError(try store.edit(fact: late.id, entity: id, text: "越界修改", scope: scope()))
        try store.edit(fact: early.id, entity: id, text: "手工纠正的描述。", scope: scope())
        let modified = try XCTUnwrap(store.entities.first?.facts.first)
        XCTAssertEqual(modified.quote, early.quote)
        XCTAssertEqual(modified.offset, early.offset)
        XCTAssertTrue(modified.manual)
        try store.split(fact: early.id, from: id, scope: scope())
        XCTAssertEqual(store.entities.count, 2)
        XCTAssertEqual(store.entities.first { $0.id == id }?.facts, [late])
    }
    /// 单书人物卡移入系列：卷序、人物与检查点整体搬到系列 ID 下，签名不含 work 故检查点仍有效。
    @MainActor
    func testMigrateWorkMovesSingleBookDataIntoSeriesKey() throws {
        let suite = "CharacterMigrate-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        let single = CharacterScope(work: "book-key", volumes: ["v1"], currentBook: "v1", currentChapter: 1, identities: ["v1": "i1"])
        try store.confirmOrder(work: single.work, volumes: ["v1"])
        let signature = try CharacterAutomaticUpdater.signature(identity: "i1", scope: single, configuration: ReadingAIConfiguration())
        let plan = try CharacterExtractionPlan(scope: single, book: "v1", identity: "i1", chapters: [.init(index: 0, title: "第一章", text: earlyQuote)])
        try store.applyAutomatic([.init(id: "p", facts: [early()])], plan: plan, signature: signature)
        XCTAssertEqual(store.scannedThrough(work: "book-key", book: "v1", signature: signature), 1)

        try store.migrateWork(from: "book-key", to: "series-id")
        XCTAssertEqual(store.order(work: "series-id"), ["v1"])
        XCTAssertEqual(store.order(work: "book-key"), [])
        XCTAssertEqual(store.entities.first?.work, "series-id")
        XCTAssertEqual(store.scannedThrough(work: "series-id", book: "v1", signature: signature), 1)
        let visible = CharacterScope(work: "series-id", volumes: ["v1"], currentBook: "v1", currentChapter: 1, identities: ["v1": "i1"]).visible(store.entities)
        XCTAssertEqual(visible.first?.name, "面具人")
        // 来源无数据时重复迁移是无害空操作；目标已有独立数据时不覆盖。
        try store.migrateWork(from: "book-key", to: "series-id")
        try store.confirmOrder(work: "other-book", volumes: ["v1"])
        try store.migrateWork(from: "other-book", to: "series-id")
        XCTAssertEqual(store.order(work: "series-id"), ["v1"])
        XCTAssertEqual(store.order(work: "other-book"), ["v1"])
        let reopened = CharacterLexiconStore(defaults: defaults)
        XCTAssertEqual(reopened.order(work: "series-id"), ["v1"])
        XCTAssertEqual(reopened.entities, store.entities)
    }
    @MainActor
    func testOrderChangesRequireNewExplicitConfirmationAndCorruptDataIsRetained() throws {
        let suite = "CharacterStore-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        XCTAssertThrowsError(try store.accept(.init(facts: [early()]), scope: scope()))
        try store.confirmOrder(work: "stable-work", volumes: ["v2", "v1", "v3"])
        XCTAssertThrowsError(try store.accept(.init(facts: [early()]), scope: scope()))
        let corrupt = Data("broken archive".utf8)
        defaults.set(corrupt, forKey: "reader.characters.archive.v1")
        let damaged = CharacterLexiconStore(defaults: defaults)
        XCTAssertThrowsError(try damaged.confirmOrder(work: "work", volumes: ["one"]))
        XCTAssertEqual(defaults.data(forKey: "reader.characters.archive.v1"), corrupt)
    }
    private func extractionResponse(name: String = "面具人", quote: String, chapter: Int, id: String? = nil, nameQuote: String? = nil) throws -> String {
        var fact: [String: Any] = ["chapter": chapter, "text": "将重要物品交给了同伴。", "quote": quote]
        if let nameQuote { fact["name_quote"] = nameQuote }
        var person: [String: Any] = ["name": name, "facts": [fact]]
        if let id { person["candidate_id"] = id }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": [person]]), as: UTF8.self)
    }
    func testWholeVisibleVolumeExceedsThreeChaptersAndPreservesEmptyChapters() throws {
        let chapters = (0..<12).map { RecapChapter(index: $0, title: "第\($0)章", text: $0 == 3 ? "" : earlyQuote) }
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: chapters)
        XCTAssertEqual(plan.chapterCount, 12)
        XCTAssertEqual(plan.chunks.map(\.chapter), (0..<12).filter { $0 != 3 })
        XCTAssertThrowsError(try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [chapters[0], chapters[2]]))
        XCTAssertThrowsError(try CharacterExtractionPlan(scope: scope(), book: "v3", identity: "i1", chapters: [chapters[0]]))
    }
    func testLargeUnicodeChapterOverlapKeepsOriginalOffsetsAndNoTruncation() throws {
        let original = String(repeating: "😀面具人继续前行。", count: 5_000)
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "长章", text: original)])
        XCTAssertGreaterThan(plan.inputBytes, 96 * 1_024)
        XCTAssertGreaterThan(plan.chunks.count, 12)
        var end = 0
        for chunk in plan.chunks {
            XCTAssertLessThanOrEqual(chunk.text.utf8.count, 8_000)
            XCTAssertEqual((original as NSString).substring(with: NSRange(location: chunk.offset, length: chunk.text.utf16.count)), chunk.text)
            XCTAssertLessThanOrEqual(chunk.offset, end)
            end = chunk.offset + chunk.text.utf16.count
        }
        XCTAssertEqual(end, original.utf16.count)
    }
    func testBudgetFailsBeforeModelAndNeverSilentlyDropsChapters() throws {
        let huge = String(repeating: "x", count: CharacterExtractionPlan.maximumBytes + 1)
        XCTAssertThrowsError(try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "大章", text: huge)]))
        let many = (0...CharacterExtractionPlan.maximumChunks).map { RecapChapter(index: $0, title: "小章", text: earlyQuote) }
        XCTAssertThrowsError(try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: many))
    }
    func testPronounFactsRequireEarlierVerifiedNameEvidence() throws {
        let quote = "他将重要物品交给同伴，随后独自离开村子。"
        let nameQuote = "面具人终于来到了约定的地方。"
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "开头", text: nameQuote + quote)])
        let candidate = try XCTUnwrap(plan.validate(extractionResponse(quote: quote, chapter: 0, nameQuote: nameQuote), chunk: plan.chunks[0]).first)
        XCTAssertEqual(candidate.facts.first?.attribution?.quote, nameQuote)
        XCTAssertEqual(candidate.facts.first?.offset, nameQuote.utf16.count)
        XCTAssertThrowsError(try plan.validate(extractionResponse(quote: quote, chapter: 0), chunk: plan.chunks[0]))
        XCTAssertThrowsError(try plan.validate(extractionResponse(quote: quote, chapter: 0, nameQuote: "面具人并未出现的伪造引文。"), chunk: plan.chunks[0]))
        let reversed = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "开头", text: quote + nameQuote)])
        XCTAssertThrowsError(try reversed.validate(extractionResponse(quote: quote, chapter: 0, nameQuote: nameQuote), chunk: reversed.chunks[0]))
    }
    func testContextContainsOnlyEarlierSameVolumeFactsAndExplicitIDs() throws {
        let quote = "他将重要物品交给同伴，随后独自离开村子。"
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote), .init(index: 1, title: "二", text: quote)])
        let first = try plan.validate(extractionResponse(quote: earlyQuote, chapter: 0), chunk: plan.chunks[0])
        let known = plan.context(before: plan.chunks[1], candidates: first + [.init(facts: [late()])])
        XCTAssertEqual(known.count, 1)
        let request = try plan.request(plan.chunks[1], known: known)
        XCTAssertFalse(request.input.contains("张三"))
        let next = try XCTUnwrap(plan.validate(extractionResponse(quote: quote, chapter: 1, id: known[0].id), chunk: plan.chunks[1], known: known).first)
        XCTAssertEqual(next.id, known[0].id)
        XCTAssertEqual(next.facts[0].attribution?.chapter, 0)
        XCTAssertThrowsError(try plan.validate(extractionResponse(quote: quote, chapter: 1, id: "invented"), chunk: plan.chunks[1], known: known))
        XCTAssertThrowsError(try plan.validate(extractionResponse(name: "张三", quote: quote, chapter: 1, id: known[0].id), chunk: plan.chunks[1], known: known))
    }
    func testRejectedSiblingCandidateDoesNotDiscardVerifiedOnes() throws {
        let valid = "甲把信交给乙，随后离开了房间。"
        let text = valid + "乙把信收进抽屉，然后关灯睡觉。"
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "第一章", text: text)])
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": [
            ["name": "甲", "facts": [["chapter": 0, "text": "甲把信交给乙后离开。", "quote": valid]]],
            ["name": "乙", "facts": [["chapter": 0, "text": "乙早已知道真相。", "quote": "乙其实早就知道这封信的全部真相。"]]]
        ]]), as: UTF8.self)
        // 乙的引文不在原文里，只丢弃这一条；甲的已核验事实必须保留，不能整块作废。
        let candidates = try plan.validate(response, chunk: plan.chunks[0])
        XCTAssertEqual(candidates.map(\.name), ["甲"])
        XCTAssertEqual(candidates.first?.facts.count, 1)
    }
    func testFencedJSONResponseIsAcceptedAndStillVerified() throws {
        let quote = "甲把信交给乙，随后离开了房间。"
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "第一章", text: quote)])
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": [
            ["name": "甲", "facts": [["chapter": 0, "text": "甲交出信件后离开。", "quote": quote]]]
        ]]), as: UTF8.self)
        XCTAssertEqual(try plan.validate("```json\n" + body + "\n```", chunk: plan.chunks[0]).first?.name, "甲")
        let fabricated = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": [
            ["name": "甲", "facts": [["chapter": 0, "text": "甲交出信件后离开。", "quote": "甲交出的是伪造的信件原文。"]]]
        ]]), as: UTF8.self)
        XCTAssertThrowsError(try plan.validate(fabricated, chunk: plan.chunks[0]))
        XCTAssertThrowsError(try plan.validate("这不是 JSON。", chunk: plan.chunks[0]))
    }
    func testNonContentFrontMatterPageIsNotSentForExtraction() throws {
        let colophon = "死神广播 版权信息书名：死神广播作者：白井智之译者：佳辰出版社：某出版社出版时间：2024年8月"
        XCTAssertTrue(CharacterExtractionPlan.isNonContent([.init(index: 0, title: "版权信息", text: colophon)]))
        XCTAssertFalse(CharacterExtractionPlan.isNonContent([.init(index: 1, title: "第一章", text: String(repeating: "甲走进房间，看见了乙。", count: 60))]))
    }
    func testFactMissingAFieldIsSkippedWithoutLosingTheChunk() throws {
        let quote = "甲把信交给乙，随后离开了房间。"
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "第一章", text: quote)])
        // 第一条缺 quote：只丢这一条，不能连累同一个人物的另一条，更不能让整块 JSON 解析失败。
        let response = """
        {"candidates":[{"name":"甲","facts":[{"chapter":0,"text":"缺少引文的事实。"},{"chapter":0,"text":"甲交出信件。","quote":"\(quote)"}]}]}
        """
        let candidates = try plan.validate(response, chunk: plan.chunks[0])
        XCTAssertEqual(candidates.first?.name, "甲")
        XCTAssertEqual(candidates.first?.facts.count, 1)
        XCTAssertEqual(candidates.first?.facts.first?.quote, quote)
    }
    @MainActor
    func testGeneratorRetriesOnceWhenModelOutputFailsVerification() async throws {
        let suite = "CharacterRetry-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = CharacterRetryAI()
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        let values = try await CharacterGenerator.generate(plan: plan, ai: ai) { _, _ in }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.facts.count, 1)
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
    }
    @MainActor
    func testRemoveEntityDeletesWholeCardAndKeepsEvidenceRejected() throws {
        let suite = "CharacterRemove-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let id = try store.accept(.init(facts: [early()]), scope: scope())
        XCTAssertEqual(store.entities.count, 1)
        try store.removeEntity(id, scope: scope())
        XCTAssertTrue(store.entities.isEmpty)
        // 同一正文版本的同一证据已被否决，重新扫描不该把整张卡再建回来。
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1",
            chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        try store.applyAutomatic([.init(facts: [early()])], plan: plan, signature: "sig")
        XCTAssertTrue(store.entities.isEmpty)
    }
    @MainActor
    func testResetClearsCardsCheckpointsAndRevivesRejectedEvidence() throws {
        let suite = "CharacterReset-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1",
            chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        try store.applyAutomatic([.init(facts: [early()])], plan: plan, signature: "sig")
        XCTAssertEqual(store.entities.count, 1)
        XCTAssertEqual(store.scannedThrough(work: scope().work, book: "v1", signature: "sig"), 1)
        let id = try XCTUnwrap(store.entities.first?.id)
        try store.removeEntity(id, scope: scope())
        // 主动删除后同一证据被否决，重扫不会再建卡。
        try store.applyAutomatic([.init(facts: [early()])], plan: plan, signature: "sig")
        XCTAssertTrue(store.entities.isEmpty)
        // 重新创建：清卡、清检查点，并让用户删过的条目重新参与提取。
        try store.reset(scope: scope())
        XCTAssertEqual(store.scannedThrough(work: scope().work, book: "v1", signature: "sig"), 0)
        try store.applyAutomatic([.init(facts: [early()])], plan: plan, signature: "sig")
        XCTAssertEqual(store.entities.count, 1)
    }
    @MainActor
    func testDuplicateGroupsFindSameNameCardsAndMergeKeepsFacts() throws {
        let suite = "CharacterDuplicates-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let first = early()
        let second = CharacterFact(book: "v1", identity: "i1", chapter: 1, offset: 0, name: "面具人",
            text: "独自离开村子。", quote: "面具人独自离开了村子，没有回头。")
        try store.accept(.init(facts: [first]), scope: scope())
        try store.accept(.init(facts: [second]), scope: scope())
        let groups = store.duplicates(scope: scope())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 2)
        let target = try XCTUnwrap(groups.first?.members.first)
        let source = try XCTUnwrap(groups.first?.members.last)
        try store.merge(source.id, into: target.id, scope: scope())
        XCTAssertTrue(store.duplicates(scope: scope()).isEmpty)
        XCTAssertEqual(store.entities.count, 1)
        XCTAssertEqual(store.entities.first?.facts.count, 2)
    }
    @MainActor
    func testExplicitAppendPreservesAttributionAndOldArchiveCompatibility() throws {
        let suite = "CharacterAppend-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let id = try store.accept(.init(facts: [early()]), scope: scope())
        let value = CharacterFact(book: "v1", identity: "i1", chapter: 1, offset: 0, name: "面具人", text: "他将物品交给同伴。",
            quote: "他将重要物品交给同伴，随后独自离开村子。", attribution: .init(chapter: 0, offset: 0, quote: earlyQuote))
        try store.append(.init(facts: [value]), to: id, scope: scope())
        try store.append(.init(facts: [value]), to: id, scope: scope())
        XCTAssertEqual(store.entities[0].facts.count, 2)
        let reopened = CharacterLexiconStore(defaults: defaults)
        XCTAssertEqual(reopened.entities[0].facts.last?.attribution, value.attribution)
        XCTAssertTrue(scope(chapter: 1, book: "v1").visible(reopened.entities)[0].facts.allSatisfy { $0.attribution == nil })
        try store.split(fact: value.id, from: id, scope: scope())
        XCTAssertEqual(store.entities.last?.facts[0].attribution, value.attribution)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(early())) as? [String: Any])
        old.removeValue(forKey: "attribution")
        XCTAssertNil(try JSONDecoder().decode(CharacterFact.self, from: JSONSerialization.data(withJSONObject: old)).attribution)
    }
    @MainActor
    func testGeneratorLinksExplicitCandidateAcrossChaptersAndRejectsPartialFailure() async throws {
        for failSecond in [false, true] {
            let suite = "CharacterGenerate-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = CharacterSequenceAI(failSecond: failSecond)
            let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
            var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
            try ai.save(config, newKey: "fake")
            let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [
                .init(index: 0, title: "一", text: earlyQuote), .init(index: 1, title: "二", text: "他将重要物品交给同伴，随后独自离开村子。")])
            do {
                let values = try await CharacterGenerator.generate(plan: plan, ai: ai) { _, _ in }
                XCTAssertFalse(failSecond)
                XCTAssertEqual(values.count, 1)
                XCTAssertEqual(values[0].facts.count, 2)
                XCTAssertEqual(values[0].facts.last?.attribution?.chapter, 0)
            } catch { XCTAssertTrue(failSecond) }
        }
    }

    @MainActor
    func testCacheReusesPrefixAfterExtensionAndInvalidatesModelOrText() async throws {
        let suite = "CharacterCache-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = CharacterSequenceAI(failSecond: false)
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        let chapters = (0..<3).map { RecapChapter(index: $0, title: "章", text: earlyQuote) }
        func plan(_ chapters: [RecapChapter]) throws -> CharacterExtractionPlan {
            try .init(scope: scope(), book: "v1", identity: "i1", chapters: chapters)
        }
        let cache = CharacterExtractionCache(defaults: defaults)
        let first = try await CharacterGenerator.generate(plan: plan(Array(chapters.prefix(2))), ai: ai, cache: cache) { _, _ in }
        let firstCalls = await client.calls
        XCTAssertEqual(firstCalls, 2)
        // 重开缓存与扩大范围仍复用前两章，且每次命中重新核验引文。
        let second = try await CharacterGenerator.generate(plan: plan(chapters), ai: ai, cache: CharacterExtractionCache(defaults: defaults)) { _, _ in }
        XCTAssertEqual(first[0].id, second[0].id)
        let extendedCalls = await client.calls
        XCTAssertEqual(extendedCalls, 3)
        config.model = "other-model"; try ai.save(config, newKey: "")
        _ = try await CharacterGenerator.generate(plan: plan(chapters), ai: ai, cache: cache) { _, _ in }
        let changedModelCalls = await client.calls
        XCTAssertEqual(changedModelCalls, 6)
        let changed = [RecapChapter(index: 0, title: "章", text: earlyQuote + "新的内容。")]
        _ = try await CharacterGenerator.generate(plan: plan(changed), ai: ai, cache: cache) { _, _ in }
        let changedTextCalls = await client.calls
        XCTAssertEqual(changedTextCalls, 7)
    }
    @MainActor
    func testTamperedCacheIsRejectedThenRemovedWithoutAutomaticNetworkRetry() async throws {
        let suite = "CharacterBadCache-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = CharacterSequenceAI(failSecond: false)
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        _ = try await CharacterGenerator.generate(plan: plan, ai: ai, cache: CharacterExtractionCache(defaults: defaults)) { _, _ in }
        let storageKey = "reader.characters.extractionCache.v3"
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: storageKey))) as? [String: Any])
        var responses = try XCTUnwrap(archive["responses"] as? [String: String])
        let key = try XCTUnwrap(responses.keys.first)
        responses[key] = try extractionResponse(quote: "面具人做了原文中并不存在的事情。", chapter: 0)
        archive["responses"] = responses
        defaults.set(try JSONSerialization.data(withJSONObject: archive), forKey: storageKey)
        let reopened = CharacterExtractionCache(defaults: defaults)
        do { _ = try await CharacterGenerator.generate(plan: plan, ai: ai, cache: reopened) { _, _ in }; XCTFail() }
        catch { XCTAssertTrue(error is CharacterLexiconError) }
        XCTAssertNil(reopened.read(key))
        let beforeRetry = await client.calls
        XCTAssertEqual(beforeRetry, 1)
        _ = try await CharacterGenerator.generate(plan: plan, ai: ai, cache: reopened) { _, _ in }
        let afterRetry = await client.calls
        XCTAssertEqual(afterRetry, 2)
    }
    func testCompactContextHasBoundedBytesAndDoesNotResendEvidence() throws {
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 1, title: "一", text: "他在路上继续前行，并没有停下自己的脚步。")])
        let candidates = (0..<100).map { index -> CharacterCandidate in
            var fact = early()
            fact.text = String(repeating: "已经确认的描述", count: 30)
            return .init(id: "person-\(index)", facts: [fact])
        }
        let known = plan.context(before: plan.chunks[0], candidates: candidates)
        XCTAssertLessThanOrEqual(known.count, 12)
        let request = try plan.request(plan.chunks[0], known: known)
        XCTAssertFalse(request.input.contains(earlyQuote))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.input.utf8)) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: input["known_candidates"]!)
        XCTAssertLessThanOrEqual(data.count, 3_025)
    }
    @MainActor
    func testCancellationAndConfigurationChangeDiscardNonCooperativeLateResults() async throws {
        for changeConfiguration in [false, true] {
            let suite = "CharacterCancel-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = CharacterPausedAI()
            let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
            var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
            try ai.save(config, newKey: "fake")
            let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
            let task = Task { try await CharacterGenerator.generate(plan: plan, ai: ai) { _, _ in } }
            await client.waitUntilStarted()
            if changeConfiguration { config.model = "changed"; try ai.save(config, newKey: "") }
            else { task.cancel() }
            await client.resolve(try extractionResponse(quote: earlyQuote, chapter: 0))
            do { _ = try await task.value; XCTFail("迟到结果不能交付") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testManualBookOrSeriesSelectionNeverIncludesLaterVolumes() {
        XCTAssertEqual(scope().booksForScan(series: false), ["v2"])
        XCTAssertEqual(scope().booksForScan(series: true), ["v1", "v2"])
        XCTAssertEqual(scope(book: "v1").booksForScan(series: true), ["v1"])
        XCTAssertEqual(scope(book: "missing").booksForScan(series: true), [])
    }
    func testAutomaticScopeUsesEachVolumesOwnProgressAndSkipsMissingAndFuture() {
        let value = CharacterScope(work: "stable-work", volumes: ["v1", "v2", "v3"], currentBook: "v2", currentChapter: 2,
            identities: ["v1": "i1", "v2": "i2"], readBoundaries: ["v1": 1, "v2": 2, "v3": 20])
        XCTAssertTrue(value.permits(book: "v1", chapter: 0))
        XCTAssertFalse(value.permits(book: "v1", chapter: 1))
        XCTAssertFalse(value.permits(book: "v2", chapter: 2))
        XCTAssertFalse(value.permits(book: "v3", chapter: 0))
        XCTAssertFalse(value.permits(book: "missing", chapter: 0))
        var missing = value; missing.readBoundaries = ["v2": 2]
        XCTAssertFalse(missing.permits(early()))
    }
    @MainActor
    func testAutomaticCreationUpdateAndCheckpointPersistWithoutManualAcceptance() async throws {
        let suite = "AutomaticCards-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults), client = CharacterSequenceAI(failSecond: false)
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let first = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        let second = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 1, title: "二", text: "他将重要物品交给同伴，随后独自离开村子。")])
        try await CharacterAutomaticUpdater.update(plan: first, store: store, ai: ai) { _, _ in }
        XCTAssertEqual(store.entities.count, 1)
        try await CharacterAutomaticUpdater.update(plan: second, store: store, ai: ai) { _, _ in }
        XCTAssertEqual(store.entities.count, 1)
        XCTAssertEqual(store.entities[0].facts.count, 2)
        XCTAssertTrue(store.entities[0].facts.last?.needsReview == true)
        let signature = try CharacterAutomaticUpdater.signature(identity: "i1", scope: scope(), configuration: config)
        let reopened = CharacterLexiconStore(defaults: defaults)
        XCTAssertEqual(reopened.scannedThrough(work: scope().work, book: "v1", signature: signature), 2)
        try await CharacterAutomaticUpdater.update(plan: first, store: reopened, ai: ai) { _, _ in }
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(reopened.entities, store.entities)
        let pending = try XCTUnwrap(reopened.entities[0].facts.last)
        try reopened.confirm(fact: pending.id, entity: reopened.entities[0].id, scope: scope())
        XCTAssertFalse(reopened.entities[0].facts.last?.needsReview == true)
        XCTAssertEqual(reopened.scannedThrough(work: scope().work, book: "v1", signature: signature), 2)
        let changed = try CharacterAutomaticUpdater.signature(identity: "changed-version", scope: scope(), configuration: config)
        XCTAssertEqual(reopened.scannedThrough(work: scope().work, book: "v1", signature: changed), 0)
    }
    @MainActor
    func testAutomaticFailurePreservesOnlyCompletedChapterAndRequestBudget() async throws {
        let suite = "AutomaticFailure-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults), client = CharacterSequenceAI(failSecond: true)
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let first = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        let second = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 1, title: "二", text: earlyQuote)])
        try await CharacterAutomaticUpdater.update(plan: first, store: store, ai: ai) { _, _ in }
        do { try await CharacterAutomaticUpdater.update(plan: second, store: store, ai: ai) { _, _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? ReadingAIError, .transport) }
        let signature = try CharacterAutomaticUpdater.signature(identity: "i1", scope: scope(), configuration: config)
        XCTAssertEqual(store.scannedThrough(work: scope().work, book: "v1", signature: signature), 1)
        XCTAssertEqual(store.entities[0].facts.count, 1)
        do {
            try await CharacterAutomaticUpdater.update(plan: second, store: store, ai: ai, beforeRequest: { throw CharacterLexiconError.requestBudget }) { _, _ in }
            XCTFail()
        } catch { XCTAssertTrue(error is CharacterLexiconError) }
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.scannedThrough(work: scope().work, book: "v1", signature: signature), 1)
    }
    @MainActor
    func testAutomaticCancellationNeverCommitsLateChapter() async throws {
        let suite = "AutomaticCancel-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults), client = CharacterPausedAI()
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        let task = Task { try await CharacterAutomaticUpdater.update(plan: plan, store: store, ai: ai) { _, _ in } }
        await client.waitUntilStarted(); task.cancel()
        await client.resolve(try extractionResponse(quote: earlyQuote, chapter: 0))
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.entities.isEmpty)
        let signature = try CharacterAutomaticUpdater.signature(identity: "i1", scope: scope(), configuration: config)
        XCTAssertEqual(store.scannedThrough(work: scope().work, book: "v1", signature: signature), 0)
    }
    @MainActor
    func testAutomaticCrossVolumePronounKeepsEarlierBookEvidenceAndRewindIsolation() async throws {
        let suite = "AutomaticVolumes-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults), client = CharacterSequenceAI(failSecond: false)
        let ai = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        var config = ReadingAIConfiguration(); config.isEnabled = true; config.baseURL = "https://test.example/v1"; config.model = "fixture"
        try ai.save(config, newKey: "fake")
        let value = CharacterScope(work: "stable-work", volumes: ["v1", "v2", "v3"], currentBook: "v2", currentChapter: 1,
            identities: ["v1": "i1", "v2": "i2"], readBoundaries: ["v1": 1, "v2": 1])
        try store.confirmOrder(work: value.work, volumes: value.volumes)
        let first = try CharacterExtractionPlan(scope: value, book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        let second = try CharacterExtractionPlan(scope: value, book: "v2", identity: "i2", chapters: [.init(index: 0, title: "二", text: "他将重要物品交给同伴，随后独自离开村子。")])
        try await CharacterAutomaticUpdater.update(plan: first, store: store, ai: ai) { _, _ in }
        try await CharacterAutomaticUpdater.update(plan: second, store: store, ai: ai) { _, _ in }
        XCTAssertEqual(store.entities.count, 1)
        let fact = try XCTUnwrap(store.entities[0].facts.last)
        XCTAssertEqual(fact.book, "v2")
        XCTAssertEqual(fact.attribution?.book, "v1")
        XCTAssertEqual(fact.attribution?.identity, "i1")
        XCTAssertTrue(value.permits(fact))
        let rewound = CharacterScope(work: value.work, volumes: value.volumes, currentBook: "v1", currentChapter: 1,
            identities: value.identities, readBoundaries: ["v1": 1, "v2": 1])
        XCTAssertEqual(rewound.visible(store.entities)[0].facts.count, 1)
        var missing = value; missing.readBoundaries = ["v2": 1]
        XCTAssertFalse(missing.permits(fact))
    }
    @MainActor
    func testEmptyChapterCheckpointAndSameNameAutomaticCardsStayIndependent() throws {
        let suite = "AutomaticEmpty-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        try store.completeEmptyChapter(book: "v1", identity: "i1", chapter: 0, scope: scope(), signature: "empty")
        XCTAssertEqual(store.scannedThrough(work: scope().work, book: "v1", signature: "empty"), 1)
        XCTAssertTrue(store.entities.isEmpty)
        XCTAssertThrowsError(try store.completeEmptyChapter(book: "v3", identity: "i3", chapter: 0, scope: scope(), signature: "empty"))
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 1, title: "二", text: earlyQuote)])
        let a = CharacterFact(book: "v1", identity: "i1", chapter: 1, offset: 0, name: "面具人", text: "交出地图。", quote: earlyQuote)
        try store.applyAutomatic([.init(id: "a", facts: [a]), .init(id: "b", facts: [a])], plan: plan, signature: "next")
        XCTAssertEqual(store.entities.count, 2)
        XCTAssertTrue(store.entities.first { $0.id == "b" }?.facts[0].needsReview == true)
        XCTAssertEqual(store.scannedThrough(work: scope().work, book: "v1", signature: "next"), 2)
        XCTAssertEqual(CharacterLexiconStore(defaults: defaults).entities.count, 2)
    }
    @MainActor
    func testDeletedEvidenceIsNotReintroducedByModelRescan() throws {
        let suite = "AutomaticRejected-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        let value = early()
        try store.applyAutomatic([.init(id: "a", facts: [value])], plan: plan, signature: "first-model")
        try store.remove(fact: value.id, entity: "a", scope: scope())
        XCTAssertTrue(store.entities.isEmpty)
        let reopened = CharacterLexiconStore(defaults: defaults)
        var changed = value; changed.id = UUID().uuidString; changed.text = "另一个模型改写的同一事实。"
        try reopened.applyAutomatic([.init(id: "b", facts: [changed])], plan: plan, signature: "other-model")
        XCTAssertTrue(reopened.entities.isEmpty)
        XCTAssertEqual(reopened.scannedThrough(work: scope().work, book: "v1", signature: "other-model"), 1)
    }
    @MainActor
    func testModelRescanPreservesOriginalIdentityAndQuarantinesChangedDescription() throws {
        let suite = "AutomaticConflict-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        var first = early(); first.category = "身份"
        try store.applyAutomatic([.init(id: "p", facts: [first])], plan: plan, signature: "first-model")
        var later = first; later.id = UUID().uuidString; later.text = "另一个模型提出不同身份。"
        try store.applyAutomatic([.init(id: "p", facts: [later])], plan: plan, signature: "other-model")
        XCTAssertEqual(store.entities[0].facts[0].text, first.text)
        XCTAssertTrue(store.entities[0].facts[1].needsReview == true)
    }
    func testNewCandidateIDsCannotCollideAfterModelReordersNames() throws {
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote + lateQuote)])
        let a = try plan.validate(extractionResponse(quote: earlyQuote, chapter: 0), chunk: plan.chunks[0])
        let b = try plan.validate(extractionResponse(name: "张三", quote: lateQuote, chapter: 0), chunk: plan.chunks[0])
        XCTAssertNotEqual(a[0].id, b[0].id)
    }

    @MainActor
    func testPortraitReplaceRemoveMergeAndReadingBoundary() throws {
        let suite = "PortraitStore-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = CharacterLexiconStore(defaults: defaults, portraitDirectory: directory)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let a = try store.accept(.init(facts: [early()]), scope: scope())
        let b = try store.accept(.init(facts: [early()]), scope: scope())
        let first = Data([0xff, 0xd8, 0xff, 0x01, 0xff, 0xd9])
        let second = Data([0xff, 0xd8, 0xff, 0x02, 0xff, 0xd9])
        try store.setPortrait(first, entity: a, scope: scope())
        let hash = try XCTUnwrap(store.portrait(for: a, scope: scope())?.hash)
        XCTAssertNotNil(store.portraitFile(hash))
        XCTAssertNil(store.portrait(for: a, scope: scope(chapter: 1)))
        XCTAssertNil(store.portrait(for: a, scope: scope(book: "v1")))
        try store.setPortrait(second, entity: a, scope: scope())
        XCTAssertNil(store.portraitFile(hash))
        let replacement = try XCTUnwrap(store.portrait(for: a, scope: scope())?.hash)
        try store.merge(a, into: b, scope: scope())
        XCTAssertEqual(store.portrait(for: b, scope: scope())?.hash, replacement)
        let reopened = CharacterLexiconStore(defaults: defaults, portraitDirectory: directory)
        XCTAssertEqual(reopened.portrait(for: b, scope: scope())?.hash, replacement)
        try reopened.setPortrait(nil, entity: b, scope: scope())
        XCTAssertNil(reopened.portrait(for: b, scope: scope()))
        XCTAssertNil(reopened.portraitFile(replacement))
        XCTAssertThrowsError(try reopened.setPortrait(Data("invalid-image".utf8), entity: b, scope: scope()))
        XCTAssertThrowsError(try reopened.installPortrait(first, hash: String(repeating: "a", count: 64)))
        XCTAssertNil(reopened.portraitFile("../outside"))
    }
    @MainActor
    func testImageRemovalAndFactsAreSyncableButSecretsAndRequestCacheAreNot() throws {
        let suite = "CharacterSyncPayload-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = CharacterLexiconStore(defaults: defaults, portraitDirectory: directory)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let id = try store.accept(.init(facts: [early()]), scope: scope())
        store.extractionCache.save("private-request-cache", key: "cache")
        defaults.set("private-api-key", forKey: "test-only-secret")
        let data = try JSONEncoder().encode(store.characterSnapshot())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-request-cache"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-api-key"))
        let image = Data([0xff, 0xd8, 0xff, 0x03, 0xff, 0xd9])
        try store.setPortrait(image, entity: id, scope: scope())
        try store.setPortrait(nil, entity: id, scope: scope())
        XCTAssertNil(try store.characterSnapshot().portraits[id]?.value)
        XCTAssertNotNil(try store.characterSnapshot().portraits[id]?.updatedAt)
    }
    func testRelationshipColumnNameMustBeInTheSameEvidence() throws {
        let plan = try CharacterExtractionPlan(scope: scope(), book: "v1", identity: "i1", chapters: [.init(index: 0, title: "一", text: earlyQuote)])
        func response(_ name: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": [["name": "面具人", "facts": [["chapter": 0, "text": "同行伙伴", "quote": earlyQuote, "category": "关系", "related_name": name]]]]]), as: UTF8.self)
        }
        XCTAssertEqual(try plan.validate(response("同伴"), chunk: plan.chunks[0])[0].facts[0].relatedName, "同伴")
        XCTAssertThrowsError(try plan.validate(response("张三的未来真名"), chunk: plan.chunks[0]))
        var fact = early(); fact.relatedName = "不在原文里的名字"
        XCTAssertFalse(CharacterLexiconStore.valid(fact))
    }
    func testCharacterSyncFingerprintIsStableAcrossRejectedSetInsertionOrder() throws {
        let keys = (0..<30).map { FileContentHash.sha256(Data("key-\($0)".utf8)) }
        var a = CharacterSyncState(), b = CharacterSyncState()
        for key in keys { a.rejected.insert(key) }
        for key in keys.reversed() { b.rejected.insert(key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(a), try encoder.encode(b))
    }
    func testCharacterSyncMergeKeepsIndependentFactsAndUsesLargestCompatibleCheckpoint() throws {
        let key = FileContentHash.sha256(Data("scan".utf8)), time = Date(timeIntervalSince1970: 100)
        var a = CharacterSyncState(), b = CharacterSyncState()
        let first = early(), second = late()
        a.facts[first.id] = .init(value: .init(entity: "p", work: "stable-work", fact: first), updatedAt: time)
        b.facts[second.id] = .init(value: .init(entity: "p", work: "stable-work", fact: second), updatedAt: time)
        a.scans[key] = .init(value: .init(signature: "same-version", nextChapter: 12), updatedAt: time)
        b.scans[key] = .init(value: .init(signature: "same-version", nextChapter: 4), updatedAt: time.addingTimeInterval(1))
        let merged = try CharacterSyncState.merged(a, b)
        XCTAssertEqual(merged.facts.count, 2)
        XCTAssertEqual(merged.scans[key]?.value?.nextChapter, 12)
        XCTAssertEqual(try CharacterSyncState.merged(a, b), try CharacterSyncState.merged(b, a))
        XCTAssertEqual(try CharacterSyncState.merged(merged, merged), merged)
        b.scans[key] = .init(value: .init(signature: "different-version", nextChapter: 2), updatedAt: time.addingTimeInterval(2))
        XCTAssertEqual(try CharacterSyncState.merged(a, b).scans[key]?.value?.nextChapter, 2)
        b.facts[first.id] = .init(value: nil, updatedAt: time)
        XCTAssertNil(try CharacterSyncState.merged(a, b).facts[first.id]?.value)
    }
    @MainActor
    func testRemoteSnapshotDoesNotOverwriteNewLocalEditsAndRejectsMalformedState() throws {
        let suite = "CharacterSyncRace-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterLexiconStore(defaults: defaults)
        try store.confirmOrder(work: scope().work, volumes: scope().volumes)
        let fact = early(), id = try store.accept(.init(facts: [fact]), scope: scope())
        let old = try store.characterSnapshot()
        try store.edit(fact: fact.id, entity: id, text: "同步等待期间的本机修改。", scope: scope())
        try store.applyCharacters(old)
        XCTAssertEqual(store.entities[0].facts[0].text, "同步等待期间的本机修改。")
        var broken = old; broken.version = 999
        XCTAssertThrowsError(try store.applyCharacters(broken))
        XCTAssertEqual(store.entities[0].facts[0].text, "同步等待期间的本机修改。")
        var missing = old
        missing.facts = ["wrong-id": .init(value: .init(entity: id, work: scope().work, fact: fact), updatedAt: Date())]
        XCTAssertThrowsError(try missing.validated())
    }

}

private actor CharacterRetryAI: ReadingAICompleting {
    private(set) var calls = 0
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        calls += 1
        // 第一次返回无法解析的说明文字，模拟真实模型偶发的非 JSON 回复。
        if calls == 1 { return .init(text: "抱歉，我无法按要求提取人物。", inputTokens: nil, outputTokens: nil) }
        let input = try JSONSerialization.jsonObject(with: Data(request.input.utf8)) as! [String: Any]
        let chapter = input["chapter"] as! Int
        let data = try JSONSerialization.data(withJSONObject: ["candidates": [[
            "name": "面具人", "facts": [["chapter": chapter, "text": "交出物品。", "quote": input["text"] as! String]]]]])
        return .init(text: String(decoding: data, as: UTF8.self), inputTokens: nil, outputTokens: nil)
    }
}

private actor CharacterSequenceAI: ReadingAICompleting {
    let failSecond: Bool
    var calls = 0
    init(failSecond: Bool) { self.failSecond = failSecond }
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        calls += 1
        let input = try JSONSerialization.jsonObject(with: Data(request.input.utf8)) as! [String: Any]
        let chapter = input["chapter"] as! Int
        if chapter == 1 && failSecond { throw ReadingAIError.transport }
        let known = input["known_candidates"] as! [[String: Any]]
        var person: [String: Any] = ["name": "面具人", "facts": [["chapter": chapter, "text": "交出物品。", "quote": input["text"] as! String]]]
        if let id = known.first?["id"] { person["candidate_id"] = id }
        let data = try JSONSerialization.data(withJSONObject: ["candidates": [person]])
        return .init(text: String(decoding: data, as: UTF8.self), inputTokens: nil, outputTokens: nil)
    }
}

private actor CharacterPausedAI: ReadingAICompleting {
    private var pending: CheckedContinuation<ReadingAIResponse, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume(); started = nil
        }
    }
    func resolve(_ text: String) {
        pending?.resume(returning: .init(text: text, inputTokens: nil, outputTokens: nil)); pending = nil
    }
}
