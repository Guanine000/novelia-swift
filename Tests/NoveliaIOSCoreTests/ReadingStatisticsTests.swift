import Foundation
import XCTest
@testable import NoveliaIOSCore

final class ReadingStatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private func date(_ day: Int = 13, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func book(_ kind: ReadingKind, id: String? = nil) -> ReadingBook {
        ReadingBook(id: id ?? kind.rawValue, title: "同名书", kind: kind)
    }

    func testTypesAndBooksStaySeparateAndReadingDayUsesCombinedMinute() {
        var stats = ReadingStatistics()
        for kind in ReadingKind.allCases {
            stats.record(book: book(kind), from: date(), to: date().addingTimeInterval(20), duration: 20, calendar: calendar)
        }
        XCTAssertEqual(stats.seconds(), 60)
        XCTAssertEqual(stats.readingDays, 1)
        XCTAssertEqual(stats.books.count, 3)
        for kind in ReadingKind.allCases { XCTAssertEqual(stats.seconds(kind: kind), 20) }
    }

    func testSubMinuteDoesNotCountAsReadingDay() {
        var stats = ReadingStatistics()
        stats.record(book: book(.txt), from: date(), to: date().addingTimeInterval(59), duration: 59, calendar: calendar)
        XCTAssertEqual(stats.readingDays, 0)
    }

    func testCrossMidnightSplitsTimeAndPreservesTotal() {
        var stats = ReadingStatistics()
        let start = date(hour: 23, minute: 59)
        stats.record(book: book(.epub), from: start, to: start.addingTimeInterval(180), duration: 180, calendar: calendar)
        XCTAssertEqual(stats.seconds(days: ["2026-10-13"]), 60)
        XCTAssertEqual(stats.seconds(days: ["2026-10-14"]), 120)
        XCTAssertEqual(stats.readingDays, 2)
        XCTAssertEqual(stats.seconds(), 180)
    }

    func testSystemClockChangeUsesMonotonicDuration() {
        var stats = ReadingStatistics()
        stats.record(book: book(.online), from: date(), to: date().addingTimeInterval(-3600), duration: 30, calendar: calendar)
        stats.record(book: book(.online), from: date(), to: date(20), duration: 30, calendar: calendar)
        XCTAssertEqual(stats.seconds(), 60)
        XCTAssertEqual(stats.books["online"]?.days.count, 2)
    }

    func testInvalidDurationsAreIgnored() {
        var stats = ReadingStatistics()
        for duration in [-1.0, 0, Double.nan, Double.infinity] {
            stats.record(book: book(.epub), from: date(), to: date(), duration: duration, calendar: calendar)
        }
        XCTAssertTrue(stats.books.isEmpty)
    }

    func testPauseResumeExcludesBackgroundAndCheckpointsDoNotDoubleCount() {
        let id = UUID()
        var tracker = ReadingTimeTracker()
        tracker.begin(id: id, book: book(.txt), date: date(), uptime: 100, calendar: calendar)
        tracker.begin(id: id, book: book(.txt), date: date().addingTimeInterval(5), uptime: 105, calendar: calendar)
        tracker.checkpoint(id: id, date: date().addingTimeInterval(15), uptime: 115, calendar: calendar)
        tracker.end(id: id, date: date().addingTimeInterval(30), uptime: 130, calendar: calendar)
        tracker.checkpoint(id: id, date: date().addingTimeInterval(100), uptime: 200, calendar: calendar)
        tracker.begin(id: id, book: book(.txt), date: date().addingTimeInterval(100), uptime: 200, calendar: calendar)
        tracker.end(id: id, date: date().addingTimeInterval(120), uptime: 220, calendar: calendar)
        XCTAssertEqual(tracker.statistics.seconds(), 50)
    }

    func testReaderSwitchAndStaleCallbacksNeverOverlap() {
        let first = UUID(), second = UUID()
        var tracker = ReadingTimeTracker()
        tracker.begin(id: first, book: book(.online), date: date(), uptime: 0, calendar: calendar)
        tracker.begin(id: second, book: book(.epub), date: date().addingTimeInterval(20), uptime: 20, calendar: calendar)
        tracker.end(id: first, date: date().addingTimeInterval(25), uptime: 25, calendar: calendar)
        tracker.end(id: second, date: date().addingTimeInterval(50), uptime: 50, calendar: calendar)
        XCTAssertEqual(tracker.statistics.seconds(kind: .online), 20)
        XCTAssertEqual(tracker.statistics.seconds(kind: .epub), 30)
        XCTAssertEqual(tracker.statistics.seconds(), 50)
    }

    func testBookAccumulatesAcrossSessionsAndUpdatesTitleAndLastRead() {
        var stats = ReadingStatistics()
        stats.record(book: book(.epub), from: date(), to: date().addingTimeInterval(60), duration: 60, calendar: calendar)
        let renamed = ReadingBook(id: "epub", title: "新书名", kind: .epub)
        stats.record(book: renamed, from: date(14), to: date(14).addingTimeInterval(120), duration: 120, calendar: calendar)
        XCTAssertEqual(stats.books.count, 1)
        XCTAssertEqual(stats.books["epub"]?.seconds, 180)
        XCTAssertEqual(stats.books["epub"]?.book.title, "新书名")
        XCTAssertEqual(stats.books["epub"]?.lastReadAt, date(14).addingTimeInterval(120))
    }

    func testPersistenceRoundTripKeepsDailyAndBookRecords() throws {
        var stats = ReadingStatistics()
        stats.record(book: book(.epub), from: date(), to: date().addingTimeInterval(70), duration: 70, calendar: calendar)
        let restored = try JSONDecoder().decode(ReadingStatistics.self, from: JSONEncoder().encode(stats))
        XCTAssertEqual(restored, stats)
        XCTAssertEqual(restored.readingDays, 1)
    }

    func testWeekSelectionExcludesOtherDays() {
        var stats = ReadingStatistics()
        for day in [1, 12, 13, 18, 19] {
            stats.record(book: book(.txt), from: date(day), to: date(day).addingTimeInterval(60), duration: 60, calendar: calendar)
        }
        let keys = Set((12...18).map { ReadingStatistics.dayKey(date($0), calendar: calendar) })
        XCTAssertEqual(stats.seconds(days: keys), 180)
        XCTAssertEqual(stats.seconds(), 300)
    }
}

extension ReadingStatisticsTests {
    private func snapshot(_ seconds: TimeInterval, device: String, bookID: String = "same") -> ReadingStatisticsSync {
        var stats = ReadingStatistics()
        let date = Date(timeIntervalSince1970: 1_000_000)
        stats.record(book: ReadingBook(id: bookID, title: "书", kind: .txt), from: date,
                     to: date.addingTimeInterval(seconds), duration: seconds)
        return ReadingStatisticsSync(devices: [device: stats])
    }

    func testSyncIsIdempotentAndSumsDifferentDevices() {
        let a = snapshot(30, device: "a"), b = snapshot(40, device: "b")
        let merged = ReadingStatisticsSync.merged(a, b)
        XCTAssertEqual(merged.statistics.seconds(), 70)
        XCTAssertEqual(ReadingStatisticsSync.merged(merged, b), merged)
        XCTAssertEqual(ReadingStatisticsSync.merged(a, merged), merged)
        XCTAssertEqual(merged.statistics.books["same"]?.seconds, 70)
        XCTAssertEqual(merged.statistics.readingDays, 1)
    }

    func testStaleDeviceSnapshotCannotDecreaseOrDuplicateTime() {
        let a = snapshot(30, device: "a")
        let newer = snapshot(50, device: "a")
        let merged = ReadingStatisticsSync.merged(a, newer)
        XCTAssertEqual(merged.statistics.seconds(), 50)
        XCTAssertEqual(ReadingStatisticsSync.merged(merged, a).statistics.seconds(), 50)
        XCTAssertEqual(ReadingStatisticsSync.merged(newer, a), ReadingStatisticsSync.merged(a, newer))
    }

    func testSyncPreservesAllDaysAndBooksAcrossDevices() {
        let a = snapshot(30, device: "a", bookID: "one")
        let b = snapshot(40, device: "b", bookID: "two")
        let merged = ReadingStatisticsSync.merged(a, b)
        XCTAssertEqual(merged.statistics.books.count, 2)
        XCTAssertEqual(merged.devices.count, 2)
        XCTAssertEqual(merged.statistics.seconds(), 70)
    }

    func testSyncedBaselineKeepsOngoingSession() {
        var tracker = ReadingTimeTracker()
        let id = UUID(), now = Date(timeIntervalSince1970: 1_000_000)
        let b = ReadingBook(id: "same", title: "书", kind: .txt)
        tracker.begin(id: id, book: b, date: now, uptime: 0)
        tracker.checkpoint(id: id, date: now.addingTimeInterval(30), uptime: 30)
        tracker.mergeBaseline(snapshot(50, device: "a").devices["a"]!)
        tracker.end(id: id, date: now.addingTimeInterval(40), uptime: 40)
        XCTAssertEqual(tracker.statistics.seconds(), 60)
    }
}
