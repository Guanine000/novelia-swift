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

    func testAutoStatusClassifierTransitionsAndBatchReorganize() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let recent = Date(timeIntervalSince1970: 95 * 86_400)
        let stale = Date(timeIntervalSince1970: 50 * 86_400)

        // 打开书籍：未设置、想读、搁置转为在读；读过与抛弃保持不变
        XCTAssertEqual(LibraryBookStatusAutoClassifier.transitionOnOpen(current: nil), .reading)
        XCTAssertEqual(LibraryBookStatusAutoClassifier.transitionOnOpen(current: .wantToRead), .reading)
        XCTAssertEqual(LibraryBookStatusAutoClassifier.transitionOnOpen(current: .onHold), .reading)
        XCTAssertNil(LibraryBookStatusAutoClassifier.transitionOnOpen(current: .reading))
        XCTAssertNil(LibraryBookStatusAutoClassifier.transitionOnOpen(current: .completed))
        XCTAssertNil(LibraryBookStatusAutoClassifier.transitionOnOpen(current: .dropped))

        // 进度推进：98% 以上或末章自动读过；抛弃永不覆盖
        XCTAssertTrue(LibraryBookStatusAutoClassifier.isCompleted(fraction: 0.98, isAtLastChapter: false))
        XCTAssertFalse(LibraryBookStatusAutoClassifier.isCompleted(fraction: 0.97, isAtLastChapter: false))
        XCTAssertTrue(LibraryBookStatusAutoClassifier.isCompleted(fraction: nil, isAtLastChapter: true))
        XCTAssertEqual(
            LibraryBookStatusAutoClassifier.transitionOnProgress(current: .reading, isCompleted: true, hasProgress: true),
            .completed
        )
        XCTAssertNil(
            LibraryBookStatusAutoClassifier.transitionOnProgress(current: .dropped, isCompleted: true, hasProgress: true),
            "手动抛弃的书不应被进度自动覆盖"
        )
        XCTAssertEqual(
            LibraryBookStatusAutoClassifier.transitionOnProgress(current: .wantToRead, isCompleted: false, hasProgress: true),
            .reading
        )

        // 新书无进度归入想读
        XCTAssertEqual(
            LibraryBookStatusAutoClassifier.transitionOnNewBook(current: nil, hasProgress: false, lastReadAt: nil),
            .wantToRead
        )
        XCTAssertNil(
            LibraryBookStatusAutoClassifier.transitionOnNewBook(current: .reading, hasProgress: false, lastReadAt: nil)
        )

        // 自动搁置：超过 30 天未读转为搁置；若刚手动改回在读（updatedAt 较新），则不立即搁置
        let staleReading = LibraryBookStatusEntry(status: .reading, updatedAt: stale)
        XCTAssertEqual(
            LibraryBookStatusAutoClassifier.autoOnHoldTransition(entry: staleReading, lastReadAt: stale, now: now, onHoldDays: 30),
            .onHold
        )
        let recentlyManuallySetReading = LibraryBookStatusEntry(status: .reading, updatedAt: recent)
        XCTAssertNil(
            LibraryBookStatusAutoClassifier.autoOnHoldTransition(entry: recentlyManuallySetReading, lastReadAt: stale, now: now, onHoldDays: 30)
        )
        XCTAssertNil(
            LibraryBookStatusAutoClassifier.autoOnHoldTransition(entry: staleReading, lastReadAt: stale, now: now, onHoldDays: 0)
        )

        // 存量一键整理：保留手动抛弃，其余按进度归类
        var existing = LibraryBookStatusState()
        existing.setStatus(.dropped, forBook: "dropped", now: recent)
        existing.setStatus(.reading, forBook: "done", now: recent)
        let snapshots: [LibraryBookStatusAutoClassifier.BookProgressSnapshot] = [
            .init(key: "unread", fraction: nil, hasProgress: false, isAtLastChapter: false, lastReadAt: nil),
            .init(key: "active", fraction: 0.35, hasProgress: true, isAtLastChapter: false, lastReadAt: recent),
            .init(key: "done", fraction: 0.99, hasProgress: true, isAtLastChapter: false, lastReadAt: recent),
            .init(key: "stale", fraction: 0.2, hasProgress: true, isAtLastChapter: false, lastReadAt: stale),
            .init(key: "dropped", fraction: 1.0, hasProgress: true, isAtLastChapter: true, lastReadAt: recent),
        ]
        let changes = LibraryBookStatusAutoClassifier.batchReorganizeChanges(
            snapshots: snapshots,
            existing: existing,
            now: now,
            config: LibraryAutoStatusConfig(enabled: true, completionThreshold: 0.98, onHoldDays: 30)
        )
        XCTAssertEqual(changes["unread"], .wantToRead)
        XCTAssertNil(changes["active"], "已在读且活跃的书无需变更")
        XCTAssertEqual(changes["done"], .completed)
        XCTAssertEqual(changes["stale"], .onHold)
        XCTAssertNil(changes["dropped"], "手动抛弃的书不参与一键整理覆盖")
    }

    func testGlobalSearchMatchesAnnotationsAndBookmarksAcrossBooks() {
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let books = ["epub:a": "冰菓", "txt:b": "三日间的幸福"]

        let a1 = ReaderAnnotation(
            id: UUID(), bookKey: "epub:a", chapterIndex: 2,
            startUTF16: 0, endUTF16: 10, quote: "我很好奇！", prefix: "", suffix: "",
            projectionIdentity: "", color: .green, note: "经典台词", createdAt: t1, updatedAt: t1
        )
        let a2 = ReaderAnnotation(
            id: UUID(), bookKey: "txt:b", chapterIndex: 5,
            startUTF16: 0, endUTF16: 12, quote: "一年的寿命价值一万元", prefix: "", suffix: "",
            projectionIdentity: "", color: .yellow, note: "很好奇结局", createdAt: t2, updatedAt: t2
        )
        var deleted = a1
        deleted.deleted = true

        let annHits = LibraryGlobalSearch.searchAnnotations(
            query: "好奇",
            annotations: [a1, a2, deleted],
            bookTitlesByKey: books
        )
        XCTAssertEqual(annHits.map(\.bookTitle), ["三日间的幸福", "冰菓"], "按最近更新时间倒序并排除已删除")
        XCTAssertEqual(annHits.count, 2)

        let b1 = ReaderBookmark(
            id: UUID(), bookKey: "epub:a", chapterIndex: 0, chapterProgression: 0.2,
            chapterTitle: "古籍研究社的复苏", snippet: "折木奉太郎推开门", createdAt: t1, updatedAt: t1
        )
        let b2 = ReaderBookmark(
            id: UUID(), bookKey: "unknown:x", chapterIndex: 0, chapterProgression: 0.5,
            chapterTitle: "古籍", snippet: "已删除书的残留书签", createdAt: t2, updatedAt: t2
        )
        let bmHits = LibraryGlobalSearch.searchBookmarks(
            query: "古籍",
            bookmarks: [b1, b2],
            bookTitlesByKey: books
        )
        XCTAssertEqual(bmHits.count, 1, "未在当前书库映射中的书签不返回")
        XCTAssertEqual(bmHits[0].bookTitle, "冰菓")
    }
}
