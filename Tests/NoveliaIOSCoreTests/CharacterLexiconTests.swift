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
}
