import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
final class ReaderAnnotationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderAnnotationTests-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func annotation(_ bookKey: String = "epub:a", start: Int = 0, quote: String = "第一段",
                            prefix: String = "", suffix: String = "", updated: TimeInterval = 10,
                            deleted: Bool? = nil) -> ReaderAnnotation {
        ReaderAnnotation(
            id: UUID(), bookKey: bookKey, chapterIndex: 0, chapterID: nil, resourceHref: "ch1.xhtml",
            progression: nil, startUTF16: start, endUTF16: start + quote.utf16.count,
            quote: quote, prefix: prefix, suffix: suffix, projectionIdentity: "",
            color: .yellow, note: "", createdAt: Date(timeIntervalSince1970: updated),
            updatedAt: Date(timeIntervalSince1970: updated), deleted: deleted
        )
    }

    func testAddUsesContextAndReplacesOverlaps() throws {
        let text = "第一段内容。第二段内容。"
        let store = ReaderAnnotationStore()
        let first = try store.add(bookKey: "epub:a", chapterIndex: 0, range: NSRange(location: 0, length: 3),
                                  quote: "第一段", chapterText: text, projectionIdentity: "")
        XCTAssertEqual(first.prefix, "")
        XCTAssertEqual(first.suffix, "内容。第二段内容。")

        let overlapping = try store.add(bookKey: "epub:a", chapterIndex: 0, range: NSRange(location: 1, length: 3),
                                        quote: "一段内", chapterText: text, projectionIdentity: "")
        XCTAssertEqual(store.annotations(for: "epub:a").map(\.id), [overlapping.id])
        XCTAssertEqual(store.records[first.id.uuidString]?.isDeleted, true)

        let same = try store.add(bookKey: "epub:a", chapterIndex: 0, range: NSRange(location: 1, length: 3),
                                 quote: "一段内", chapterText: text, projectionIdentity: "",
                                 color: .green, note: "笔记")
        XCTAssertEqual(same.id, overlapping.id)
        XCTAssertEqual(store.annotations(for: "epub:a").count, 1)
        XCTAssertEqual(store.annotation(id: overlapping.id)?.color, .green)
        XCTAssertEqual(store.annotation(id: overlapping.id)?.note, "笔记")

        _ = try store.add(bookKey: "epub:a", chapterIndex: 0, range: NSRange(location: 6, length: 3),
                          quote: "第二段", chapterText: text, projectionIdentity: "")
        XCTAssertEqual(store.annotations(for: "epub:a").count, 2)
    }

    func testResolverUsesContextForRepeatedQuotes() {
        let text = "重复。中间。重复。结尾。"
        let first = annotation(start: 1, quote: "重复", prefix: "", suffix: "。中间。重复。结尾。")
        let second = annotation(start: 1, quote: "重复", prefix: "重复。中间。", suffix: "。结尾。")
        XCTAssertEqual(ReaderAnnotationResolver.resolve(second, in: text)?.location, 6)
        XCTAssertEqual(ReaderAnnotationResolver.resolve(first, in: text)?.location, 0)

        let ambiguous = annotation(start: 1, quote: "重复", prefix: "", suffix: "")
        XCTAssertNil(ReaderAnnotationResolver.resolve(ambiguous, in: text))
    }

    func testResolverUsesProgressionWhenContextIsEmpty() {
        let text = "重复。中间。重复。结尾。"
        var value = annotation(start: 1, quote: "重复")
        value.progression = 0.9
        XCTAssertEqual(ReaderAnnotationResolver.resolve(value, in: text)?.location, 6)
    }

    func testMergeUsesNewerRecordAndTombstone() {
        let first = annotation(updated: 20)
        var remoteOlder = first
        remoteOlder.updatedAt = Date(timeIntervalSince1970: 10)
        var remoteDeleted = first
        remoteDeleted.deleted = true
        remoteDeleted.updatedAt = Date(timeIntervalSince1970: 30)
        XCTAssertEqual(ReaderAnnotation.merged([first.id.uuidString: first],
                                               [first.id.uuidString: remoteOlder]),
                       [first.id.uuidString: first])
        XCTAssertEqual(ReaderAnnotation.merged([first.id.uuidString: first],
                                               [first.id.uuidString: remoteDeleted])[first.id.uuidString]?.isDeleted,
                       true)
    }

    func testStorePersistsTombstoneAndRejectsInvalidRemote() throws {
        let store = ReaderAnnotationStore(directory: directory)
        let first = try store.add(bookKey: "txt:a", chapterIndex: 1, range: NSRange(location: 0, length: 2),
                                  quote: "正文", chapterText: "正文内容", projectionIdentity: "")
        try store.remove(first.id)
        XCTAssertTrue(store.annotations(for: "txt:a").isEmpty)
        let reopened = ReaderAnnotationStore(directory: directory)
        XCTAssertEqual(reopened.records[first.id.uuidString]?.isDeleted, true)

        var invalid = annotation("book")
        invalid.note = String(repeating: "字", count: ReaderAnnotation.maxNoteLength + 1)
        try reopened.applySynced([invalid.id.uuidString: invalid])
        XCTAssertNil(reopened.records[invalid.id.uuidString])
    }

    func testSyncMergeKeepsNewerValidRecords() {
        let local = annotation(updated: 20)
        var remoteNewer = local
        remoteNewer.note = "远端笔记"
        remoteNewer.updatedAt = Date(timeIntervalSince1970: 30)
        var remoteOlder = local
        remoteOlder.note = "旧笔记"
        remoteOlder.updatedAt = Date(timeIntervalSince1970: 10)
        let merged = ReaderAnnotation.mergedSync([local.id.uuidString: local],
                                                 [local.id.uuidString: remoteNewer])
        XCTAssertEqual(merged[local.id.uuidString]?.note, "远端笔记")
        XCTAssertEqual(ReaderAnnotation.mergedSync([local.id.uuidString: local],
                                                   [local.id.uuidString: remoteOlder])[local.id.uuidString]?.note,
                       "")

        let invalid = annotation("book")
        XCTAssertTrue(ReaderAnnotation.mergedSync([:], [invalid.id.uuidString: invalid]).isEmpty)
    }

    func testValidationRejectsBadRangesAndKeys() {
        var value = annotation()
        XCTAssertTrue(value.isValid)
        value.endUTF16 = value.startUTF16
        XCTAssertFalse(value.isValid)
        value = annotation("book")
        XCTAssertFalse(value.isValid)
        value = annotation()
        value.note = String(repeating: "字", count: ReaderAnnotation.maxNoteLength + 1)
        XCTAssertFalse(value.isValid)
    }
}
