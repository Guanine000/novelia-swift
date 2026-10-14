import Foundation
import XCTest
@testable import NoveliaIOSCore

/// WebDAV 清单兼容性与文件记录校验（原 scripts/test_webdav_manifest.py）。
final class WebDAVManifestTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testLegacyManifestDecodesWithoutNewerRecords() throws {
        let legacy = try JSONDecoder().decode(WebDAVManifest.self,
            from: Data(#"{"version":1,"webBooks":[],"wenkuBooks":[],"positions":{}}"#.utf8))
        XCTAssertEqual(legacy.version, 1)
        XCTAssertNil(legacy.blockedTags)
        XCTAssertNil(legacy.backgrounds)
        XCTAssertNil(legacy.fonts)
        XCTAssertNil(legacy.librarySeries)
    }

    func testSyncedRecordsRoundTrip() throws {
        var manifest = WebDAVManifest()
        manifest.blockedTags = ["标签": SyncedBlockedTag(blocked: true, updatedAt: date(100))]
        manifest.fonts = ["hash": SyncedImportedFont(hash: "hash", format: "ttf", deleted: false, updatedAt: date(100))]
        manifest.backgrounds = ["dark": SyncedReaderBackground(mode: "image", color: "000000",
                                                               portraitHash: "p", landscapeHash: nil, updatedAt: date(100))]
        manifest.positions = [
            "web:a": SyncedReadingPosition(chapterIndex: 2, fraction: nil, updatedAt: date(100)),
            "txt:h": SyncedReadingPosition(chapterIndex: 4, fraction: nil, updatedAt: date(100),
                                           chapterOffset: 80, unit: 9, unitCount: 120),
        ]
        var series = LibrarySeriesState()
        _ = series.createSeries(named: "系列", now: date(100), id: "s1")
        series.assign(book: "wenku:1", to: "s1", now: date(101))
        manifest.librarySeries = series
        let book = LocalWenkuEPUB(id: UUID(), title: "书", filename: "book.epub", addedAt: date(50))
        manifest.wenkuBooks = [WebDAVBook(record: book, assets: [WebDAVAsset(filename: "book.epub", hash: "h")])]

        let roundTrip = try JSONDecoder().decode(WebDAVManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(roundTrip.blockedTags, manifest.blockedTags)
        XCTAssertEqual(roundTrip.fonts?["hash"]?.format, "ttf")
        XCTAssertEqual(roundTrip.backgrounds?["dark"]?.portraitHash, "p")
        XCTAssertEqual(roundTrip.positions, manifest.positions)
        XCTAssertEqual(roundTrip.positions["txt:h"]?.unit, 9)
        XCTAssertEqual(roundTrip.librarySeries, series)
        XCTAssertEqual(roundTrip.wenkuBooks, manifest.wenkuBooks)
    }

    func testBookRecordWithoutOptionalFieldsDecodes() throws {
        let book = LocalWenkuEPUB(id: UUID(), title: "书", filename: "book.txt", addedAt: date(50), fileFormat: .txt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        object.removeValue(forKey: "fileFormat")
        let decoded = try JSONDecoder().decode(LocalWenkuEPUB.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.fileFormat)
        XCTAssertEqual(decoded.resolvedFileFormat, .txt, "older records infer the format from the filename")
    }

    func testAssetFilenameMustBeSingleComponent() {
        XCTAssertTrue(WebDAVAsset.isSafeFilename("book.epub"))
        XCTAssertTrue(WebDAVAsset.isSafeFilename("cover-1.jpg"))
        for unsafe in ["", ".", "..", "a/b.epub", "../book.epub", "/book.epub"] {
            XCTAssertFalse(WebDAVAsset.isSafeFilename(unsafe), unsafe)
        }
    }

    func testAssetHashMustBeLowercaseSHA256Hex() {
        XCTAssertTrue(WebDAVAsset.isValidHash(String(repeating: "0123456789abcdef", count: 4)))
        XCTAssertFalse(WebDAVAsset.isValidHash(String(repeating: "A", count: 64)), "uppercase")
        XCTAssertFalse(WebDAVAsset.isValidHash(String(repeating: "a", count: 63)), "too short")
        XCTAssertFalse(WebDAVAsset.isValidHash(String(repeating: "g", count: 64)), "not hex")
        XCTAssertFalse(WebDAVAsset.isValidHash(String(repeating: "a", count: 62) + "/."), "path characters")
    }

    func testAssetSizeIsOptionalAndRoundTrips() throws {
        let old = try JSONDecoder().decode(WebDAVAsset.self, from: Data(#"{"filename":"a.epub","hash":"h"}"#.utf8))
        XCTAssertNil(old.size, "manifests written before sizes still decode")
        let sized = WebDAVAsset(filename: "a.epub", hash: "h", size: 1_234)
        XCTAssertEqual(try JSONDecoder().decode(WebDAVAsset.self, from: JSONEncoder().encode(sized)), sized)
    }
}
