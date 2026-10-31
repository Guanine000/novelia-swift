import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
final class EPUBUpdateStateTests: XCTestCase {
    private func positions() -> ReadingPositionStore {
        let suite = "EPUBUpdateStateTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ReadingPositionStore(defaults: defaults)
    }
    func testChapterPathMappingPreservesOldStateAndIsIdempotent() throws {
        let positions = positions(), bookmarks = ReaderBookmarkStore()
        positions.recordEPUB(hash: "old", fraction: 0.5, spineIndex: 1, chapterOffset: 12, chapterProgression: 0.2)
        let oldPosition = positions.epubPosition(hash: "old")
        _ = try bookmarks.add(bookKey: "epub:old", chapterIndex: 1, progression: 0.2, chapterTitle: "B", snippet: "text")
        try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a", "b"], newPaths: ["cover", "a", "b", "c"], positions: positions, bookmarks: bookmarks)
        XCTAssertEqual(positions.epubPosition(hash: "new")?.chapterIndex, 2)
        XCTAssertEqual(positions.epubPosition(hash: "new")?.chapterOffset, 12)
        XCTAssertEqual(positions.epubPosition(hash: "new")?.updatedAt, oldPosition?.updatedAt)
        XCTAssertEqual(positions.epubPosition(hash: "old"), oldPosition)
        XCTAssertEqual(bookmarks.bookmarks(for: "epub:new").map(\.chapterIndex), [2])
        XCTAssertEqual(bookmarks.bookmarks(for: "epub:old").count, 1)
        try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a", "b"], newPaths: ["cover", "a", "b", "c"], positions: positions, bookmarks: bookmarks)
        XCTAssertEqual(bookmarks.bookmarks(for: "epub:new").count, 1)
    }
    func testMissingAndAmbiguousPathsDoNotGuessPositions() throws {
        let positions = positions(), bookmarks = ReaderBookmarkStore()
        positions.recordEPUB(hash: "old", fraction: 0.5, spineIndex: 0, chapterOffset: nil, chapterProgression: 0.4)
        _ = try bookmarks.add(bookKey: "epub:old", chapterIndex: 0, progression: 0.4, chapterTitle: nil, snippet: "")
        for paths in [["unrelated"], ["a", "a"]] {
            try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a"], newPaths: paths, positions: positions, bookmarks: bookmarks)
            XCTAssertNil(positions.epubPosition(hash: "new"))
            XCTAssertTrue(bookmarks.bookmarks(for: "epub:new").isEmpty)
        }
    }
    func testNewVersionExistingStateIsNotOverwrittenOrResurrected() throws {
        let positions = positions(), bookmarks = ReaderBookmarkStore()
        positions.recordEPUB(hash: "old", fraction: 0.1, spineIndex: 0, chapterOffset: nil, chapterProgression: nil)
        positions.recordEPUB(hash: "new", fraction: 0.9, spineIndex: 2, chapterOffset: nil, chapterProgression: nil)
        let saved = positions.epubPosition(hash: "new")
        _ = try bookmarks.add(bookKey: "epub:old", chapterIndex: 0, progression: 0.1, chapterTitle: nil, snippet: "")
        try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a"], newPaths: ["a"], positions: positions, bookmarks: bookmarks)
        let newer = try XCTUnwrap(bookmarks.bookmarks(for: "epub:new").first)
        try bookmarks.remove(newer.id)
        try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a"], newPaths: ["a"], positions: positions, bookmarks: bookmarks)
        XCTAssertEqual(positions.epubPosition(hash: "new"), saved)
        XCTAssertTrue(bookmarks.bookmarks(for: "epub:new").isEmpty)
    }
    func testNewerOldPositionAndDeletedBookmarkMergeWithTargetState() throws {
        let positions = positions(), bookmarks = ReaderBookmarkStore()
        positions.merge(["epub:new": SyncedReadingPosition(chapterIndex: 0, fraction: 0, updatedAt: Date(timeIntervalSince1970: 1))], webBooks: [])
        positions.recordEPUB(hash: "old", fraction: 0.7, spineIndex: 1, chapterOffset: 20, chapterProgression: 0.4)
        let old = try bookmarks.add(bookKey: "epub:old", chapterIndex: 1, progression: 0.4, chapterTitle: "B", snippet: "")
        let unrelated = try bookmarks.add(bookKey: "epub:new", chapterIndex: 0, progression: 0.1, chapterTitle: nil, snippet: "other")
        try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a", "b"], newPaths: ["cover", "a", "b"], positions: positions, bookmarks: bookmarks)
        let carried = try XCTUnwrap(bookmarks.bookmarks(for: "epub:new").first { $0.id != unrelated.id })
        XCTAssertEqual(positions.epubPosition(hash: "new")?.chapterIndex, 2)
        XCTAssertEqual(positions.epubPosition(hash: "new")?.updatedAt, positions.epubPosition(hash: "old")?.updatedAt)
        try bookmarks.remove(old.id, now: Date().addingTimeInterval(10))
        try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a", "b"], newPaths: ["cover", "a", "b"], positions: positions, bookmarks: bookmarks)
        XCTAssertTrue(bookmarks.records[carried.id.uuidString]?.isDeleted == true)
        XCTAssertEqual(bookmarks.bookmarks(for: "epub:new").map(\.id), [unrelated.id])
        let secondDevice = ReaderBookmarkStore()
        try secondDevice.applySynced(bookmarks.records.filter { $0.value.bookKey == "epub:old" })
        try EPUBUpdateState.carry(oldHash: "old", newHash: "new", oldPaths: ["a", "b"], newPaths: ["cover", "a", "b"], positions: positions, bookmarks: secondDevice)
        XCTAssertEqual(secondDevice.records[carried.id.uuidString], bookmarks.records[carried.id.uuidString])
    }

}
