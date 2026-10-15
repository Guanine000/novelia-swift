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

    func testEqualTimestampRetainsExistingMergeRule() {
        let store = ReadingPositionStore(defaults: preferences())
        let date = Date(timeIntervalSince1970: 20)
        store.merge(["txt:book": SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: date)], webBooks: [])
        store.merge(["txt:book": SyncedReadingPosition(chapterIndex: 2, fraction: nil, updatedAt: date)], webBooks: [])
        XCTAssertEqual(store.all()["txt:book"]?.chapterIndex, 2)
    }
}
