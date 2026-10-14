import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
private final class StubLibrary<Record: SyncableBook>: SyncBookLibrary {
    var books: [Record] = []
    func syncFiles(for book: Record) -> [String: URL] { [:] }
    func restoreFromSync(_ book: Record, files: [String: URL]) throws {}
    func replaceFromSync(_ book: Record, files: [String: URL]) throws {}
    func removeFromSync(_ book: Record) {}
}

/// 只提供指纹会读取的状态；背景与字体不参与指纹，访问即视为错误。
@MainActor
private final class StubLocalState: WebDAVSyncLocalState {
    var readingPositions: [String: SyncedReadingPosition] = [:]
    var librarySeries = LibrarySeriesState()
    var blockedTags: [String: SyncedBlockedTag] = [:]

    func mergeReadingPositions(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {}
    func applyLibrarySeries(_ series: LibrarySeriesState) {}
    func applyBlockedTags(_ tags: [String: SyncedBlockedTag]) {}
    func background(dark: Bool) throws -> SyncedReaderBackground {
        XCTFail("fingerprint must not read backgrounds")
        throw CocoaError(.fileReadUnknown)
    }
    func backgroundImageURL(dark: Bool, landscape: Bool) -> URL { URL(fileURLWithPath: "/dev/null") }
    func isValidBackgroundImage(_ file: URL) -> Bool { false }
    func applyBackground(_ value: SyncedReaderBackground, dark: Bool, files: [String: URL]) throws {}
    func fonts() throws -> [String: SyncedImportedFont] {
        XCTFail("fingerprint must not hash fonts")
        return [:]
    }
    func fontFiles() throws -> [String: URL] { [:] }
    func applyFonts(_ records: [String: SyncedImportedFont], files: [String: URL]) throws {}
}

/// 自动同步的触发判断：前台过期拉取、背景/改动只推送脏状态、失败退避与网络恢复。
@MainActor
final class WebDAVAutoSyncPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    /// 未指定 `attempt` 时视为上次尝试即上次成功。
    private func state(success: TimeInterval? = 120, attempt: TimeInterval? = nil, failures: Int = 0,
                       fingerprint: String? = "clean") -> WebDAVAutoSyncPart {
        WebDAVAutoSyncPart(lastAttempt: (attempt ?? success).map(ago), lastSuccess: success.map(ago),
                           syncedFingerprint: fingerprint, failures: failures)
    }

    private func should(_ trigger: WebDAVAutoSyncTrigger, _ part: WebDAVAutoSyncPart,
                        fingerprint: String = "clean") -> Bool {
        WebDAVAutoSyncPolicy.shouldSync(trigger, part: part, fingerprint: fingerprint, now: now)
    }

    // MARK: 触发规则

    func testForegroundSyncsWhenNeverSyncedStaleOrDirty() {
        XCTAssertTrue(should(.foreground, WebDAVAutoSyncPart()))
        XCTAssertFalse(should(.foreground, state(success: 60)), "recent clean sync is skipped")
        XCTAssertTrue(should(.foreground, state(success: WebDAVAutoSyncPolicy.staleInterval)))
        XCTAssertTrue(should(.foreground, state(success: 60), fingerprint: "changed"))
    }

    func testBackgroundAndLocalChangeOnlyPushDirtyState() {
        for trigger in [WebDAVAutoSyncTrigger.background, .localChange] {
            XCTAssertFalse(should(trigger, state(success: 3600)), "clean state is not pushed even when stale")
            XCTAssertTrue(should(trigger, state(), fingerprint: "changed"))
        }
    }

    func testFailuresBackOffWithGrowingDelays() {
        let failedOnce = state(success: 3600, attempt: 30, failures: 1)
        XCTAssertFalse(should(.foreground, failedOnce))
        XCTAssertFalse(should(.background, failedOnce, fingerprint: "changed"))
        XCTAssertTrue(should(.foreground, state(success: 3600, attempt: 61, failures: 1)))
        XCTAssertFalse(should(.foreground, state(success: 3600, attempt: 4 * 60, failures: 2)))
        XCTAssertTrue(should(.foreground, state(success: 3600, attempt: 5 * 60, failures: 2)))
        // 超出表长沿用最后一项（30 分钟）。
        XCTAssertFalse(should(.foreground, state(success: 7200, attempt: 29 * 60, failures: 9)))
        XCTAssertTrue(should(.foreground, state(success: 7200, attempt: 30 * 60, failures: 9)))
    }

    func testNetworkRestoredIgnoresBackoffButNeedsWork() {
        XCTAssertTrue(should(.networkRestored, state(attempt: 90, failures: 3)))
        XCTAssertTrue(should(.networkRestored, state(), fingerprint: "changed"))
        XCTAssertFalse(should(.networkRestored, state(success: 3600)), "nothing pending")
    }

    /// 频繁切换前后台时，距上次尝试不到 1 分钟的任何触发都跳过，改动留到之后的触发。
    func testMinimumIntervalAppliesToEveryTrigger() {
        let recent = state(success: 3600, attempt: 30, fingerprint: "old")
        for trigger in [WebDAVAutoSyncTrigger.foreground, .background, .localChange, .networkRestored] {
            XCTAssertFalse(should(trigger, recent, fingerprint: "changed"), "\(trigger)")
        }
        XCTAssertTrue(should(.background, state(success: 3600, attempt: 60, fingerprint: "old"), fingerprint: "changed"))
    }

    func testStateRoundTripsAndMissingFieldsDecodeAsDefaults() throws {
        let value = WebDAVAutoSyncState(content: state(failures: 2), statistics: state(fingerprint: "stats"))
        XCTAssertEqual(try JSONDecoder().decode(WebDAVAutoSyncState.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(try JSONDecoder().decode(WebDAVAutoSyncState.self, from: Data("{}".utf8)), WebDAVAutoSyncState())
        XCTAssertEqual(try JSONDecoder().decode(WebDAVAutoSyncState.self, from: Data(#"{"content":{}}"#.utf8)),
                       WebDAVAutoSyncState())
    }

    /// 内容与阅读时长分别退避：统计因服务器不支持 ETag 持续失败时，书籍仍按正常节奏同步。
    func testContentAndStatisticsBackOffIndependently() {
        let value = WebDAVAutoSyncState(content: state(success: 3600, attempt: 3600),
                                        statistics: state(success: 7200, attempt: 30, failures: 5))
        XCTAssertTrue(should(.foreground, value.content))
        XCTAssertFalse(should(.foreground, value.statistics))
        XCTAssertFalse(should(.background, value.statistics, fingerprint: "read more"))
    }

    func testStatisticsFingerprintChangesWithReadingTime() {
        var snapshot = ReadingStatisticsSync()
        let empty = WebDAVAutoSyncPolicy.fingerprint(statistics: snapshot)
        XCTAssertEqual(WebDAVAutoSyncPolicy.fingerprint(statistics: snapshot), empty)
        snapshot.devices["device"] = ReadingStatistics()
        XCTAssertNotEqual(WebDAVAutoSyncPolicy.fingerprint(statistics: snapshot), empty)
    }

    // MARK: 指纹

    func testFingerprintTracksSyncedStateAndOptions() {
        let local = StubLocalState()
        let web = StubLibrary<DownloadedWebNovel>()
        let wenku = StubLibrary<LocalWenkuEPUB>()
        let all = WebDAVSyncOptions(books: true, tags: true, backgrounds: true, fonts: true)
        func fp(_ options: WebDAVSyncOptions = all) -> String {
            WebDAVAutoSyncPolicy.fingerprint(local: local, web: web, wenku: wenku, options: options)
        }

        let base = fp()
        XCTAssertEqual(fp(), base, "fingerprint is deterministic")

        local.readingPositions["web:a"] = SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: now)
        let withPosition = fp()
        XCTAssertNotEqual(withPosition, base)
        local.readingPositions["web:a"]?.chapterIndex = 2
        XCTAssertNotEqual(fp(), withPosition, "a page turn makes the state dirty")

        let beforeBook = fp()
        wenku.books.append(LocalWenkuEPUB(id: UUID(), title: "文库", filename: "a.epub", addedAt: now))
        XCTAssertNotEqual(fp(), beforeBook)

        let beforeTag = fp()
        local.blockedTags["标签"] = SyncedBlockedTag(blocked: true, updatedAt: now)
        XCTAssertNotEqual(fp(), beforeTag)

        // 关闭的同步项不参与指纹。
        let tagsOnly = WebDAVSyncOptions(books: false, tags: true, backgrounds: false, fonts: false)
        let tagsPrint = fp(tagsOnly)
        local.readingPositions["web:a"]?.chapterIndex = 3
        XCTAssertEqual(fp(tagsOnly), tagsPrint)
        XCTAssertNotEqual(fp(all), fp(tagsOnly), "changing options changes the fingerprint")
    }

    func testFingerprintIgnoresDictionaryInsertionOrder() {
        let first = StubLocalState(), second = StubLocalState()
        let web = StubLibrary<DownloadedWebNovel>(), wenku = StubLibrary<LocalWenkuEPUB>()
        let keys = (0..<50).map { "txt:\($0)" }
        for key in keys { first.readingPositions[key] = SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: now) }
        for key in keys.reversed() { second.readingPositions[key] = SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: now) }
        let options = WebDAVSyncOptions(books: true, tags: true, backgrounds: false, fonts: false)
        XCTAssertEqual(WebDAVAutoSyncPolicy.fingerprint(local: first, web: web, wenku: wenku, options: options),
                       WebDAVAutoSyncPolicy.fingerprint(local: second, web: web, wenku: wenku, options: options))
    }
}
