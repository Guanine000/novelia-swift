import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
final class TextProjectionSyncTests: XCTestCase {
    private func record(_ seconds: TimeInterval, _ chinese: ReadingTextProjection.Chinese) -> ReaderTextProjectionRecord {
        var projection = ReadingTextProjection()
        projection.chinese = chinese
        return ReaderTextProjectionRecord(projection: projection, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    func testMergeUsesNewestValidRecordAndRejectsInvalidKeys() {
        let local = ["epub:a": record(10, .simplified)]
        let remote = [
            "epub:a": record(20, .traditional),
            "book-a": record(30, .traditional),
            "txt:b": record(20, .simplified)
        ]
        let merged = ReaderTextProjectionRecord.merged(local, remote)
        XCTAssertEqual(merged["epub:a"]?.projection.chinese, .traditional)
        XCTAssertNil(merged["book-a"], "unrecognized key prefixes must not enter the manifest")
        XCTAssertEqual(merged["txt:b"]?.projection.chinese, .simplified)
        XCTAssertFalse(ReaderTextProjectionRecord.isValidKey("book-a"))
        XCTAssertTrue(ReaderTextProjectionRecord.isValidKey("epub:\(String(repeating: "a", count: 64))"))
        XCTAssertFalse(ReaderTextProjectionRecord.isValidKey("epub:" + String(repeating: "a", count: 300)))
    }

    func testOversizedReplacementRecordIsInvalid() {
        var projection = ReadingTextProjection()
        projection.replacements = Dictionary(uniqueKeysWithValues: (0..<500).map {
            (String(format: "旧词%04d", $0) + String(repeating: "甲", count: 60),
             String(repeating: "乙", count: 80))
        })
        let oversized = ReaderTextProjectionRecord(projection: projection, updatedAt: Date())
        XCTAssertFalse(oversized.isValid, "large replacement tables must not bloat the manifest")
        XCTAssertTrue(record(10, .simplified).isValid)
    }

    func testReaderSettingsStoresAndAppliesNewerProjection() throws {
        let suiteName = "TextProjectionSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ReaderSettings(defaults: defaults)

        settings.activateBook("epub:a")
        var value = ReadingTextProjection()
        value.chinese = .traditional
        settings.setProjection(value)
        XCTAssertEqual(settings.textProjectionRecords["epub:a"]?.projection.chinese, .traditional)

        let now = Date().timeIntervalSince1970
        let revision = settings.projectionRevision
        settings.applyTextProjectionRecords([
            "epub:a": record(now + 60, .simplified),
            "txt:b": record(now + 60, .simplified)
        ])
        XCTAssertEqual(settings.projection.chinese, .simplified)
        XCTAssertGreaterThan(settings.projectionRevision, revision)
        settings.activateBook("txt:b")
        XCTAssertEqual(settings.projection.chinese, .simplified)

        settings.activateBook("epub:a")
        settings.applyTextProjectionRecords(["epub:a": record(now - 60, .traditional)])
        XCTAssertEqual(settings.projection.chinese, .simplified, "older remote records must not overwrite local state")
    }

    func testProjectionRoundTripsThroughPreferences() throws {
        let suiteName = "TextProjectionSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ReaderSettings(defaults: defaults)
        settings.activateBook("txt:a")
        var value = ReadingTextProjection()
        value.chinese = .simplified
        value.replacements = ["旧": "新"]
        settings.setProjection(value)

        let restored = ReaderSettings(defaults: defaults)
        restored.activateBook("txt:a")
        XCTAssertEqual(restored.projection.chinese, .simplified)
        XCTAssertEqual(restored.projection.replacements, ["旧": "新"])
        XCTAssertNotNil(restored.textProjectionRecords["txt:a"])
    }
}
