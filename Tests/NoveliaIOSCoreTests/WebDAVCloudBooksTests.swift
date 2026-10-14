import CryptoKit
import Foundation
import XCTest
@testable import NoveliaIOSCore

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 只提供下载的远端替身。
private final class BlobRemote: WebDAVRemote {
    let directory: URL
    var blobs: [String: Data] = [:]
    var failing: String?
    var handedOut: [URL] = []
    init(directory: URL) { self.directory = directory }

    func seed(_ text: String, as filename: String) -> WebDAVAsset {
        let data = Data(text.utf8)
        blobs[sha256(data)] = data
        return WebDAVAsset(filename: filename, hash: sha256(data))
    }

    func verifyConnection() async throws {}
    func prepareFolders() async throws {}
    func fetchManifest() async throws -> (WebDAVManifest, String?, Bool) { (WebDAVManifest(), nil, false) }
    func putManifest(_ manifest: WebDAVManifest, etag: String?, existed: Bool) async throws {}
    func uploadBlob(_ file: URL, hash: String) async throws {}
    func deleteBlob(_ hash: String) async throws {}
    func downloadBlob(_ hash: String) async throws -> URL {
        guard hash != failing, let data = blobs[hash] else { throw WebDAVSyncError.unexpectedResponse(404) }
        let url = directory.appendingPathComponent("blob-\(UUID())")
        try data.write(to: url)
        handedOut.append(url)
        return url
    }
}

/// 云端书籍的本机记录、封面缓存与按需下载。
@MainActor
final class WebDAVCloudBooksTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WebDAVCloudBooksTests-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func book(cover: WebDAVAsset?) -> WebDAVBook<LocalWenkuEPUB> {
        let record = LocalWenkuEPUB(id: UUID(), title: "文库", filename: "book.epub", addedAt: Date(timeIntervalSince1970: 1),
                                    coverFilename: cover?.filename)
        return WebDAVBook(record: record, assets: [WebDAVAsset(filename: "book.epub", hash: String(repeating: "a", count: 64))]
                          + (cover.map { [$0] } ?? []))
    }

    func testStorePersistsRecordsAndCachesCoversUntilUnused() throws {
        let storeDirectory = directory.appendingPathComponent("store")
        let coverData = Data("cover".utf8)
        let coverFile = directory.appendingPathComponent("cover-temp")
        try coverData.write(to: coverFile)
        let cover = WebDAVAsset(filename: "cover.jpg", hash: sha256(coverData))
        let withCover = book(cover: cover)
        let plain = book(cover: nil)

        let store = CloudBookStore(directory: storeDirectory)
        try store.replaceCloudBooks(web: [], wenku: [withCover, plain], covers: [cover.hash: coverFile])
        let coverURL = try XCTUnwrap(store.coverURL(for: withCover))
        XCTAssertEqual(try Data(contentsOf: coverURL), coverData)
        XCTAssertNil(store.coverURL(for: plain), "books without a cover have none")
        XCTAssertEqual(store.cloudBookKeys, ["wenku:\(withCover.record.id.uuidString)", "wenku:\(plain.record.id.uuidString)"])

        let reopened = CloudBookStore(directory: storeDirectory)
        XCTAssertEqual(reopened.wenkuBooks, [withCover, plain])
        XCTAssertNotNil(reopened.cachedCover(hash: cover.hash))

        reopened.remove(wenkuID: withCover.record.id)
        XCTAssertEqual(reopened.wenkuBooks, [plain])
        XCTAssertNil(reopened.cachedCover(hash: cover.hash), "covers no longer used are deleted")
        XCTAssertNil(reopened.cachedCover(hash: "../index.json"))
    }

    func testDownloaderFetchesEveryFileAndCleansUpOnFailure() async throws {
        let remote = BlobRemote(directory: directory)
        let main = remote.seed("book", as: "book.epub")
        let cover = remote.seed("cover", as: "cover.jpg")
        var reported: [Double] = []
        let files = try await WebDAVCloudBookDownloader.download([main, cover], from: remote) {
            reported.append(Double($0) / Double($1))
        }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(files["book.epub"])), Data("book".utf8))
        XCTAssertEqual(reported, [0.5, 1])
        files.values.forEach { try? FileManager.default.removeItem(at: $0) }

        remote.handedOut = []
        remote.failing = cover.hash
        do {
            _ = try await WebDAVCloudBookDownloader.download([main, cover], from: remote)
            XCTFail("expected failure")
        } catch {}
        XCTAssertFalse(remote.handedOut.isEmpty)
        XCTAssertTrue(remote.handedOut.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                      "partial downloads are deleted")
    }

    func testDownloaderRejectsUnsafeFilenames() async {
        let remote = BlobRemote(directory: directory)
        let unsafe = WebDAVAsset(filename: "../escape.epub", hash: remote.seed("x", as: "x").hash)
        do {
            _ = try await WebDAVCloudBookDownloader.download([unsafe], from: remote)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? WebDAVSyncError, .invalidAsset)
        }
        XCTAssertTrue(remote.handedOut.isEmpty)
    }
}
