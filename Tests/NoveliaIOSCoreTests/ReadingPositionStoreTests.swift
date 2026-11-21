import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
final class ReadingPositionStoreTests: XCTestCase {
    private var suites: [String] = []
    private func preferences() -> UserDefaults {
        let suite = "reading-position-boundary-" + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites.removeAll()
    }

    func testPositionsPersistWithExistingKeysAndFormats() throws {
        let defaults = preferences()
        let store = ReadingPositionStore(defaults: defaults)
        store.recordWeb(id: "novel", chapterIndex: 4)
        store.recordEPUB(hash: "epub", fraction: 1.5, spineIndex: 2, chapterOffset: 70, chapterProgression: -1)
        store.recordTXT(hash: "txt", position: TXTReadingPosition(chapter: 3, unit: 8, offset: 9, unitCount: 10))
        XCTAssertNotNil(defaults.data(forKey: "readingPositions.v1"))
        let reopened = ReadingPositionStore(defaults: defaults)
        XCTAssertEqual(reopened.all()["web:novel"]?.chapterIndex, 4)
        XCTAssertEqual(reopened.epubPosition(hash: "epub")?.fraction, 1)
        XCTAssertEqual(reopened.epubPosition(hash: "epub")?.chapterProgression, 0)
        XCTAssertEqual(reopened.epubPosition(hash: "epub")?.chapterOffset, 70)
        XCTAssertEqual(reopened.txtPosition(hash: "txt"), TXTReadingPosition(chapter: 3, unit: 8, offset: 9, unitCount: 10))
    }

    func testLegacyTXTUsesInjectedPreferences() throws {
        let defaults = preferences()
        let legacy = TXTReadingPosition(chapter: 7, unit: 12, offset: 30, unitCount: 20)
        defaults.set(try JSONEncoder().encode(legacy), forKey: TXTReadingPosition.legacyKey(hash: "legacy"))
        let store = ReadingPositionStore(defaults: defaults)
        XCTAssertEqual(store.txtPosition(hash: "legacy"), legacy)
        store.recordTXT(hash: "legacy", position: TXTReadingPosition(chapter: 8))
        XCTAssertEqual(store.txtPosition(hash: "legacy")?.chapter, 8)
    }

    func testReaderPreferencesAndPositionStoreShareInjectedInstance() {
        let defaults = preferences()
        let positions = ReadingPositionStore(defaults: defaults)
        let settings = ReaderSettings(defaults: defaults, positions: positions)
        settings.recordEPUBPosition(hash: "same", fraction: 0.2, spineIndex: 1, chapterOffset: 3, chapterProgression: 0.4)
        XCTAssertEqual(positions.epubPosition(hash: "same"), settings.epubPosition(hash: "same"))
        let other = ReadingPositionStore(defaults: preferences())
        XCTAssertTrue(other.all().isEmpty, "Different local profiles must not read a global position store")
    }

    func testMergePreservesLegacyWebProgressAndWritesRemoteContinuation() {
        let defaults = preferences()
        let progress = ReadingProgressStore(defaults: defaults)
        let oldDate = Date(timeIntervalSince1970: 10)
        progress.save(chapterIndex: 2, updatedAt: oldDate, novelID: "book")
        let novel = Novel(id: "book", title: "Book", author: "", summary: "", genres: [], chapters: [], accent: .ocean)
        let record = DownloadedWebNovel(novel: novel, fileFilename: "book.epub", downloadedAt: oldDate,
                                       translationSource: nil, downloadMode: nil, fileFormat: .epub)
        let store = ReadingPositionStore(defaults: defaults)
        store.merge([:], webBooks: [record])
        XCTAssertEqual(store.all()["web:book"]?.chapterIndex, 2)
        let remote = SyncedReadingPosition(chapterIndex: 5, fraction: nil, updatedAt: Date(timeIntervalSince1970: 20))
        store.merge(["web:book": remote], webBooks: [record])
        XCTAssertEqual(progress.chapterIndex(novelID: "book"), 5)
        XCTAssertEqual(progress.updatedAt(novelID: "book"), remote.updatedAt)
        store.merge(["web:book": SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: oldDate)], webBooks: [record])
        XCTAssertEqual(progress.chapterIndex(novelID: "book"), 5)
    }

    /// 内存缓存不改变落盘结果：每次记录立即写入，重新打开读到最新值；无变化的合并不改写已保存数据。
    func testCachedPositionsAreWrittenImmediately() throws {
        let defaults = preferences()
        let store = ReadingPositionStore(defaults: defaults)
        for chapter in 0..<5 { store.recordWeb(id: "novel", chapterIndex: chapter) }
        XCTAssertEqual(store.all()["web:novel"]?.chapterIndex, 4)
        XCTAssertEqual(ReadingPositionStore(defaults: defaults).all()["web:novel"]?.chapterIndex, 4)
        let saved = defaults.data(forKey: "readingPositions.v1")
        store.merge([:], webBooks: [])
        XCTAssertEqual(defaults.data(forKey: "readingPositions.v1"), saved)
    }

    /// 打开在线小说只是恢复时不写入，保留原时间戳，同步时不会盖过其他设备较新的进度。
    func testOpeningWebNovelAtRestoredChapterIsNotARecord() {
        let defaults = preferences()
        let positions = ReadingPositionStore(defaults: defaults)
        let settings = ReaderSettings(defaults: defaults, positions: positions)
        XCTAssertTrue(settings.isRestoringWebPosition(id: "novel", chapterIndex: 0), "first chapter of an unread novel")
        XCTAssertFalse(settings.isRestoringWebPosition(id: "novel", chapterIndex: 5), "explicitly chosen chapter is recorded")
        positions.merge(["web:novel": SyncedReadingPosition(chapterIndex: 3, fraction: nil, updatedAt: Date(timeIntervalSince1970: 10))],
                        webBooks: [])
        XCTAssertTrue(settings.isRestoringWebPosition(id: "novel", chapterIndex: 3))
        XCTAssertFalse(settings.isRestoringWebPosition(id: "novel", chapterIndex: 0), "starting over is a real change")
        XCTAssertEqual(positions.all()["web:novel"]?.updatedAt, Date(timeIntervalSince1970: 10))
    }

    /// 只清理书已不在书库、且超过保留期未更新的文件位置；在线小说位置一律保留。
    func testPruneKeepsLibraryBooksRecentAndWebPositions() {
        let store = ReadingPositionStore(defaults: preferences())
        let old = Date(timeIntervalSince1970: 100), recent = Date(timeIntervalSince1970: 10_000)
        func position(_ date: Date) -> SyncedReadingPosition { SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: date) }
        store.merge(["epub:kept": position(old), "txt:gone": position(old), "epub:gone": position(old),
                     "txt:recent": position(recent), "web:novel": position(old)], webBooks: [])
        let removed = store.pruneFilePositions(keepingHashes: ["kept"], olderThan: Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(Set(store.all().keys), ["epub:kept", "txt:recent", "web:novel"])
    }

    func testOrphanedReadiumKeysMatchOnlyBooksOutsideTheLibrary() {
        let keys = ["readium.locator.v1.gone", "readium.locatorTime.v1.gone", "readium.locator.v1.kept",
                    "readium.text.locator.v1.txt|gone|rules", "readium.text.time.v1.txt|gone|rules",
                    "readium.text.locator.v1.txt|kept|rules", "readium.text.locator.v1.unexpected", "readerFontSize"]
        XCTAssertEqual(ReadiumLocatorKeys.bookLocator(hash: "h"), "readium.locator.v1.h", "stored key names are a compatibility contract")
        XCTAssertEqual(ReadiumLocatorKeys.textTime(identity: "txt|h|r"), "readium.text.time.v1.txt|h|r")
        XCTAssertEqual(Set(ReadiumLocatorKeys.orphanedKeys(keys, keepingHashes: ["kept"])),
                       ["readium.locator.v1.gone", "readium.locatorTime.v1.gone",
                        "readium.text.locator.v1.txt|gone|rules", "readium.text.time.v1.txt|gone|rules"])
    }

    func testEqualTimestampRetainsExistingMergeRule() {
        let store = ReadingPositionStore(defaults: preferences())
        let date = Date(timeIntervalSince1970: 20)
        store.merge(["txt:book": SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: date)], webBooks: [])
        store.merge(["txt:book": SyncedReadingPosition(chapterIndex: 2, fraction: nil, updatedAt: date)], webBooks: [])
        XCTAssertEqual(store.all()["txt:book"]?.chapterIndex, 2)
    }
}

extension ReadingPositionStoreTests {
    func testNativeOffsetsAreOptionalAndPreserveLegacyCoordinates() throws {
        let oldJSON = Data("{\"chapterIndex\":2,\"chapterOffset\":10,\"updatedAt\":0}".utf8)
        let old = try JSONDecoder().decode(SyncedReadingPosition.self, from: oldJSON)
        XCTAssertNil(old.nativeChapterOffset)
        XCTAssertNil(old.nativeSourceHash)
        var native = old
        native.nativeChapterOffset = 12
        native.nativeSourceHash = "source-fingerprint"
        let store = ReadingPositionStore(defaults: preferences())
        store.mergePosition(key: "epub:book", position: native)
        let loaded = try XCTUnwrap(store.epubPosition(hash: "book"))
        XCTAssertEqual(loaded.chapterOffset, 10)
        XCTAssertEqual(loaded.nativeChapterOffset, 12)
        XCTAssertEqual(try JSONDecoder().decode(SyncedReadingPosition.self, from: JSONEncoder().encode(loaded)), native)
        store.recordEPUB(hash: "book", fraction: 0.5, spineIndex: 2, chapterOffset: 20, chapterProgression: 0.4)
        XCTAssertNil(store.epubPosition(hash: "book")?.nativeChapterOffset, "其他引擎重新保存后不得沿用旧精确坐标")
    }
}

extension ReadingPositionStoreTests {
    func testUserReadingReplacesFutureTimestampWithBothCoordinatesAtomically() throws {
        let store = ReadingPositionStore(defaults: preferences())
        store.mergePosition(key: "epub:book", position: SyncedReadingPosition(chapterIndex: 0, fraction: 0,
                            updatedAt: Date().addingTimeInterval(3600), chapterOffset: 1))
        let boundary: any ReadingPositionProviding = store
        boundary.recordEPUB(hash: "book", fraction: 0.5, spineIndex: 1, chapterOffset: 20, chapterProgression: 0.5,
                            nativeChapterOffset: 22, nativeSourceHash: "text")
        let saved = try XCTUnwrap(store.epubPosition(hash: "book"))
        XCTAssertEqual(saved.chapterIndex, 1)
        XCTAssertEqual(saved.chapterOffset, 20)
        XCTAssertEqual(saved.nativeChapterOffset, 22)
        XCTAssertEqual(saved.nativeSourceHash, "text")
        XCTAssertLessThan(saved.updatedAt, Date().addingTimeInterval(1))
    }

    func testDirtyPositionKeysTrackLocalMutationsAndRespectTimestampGuard() throws {
        let defaults = preferences()
        let store = ReadingPositionStore(defaults: defaults)
        XCTAssertFalse(store.hasSyncedPositionBaseline)
        XCTAssertTrue(store.dirtyPositionKeys.isEmpty)

        store.recordEPUB(hash: "a", fraction: 0.2, spineIndex: 1, chapterOffset: 10, chapterProgression: 0.1)
        store.recordWeb(id: "syosetu:n1", chapterIndex: 3)
        XCTAssertEqual(store.dirtyPositionKeys, ["epub:a", "web:syosetu:n1"])

        // 模拟同步前快照时间戳；若同步期间 epub:a 又翻页推进了时间，markPositionsSynced 不得清掉 epub:a。
        let syncedAtA = try XCTUnwrap(store.epubPosition(hash: "a")?.updatedAt)
        let syncedAtWeb = try XCTUnwrap(store.all()["web:syosetu:n1"]?.updatedAt)
        let newerA = SyncedReadingPosition(chapterIndex: 2, fraction: 0.4, updatedAt: syncedAtA.addingTimeInterval(5), chapterOffset: 20)
        store.mergePosition(key: "epub:a", position: newerA, replacingEqualTimestamp: false)

        store.markPositionsSynced(["epub:a": syncedAtA, "web:syosetu:n1": syncedAtWeb])
        XCTAssertTrue(store.hasSyncedPositionBaseline)
        XCTAssertEqual(store.dirtyPositionKeys, ["epub:a"], "同步期间被推进的脏键必须保留待下次同步")

        // 新实例重新加载应保留持久化脏键与基线状态。
        let reloaded = ReadingPositionStore(defaults: defaults)
        XCTAssertTrue(reloaded.hasSyncedPositionBaseline)
        XCTAssertEqual(reloaded.dirtyPositionKeys, ["epub:a"])

        // 远端合并进来的新书进度不应被标记为本地脏键。
        let remotePos = SyncedReadingPosition(chapterIndex: 5, fraction: 0.5, updatedAt: Date(), chapterOffset: 99)
        reloaded.merge(["epub:remote": remotePos], webBooks: [])
        XCTAssertEqual(reloaded.dirtyPositionKeys, ["epub:a"])

        // 重置基线后，所有本地进度都会重新进入脏键集合。
        reloaded.resetSyncBaseline()
        XCTAssertFalse(reloaded.hasSyncedPositionBaseline)
        XCTAssertTrue(reloaded.dirtyPositionKeys.isSuperset(of: ["epub:a", "epub:remote", "web:syosetu:n1"]))
    }

    func testIncrementalPositionsToSyncAppliesOnlyDirtyAndNewManifestBooks() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let bookA = LocalWenkuEPUB(id: UUID(), title: "A", filename: "a.epub", addedAt: t1, coverFilename: nil)
        let bookB = LocalWenkuEPUB(id: UUID(), title: "B", filename: "b.epub", addedAt: t1, coverFilename: nil)
        var manifest = WebDAVManifest()
        manifest.wenkuBooks = [
            WebDAVBook(record: bookA, assets: [WebDAVAsset(filename: "a.epub", hash: "hashA", size: 10)]),
            WebDAVBook(record: bookB, assets: [WebDAVAsset(filename: "b.epub", hash: "hashB", size: 10)]),
        ]
        let remote: [String: SyncedReadingPosition] = [
            "epub:hashA": SyncedReadingPosition(chapterIndex: 1, fraction: 0.1, updatedAt: t1),
            "epub:deleted": SyncedReadingPosition(chapterIndex: 9, fraction: 0.9, updatedAt: t1),
        ]
        let local: [String: SyncedReadingPosition] = [
            "epub:hashA": SyncedReadingPosition(chapterIndex: 2, fraction: 0.3, updatedAt: t2),
            "epub:hashB": SyncedReadingPosition(chapterIndex: 4, fraction: 0.5, updatedAt: t2),
        ]

        // 已建立基线且仅 hashA 为脏键：保留 hashA 更新、补齐远端缺失的新书 hashB、裁剪已删的 deleted。
        let incremental = WebDAVSyncPlanner.positionsToSyncIncremental(
            local: local, dirtyKeys: ["epub:hashA"], hasSyncedBaseline: true, remote: remote, in: manifest
        )
        XCTAssertEqual(incremental["epub:hashA"]?.chapterIndex, 2)
        XCTAssertEqual(incremental["epub:hashB"]?.chapterIndex, 4)
        XCTAssertNil(incremental["epub:deleted"])
    }
}
