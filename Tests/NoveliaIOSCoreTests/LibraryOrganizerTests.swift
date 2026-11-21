import Foundation
import XCTest
@testable import NoveliaIOSCore

/// 书库统一搜索、三种排序与系列合并规则。
final class LibraryOrganizerTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private lazy var books: [LibrarySortItem] = [
        LibrarySortItem(key: "a", title: "第10卷", author: "甲", importedAt: date(100), lastReadAt: date(500)),
        LibrarySortItem(key: "b", title: "第2卷", author: "乙", importedAt: date(300), lastReadAt: nil),
        LibrarySortItem(key: "c", title: "Abc", author: "丙", importedAt: date(200), lastReadAt: date(900)),
        LibrarySortItem(key: "d", title: "未读旧书", author: "丁", importedAt: date(50), lastReadAt: nil),
    ]

    private func keys(_ options: LibrarySortOptions) -> [String] {
        LibraryOrganizer.sorted(books, options: options) { $0 }.map(\.key)
    }

    func testSourceFilterIncludesOnlySelectedCategory() {
        XCTAssertTrue(LibrarySourceFilter.all.includes(isWenku: true))
        XCTAssertTrue(LibrarySourceFilter.all.includes(isWenku: false))
        XCTAssertTrue(LibrarySourceFilter.wenku.includes(isWenku: true))
        XCTAssertFalse(LibrarySourceFilter.wenku.includes(isWenku: false))
        XCTAssertTrue(LibrarySourceFilter.webNovel.includes(isWenku: false))
        XCTAssertFalse(LibrarySourceFilter.webNovel.includes(isWenku: true))
    }

    func testDuplicateIdentifiersKeepNewestRecordWithoutMergingSameTitles() {
        let records = [
            LibrarySortItem(key: "a", title: "同名书", author: "甲", importedAt: date(100), lastReadAt: nil),
            LibrarySortItem(key: "b", title: "同名书", author: "甲", importedAt: date(200), lastReadAt: nil),
            LibrarySortItem(key: "a", title: "新版", author: "甲", importedAt: date(300), lastReadAt: nil),
            LibrarySortItem(key: "a", title: "同时间旧记录", author: "甲", importedAt: date(300), lastReadAt: nil),
        ]
        let unique = LibraryOrganizer.uniqueRecords(records, id: { $0.key }, date: { $0.importedAt })
        XCTAssertEqual(unique.map(\.key), ["a", "b"])
        XCTAssertEqual(unique.map(\.title), ["新版", "同名书"])
        XCTAssertTrue(LibraryOrganizer.uniqueRecords([LibrarySortItem](), id: { $0.key }, date: { $0.importedAt }).isEmpty)
    }

    func testSearchMatchesTitleOrAuthor() {
        XCTAssertTrue(LibraryOrganizer.matches(title: "无职转生", author: "理不尽な孫の手", query: "转生"))
        XCTAssertTrue(LibraryOrganizer.matches(title: "无职转生", author: "理不尽な孫の手", query: "孫の手"))
        XCTAssertTrue(LibraryOrganizer.matches(title: "Re:Zero", author: "長月達平", query: " re:ZERO "), "case and whitespace")
        XCTAssertTrue(LibraryOrganizer.matches(title: "ＡＢＣ", author: "", query: "abc"), "full-width folds")
        XCTAssertTrue(LibraryOrganizer.matches(title: "任意", author: "", query: "   "), "empty query matches")
        XCTAssertTrue(LibraryOrganizer.matches(title: "Zeta 物语", author: "", query: "ze ta"), "IME-segmented Latin")
        XCTAssertTrue(LibraryOrganizer.matches(title: "Spaced   Title", author: "", query: "spacedtitle"))
        XCTAssertFalse(LibraryOrganizer.matches(title: "无职转生", author: "理不尽な孫の手", query: "魔法"))
    }

    func testImportTimeSort() {
        XCTAssertEqual(keys(.init(field: .importedAt, ascending: false)), ["b", "c", "a", "d"])
        XCTAssertEqual(keys(.init(field: .importedAt, ascending: true)), ["d", "a", "c", "b"])
    }

    func testRecentReadingUsesImportTimeForUnreadBooks() {
        XCTAssertEqual(keys(.init(field: .lastRead, ascending: false)), ["c", "a", "b", "d"])
        XCTAssertEqual(keys(.init(field: .lastRead, ascending: true)), ["d", "b", "a", "c"])
    }

    func testNewImportAppearsBeforePreviouslyReadBooksWithoutMarkingItRead() {
        let imported = LibrarySortItem(key: "new", title: "新导入", author: "", importedAt: date(1000), lastReadAt: nil)
        let items = books + [imported]
        let sorted = LibraryOrganizer.sorted(items, options: .init(field: .lastRead, ascending: false)) { $0 }
        XCTAssertEqual(sorted.map(\.key), ["new", "c", "a", "b", "d"])
        XCTAssertNil(sorted.first?.lastReadAt)

        var resumed = books[0]
        resumed.lastReadAt = date(1100)
        let afterReading = LibraryOrganizer.sorted([resumed] + items.filter { $0.key != resumed.key },
                                                   options: .init(field: .lastRead, ascending: false)) { $0 }
        XCTAssertEqual(afterReading.map(\.key), ["a", "new", "c", "b", "d"])
    }

    func testTitleSortIsNumericAndReversible() {
        let ascending = keys(.init(field: .title, ascending: true))
        XCTAssertLessThan(ascending.firstIndex(of: "b")!, ascending.firstIndex(of: "a")!, "第2卷 before 第10卷")
        XCTAssertEqual(keys(.init(field: .title, ascending: false)), Array(ascending.reversed()))
    }

    func testSeriesAssignAndRemoveKeepsOtherBooks() {
        var state = LibrarySeriesState()
        let series = state.createSeries(named: "  无职  ", now: date(1), id: "s1")
        XCTAssertEqual(series.name, "无职")
        state.assign(book: "wenku:1", to: "s1", now: date(2))
        state.assign(book: "web:x", to: "s1", now: date(2))
        XCTAssertEqual(state.bookKeys(inSeries: "s1"), ["wenku:1", "web:x"])
        state.assign(book: "wenku:1", to: nil, now: date(3))
        XCTAssertNil(state.seriesID(forBook: "wenku:1"))
        XCTAssertEqual(state.bookKeys(inSeries: "s1"), ["web:x"])
        state.assign(book: "web:y", to: "missing", now: date(4))
        XCTAssertNil(state.seriesID(forBook: "web:y"), "unknown series ignored")
    }

    func testDeleteSeriesReleasesBooksAndTransferFollowsMove() {
        var state = LibrarySeriesState()
        state.createSeries(named: "A", now: date(1), id: "s1")
        state.assign(book: "web:x", to: "s1", now: date(2))
        state.transfer(from: "web:x", to: "wenku:9", now: date(3))
        XCTAssertNil(state.seriesID(forBook: "web:x"))
        XCTAssertEqual(state.seriesID(forBook: "wenku:9"), "s1")
        state.deleteSeries("s1", now: date(4))
        XCTAssertTrue(state.activeSeries.isEmpty)
        XCTAssertNil(state.seriesID(forBook: "wenku:9"))
        state.assign(book: "wenku:9", to: "s1", now: date(5))
        XCTAssertNil(state.seriesID(forBook: "wenku:9"), "cannot join a deleted series")
    }

    func testMergeKeepsNewerPerSeriesAndPerBook() {
        var local = LibrarySeriesState()
        local.createSeries(named: "本地", now: date(1), id: "s1")
        local.assign(book: "web:a", to: "s1", now: date(5))
        var remote = local
        remote.renameSeries("s1", to: "远端改名", now: date(3))
        remote.createSeries(named: "远端新建", now: date(4), id: "s2")
        remote.assign(book: "web:a", to: nil, now: date(4))
        remote.assign(book: "web:b", to: "s2", now: date(6))

        let merged = LibrarySeriesState.merged(local, remote)
        XCTAssertEqual(merged.series["s1"]?.name, "远端改名")
        XCTAssertEqual(merged.activeSeries.map(\.id).sorted(), ["s1", "s2"])
        XCTAssertEqual(merged.seriesID(forBook: "web:a"), "s1", "local membership is newer")
        XCTAssertEqual(merged.seriesID(forBook: "web:b"), "s2")

        var deletedRemotely = merged
        deletedRemotely.deleteSeries("s2", now: date(9))
        let afterDelete = LibrarySeriesState.merged(merged, deletedRemotely)
        XCTAssertEqual(afterDelete.activeSeries.map(\.id), ["s1"], "deletion propagates")
        XCTAssertNil(afterDelete.seriesID(forBook: "web:b"))

        let roundTrip = try! JSONDecoder().decode(LibrarySeriesState.self, from: JSONEncoder().encode(afterDelete))
        XCTAssertEqual(roundTrip, afterDelete)
    }

    func testShelfUpdateSummaryDiffDetectsNewChaptersAndRejectsMismatchedNovel() {
        let localChapters = [
            NovelChapter(id: "c1", title: "第一章", originalText: "", translatedText: ""),
            NovelChapter(id: "c2", title: "第二章", originalText: "", translatedText: ""),
        ]
        let localNovel = Novel(
            id: "syosetu:n1234",
            title: "测试网文",
            author: "作者",
            summary: "",
            genres: [],
            chapters: localChapters,
            accent: .plum,
            providerId: "syosetu",
            novelId: "n1234"
        )
        let downloaded = DownloadedWebNovel(
            novel: localNovel,
            fileFilename: "n1234.epub",
            downloadedAt: Date(timeIntervalSince1970: 1000),
            translationSource: nil,
            downloadMode: nil,
            fileFormat: nil
        )

        // 章节一致时无更新
        XCTAssertNil(ShelfUpdateSummary.diff(local: downloaded, remote: localNovel))

        // 远端新增两章时返回增量数与最新章节名
        let remoteChapters = localChapters + [
            NovelChapter(id: "c3", title: "第三章", originalText: "", translatedText: ""),
            NovelChapter(id: "c4", title: "第四章 终幕", originalText: "", translatedText: ""),
        ]
        let remoteUpdated = Novel(
            id: "syosetu:n1234", title: "测试网文", author: "作者", summary: "", genres: [],
            chapters: remoteChapters, accent: .plum, providerId: "syosetu", novelId: "n1234"
        )
        let diff = ShelfUpdateSummary.diff(local: downloaded, remote: remoteUpdated)
        XCTAssertEqual(diff?.bookID, "syosetu:n1234")
        XCTAssertEqual(diff?.newChapterCount, 2)
        XCTAssertEqual(diff?.latestChapterTitle, "第四章 终幕")

        // providerId / novelId 不匹配时忽略
        let mismatched = Novel(
            id: "syosetu:other", title: "测试网文", author: "作者", summary: "", genres: [],
            chapters: remoteChapters, accent: .plum, providerId: "syosetu", novelId: "other"
        )
        XCTAssertNil(ShelfUpdateSummary.diff(local: downloaded, remote: mismatched))
    }

    func testReadingStatusStateDefaultsAndMergesByLatestTimestamp() {
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)

        var local = LibraryBookStatusState()
        // 未显式设置的书默认归入「在读」
        XCTAssertEqual(local.status(forBook: "wenku:a"), .reading)

        local.setStatus(.completed, forBook: "wenku:a", now: t1)
        local.setStatus(.onHold, forBook: "web:b", now: t2)
        XCTAssertEqual(local.status(forBook: "wenku:a"), .completed)
        XCTAssertEqual(local.status(forBook: "web:b"), .onHold)

        var remote = LibraryBookStatusState()
        // 远端把 wenku:a 切回默认的「在读」且时间更新，合并后应覆盖本地的「读过」
        remote.setStatus(.reading, forBook: "wenku:a", now: t3)
        // 远端对 web:b 的状态较旧，合并后保留本地的「搁置」
        remote.setStatus(.dropped, forBook: "web:b", now: t1)
        remote.setStatus(.wantToRead, forBook: "wenku:c", now: t2)

        let merged = LibraryBookStatusState.merged(local, remote)
        XCTAssertEqual(merged.status(forBook: "wenku:a"), .reading)
        XCTAssertEqual(merged.status(forBook: "web:b"), .onHold)
        XCTAssertEqual(merged.status(forBook: "wenku:c"), .wantToRead)

        // 移动书籍键时同步转移状态
        var moved = merged
        moved.transfer(from: "wenku:c", to: "web:c", now: t3)
        XCTAssertEqual(moved.status(forBook: "web:c"), .wantToRead)
        XCTAssertNil(moved.statuses["wenku:c"])
    }
}
