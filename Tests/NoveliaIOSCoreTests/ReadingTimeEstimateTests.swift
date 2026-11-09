// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NoveliaIOSCore

final class ReadingTimeEstimateTests: XCTestCase {
    func testLogicalChapterIncludesAllTXTUnits() throws {
        let metrics = try ReadingTimeMetrics(words: [100, 200, 300], chapterStarts: [0, 2], language: .chinese)
        let remaining = try XCTUnwrap(metrics.remaining(.init(resource: 0, fraction: 0.5)))
        XCTAssertEqual(remaining.chapter, 250)
        XCTAssertEqual(remaining.book, 550)
        XCTAssertEqual(metrics.chapterGroups, [0, 0, 1])
        XCTAssertEqual(metrics.remaining(.init(resource: 1, fraction: 1))?.chapter, 0)
        XCTAssertEqual(metrics.remaining(.init(resource: 2, fraction: 1))?.book, 0)
    }

    func testInvalidAndEmptyResourcesNeverProduceFalseEstimate() throws {
        XCTAssertThrowsError(try ReadingTimeMetrics(words: [], chapterStarts: [], language: .english))
        XCTAssertThrowsError(try ReadingTimeMetrics(words: [-1], chapterStarts: [], language: .english))
        let metrics = try ReadingTimeMetrics(words: [100], chapterStarts: [], language: .english)
        for point in [ReadingTimePoint(resource: -1, fraction: 0), .init(resource: 1, fraction: 0),
                      .init(resource: 0, fraction: .nan), .init(resource: 0, fraction: 1.1)] {
            XCTAssertNil(metrics.remaining(point))
        }
    }

    func testSamplerRejectsNavigationIdleAndInactiveIntervals() throws {
        let metrics = try ReadingTimeMetrics(words: [1_000, 1_000, 1_000], chapterStarts: [0, 1, 2], language: .chinese)
        var sampler = ReadingSpeedSampler()
        XCTAssertNil(sampler.observe(.start, metrics: metrics, now: 0, active: true))
        XCTAssertEqual(sampler.observe(.init(resource: 0, fraction: 0.1, reason: .forward), metrics: metrics, now: 20, active: true), 300)
        XCTAssertNil(sampler.observe(.init(resource: 0, fraction: 0.2, reason: .forward), metrics: metrics, now: 21, active: true))
        XCTAssertNil(sampler.observe(.init(resource: 2, fraction: 0.3, reason: .forward), metrics: metrics, now: 40, active: true))
        XCTAssertNil(sampler.observe(.init(resource: 2, fraction: 0.1, reason: .forward), metrics: metrics, now: 60, active: true))
        XCTAssertNil(sampler.observe(.init(resource: 2, fraction: 0.2, reason: .forward), metrics: metrics, now: 300, active: true))
        XCTAssertNil(sampler.observe(.init(resource: 2, fraction: 0.3, reason: .forward), metrics: metrics, now: 320, active: false))
        XCTAssertNil(sampler.observe(.init(resource: 2, fraction: 0.4, reason: .forward), metrics: metrics, now: 340, active: true))
        XCTAssertNil(sampler.observe(.init(resource: 2, fraction: 0.5, reason: .reset), metrics: metrics, now: 360, active: true))
        XCTAssertEqual(try XCTUnwrap(sampler.observe(.init(resource: 2, fraction: 0.6, reason: .forward), metrics: metrics, now: 380, active: true)), 300, accuracy: 0.01)
    }

    func testMedianRequiresFiveSamplesAndBoundsStorage() {
        var profile = ReadingSpeedProfile()
        for speed in [300.0, 310, 290, 3_000] { profile.add(speed) }
        XCTAssertNil(profile.speed)
        profile.add(305)
        XCTAssertEqual(profile.speed, 305)
        profile.add(.nan); profile.add(0)
        XCTAssertEqual(profile.samples.count, 5)
        for _ in 0..<100 { profile.add(400) }
        XCTAssertEqual(profile.samples.count, 31)
        XCTAssertEqual(profile.speed, 400)
    }

    func testTXTCountingUsesSameUnitCutsAndLogicalChapter() throws {
        let body = String(repeating: "中文正文。\n", count: 4_000)
        let book = TXTParsedBook(contentHash: "test", byteCount: body.utf8.count, text: body,
            chapters: [.init(index: 0, title: "一", body: body, volumeTitle: nil),
                       .init(index: 1, title: "二", body: "后文", volumeTitle: nil)], rulesFingerprint: "rules")
        let metrics = try ReadingTimeMetrics.txt(book, projection: .init(), paged: true)
        let cuts = TXTTextUnitCuts.cuts(utf8: body.utf8, maximumUTF8: 36_000)
        XCTAssertGreaterThan(cuts.count, 2)
        XCTAssertEqual(metrics.words.count, cuts.count)
        XCTAssertEqual(metrics.chapterGroups, Array(repeating: 0, count: cuts.count - 1) + [1])
        XCTAssertEqual(metrics.words.reduce(0, +), BookWordCount.count(text: body) + BookWordCount.count(text: "后文"))
    }

    @MainActor
    func testLocalPreferencesLearningIsolationPersistenceAndClear() throws {
        let suite = "ReadingTimeTests-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingTimeEstimateStore(defaults: defaults)
        XCTAssertFalse(store.preferences.isEnabled)
        XCTAssertFalse(store.preferences.learnsSpeed)
        for _ in 0..<5 { store.record(300, book: "a", language: .chinese, mode: "paged") }
        XCTAssertNil(store.speed(book: "a", language: .chinese, mode: "paged"))
        store.preferences.isEnabled = true; store.preferences.learnsSpeed = true
        for _ in 0..<5 { store.record(300, book: "a", language: .chinese, mode: "paged") }
        XCTAssertEqual(store.speed(book: "b", language: .chinese, mode: "paged"), 300)
        XCTAssertNil(store.speed(book: "a", language: .japanese, mode: "paged"))
        XCTAssertNil(store.speed(book: "a", language: .chinese, mode: "scroll"))
        let reopened = ReadingTimeEstimateStore(defaults: defaults)
        XCTAssertEqual(reopened.speed(book: "a", language: .chinese, mode: "paged"), 300)
        reopened.preferences.usesManualSpeed = true; reopened.preferences.manualSpeed = 500
        XCTAssertEqual(reopened.speed(book: "a", language: .english, mode: "scroll"), 500)
        reopened.clearLearning(); reopened.preferences.usesManualSpeed = false
        XCTAssertNil(reopened.speed(book: "a", language: .chinese, mode: "paged"))
        XCTAssertEqual(reopened.resetRevision, 1)
    }

    @MainActor
    func testCorruptLocalDataFallsBackToDisabledDefaults() throws {
        let suite = "ReadingTimeCorrupt-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: "reader.remainingTime.preferences.v1")
        defaults.set(Data("invalid".utf8), forKey: "reader.remainingTime.profiles.v1")
        let store = ReadingTimeEstimateStore(defaults: defaults)
        XCTAssertFalse(store.preferences.isEnabled)
        XCTAssertEqual(store.preferences.manualSpeed, 400)
        XCTAssertNil(store.speed(book: "a", language: .chinese, mode: "paged"))
    }

    func testDurationRoundingAndInvalidValues() {
        XCTAssertEqual(ReadingTimeFormatting.duration(seconds: 1), "不足 1 分钟")
        XCTAssertEqual(ReadingTimeFormatting.duration(seconds: 61), "2 分钟")
        XCTAssertEqual(ReadingTimeFormatting.duration(seconds: 3_600), "1 小时")
        XCTAssertNil(ReadingTimeFormatting.duration(seconds: .infinity))
        XCTAssertNil(ReadingTimeFormatting.duration(seconds: -1))
    }
}
