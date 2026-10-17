import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
final class ReaderBookmarkTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderBookmarkTests-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddRemoveAndPersist() throws {
        let store = ReaderBookmarkStore(directory: directory)
        let date = Date(timeIntervalSince1970: 100)
        let first = try store.add(bookKey: "epub:a", chapterIndex: 2, progression: 0.4, chapterTitle: "第二章",
                              snippet: "第一行\n第二行", now: date)
        try store.add(bookKey: "epub:a", chapterIndex: 0, progression: 1.5, chapterTitle: nil, snippet: "", now: date)
        try store.add(bookKey: "txt:b", chapterIndex: 0, progression: 0, chapterTitle: nil, snippet: "", now: date)
        XCTAssertEqual(store.bookmarks(for: "epub:a").map(\.chapterIndex), [0, 2], "sorted by chapter")
        XCTAssertEqual(store.bookmarks(for: "epub:a").first?.chapterProgression, 1, "progression is clamped")
        XCTAssertEqual(first.snippet, "第一行 第二行", "snippets are flattened to one line")
        XCTAssertEqual(store.bookmarks(for: "epub:a", chapter: 2, in: 0.3..<0.5).map(\.id), [first.id])
        XCTAssertTrue(store.bookmarks(for: "epub:a", chapter: 2, in: 0.5..<0.6).isEmpty)

        try store.remove(first.id, now: date.addingTimeInterval(10))
        XCTAssertEqual(store.bookmarks(for: "epub:a").count, 1)
        XCTAssertEqual(store.records[first.id.uuidString]?.isDeleted, true, "deletion is kept as a tombstone for sync")
        let reopened = ReaderBookmarkStore(directory: directory)
        XCTAssertEqual(reopened.records, store.records)
        XCTAssertTrue(ReaderBookmarkStore().records.isEmpty, "without a directory nothing is persisted")
    }

    func testFailedAddDoesNotPublishAndCanBeRetried() throws {
        // 用普通文件占住目录，确定性制造写盘失败，不依赖权限或磁盘剩余空间。
        try Data("not a directory".utf8).write(to: directory)
        let store = ReaderBookmarkStore(directory: directory)
        XCTAssertThrowsError(try store.add(bookKey: "txt:a", chapterIndex: 0, progression: 0,
                                           chapterTitle: nil, snippet: "test"))
        XCTAssertTrue(store.records.isEmpty)
        try FileManager.default.removeItem(at: directory)
        let added = try store.add(bookKey: "txt:a", chapterIndex: 0, progression: 0,
                                  chapterTitle: nil, snippet: "retry")
        XCTAssertEqual(ReaderBookmarkStore(directory: directory).records[added.id.uuidString], added)
    }

    func testFailedDeleteAndSyncLeavePublishedAndPersistedStateUnchanged() throws {
        let store = ReaderBookmarkStore(directory: directory)
        let first = try store.add(bookKey: "txt:a", chapterIndex: 0, progression: 0,
                                  chapterTitle: nil, snippet: "first")
        let second = try store.add(bookKey: "txt:a", chapterIndex: 0, progression: 0.2,
                                   chapterTitle: nil, snippet: "second")
        let saved = store.records
        let file = directory.appendingPathComponent("bookmarks.json")
        let backup = directory.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.remove([first.id, second.id]))
        XCTAssertEqual(store.records, saved)
        let remote = try ReaderBookmarkStore().add(bookKey: "txt:b", chapterIndex: 1, progression: 0,
                                                   chapterTitle: nil, snippet: "remote")
        XCTAssertThrowsError(try store.applySynced([remote.id.uuidString: remote]))
        XCTAssertEqual(store.records, saved)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        XCTAssertEqual(ReaderBookmarkStore(directory: directory).records, saved)
        try store.remove([first.id, second.id])
        XCTAssertTrue(store.bookmarks(for: "txt:a").isEmpty)
        XCTAssertTrue(ReaderBookmarkStore(directory: directory).bookmarks(for: "txt:a").isEmpty)
    }

    func testMergeKeepsNewerAndRejectsInvalidRemoteRecords() {
        let id = UUID()
        func mark(_ seconds: TimeInterval, deleted: Bool? = nil, progression: Double = 0.2) -> ReaderBookmark {
            ReaderBookmark(id: id, bookKey: "epub:a", chapterIndex: 1, chapterProgression: progression, chapterTitle: nil,
                           snippet: "", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: seconds),
                           deleted: deleted)
        }
        let local = [id.uuidString: mark(10)]
        XCTAssertEqual(ReaderBookmark.merged(local, [id.uuidString: mark(20, deleted: true)])[id.uuidString]?.isDeleted, true)
        XCTAssertEqual(ReaderBookmark.merged(local, [id.uuidString: mark(10, deleted: true)])[id.uuidString]?.isDeleted, false,
                       "equal time keeps the local record")
        XCTAssertEqual(ReaderBookmark.merged(local, [id.uuidString: mark(30, progression: .nan)]), local, "invalid data is ignored")
        XCTAssertEqual(ReaderBookmark.merged(local, ["other": mark(30)]), local, "the key must match the bookmark ID")
        let decoded = try? JSONDecoder().decode(ReaderBookmark.self, from: Data(#"{"id":"\#(id.uuidString)","bookKey":"txt:x","chapterIndex":0,"chapterProgression":0,"snippet":"","createdAt":0,"updatedAt":0}"#.utf8))
        XCTAssertEqual(decoded?.isDeleted, false, "records without the deleted flag decode")
    }
}
