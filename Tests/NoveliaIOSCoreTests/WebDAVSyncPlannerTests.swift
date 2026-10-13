import Foundation
import XCTest
@testable import NoveliaIOSCore

/// WebDAV 同步的决策规则：书籍比较、阅读位置筛选、背景与字体计划。
final class WebDAVSyncPlannerTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func hash(_ seed: Character) -> String { String(repeating: seed, count: 64) }

    private func wenku(_ id: UUID, at seconds: TimeInterval) -> LocalWenkuEPUB {
        LocalWenkuEPUB(id: id, title: "文库", filename: "\(id).epub", addedAt: date(seconds))
    }

    private func web(_ id: String, at seconds: TimeInterval) -> DownloadedWebNovel {
        DownloadedWebNovel(
            novel: Novel(id: id, title: "网络小说", author: "", summary: "", genres: [], chapters: [], accent: .plum),
            fileFilename: "\(id).epub", downloadedAt: date(seconds),
            translationSource: nil, downloadMode: nil, fileFormat: nil)
    }

    private func remote<Record>(_ record: Record, hashes: [Character] = ["a"]) -> WebDAVBook<Record> {
        WebDAVBook(record: record, assets: hashes.enumerated().map { WebDAVAsset(filename: "f\($0.offset)", hash: hash($0.element)) })
    }

    // MARK: 书籍

    func testEmptyRemoteUploadsEveryLocalBook() {
        let books = [web("a", at: 1), web("b", at: 2)]
        let plan = WebDAVSyncPlanner.planBooks(local: books, remote: [])
        XCTAssertTrue(plan.downloads.isEmpty)
        XCTAssertEqual(plan.uploads, books)
    }

    func testRemoteOnlyBooksAreRestoredInManifestOrder() {
        let remoteBooks = [remote(web("z", at: 1)), remote(web("a", at: 2))]
        let plan = WebDAVSyncPlanner.planBooks(local: [], remote: remoteBooks)
        XCTAssertEqual(plan.downloads.map(\.book), remoteBooks)
        XCTAssertEqual(plan.downloads.map(\.replacesLocal), [false, false])
        XCTAssertTrue(plan.uploads.isEmpty)
    }

    func testNewerRemoteReplacesLocalCopy() {
        let plan = WebDAVSyncPlanner.planBooks(local: [web("a", at: 1)], remote: [remote(web("a", at: 2))])
        XCTAssertEqual(plan.downloads.map(\.book.record.downloadedAt), [date(2)])
        XCTAssertEqual(plan.downloads.map(\.replacesLocal), [true])
        XCTAssertTrue(plan.uploads.isEmpty)
    }

    func testNewerLocalCopyIsUploaded() {
        let local = web("a", at: 2)
        let plan = WebDAVSyncPlanner.planBooks(local: [local], remote: [remote(web("a", at: 1))])
        XCTAssertTrue(plan.downloads.isEmpty)
        XCTAssertEqual(plan.uploads, [local])
    }

    func testEqualTimestampsKeepLocalCopy() {
        let local = web("a", at: 5)
        let plan = WebDAVSyncPlanner.planBooks(local: [local], remote: [remote(web("a", at: 5))])
        XCTAssertTrue(plan.downloads.isEmpty, "a book is never downloaded over an equally new local copy")
        XCTAssertEqual(plan.uploads, [local])
    }

    func testWenkuBooksCompareImportTime() {
        let shared = UUID(), remoteOnly = UUID(), localOnly = UUID()
        let plan = WebDAVSyncPlanner.planBooks(
            local: [wenku(shared, at: 1), wenku(localOnly, at: 1)],
            remote: [remote(wenku(shared, at: 3)), remote(wenku(remoteOnly, at: 0))])
        XCTAssertEqual(plan.downloads.map(\.book.record.id), [shared, remoteOnly])
        XCTAssertEqual(plan.downloads.map(\.replacesLocal), [true, false])
        XCTAssertEqual(plan.uploads.map(\.id), [localOnly])
    }

    func testDuplicateBookIDsKeepNewestEntryInsteadOfCrashing() {
        let duplicated = [remote(web("a", at: 1), hashes: ["a"]), remote(web("b", at: 1)), remote(web("a", at: 3), hashes: ["c"]),
                          remote(web("a", at: 2))]
        XCTAssertEqual(WebDAVSyncPlanner.uniqueBooks(duplicated).map(\.record.id), ["a", "b"])
        XCTAssertEqual(WebDAVSyncPlanner.uniqueBooks(duplicated).first?.record.downloadedAt, date(3))

        let plan = WebDAVSyncPlanner.planBooks(local: [web("b", at: 5), web("b", at: 0)], remote: duplicated)
        XCTAssertEqual(plan.downloads.map(\.book.record.id), ["a"])
        XCTAssertEqual(plan.downloads.first?.book.assets.map(\.hash), [hash("c")])
        XCTAssertEqual(plan.uploads.map(\.downloadedAt), [date(5)])
    }

    func testUnitCountAddsRemoteAssetsAndLocalFiles() {
        let plan = WebDAVSyncPlanner.planBooks(
            local: [web("up", at: 1)],
            remote: [remote(web("down", at: 1), hashes: ["a", "b", "c"])])
        XCTAssertEqual(plan.unitCount { _ in 2 }, 5)
    }

    func testUpsertReplacesSameBookAndAppendsNewOnes() {
        var books = [remote(web("a", at: 1), hashes: ["a"]), remote(web("b", at: 1))]
        books.upsert(remote(web("a", at: 2), hashes: ["c"]))
        books.upsert(remote(web("c", at: 1)))
        XCTAssertEqual(books.map(\.record.id), ["b", "a", "c"])
        XCTAssertEqual(books[1].assets.map(\.hash), [hash("c")])
    }

    // MARK: 阅读位置

    func testPositionsKeepOnlyBooksInManifest() {
        var manifest = WebDAVManifest()
        manifest.webBooks = [remote(web("a", at: 1), hashes: ["a"])]
        manifest.wenkuBooks = [remote(wenku(UUID(), at: 1), hashes: ["b"])]
        let position = SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: date(1))
        let all = [
            "web:a": position, "web:gone": position,
            "epub:\(hash("a"))": position, "txt:\(hash("b"))": position,
            "epub:\(hash("f"))": position, "unknown": position,
        ]
        let kept = WebDAVSyncPlanner.positionsToSync(all, in: manifest)
        XCTAssertEqual(Set(kept.keys), ["web:a", "epub:\(hash("a"))", "txt:\(hash("b"))"])
    }

    func testReferencedBlobsCoverBooksBackgroundsAndLiveFonts() {
        var manifest = WebDAVManifest()
        manifest.webBooks = [remote(web("a", at: 1), hashes: ["a"])]
        manifest.wenkuBooks = [remote(wenku(UUID(), at: 1), hashes: ["b", "c"])]
        manifest.backgrounds = ["dark": background(at: 1, portrait: hash("d"), landscape: hash("e")), "light": background(at: 1)]
        manifest.fonts = [hash("f"): font(hash("f")), hash("9"): font(hash("9"), deleted: true)]
        XCTAssertEqual(WebDAVSyncPlanner.referencedBlobs(in: manifest), Set(["a", "b", "c", "d", "e", "f"].map { hash(Character($0)) }),
                       "a deleted font's blob may never have been uploaded")
    }

    // MARK: 阅读背景

    private func background(at seconds: TimeInterval, portrait: String? = nil, landscape: String? = nil) -> SyncedReaderBackground {
        SyncedReaderBackground(mode: "image", color: "ffffff", portraitHash: portrait, landscapeHash: landscape,
                               updatedAt: date(seconds))
    }

    func testBackgroundUsesRemoteOnlyWhenStrictlyNewer() {
        let local = background(at: 5)
        XCTAssertEqual(WebDAVSyncPlanner.planBackground(local: local, remote: nil), .useLocal)
        XCTAssertEqual(WebDAVSyncPlanner.planBackground(local: local, remote: background(at: 4)), .useLocal)
        XCTAssertEqual(WebDAVSyncPlanner.planBackground(local: local, remote: background(at: 5)), .useLocal)
        XCTAssertEqual(WebDAVSyncPlanner.planBackground(local: local, remote: background(at: 6, portrait: "p", landscape: "l")),
                       .useRemote(downloadHashes: ["p", "l"]))
        XCTAssertEqual(WebDAVSyncPlanner.planBackground(local: local, remote: background(at: 6, landscape: "l")),
                       .useRemote(downloadHashes: ["l"]))
    }

    // MARK: 导入字体

    private func font(_ hash: String, format: String = "ttf", deleted: Bool = false) -> SyncedImportedFont {
        SyncedImportedFont(hash: hash, format: format, deleted: deleted, updatedAt: date(1))
    }

    func testFontsUploadLocalFilesDownloadMissingAndSkipDeleted() throws {
        let fonts = ["b": font("b"), "a": font("a", format: "otf"), "c": font("c", format: "ttc"), "d": font("d", deleted: true)]
        let plan = try WebDAVSyncPlanner.planFonts(fonts, localHashes: ["a", "d"])
        XCTAssertEqual(plan, FontSyncPlan(uploads: ["a"], downloads: ["b", "c"]))
    }

    func testInvalidFontRecordRejectsWholePlan() {
        XCTAssertThrowsError(try WebDAVSyncPlanner.planFonts(["a": font("a"), "b": font("b", format: "woff")], localHashes: []))
        XCTAssertThrowsError(try WebDAVSyncPlanner.planFonts(["a": font("other")], localHashes: []))
        XCTAssertThrowsError(try WebDAVSyncPlanner.planFonts(["a": font("a", format: "exe", deleted: true)], localHashes: []),
                             "deleted records are still validated")
    }
}
