// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NoveliaIOSCore

final class TXTChapterAdjustmentTests: XCTestCase {
    private func document(_ text: String) throws -> TXTAdjustmentDocument {
        let normalized = TXTAdjustmentDocument.normalized(text)
        return try .init(text: normalized, boundaries: TXTChapterParser.adjustmentBoundaries(normalized, rules: .defaults))
    }

    func testSelectedOccurrenceSplitsWithoutLosingSource() throws {
        let original = "前半正文\n重复标题\n中段正文\n重复标题\n后半正文"
        var book = try document(original)
        let range = (original as NSString).range(of: "重复标题", options: .backwards)
        try book.setTitle(selection: range)
        XCTAssertEqual(book.boundaries.count, 2)
        XCTAssertEqual(book.chapters()[1].title, "重复标题")
        XCTAssertEqual(book.chapters()[1].body, "后半正文")
        XCTAssertTrue(book.chapters()[0].body.contains("重复标题\n中段正文"))
        XCTAssertEqual(book.text, original)
        XCTAssertEqual(book.boundaries[1].start, range.location)
    }

    func testDeleteMergesTitleAndBodyThenUndoRestores() throws {
        var book = try document("开头\n新标题\n之后正文")
        try book.setTitle(selection: (book.text as NSString).range(of: "新标题"))
        let beforeDelete = book
        try book.removeChapter(1)
        XCTAssertEqual(book.chapters().map(\.body), ["开头\n新标题\n之后正文"])
        book = beforeDelete
        XCTAssertEqual(book.chapters().map(\.title), ["全文", "新标题"])
    }

    func testFirstChapterCannotBeDeleted() throws {
        var book = try document("原文")
        XCTAssertThrowsError(try book.removeChapter(0))
        XCTAssertEqual(book.chapters()[0].body, "原文")
    }

    func testExistingBoundaryRetitlesWithoutEmptyChapter() throws {
        var book = try document("新标题\n正文")
        try book.setTitle(selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(book.boundaries.count, 1)
        XCTAssertEqual(book.chapters()[0].title, "新标题")
        XCTAssertEqual(book.chapters()[0].body, "正文")
    }

    func testRejectsCrossBoundaryAndInvalidUTF16Selection() throws {
        var book = try document("前文\n标题\n😀尾文")
        try book.setTitle(selection: (book.text as NSString).range(of: "标题"))
        let snapshot = book
        XCTAssertThrowsError(try book.setTitle(selection: NSRange(location: 0, length: book.text.utf16.count)))
        let emoji = (book.text as NSString).range(of: "😀")
        XCTAssertThrowsError(try book.setTitle(selection: NSRange(location: emoji.location, length: 1)))
        XCTAssertEqual(book, snapshot)
    }

    func testManualTwoChapterDirectoryBypassesAutomaticThreshold() throws {
        var book = try document("第一章 开始\r\n内容\r\n第二章 后续\r\n后面内容")
        XCTAssertEqual(book.boundaries.count, 1)
        try book.setTitle(selection: (book.text as NSString).range(of: "第二章 后续"))
        XCTAssertEqual(book.boundaries.count, 2)
        XCTAssertEqual(book.text, TXTAdjustmentDocument.normalized(book.text))
        let encoded = try JSONEncoder().encode(book.boundaries)
        let decoded = try JSONDecoder().decode([TXTChapterBoundary].self, from: encoded)
        XCTAssertEqual(try TXTAdjustmentDocument(text: book.text, boundaries: decoded), book)
    }

    func testAutomaticBaselineRetainsVolumeTextWhenDeleting() throws {
        let body = String(repeating: "较长正文，避免被判成开头目录。\n", count: 5)
        let raw = ["第一卷 春", "第一章 出发", body, "第二章 相遇", body, "第三章 结束", body].joined(separator: "\n")
        var book = try document(raw)
        XCTAssertEqual(book.boundaries.count, 4)
        XCTAssertEqual(book.chapters()[0].body, "第一卷 春")
        try book.removeChapter(1)
        XCTAssertTrue(book.chapters()[0].body.contains("第一章 出发"))
        XCTAssertTrue(book.chapters()[0].body.contains("第一卷 春"))
        XCTAssertEqual(book.text, raw)
    }

    func testStorePersistsAndRejectsStaleWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TXTChapterAdjustmentStore(directory: directory)
        let hash = String(repeating: "a", count: 64)
        let book = try document("原文")
        let revision = try await store.save(book, hash: hash, expectedRevision: nil, position: nil, bookmarks: [:])
        let restored = try await TXTChapterAdjustmentStore(directory: directory).snapshot(hash: hash)
        XCTAssertEqual(restored?.revision, revision)
        XCTAssertEqual(restored?.boundaries, book.boundaries)
        do {
            _ = try await store.save(book, hash: hash, expectedRevision: nil, position: nil, bookmarks: [:])
            XCTFail("stale writer overwrote directory")
        } catch { XCTAssertTrue(error is TXTAdjustmentError) }
        let after = try await store.snapshot(hash: hash)
        XCTAssertEqual(after?.revision, revision)
    }

    func testCoordinateRebaseAfterInsertionAndDeletion() throws {
        var book = try document("开头正文\n新标题\n😀这是需要保留的位置\n结尾")
        let before = try TXTAdjustmentCoordinates(text: book.text, chapters: book.chapters(), projection: .init(), boundaries: book.boundaries)
        let raw = (book.text as NSString).range(of: "这是").location
        let old = try XCTUnwrap(before.location(rawOffset: raw))
        XCTAssertEqual(before.rawOffset(unit: old.unit, offset: old.offset), raw)
        try book.setTitle(selection: (book.text as NSString).range(of: "新标题"))
        let after = try TXTAdjustmentCoordinates(text: book.text, chapters: book.chapters(), projection: .init(), boundaries: book.boundaries)
        let rebased = try XCTUnwrap(after.location(rawOffset: raw))
        XCTAssertEqual(after.units[rebased.unit].chapter, 1)
        XCTAssertEqual(after.rawOffset(unit: rebased.unit, offset: rebased.offset), raw)
        let atTitle = try XCTUnwrap(after.location(rawOffset: book.boundaries[1].start))
        XCTAssertEqual(after.units[atTitle.unit].chapter, 1)
        try book.removeChapter(1)
        let merged = try TXTAdjustmentCoordinates(text: book.text, chapters: book.chapters(), projection: .init(), boundaries: book.boundaries)
        let restored = try XCTUnwrap(merged.location(rawOffset: raw))
        XCTAssertEqual(merged.units[restored.unit].chapter, 0)
        XCTAssertEqual(merged.rawOffset(unit: restored.unit, offset: restored.offset), raw)
    }

    func testCoordinatesPreserveRepeatedBodiesInOrder() throws {
        var book = try document("相同正文\n中间标题\n相同正文")
        try book.setTitle(selection: (book.text as NSString).range(of: "中间标题"))
        let map = try TXTAdjustmentCoordinates(text: book.text, chapters: book.chapters(), projection: .init(), boundaries: book.boundaries)
        let second = (book.text as NSString).range(of: "相同正文", options: .backwards).location
        let location = try XCTUnwrap(map.location(rawOffset: second))
        XCTAssertEqual(map.units[location.unit].chapter, 1)
        XCTAssertEqual(map.rawOffset(unit: location.unit, offset: location.offset), second)
    }

    func testTrailingTitleWithEmptyBodyStillMaps() throws {
        var book = try document("开头\n新标题")
        try book.setTitle(selection: (book.text as NSString).range(of: "新标题"))
        XCTAssertEqual(book.chapters().map(\.body), ["开头", ""])
        let map = try TXTAdjustmentCoordinates(text: book.text, chapters: book.chapters(), projection: .init(), boundaries: book.boundaries)
        let inFirst = try XCTUnwrap(map.location(rawOffset: (book.text as NSString).range(of: "开头").location))
        XCTAssertEqual(map.units[inFirst.unit].chapter, 0)
        let atTitle = try XCTUnwrap(map.location(rawOffset: book.boundaries[1].start))
        XCTAssertEqual(map.units[atTitle.unit].chapter, 1)
        var blank = try document("开头\n新标题\n   ")
        try blank.setTitle(selection: (blank.text as NSString).range(of: "新标题"))
        XCTAssertEqual(blank.chapters()[1].body, "")
        _ = try TXTAdjustmentCoordinates(text: blank.text, chapters: blank.chapters(), projection: .init(), boundaries: blank.boundaries)
    }

    func testLongChapterUsesSameBoundedUnitCuts() throws {
        let text = String(repeating: "一段😀正文\n", count: 10_000)
        let book = try document(text)
        let map = try TXTAdjustmentCoordinates(text: book.text, chapters: book.chapters(), projection: .init(), boundaries: book.boundaries)
        XCTAssertGreaterThan(map.units.count, 1)
        for unit in map.units {
            let target = try XCTUnwrap(map.location(rawOffset: unit.start))
            XCTAssertEqual(map.units[target.unit].chapter, 0)
        }
    }

    func testCorruptSnapshotIsNotSilentlyOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = String(repeating: "b", count: 64)
        let url = directory.appendingPathComponent(hash + ".json")
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: url)
        do {
            _ = try await TXTChapterAdjustmentStore(directory: directory).save(document("原文"), hash: hash,
                expectedRevision: nil, position: nil, bookmarks: [:])
            XCTFail("corrupt snapshot was overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testSavedDirectoryLoadsInReaderWithoutChangingTXTBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("book.txt")
        let bytes = Data("开头\r\n新章标题\r\n新章内容".utf8)
        try bytes.write(to: file)
        let store = TXTChapterAdjustmentStore(directory: folder.appendingPathComponent("adjustments"))
        let session = try await store.session(url: file, rules: .defaults)
        var edited = session.document
        try edited.setTitle(selection: (edited.text as NSString).range(of: "新章标题"))
        let revision = try await store.save(edited, hash: session.baseBook.contentHash, expectedRevision: nil,
                                            position: nil, bookmarks: [:])
        let result = try await store.readingBook(session.baseBook, url: file)
        XCTAssertEqual(result.book.chapters.map(\.title), ["全文", "新章标题"])
        XCTAssertEqual(result.book.chapters[1].body, "新章内容")
        XCTAssertTrue(result.book.rulesFingerprint.hasSuffix("|adjust:" + revision))
        XCTAssertEqual(result.snapshot?.revision, revision)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
