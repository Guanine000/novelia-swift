import Foundation
import Combine
import XCTest
@testable import NoveliaIOSCore

@MainActor
final class WebNovelEPUBIdentityTests: XCTestCase {
    private func settings() -> ReaderSettings {
        let suite = "WebNovelEPUBIdentityTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ReaderSettings(defaults: defaults)
    }
    private let testHash = String(repeating: "a", count: 64)
    private var key: String { WebNovelEPUBContext.key(provider: "site", novel: "novel") }
    private func context(_ ids: [String: String], hash fileHash: String? = nil) -> WebNovelEPUBContext {
        WebNovelEPUBContext(bookKey: key, fileHash: fileHash ?? self.testHash, chapterIDs: ids, legacyHashes: [self.testHash, String(repeating: "b", count: 64)])
    }
    func testIdentityDoesNotCollideAtComponentBoundaries() {
        XCTAssertNotEqual(WebNovelEPUBContext.key(provider: "ab", novel: "c"), WebNovelEPUBContext.key(provider: "a", novel: "bc"))
        XCTAssertEqual(key.count, 72)
    }
    func testSameChapterRestoresAcrossInsertedAndReorderedFiles() {
        let settings = settings()
        let old = context(["a": "first", "b": "second"])
        settings.recordEPUBPosition(hash: testHash, fraction: 0.8, spineIndex: 1, chapterOffset: 222, chapterProgression: 0.6, context: old, paths: ["a", "b"])
        let newHash = String(repeating: "b", count: 64)
        let newer = context(["new-b": "second", "new-a": "first", "extra": "third"], hash: newHash)
        let restored = settings.epubPosition(hash: newHash, context: newer, paths: ["extra", "new-b", "new-a"])
        XCTAssertEqual(restored?.chapterIndex, 1)
        XCTAssertEqual(restored?.chapterProgression, 0.6)
        XCTAssertNil(restored?.chapterOffset)
        XCTAssertNil(restored?.fraction)
    }
    func testMissingChapterDoesNotFallBackToAnotherFilesIndexOrFraction() {
        let settings = settings()
        settings.positions.mergePosition(key: key, position: SyncedReadingPosition(chapterIndex: 99, fraction: 0.99, updatedAt: Date(), chapterProgression: 0.6, chapterID: "absent"))
        let map = context(["a": "first"])
        XCTAssertNil(settings.epubPosition(hash: testHash, context: map, paths: ["a"]))
        XCTAssertTrue(settings.missingWebEPUBChapter(context: map, paths: ["a"]))
        let before = settings.positions.all()[key]
        // 未确认章节上的本机阅读只记文件状态，不会覆盖暂时缺失的云端章节ID。
        settings.recordEPUBPosition(hash: testHash, fraction: 0.1, spineIndex: 0, chapterOffset: 0, chapterProgression: 0, context: context([:]), paths: ["a"])
        XCTAssertEqual(settings.positions.all()[key], before)
    }
    func testLegacyMigrationPreservesTimeAndBookmarksAndIsIdempotent() throws {
        let settings = settings(), map = context(["a": "chapter"])
        settings.positions.recordEPUB(hash: testHash, fraction: 0.6, spineIndex: 0, chapterOffset: 20, chapterProgression: 0.6)
        let old = try settings.bookmarks.add(bookKey: "epub:" + testHash, chapterIndex: 0, progression: 0.4, chapterTitle: "Title", snippet: "text")
        let oldPosition = settings.positions.epubPosition(hash: testHash)
        for _ in 0..<2 { try WebNovelEPUBMigration.migrate(context: map, paths: ["a"], settings: settings) }
        XCTAssertEqual(settings.positions.all()[key]?.updatedAt, oldPosition?.updatedAt)
        XCTAssertEqual(settings.bookmarks.bookmarks(for: "epub:" + testHash), [old])
        XCTAssertEqual(settings.bookmarks.bookmarks(for: key).count, 1)
        let migrated = try XCTUnwrap(settings.bookmarks.bookmarks(for: key).first)
        XCTAssertEqual(migrated.updatedAt, old.updatedAt)
        XCTAssertEqual(migrated.chapterID, "chapter")
        try settings.bookmarks.remove(migrated.id, now: old.updatedAt.addingTimeInterval(10))
        try WebNovelEPUBMigration.migrate(context: map, paths: ["a"], settings: settings)
        XCTAssertTrue(settings.bookmarks.bookmarks(for: key).isEmpty)
    }
    func testLegacyDeletionAnd107CopyAreMergedIntoOneStableBookmark() throws {
        let settings = settings(), hash2 = String(repeating: "b", count: 64)
        let old = try settings.bookmarks.add(bookKey: "epub:" + testHash, chapterIndex: 0, progression: 0.4, chapterTitle: nil, snippet: "")
        let copyID = WebNovelEPUBMigration.derived(old.id, key: "epub:" + hash2)
        let copy = ReaderBookmark(id: copyID, bookKey: "epub:" + hash2, chapterIndex: 0, chapterProgression: 0.4, chapterTitle: nil, snippet: "", createdAt: old.createdAt, updatedAt: old.updatedAt)
        try settings.bookmarks.applySynced([copyID.uuidString: copy])
        try settings.bookmarks.remove(old.id, now: old.updatedAt.addingTimeInterval(5))
        try WebNovelEPUBMigration.migrate(context: context(["a": "chapter"]), paths: ["a"], settings: settings)
        try WebNovelEPUBMigration.migrate(context: context(["b": "chapter"], hash: hash2), paths: ["b"], settings: settings)
        XCTAssertTrue(settings.bookmarks.bookmarks(for: key).isEmpty)
        XCTAssertEqual(settings.bookmarks.records.values.filter { $0.bookKey == key }.count, 1)
    }
    func testUnknownMappingDoesNotMigrateAndWenkuHashPathRemainsUnchanged() throws {
        let settings = settings()
        settings.positions.recordEPUB(hash: testHash, fraction: 0.7, spineIndex: 0, chapterOffset: 10, chapterProgression: 0.5)
        let old = settings.epubPosition(hash: testHash)
        try WebNovelEPUBMigration.migrate(context: context([:]), paths: ["a"], settings: settings)
        XCTAssertNil(settings.positions.all()[key])
        XCTAssertEqual(settings.epubPosition(hash: testHash, context: nil, paths: ["a"]), old)
        let bookmark = try settings.bookmarks.add(bookKey: "epub:" + testHash, chapterIndex: 0, progression: 0.2, chapterTitle: nil, snippet: "")
        XCTAssertNil(bookmark.chapterID)
        XCTAssertEqual(settings.bookmarks.bookmarks(for: "epub:" + testHash), [bookmark])
    }
    func testMapsAreBoundToFileAndMergeComplementaryConfirmations() throws {
        let settings = settings(), now = Date()
        let a = WebNovelEPUBMap(bookKey: key, fileHash: testHash, bindings: ["a": WebNovelEPUBBinding(chapterID: "first", updatedAt: now)])
        let b = WebNovelEPUBMap(bookKey: key, fileHash: testHash, bindings: ["b": WebNovelEPUBBinding(chapterID: "second", updatedAt: now)])
        try settings.webEPUBMaps.merge([a.key: a]); try settings.webEPUBMaps.merge([b.key: b])
        XCTAssertEqual(settings.webEPUBMaps.context(bookKey: key, hash: testHash).chapterIDs.count, 2)
        XCTAssertTrue(settings.webEPUBMaps.context(bookKey: key, hash: String(repeating: "b", count: 64)).chapterIDs.isEmpty)
        let reloaded = WebNovelEPUBMapStore(defaults: settings.defaults)
        XCTAssertEqual(reloaded.maps, settings.webEPUBMaps.maps)
        let deleted = WebNovelEPUBMap(bookKey: key, fileHash: testHash, bindings: ["a": WebNovelEPUBBinding(chapterID: "first", updatedAt: now.addingTimeInterval(5), deleted: true)])
        try settings.webEPUBMaps.merge([deleted.key: deleted])
        XCTAssertNil(settings.webEPUBMaps.context(bookKey: key, hash: testHash).chapterIDs["a"])
    }
    func testDuplicateOrMalformedBindingsCannotResolveChapter() throws {
        let now = Date()
        let duplicate = WebNovelEPUBMap(bookKey: key, fileHash: testHash, bindings: ["a": WebNovelEPUBBinding(chapterID: "same", updatedAt: now), "b": WebNovelEPUBBinding(chapterID: "same", updatedAt: now)])
        XCTAssertTrue(duplicate.chapterIDs.isEmpty)
        let invalid = WebNovelEPUBMap(bookKey: key, fileHash: "../invalid", bindings: [:])
        XCTAssertTrue(WebNovelEPUBMap.merged([:], [invalid.key: invalid]).isEmpty)
    }
    func testManualCorrectionDoesNotRefreshHistoricalTimeOrResurrectDeletion() throws {
        let settings = settings()
        settings.positions.recordEPUB(hash: testHash, fraction: 0.2, spineIndex: 0, chapterOffset: 10, chapterProgression: 0.2)
        _ = try settings.bookmarks.add(bookKey: "epub:" + testHash, chapterIndex: 0, progression: 0.2, chapterTitle: nil, snippet: "")
        let time = settings.epubPosition(hash: testHash)?.updatedAt
        try WebNovelEPUBMigration.migrate(context: context(["a": "first"]), paths: ["a"], settings: settings)
        try WebNovelEPUBMigration.migrate(context: context(["a": "corrected"]), paths: ["a"], settings: settings)
        XCTAssertEqual(settings.positions.all()[key]?.chapterID, "corrected")
        XCTAssertEqual(settings.positions.all()[key]?.updatedAt, time)
        let item = try XCTUnwrap(settings.bookmarks.bookmarks(for: key).first)
        XCTAssertEqual(item.chapterID, "corrected")
        try settings.bookmarks.remove(item.id, now: item.updatedAt.addingTimeInterval(10))
        try WebNovelEPUBMigration.migrate(context: context(["a": "first"]), paths: ["a"], settings: settings)
        XCTAssertTrue(settings.bookmarks.bookmarks(for: key).isEmpty)
    }
    func testPositionChangesPublishWithoutPublishingUnchangedMigration() {
        let settings = settings()
        var changes = 0
        let token = settings.positions.changes.sink { changes += 1 }
        let position = SyncedReadingPosition(chapterIndex: 0, fraction: nil, updatedAt: Date(), chapterProgression: 0.2, chapterID: "id")
        settings.positions.mergePosition(key: key, position: position)
        settings.positions.mergePosition(key: key, position: position)
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(token) {}
    }
    func testIdentityWebDAVRootIsIsolatedFromOldClient() throws {
        let old = try WebDAVClient(address: "https://example.invalid/dav/", username: "fixture", password: "test-only")
        let new = try WebDAVClient(address: "https://example.invalid/dav/", username: "fixture", password: "test-only", webEPUBIdentity: true)
        XCTAssertTrue(old.root.absoluteString.hasSuffix("/NoveliaSync/v1/"))
        XCTAssertTrue(new.root.absoluteString.hasSuffix("/NoveliaSync/web-epub-v1/"))
        XCTAssertNotEqual(old.serverKey, new.serverKey)
    }

    func testIdentityEqualTimeKeepsLocalWhileLegacyMergeStaysCompatible() {
        let now = Date()
        let local = SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: now, chapterProgression: 0.2, chapterID: "local")
        let remote = SyncedReadingPosition(chapterIndex: 2, fraction: nil, updatedAt: now, chapterProgression: 0.7, chapterID: "remote")
        XCTAssertEqual(SyncedReadingPosition.merged([key: local], [key: remote])[key], local)
        XCTAssertEqual(SyncedReadingPosition.merged(["epub:legacy": local], ["epub:legacy": remote])["epub:legacy"], remote)
    }

}

final class WebNovelEPUBTOCMatcherTests: XCTestCase {
    private func chapter(_ id: String, _ title: String, original: String? = nil) -> NovelChapter {
        NovelChapter(id: id, title: title, originalText: "", translatedText: "", originalTitle: original)
    }
    private func entries(_ titles: [String]) -> [WebNovelEPUBTOCMatcher.Entry] {
        titles.enumerated().map { .init(path: "c\($0.offset)", title: $0.element) }
    }
    func testTitlesSurviveInsertionAndReorderingWithoutUsingIndex() {
        let remote = [chapter("b", "第二章"), chapter("new", "新增章"), chapter("a", "第一章")]
        let result = WebNovelEPUBTOCMatcher.match(local: entries(["第一章", "第二章"]), remote: remote, saved: [], existing: [:])
        XCTAssertEqual(result, ["c0": "a", "c1": "b"])
    }
    func testDuplicateTitlesOnEitherSideRemainUnresolved() {
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: entries(["幕间", "幕间"]), remote: [chapter("a", "幕间")], saved: [], existing: [:]).isEmpty)
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: entries(["幕间"]), remote: [chapter("a", "幕间"), chapter("b", "幕间")], saved: [], existing: [:]).isEmpty)
    }
    func testOriginalTitleAndWhitespaceAreSupportedButChapterNumbersAreNotGuessed() {
        let remote = [chapter("a", "第一章", original: " 第一話　出発 "), chapter("b", "第1章")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: entries(["第一話 出発", "第一章X"]), remote: remote, saved: [], existing: [:]), ["c0": "a"])
    }
    func testSavedTitleAliasRequiresSameSurvivingIDAndDetectsReusedTitle() {
        let local = entries(["旧标题"]), saved = [chapter("a", "旧标题")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: local, remote: [chapter("a", "新标题")], saved: saved, existing: [:]), ["c0": "a"])
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: local, remote: [chapter("b", "旧标题")], saved: saved, existing: [:]).isEmpty)
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: local, remote: [], saved: saved, existing: [:]).isEmpty)
    }
    func testMultipleResourcesCannotClaimOneIDOrReplaceConfirmedBinding() {
        let remote = [chapter("a", "中文", original: "日本語")]
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: entries(["中文", "日本語"]), remote: remote, saved: [], existing: [:]).isEmpty)
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: entries(["中文"]), remote: remote, saved: [], existing: ["confirmed": "a"]).isEmpty)
    }
    func testMultipleTOCSectionsInOneResourceAreNotCollapsedIntoAChapter() {
        let local = [WebNovelEPUBTOCMatcher.Entry(path: "same", title: "第一章"), .init(path: "same", title: "第二章")]
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: local, remote: [chapter("a", "第一章"), chapter("b", "第二章")], saved: [], existing: [:]).isEmpty)
    }
    func testLegacyChapterJSONDoesNotRequireOriginalTitle() throws {
        let data = Data(#"{"id":"a","title":"第一章","originalText":"","translatedText":""}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(NovelChapter.self, from: data).originalTitle)
    }
}

final class WebNovelEPUBContextualTOCTests: XCTestCase {
    private func chapter(_ id: String, _ title: String, volume: String? = nil, originalVolume: String? = nil) -> NovelChapter {
        NovelChapter(id: id, title: title, originalText: "", translatedText: "", volumeTitle: volume, originalVolumeTitle: originalVolume)
    }
    private func entries(_ titles: [String]) -> [WebNovelEPUBTOCMatcher.Entry] {
        titles.enumerated().map { .init(path: "c\($0.offset)", title: $0.element) }
    }
    func testVolumeNamesDisambiguateRepeatedTitlesIncludingOriginalVolume() {
        let local: [WebNovelEPUBTOCMatcher.Entry] = [.init(path: "one", title: "幕间", volume: "第一巻"), .init(path: "two", title: "幕间", volume: "第二卷")]
        let remote = [chapter("a", "幕间", volume: "第一卷", originalVolume: "第一巻"), chapter("b", "幕间", volume: "第二卷")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: local, remote: remote, saved: [], existing: [:]), ["one": "a", "two": "b"])
    }
    func testConflictingKnownVolumesDoNotMatchByTitleAlone() {
        let local: [WebNovelEPUBTOCMatcher.Entry] = [.init(path: "one", title: "幕间", volume: "第一卷")]
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: local, remote: [chapter("a", "幕间", volume: "第二卷")], saved: [], existing: [:]).isEmpty)
    }
    func testConfirmedNeighborsDisambiguateRepeatedTitleOutsideTheirInterval() {
        let remote = [chapter("outside", "幕间"), chapter("a", "新A"), chapter("inside", "幕间"), chapter("b", "新B")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: entries(["旧A", "幕间", "旧B"]), remote: remote, saved: [], existing: ["c0": "a", "c2": "b"]), ["c1": "inside"])
    }
    func testContinuousRepeatedTitlesHaveOneOrderedCorrespondence() {
        let remote = [chapter("a", "A"), chapter("x1", "幕间"), chapter("x2", "幕间"), chapter("b", "B")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: entries(["A", "幕间", "幕间", "B"]), remote: remote, saved: [], existing: [:]), ["c0": "a", "c1": "x1", "c2": "x2", "c3": "b"])
    }
    func testInsertedDuplicateRemainsAmbiguous() {
        let remote = [chapter("a", "A"), chapter("x1", "幕间"), chapter("x2", "幕间"), chapter("b", "B")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: entries(["A", "幕间", "B"]), remote: remote, saved: [], existing: [:]), ["c0": "a", "c2": "b"])
    }
    func testDeletedDuplicateDoesNotShiftRemainingLocalChapters() {
        let remote = [chapter("a", "A"), chapter("x", "幕间"), chapter("b", "B")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: entries(["A", "幕间", "幕间", "B"]), remote: remote, saved: [], existing: [:]), ["c0": "a", "c3": "b"])
    }
    func testCrossingAnchorsDisableSequenceInference() {
        let remote = [chapter("b", "B"), chapter("x1", "幕间"), chapter("a", "A"), chapter("x2", "幕间")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: entries(["A", "幕间", "B"]), remote: remote, saved: [], existing: [:]), ["c0": "a", "c2": "b"])
    }
    func testDistinctInsertedTitleDoesNotPreventUniqueSubsequence() {
        let remote = [chapter("x1", "幕间"), chapter("new", "新增"), chapter("x2", "幕间")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.match(local: entries(["幕间", "幕间"]), remote: remote, saved: [], existing: [:]), ["c0": "x1", "c1": "x2"])
    }
    func testCandidatesUseAnchorsAndExcludeConfirmedIDs() {
        let remote = [chapter("outside", "幕间"), chapter("a", "A"), chapter("inside", "幕间"), chapter("b", "B")]
        XCTAssertEqual(WebNovelEPUBTOCMatcher.candidates(path: "c1", local: entries(["A", "幕间", "B"]), remote: remote, saved: [], existing: ["c0": "a", "c2": "b"]), ["inside"])
        XCTAssertTrue(WebNovelEPUBTOCMatcher.candidates(path: "c0", local: entries(["不存在"]), remote: remote, saved: [], existing: [:]).isEmpty)
    }
    func testDuplicateRemoteIDsCannotBecomeAnchorsOrAutomaticBindings() {
        let remote = [chapter("same", "A"), chapter("same", "B")]
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: entries(["A", "B"]), remote: remote, saved: [], existing: [:]).isEmpty)
    }
    func testPathWithMultipleSectionsBlocksOrderedGuessing() {
        let local: [WebNovelEPUBTOCMatcher.Entry] = [.init(path: "one", title: "幕间"), .init(path: "one", title: "另一章")]
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: local, remote: [chapter("a", "幕间")], saved: [], existing: [:]).isEmpty)
    }
    func testOnlyPairsSharedByEveryOrderedAlignmentAreInferred() {
        func words(_ length: Int, _ mask: Int) -> [String] {
            (0..<length).map { mask & (1 << $0) == 0 ? "X" : "Y" }
        }
        for n in 1...4 { for m in n...5 {
            for localMask in 0..<(1 << n) { for remoteMask in 0..<(1 << m) {
                let local = words(n, localMask), remote = words(m, remoteMask)
                var alignments: [[Int]] = []
                func enumerate(_ i: Int, _ start: Int, _ chosen: [Int]) {
                    if i == n { alignments.append(chosen); return }
                    guard start < m else { return }
                    for j in start..<m where local[i] == remote[j] { enumerate(i + 1, j + 1, chosen + [j]) }
                }
                enumerate(0, 0, [])
                guard let first = alignments.first else { continue }
                var forced: [String: String] = [:]
                for i in 0..<n where alignments.allSatisfy({ $0[i] == first[i] }) { forced["c\(i)"] = "id\(first[i])" }
                let result = WebNovelEPUBTOCMatcher.match(local: entries(local), remote: remote.enumerated().map { chapter("id\($0.offset)", $0.element) }, saved: [], existing: [:])
                XCTAssertEqual(result, forced, "local=\(local), remote=\(remote)")
            }}
        }}
    }
    func testLargeIdenticalTitleGroupFallsBackWithoutQuadraticCandidates() {
        let remote = (0..<2000).map { chapter("id\($0)", "幕间") }
        XCTAssertTrue(WebNovelEPUBTOCMatcher.match(local: entries(Array(repeating: "幕间", count: 2000)), remote: remote, saved: [], existing: [:]).isEmpty)
    }
}

final class WebNovelEPUBFileMatcherTests: XCTestCase {
    private let key = WebNovelEPUBContext.key(provider: "site", novel: "one")
    private let time = Date(timeIntervalSince1970: 100)
    private func map(_ hash: String, _ bindings: [String: WebNovelEPUBBinding] = [:]) -> WebNovelEPUBMap {
        WebNovelEPUBMap(bookKey: key, fileHash: String(repeating: hash, count: 64), bindings: bindings)
    }
    private func resource(_ path: String, _ title: String = "第一章", _ body: String = "实际正文") -> WebNovelEPUBFileMatcher.Resource {
        .init(path: path, heading: title, body: body)
    }
    func testReorderedRenamedPathsInheritIDAndOriginalTime() {
        let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
        let result = WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [resource("insert", "新增"), resource("new")], source: source, target: map("b"))
        XCTAssertEqual(result.chapterIDs, ["new": "stable"])
        XCTAssertEqual(result.bindings["new"]?.updatedAt, time)
    }
    func testUnknownOldDuplicateBlocksInheritance() {
        let source = map("a", ["known": .init(chapterID: "stable", updatedAt: time)])
        let result = WebNovelEPUBFileMatcher.inherit(old: [resource("known"), resource("unknown")], new: [resource("new")], source: source, target: map("b"))
        XCTAssertTrue(result.bindings.isEmpty)
    }
    func testDuplicateNewResourcesRemainUnmapped() {
        let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
        XCTAssertTrue(WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [resource("one"), resource("two")], source: source, target: map("b")).bindings.isEmpty)
    }
    func testChangedBodyOrHeadingDoesNotInheritBySequence() {
        let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
        for changed in [resource("old", "第一章", "正文已修改"), resource("old", "修改标题")] {
            XCTAssertTrue(WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [changed], source: source, target: map("b")).bindings.isEmpty)
        }
    }
    func testTargetConfirmationAndTombstonesAreProtected() {
        let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
        for bindings: [String: WebNovelEPUBBinding] in [
            ["new": .init(chapterID: "other", updatedAt: time)],
            ["new": .init(chapterID: "stable", updatedAt: time, deleted: true)],
            ["other": .init(chapterID: "stable", updatedAt: time)],
            ["other": .init(chapterID: "stable", updatedAt: time, deleted: true)]
        ] {
            let target = map("b", bindings)
            XCTAssertEqual(WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [resource("new")], source: source, target: target), target)
        }
    }
    func testMissingEmptyAndUnconfirmedBodiesDoNotInherit() {
        for body in ["", "该章节缺失。", "翻译缺失。"] {
            let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
            XCTAssertTrue(WebNovelEPUBFileMatcher.inherit(old: [resource("old", "第一章", body)], new: [resource("new", "第一章", body)], source: source, target: map("b")).bindings.isEmpty)
        }
        XCTAssertTrue(WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [resource("new")], source: map("a"), target: map("b")).bindings.isEmpty)
    }
    func testWhitespaceOnlyChangesAreAcceptedAndRepeatIsIdempotent() {
        let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
        let old = [resource("old")], new = [resource("new", "第一 章", "实 际\n正文")]
        let result = WebNovelEPUBFileMatcher.inherit(old: old, new: new, source: source, target: map("b"))
        XCTAssertEqual(result.chapterIDs, ["new": "stable"])
        XCTAssertEqual(WebNovelEPUBFileMatcher.inherit(old: old, new: new, source: source, target: result), result)
    }
    func testRepeatedResourcePathsDoNotAcquireConflictingBindings() {
        let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
        XCTAssertTrue(WebNovelEPUBFileMatcher.inherit(old: [resource("old"), resource("old", "另一标题")], new: [resource("new")], source: source, target: map("b")).bindings.isEmpty)
        XCTAssertTrue(WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [resource("new"), resource("new", "另一标题")], source: source, target: map("b")).bindings.isEmpty)
    }
    func testSameFileAndDifferentNovelNeverRebind() {
        let source = map("a", ["old": .init(chapterID: "stable", updatedAt: time)])
        XCTAssertEqual(WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [resource("new")], source: source, target: source), source)
        let target = WebNovelEPUBMap(bookKey: WebNovelEPUBContext.key(provider: "other", novel: "one"), fileHash: String(repeating: "b", count: 64), bindings: [:])
        XCTAssertEqual(WebNovelEPUBFileMatcher.inherit(old: [resource("old")], new: [resource("new")], source: source, target: target), target)
    }
}

final class WebNovelEPUBUpdateConfigurationTests: XCTestCase {
    private func record(_ mode: WebNovelDownloadMode?, _ source: NovelTranslationSource?) -> DownloadedWebNovel {
        DownloadedWebNovel(novel: Novel(id: "remote/site/book", title: "Book", author: "", summary: "", genres: [], chapters: [], accent: .plum), fileFilename: "book.epub", downloadedAt: .distantPast, translationSource: source, downloadMode: mode, fileFormat: .epub)
    }
    func testLegacyModeIsNeverInferredForWebsiteUpdate() {
        XCTAssertNil(record(nil, nil).epubUpdateConfiguration)
        XCTAssertNil(record(nil, .sakura).epubUpdateConfiguration)
    }
    func testTranslatedModesRequireExplicitSource() {
        XCTAssertNil(record(.translated, nil).epubUpdateConfiguration)
        XCTAssertNil(record(.bilingual, nil).epubUpdateConfiguration)
        XCTAssertEqual(record(.bilingual, .gpt).epubUpdateConfiguration, .init(mode: .bilingual, translationSource: .gpt))
    }
    func testOriginalModeDoesNotNeedOrSendTranslator() {
        XCTAssertNotNil(record(.original, nil).epubUpdateConfiguration)
        XCTAssertNil(record(.original, .gpt).epubUpdateConfiguration?.effectiveSource)
    }
}
