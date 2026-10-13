import Foundation
import XCTest
@testable import NoveliaIOSCore

/// Tag blocking and the WebDAV merge rules (formerly scripts/test_blocked_tags.py).
@MainActor
final class SyncMergeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "BlockedTagsTest-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testBlockedTagsStore() {
        let store = BlockedTagsStore(defaults: defaults)
        store.add("  标签A \n"); store.add("标签A"); store.add("  ")
        XCTAssertEqual(store.tags, ["标签A"], "trimming and duplicates")
        XCTAssertTrue(store.hides(["普通", "标签A"]))
        XCTAssertFalse(store.hides(["标签AB"]), "exact match only")
        XCTAssertFalse(store.hides([]))
        store.rememberWenku(id: "synthetic-book", tags: ["标签A"])

        let restored = BlockedTagsStore(defaults: defaults)
        XCTAssertEqual(restored.tags, ["标签A"], "persisted")
        XCTAssertTrue(restored.hides(restored.wenkuTags["synthetic-book"]!), "library metadata persisted")
        restored.remove("标签A")
        XCTAssertFalse(restored.hides(["标签A"]))
        XCTAssertTrue(BlockedTagsStore(defaults: defaults).tags.isEmpty, "removal persisted")
    }

    func testBlockedTagSyncMerge() {
        let store = BlockedTagsStore(defaults: defaults)
        let old = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
        let remote = ["标签B": SyncedBlockedTag(blocked: true, updatedAt: old)]
        store.applySynced(remote)
        XCTAssertTrue(store.contains("标签B"))
        let unblocked = ["标签B": SyncedBlockedTag(blocked: false, updatedAt: newer)]
        store.applySynced(unblocked)
        XCTAssertFalse(store.contains("标签B"), "newer unblock wins")
        store.applySynced(remote)
        XCTAssertFalse(store.contains("标签B"), "older block ignored")
        XCTAssertEqual(BlockedTagsStore(defaults: defaults).syncStates["标签B"]?.blocked, false)
        XCTAssertEqual(BlockedTagsStore.merged(remote, unblocked), BlockedTagsStore.merged(unblocked, remote), "order independent")
        let equal = ["标签B": SyncedBlockedTag(blocked: false, updatedAt: old)]
        XCTAssertEqual(BlockedTagsStore.merged(remote, equal), BlockedTagsStore.merged(equal, remote), "tie resolved to unblocked")
    }

    func testLegacyBlockedTagListMigrates() {
        defaults.set(["旧标签"], forKey: "blockedNovelTags")
        let store = BlockedTagsStore(defaults: defaults)
        XCTAssertEqual(store.tags, ["旧标签"])
        XCTAssertEqual(store.syncStates["旧标签"]?.updatedAt, .distantPast, "legacy tags lose to any synced change")
    }

    func testImportedFontDeletionWins() {
        let old = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
        let font = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: false, updatedAt: old)]
        let deleted = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: true, updatedAt: newer)]
        XCTAssertTrue(SyncedImportedFont.merged(font, deleted)["hash"]!.deleted)
        XCTAssertTrue(SyncedImportedFont.merged(deleted, font)["hash"]!.deleted)
        let tied = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: true, updatedAt: old)]
        XCTAssertTrue(SyncedImportedFont.merged(font, tied)["hash"]!.deleted)
        XCTAssertTrue(SyncedImportedFont.merged(tied, font)["hash"]!.deleted)
    }

    func testReadingPositionMerge() {
        let old = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
        let local = ["web:a": SyncedReadingPosition(chapterIndex: 3, fraction: nil, updatedAt: newer),
                     "epub:b": SyncedReadingPosition(chapterIndex: nil, fraction: 0.2, updatedAt: old)]
        let remote = ["web:a": SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: old),
                      "epub:b": SyncedReadingPosition(chapterIndex: nil, fraction: 0.6, updatedAt: newer),
                      "epub:c": SyncedReadingPosition(chapterIndex: nil, fraction: 0.9, updatedAt: old)]
        let merged = SyncedReadingPosition.merged(local, remote)
        XCTAssertEqual(merged["web:a"]?.chapterIndex, 3, "newer local kept")
        XCTAssertEqual(merged["epub:b"]?.fraction, 0.6, "newer remote applied")
        XCTAssertEqual(merged["epub:c"]?.fraction, 0.9, "remote-only position added")
        let tie = SyncedReadingPosition.merged(["web:a": SyncedReadingPosition(chapterIndex: 3, fraction: nil, updatedAt: old)],
                                               ["web:a": SyncedReadingPosition(chapterIndex: 5, fraction: nil, updatedAt: old)])
        XCTAssertEqual(tie["web:a"]?.chapterIndex, 5, "equal timestamps take the remote copy")
    }

    func testReadingPositionOffsetIsOptional() throws {
        let legacy = try JSONDecoder().decode(SyncedReadingPosition.self,
                                              from: Data(#"{"fraction":0.5,"updatedAt":100}"#.utf8))
        XCTAssertNil(legacy.chapterOffset, "positions saved before offsets still decode")
        XCTAssertEqual(legacy.fraction, 0.5)
        let current = SyncedReadingPosition(chapterIndex: 3, fraction: 0.4, updatedAt: Date(timeIntervalSince1970: 1), chapterOffset: 1200)
        XCTAssertEqual(try JSONDecoder().decode(SyncedReadingPosition.self, from: JSONEncoder().encode(current)), current)
    }

    /// TXT positions (`txt:<hash>`) add `unit` and `unitCount`. Positions written before them
    /// still decode, the new fields round-trip, and a decoder that predates them (shape of
    /// 0.12.0 (52) and older) reads the same JSON without failing.
    func testTXTPositionFieldsAreBackwardCompatible() throws {
        let earlier = try JSONDecoder().decode(SyncedReadingPosition.self,
                                               from: Data(#"{"chapterIndex":7,"updatedAt":100,"chapterOffset":40}"#.utf8))
        XCTAssertNil(earlier.unit)
        XCTAssertNil(earlier.unitCount)
        let txt = SyncedReadingPosition(chapterIndex: 7, fraction: nil, updatedAt: Date(timeIntervalSince1970: 300),
                                        chapterOffset: 512, unit: 19, unitCount: 1_802)
        let data = try JSONEncoder().encode(["txt:abc": txt, "web:n": SyncedReadingPosition(chapterIndex: 2, fraction: nil, updatedAt: Date(timeIntervalSince1970: 1))])
        XCTAssertEqual(try JSONDecoder().decode([String: SyncedReadingPosition].self, from: data)["txt:abc"], txt)

        struct OlderPosition: Codable, Equatable {
            var chapterIndex: Int?
            var fraction: Double?
            var updatedAt: Date
            var chapterOffset: Int?
        }
        let older = try JSONDecoder().decode([String: OlderPosition].self, from: data)
        XCTAssertEqual(older["txt:abc"]?.chapterIndex, 7, "older versions ignore unit fields")
        XCTAssertEqual(older["web:n"]?.chapterIndex, 2)

        // A newer TXT position from another device wins; a local one is never removed.
        let merged = SyncedReadingPosition.merged(
            ["txt:abc": SyncedReadingPosition(chapterIndex: 3, fraction: nil, updatedAt: Date(timeIntervalSince1970: 200)),
             "txt:local": SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: Date(timeIntervalSince1970: 200))],
            ["txt:abc": txt])
        XCTAssertEqual(merged["txt:abc"], txt)
        XCTAssertNotNil(merged["txt:local"], "a remote manifest without the key (older uploader) keeps the local position")
    }

    func testManifestRecordsRoundTrip() throws {
        let value = SyncedReaderBackground(mode: "color", color: "112233", portraitHash: "p", landscapeHash: nil,
                                           updatedAt: Date(timeIntervalSince1970: 300))
        let decoded = try JSONDecoder().decode(SyncedReaderBackground.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.mode, "color")
        XCTAssertEqual(decoded.portraitHash, "p")
        XCTAssertNil(decoded.landscapeHash)
        let tags = ["标签": SyncedBlockedTag(blocked: true, updatedAt: Date(timeIntervalSince1970: 1))]
        XCTAssertEqual(try JSONDecoder().decode([String: SyncedBlockedTag].self, from: JSONEncoder().encode(tags)), tags)
    }
}
