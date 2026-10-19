import CryptoKit
import Foundation
import XCTest
@testable import NoveliaIOSCore

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let booksAndTags = WebDAVSyncOptions(books: true, tags: true, backgrounds: false, fonts: false)
private let everything = WebDAVSyncOptions(books: true, tags: true, backgrounds: true, fonts: true)

private func roundTrip(_ manifest: WebDAVManifest) throws -> WebDAVManifest {
    try JSONDecoder().decode(WebDAVManifest.self, from: JSONEncoder().encode(manifest))
}

private func contents(_ files: [String: URL]) -> [String: Data] {
    files.mapValues { (try? Data(contentsOf: $0)) ?? Data() }
}

/// 记录各替身的调用顺序。
@MainActor
private final class EventLog {
    var events: [String] = []
    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
}

/// 内存中的远端：清单经 JSON 往返，blob 按内容哈希保存。
@MainActor
private final class FakeRemote: WebDAVRemote {
    struct Put { let etag: String?; let existed: Bool }

    private let log: EventLog
    private let directory: URL
    var manifest: WebDAVManifest?
    var blobs: [String: Data] = [:]
    var puts: [Put] = []
    var putError: WebDAVSyncError?
    /// 依次只失败一次的写入错误。
    var putErrors: [WebDAVSyncError] = []
    /// 模拟不返回 ETag 的服务器。
    var omitsETag = false
    /// 为 false 时模拟不支持列目录的服务器。
    var listsBlobs = true
    var onFetch: (() -> Void)?
    var onDelete: ((String) throws -> Void)?
    var listError: WebDAVSyncError?
    var onDownload: (() -> Void)?
    var onPut: (() -> Void)?
    var onDidPut: (() -> Void)?
    var errorAfterPut: WebDAVSyncError?
    /// 交给引擎的临时文件；引擎负责删除。
    var handedOut: [URL] = []

    init(log: EventLog, directory: URL) {
        self.log = log
        self.directory = directory
    }

    func seed(_ text: String, as filename: String) -> WebDAVAsset {
        let data = Data(text.utf8)
        blobs[sha256(data)] = data
        return WebDAVAsset(filename: filename, hash: sha256(data))
    }

    func verifyConnection() async throws { log.events.append("remote.verify") }
    func prepareFolders() async throws { log.events.append("remote.prepare") }

    func fetchManifest() async throws -> (WebDAVManifest, String?, Bool) {
        log.events.append("remote.fetch")
        onFetch?()
        guard let manifest else { return (WebDAVManifest(), nil, false) }
        return (try roundTrip(manifest), omitsETag ? nil : "\"v\(puts.count)\"", true)
    }

    func putManifest(_ manifest: WebDAVManifest, etag: String?, existed: Bool) async throws {
        log.events.append("remote.put")
        puts.append(Put(etag: etag, existed: existed))
        if let putError { throw putError }
        if !putErrors.isEmpty { throw putErrors.removeFirst() }
        onPut?()
        self.manifest = try roundTrip(manifest)
        onDidPut?()
        if let errorAfterPut { throw errorAfterPut }
    }

    func uploadBlob(_ file: URL, hash: String) async throws {
        log.events.append("remote.upload")
        let data = try Data(contentsOf: file)
        XCTAssertEqual(sha256(data), hash, "blobs are stored under their content hash")
        blobs[hash] = data
    }

    func listBlobs() async throws -> Set<String>? {
        log.events.append("remote.list")
        if let listError { throw listError }
        return listsBlobs ? Set(blobs.keys) : nil
    }

    func deleteBlob(_ hash: String) async throws {
        log.events.append("remote.deleteBlob")
        try onDelete?(hash)
        blobs[hash] = nil
    }

    func downloadBlob(_ hash: String) async throws -> URL {
        log.events.append("remote.download")
        guard let data = blobs[hash] else { throw WebDAVSyncError.missingBlob }
        let url = directory.appendingPathComponent("download-\(UUID())")
        try data.write(to: url)
        handedOut.append(url)
        onDownload?()
        return url
    }
}

@MainActor
private final class FakeLibrary<Record: SyncableBook>: SyncBookLibrary {
    private let log: EventLog
    private let name: String
    var books: [Record] = []
    var prepareError: Error?
    var removalError: Error?
    func prepareForSync() async throws { if let prepareError { throw prepareError } }
    var files: [Record.ID: [String: URL]] = [:]
    /// 恢复或替换时收到的文件内容（引擎随后会删除临时文件）。
    var received: [Record.ID: [String: Data]] = [:]

    init(_ name: String, log: EventLog) {
        self.name = name
        self.log = log
    }

    func syncFiles(for book: Record) -> [String: URL] { files[book.id] ?? [:] }

    func restoreFromSync(_ book: Record, files: [String: URL]) throws {
        log.events.append("\(name).restore")
        books.append(book)
        received[book.id] = contents(files)
        // 与真实书库一样保留恢复的文件，之后的同步可以再上传它们。
        self.files[book.id] = try files.mapValues { source in
            let kept = source.deletingLastPathComponent().appendingPathComponent("restored-\(UUID())")
            try FileManager.default.copyItem(at: source, to: kept)
            return kept
        }
    }

    func removeFromSync(_ book: Record) async throws {
        if let removalError { throw removalError }
        log.events.append("\(name).remove")
        books.removeAll { $0.id == book.id }
    }

    var appliedMetadata: [(record: Record, cover: Data?)] = []
    func applySyncedMetadata(_ book: Record, cover: URL?) throws {
        log.events.append("\(name).applyMetadata")
        appliedMetadata.append((book, cover.flatMap { try? Data(contentsOf: $0) }))
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
    }

    func replaceFromSync(_ book: Record, files: [String: URL]) throws {
        log.events.append("\(name).replace")
        books.removeAll { $0.id == book.id }
        books.append(book)
        received[book.id] = contents(files)
    }
}

@MainActor
private final class FakeLocalState: WebDAVSyncLocalState {
    private let log: EventLog
    private let directory: URL
    var readingPositions: [String: SyncedReadingPosition] = [:]
    var mergedWebBookIDs: [String]?
    var librarySeries = LibrarySeriesState()
    var appliedSeries: LibrarySeriesState?
    var blockedTags: [String: SyncedBlockedTag] = [:]
    var appliedTags: [String: SyncedBlockedTag]?
    var backgrounds: [Bool: SyncedReaderBackground] = [:]
    var appliedBackgrounds: [Bool: (value: SyncedReaderBackground, files: [String: Data])] = [:]
    var fontRecords: [String: SyncedImportedFont] = [:]
    var fontFileURLs: [String: URL] = [:]
    var appliedFonts: (records: [String: SyncedImportedFont], files: [String: Data])?
    var bookmarks: [String: ReaderBookmark] = [:]
    var bookmarkSaveError: Error?
    var appliedBookmarks: [String: ReaderBookmark]?

    func applyBookmarks(_ bookmarks: [String: ReaderBookmark]) throws {
        if let bookmarkSaveError { throw bookmarkSaveError }
        log.events.append("local.applyBookmarks")
        appliedBookmarks = bookmarks
    }

    init(log: EventLog, directory: URL) {
        self.log = log
        self.directory = directory
    }

    func mergeReadingPositions(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {
        log.events.append("local.mergePositions")
        mergedWebBookIDs = webBooks.map(\.id)
        readingPositions = SyncedReadingPosition.merged(readingPositions, remote)
    }

    func applyLibrarySeries(_ series: LibrarySeriesState) {
        log.events.append("local.applySeries")
        appliedSeries = series
    }

    func applyBlockedTags(_ tags: [String: SyncedBlockedTag]) {
        log.events.append("local.applyTags")
        appliedTags = tags
    }

    func background(dark: Bool) throws -> SyncedReaderBackground {
        backgrounds[dark] ?? SyncedReaderBackground(mode: "default", color: "", portraitHash: nil, landscapeHash: nil,
                                                    updatedAt: .distantPast)
    }

    func backgroundImageURL(dark: Bool, landscape: Bool) -> URL {
        directory.appendingPathComponent("background-\(dark)-\(landscape)")
    }

    func isValidBackgroundImage(_ file: URL) -> Bool { (try? Data(contentsOf: file)) != Data("bad".utf8) }

    func applyBackground(_ value: SyncedReaderBackground, dark: Bool, files: [String: URL]) throws {
        log.events.append("local.applyBackground")
        appliedBackgrounds[dark] = (value, contents(files))
    }

    func fonts() throws -> [String: SyncedImportedFont] { fontRecords }
    func fontFiles() throws -> [String: URL] { fontFileURLs }

    func applyFonts(_ records: [String: SyncedImportedFont], files: [String: URL]) throws {
        log.events.append("local.applyFonts")
        appliedFonts = (records, contents(files))
    }
}

/// 记录云端书籍的替身。
@MainActor
private final class FakeCloud: SyncCloudCatalog {
    var web: [WebDAVBook<DownloadedWebNovel>] = []
    var wenku: [WebDAVBook<LocalWenkuEPUB>] = []
    var covers: [String: Data] = [:]
    var missingKeys: Set<String>?
    func setMissingFileKeys(_ keys: Set<String>) { missingKeys = keys }
    var cloudBookKeys: Set<String> {
        Set(web.map { "web:\($0.record.id)" } + wenku.map { "wenku:\($0.record.id.uuidString)" })
    }
    func cachedCover(hash: String) -> URL? { covers[hash] == nil ? nil : URL(fileURLWithPath: "/cached/\(hash)") }
    func replaceCloudBooks(web: [WebDAVBook<DownloadedWebNovel>], wenku: [WebDAVBook<LocalWenkuEPUB>],
                           covers: [String: URL]) throws {
        self.web = web
        self.wenku = wenku
        for (hash, file) in covers { self.covers[hash] = try Data(contentsOf: file) }
    }
}

/// 同步引擎的完整流程：用内存替身代替 WebDAV 服务器、书库与本机设置。
@MainActor
final class WebDAVSyncEngineTests: XCTestCase {
    private var directory: URL!
    private var log: EventLog!
    private var remote: FakeRemote!
    private var local: FakeLocalState!
    private var web: FakeLibrary<DownloadedWebNovel>!
    private var wenku: FakeLibrary<LocalWenkuEPUB>!
    private var progress: [WebDAVSyncProgress] = []
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WebDAVSyncEngineTests-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = EventLog()
        remote = FakeRemote(log: log, directory: directory)
        local = FakeLocalState(log: log, directory: directory)
        web = FakeLibrary("web", log: log)
        wenku = FakeLibrary("wenku", log: log)
        progress = []
        suiteName = "WebDAVSyncEngineTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: 辅助

    // 现有合并用例使用最近的固定事件时间，避免被三十天保留期当成历史记录裁掉。
    private let eventEpoch = Date().addingTimeInterval(-1000)
    private func date(_ seconds: TimeInterval) -> Date { eventEpoch.addingTimeInterval(seconds) }

    private func file(_ text: String) -> URL {
        let url = directory.appendingPathComponent("local-\(UUID())")
        try? Data(text.utf8).write(to: url)
        return url
    }

    private func webBook(_ id: String, at seconds: TimeInterval) -> DownloadedWebNovel {
        DownloadedWebNovel(
            novel: Novel(id: id, title: "网络小说\(id)", author: "", summary: "", genres: [], chapters: [], accent: .plum),
            fileFilename: "\(id).epub", downloadedAt: date(seconds),
            translationSource: nil, downloadMode: nil, fileFormat: nil)
    }

    private func wenkuBook(_ id: UUID = UUID(), at seconds: TimeInterval, cover: String? = nil) -> LocalWenkuEPUB {
        LocalWenkuEPUB(id: id, title: "文库", filename: "\(id).epub", addedAt: date(seconds), coverFilename: cover)
    }

    private func addLocal(_ book: DownloadedWebNovel, text: String) {
        web.books.append(book)
        web.files[book.id] = [book.fileFilename: file(text)]
    }

    private func addLocal(_ book: LocalWenkuEPUB, text: String, cover: String? = nil) {
        wenku.books.append(book)
        var files = [book.filename: file(text)]
        if let name = book.coverFilename, let cover { files[name] = file(cover) }
        wenku.files[book.id] = files
    }

    private func remoteManifest(_ edit: (inout WebDAVManifest) -> Void) {
        var manifest = remote.manifest ?? WebDAVManifest()
        edit(&manifest)
        remote.manifest = manifest
    }

    private func run(_ options: WebDAVSyncOptions = booksAndTags) async throws -> Int {
        let engine = WebDAVSyncEngine(remote: remote, local: local, web: web, wenku: wenku,
                                      options: options, defaults: defaults) { [weak self] in self?.progress.append($0) }
        return try await engine.run()
    }

    private func runCloud(_ cloud: FakeCloud, _ options: WebDAVSyncOptions = booksAndTags) async throws -> Int {
        let engine = WebDAVSyncEngine(remote: remote, local: local, web: web, wenku: wenku, options: options,
                                      defaults: defaults, cloud: cloud) { [weak self] in self?.progress.append($0) }
        return try await engine.run()
    }

    private func assertFails(with expected: WebDAVSyncError, _ options: WebDAVSyncOptions = booksAndTags,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await run(options)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WebDAVSyncError, expected, file: file, line: line)
        }
    }

    /// 进度总数包含每个传输的文件加上写清单这一步，结束时全部完成。
    private func assertProgressCompleted(totalUnits: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(progress.last?.totalUnits, totalUnits, file: file, line: line)
        XCTAssertEqual(progress.last?.completedUnits, totalUnits, file: file, line: line)
        XCTAssertFalse(progress.contains { $0.completedUnits > $0.totalUnits }, "never over 100%", file: file, line: line)
    }

    private func assertDownloadsDeleted(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(remote.handedOut.isEmpty, "the scenario downloaded something", file: file, line: line)
        for url in remote.handedOut {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent, file: file, line: line)
        }
    }

    // MARK: 书籍

    func testFirstSyncUploadsLocalBooksAndCreatesManifest() async throws {
        let novel = webBook("a", at: 10)
        addLocal(novel, text: "web a")
        let book = wenkuBook(at: 20, cover: "cover.jpg")
        addLocal(book, text: "wenku", cover: "jpg")

        let imported = try await run()
        XCTAssertEqual(imported, 0)

        let manifest = try XCTUnwrap(remote.manifest)
        XCTAssertEqual(manifest.webBooks.map(\.record), [novel])
        XCTAssertEqual(manifest.webBooks.first?.assets,
                       [WebDAVAsset(filename: "a.epub", hash: sha256(Data("web a".utf8)), size: 5)])
        XCTAssertEqual(manifest.wenkuBooks.map(\.record), [book])
        XCTAssertEqual(manifest.wenkuBooks.first?.assets.map(\.filename), ["cover.jpg", book.filename].sorted())
        XCTAssertEqual(remote.blobs.count, 3)
        XCTAssertEqual(remote.puts.map(\.existed), [false])
        XCTAssertEqual(remote.puts.map(\.etag), [nil])
        assertProgressCompleted(totalUnits: 4)
        XCTAssertEqual(progress.last?.detail, "同步完成")
    }

    /// 没有任何改动的再次同步只读取清单，不写入，以减少对有频率限制的服务器的请求。
    func testUnchangedSyncDoesNotRewriteManifest() async throws {
        addLocal(webBook("a", at: 10), text: "web a")
        local.blockedTags["标签"] = SyncedBlockedTag(blocked: true, updatedAt: date(5))
        _ = try await run()
        XCTAssertEqual(remote.puts.count, 1)
        log.events = []
        _ = try await run()
        XCTAssertEqual(remote.puts.count, 1, "nothing changed, nothing written")
        XCTAssertEqual(log.events.filter { $0.hasPrefix("remote.") && $0 != "remote.verify" && $0 != "remote.prepare" },
                       ["remote.fetch"])
        local.blockedTags["标签"] = SyncedBlockedTag(blocked: false, updatedAt: date(6))
        _ = try await run()
        XCTAssertEqual(remote.puts.count, 2, "a real change is still written")
    }

    // MARK: 云端书籍

    /// 本机没有的书只记为云端书籍：不下载书籍文件，EPUB 封面只下载一次；TXT 与无封面的书不下载任何文件。
    func testCloudCatalogRecordsRemoteBooksWithCoversOnly() async throws {
        let novel = webBook("z", at: 10)
        let withCover = wenkuBook(at: 20, cover: "cover.jpg")
        let plain = LocalWenkuEPUB(id: UUID(), title: "TXT", filename: "plain.txt", addedAt: date(30), fileFormat: .txt)
        let cover = remote.seed("cover bytes", as: "cover.jpg")
        remoteManifest {
            $0.webBooks = [WebDAVBook(record: novel, assets: [remote.seed("web z", as: "z.epub")])]
            $0.wenkuBooks = [WebDAVBook(record: withCover, assets: [remote.seed("wenku", as: withCover.filename), cover]),
                             WebDAVBook(record: plain, assets: [remote.seed("txt", as: "plain.txt")])]
        }
        let cloud = FakeCloud()
        let added = try await runCloud(cloud)
        XCTAssertEqual(added, 3)
        XCTAssertEqual(log.count("remote.download"), 1, "only the cover is downloaded")
        XCTAssertEqual(cloud.covers[cover.hash], Data("cover bytes".utf8))
        XCTAssertEqual(cloud.web.map(\.record), [novel])
        XCTAssertEqual(cloud.wenku.map(\.record.id), [withCover.id, plain.id])
        XCTAssertTrue(web.books.isEmpty && wenku.books.isEmpty, "nothing is imported into the library")
        assertDownloadsDeleted()

        log.events = []
        let again = try await runCloud(cloud)
        XCTAssertEqual(again, 0, "already known cloud books are not counted again")
        XCTAssertEqual(log.count("remote.download"), 0, "cached covers are not downloaded again")
    }

    /// 旧清单的文件没有大小：本机有同一版本且内容一致时补上大小并写回；内容不同时不猜测。
    func testMissingSizesAreFilledFromMatchingLocalFiles() async throws {
        let same = webBook("a", at: 10)
        addLocal(same, text: "web a")
        let changed = webBook("b", at: 10)
        addLocal(changed, text: "local b")
        remoteManifest {
            $0.webBooks = [WebDAVBook(record: same, assets: [WebDAVAsset(filename: "a.epub", hash: sha256(Data("web a".utf8)))]),
                           WebDAVBook(record: webBook("b", at: 20), assets: [remote.seed("remote b", as: "b.epub")])]
        }
        _ = try await runCloud(FakeCloud())
        let books = try XCTUnwrap(remote.manifest?.webBooks)
        XCTAssertEqual(books.first { $0.record.id == "a" }?.assets.first?.size, 5)
        XCTAssertNil(books.first { $0.record.id == "b" }?.assets.first?.size, "a different version is not measured")
        XCTAssertEqual(log.count("remote.download") + log.count("remote.upload"), 0, "no network transfer for sizes")
    }

    // MARK: 云端删除

    /// 删除书目并记录墓碑，清单写入成功后立即删除不再被引用的文件，仍被其他书引用的文件保留。
    func testDeleterRemovesBooksAndUnreferencedBlobsAndRecordsDeletion() async throws {
        let shared = remote.seed("shared", as: "a.epub")
        let only = remote.seed("only", as: "b.epub")
        remoteManifest {
            $0.webBooks = [WebDAVBook(record: webBook("a", at: 10), assets: [shared]),
                           WebDAVBook(record: webBook("b", at: 10), assets: [only]),
                           WebDAVBook(record: webBook("c", at: 10), assets: [WebDAVAsset(filename: "c.epub", hash: shared.hash)])]
            $0.positions = ["web:a": SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: date(1)),
                            "web:c": SyncedReadingPosition(chapterIndex: 2, fraction: nil, updatedAt: date(1))]
        }
        let removed = try await WebDAVCloudBookDeleter.delete(["web:a", "web:b"], from: remote, at: date(100))
        XCTAssertEqual(removed, 2)
        let manifest = try XCTUnwrap(remote.manifest)
        XCTAssertEqual(manifest.webBooks.map(\.record.id), ["c"])
        XCTAssertEqual(manifest.deletedBooks, ["web:a": date(100), "web:b": date(100)])
        XCTAssertEqual(Set(manifest.positions.keys), ["web:c"])
        XCTAssertNil(remote.blobs[only.hash], "file no longer referenced is deleted after the manifest commit")
        XCTAssertNotNil(remote.blobs[shared.hash], "file still used by another book is kept")
        XCTAssertEqual(log.count("remote.deleteBlob"), 1)
        XCTAssertEqual(remote.puts.last?.etag, "\"v0\"", "manifest write is conditional")
    }

    private func runRetrying(_ cloud: FakeCloud? = nil, verifiesBlobs: Bool = false) async throws -> WebDAVSyncRunResult {
        try await WebDAVSyncEngine.runRetryingConcurrentChange {
            WebDAVSyncEngine(remote: remote, local: local, web: web, wenku: wenku, options: booksAndTags,
                             defaults: defaults, cloud: cloud, verifiesBlobs: verifiesBlobs) { [weak self] in self?.progress.append($0) }
        }
    }

    /// 服务器上被手动删除的 blob：手动同步核对后由本机补传；自动同步不核对、不多发请求。
    func testManualSyncReuploadsBlobsMissingFromServer() async throws {
        addLocal(webBook("a", at: 10), text: "local a")
        _ = try await runRetrying(FakeCloud())
        let hash = try XCTUnwrap(remote.manifest?.webBooks.first?.assets.first?.hash)
        remote.blobs[hash] = nil

        let automatic = try await runRetrying(FakeCloud())
        XCTAssertNil(remote.blobs[hash], "automatic sync trusts the manifest")
        XCTAssertEqual(automatic.repairedBlobs, 0)
        XCTAssertEqual(log.count("remote.list"), 0)

        let manual = try await runRetrying(FakeCloud(), verifiesBlobs: true)
        XCTAssertEqual(remote.blobs[hash], Data("local a".utf8), "the local copy is uploaded again")
        XCTAssertEqual(manual.repairedBlobs, 1)
        XCTAssertEqual(manual.unrepairedBlobs, 0)
        let again = try await runRetrying(FakeCloud(), verifiesBlobs: true)
        XCTAssertEqual(again.repairedBlobs, 0, "nothing left to repair")
    }

    /// 本机没有的书缺文件时无法补传：同步照常完成并报告数量；缺失的封面不让同步失败。
    func testMissingBlobsWithoutLocalCopiesAreReportedNotFatal() async throws {
        let cover = LocalWenkuEPUB(id: UUID(), title: "封面书", filename: "c.epub", addedAt: date(10), coverFilename: "c.jpg")
        let book = remote.seed("cloud only", as: "c.epub"), image = remote.seed("cover", as: "c.jpg")
        remoteManifest { $0.wenkuBooks = [WebDAVBook(record: cover, assets: [book, image])] }
        remote.blobs[book.hash] = nil
        remote.blobs[image.hash] = nil
        let cloud = FakeCloud()
        let result = try await runRetrying(cloud, verifiesBlobs: true)
        XCTAssertEqual(result.unrepairedBlobs, 2)
        XCTAssertEqual(cloud.wenku.map(\.record.id), [cover.id], "the book still appears as a cloud book")
        XCTAssertEqual(cloud.missingKeys, ["wenku:\(cover.id.uuidString)"], "the library can mark the book")
        XCTAssertEqual(result.missingCloudBookTitles, ["封面书"])
        let unverified = FakeCloud()
        _ = try await runRetrying(unverified)
        XCTAssertNil(unverified.missingKeys, "automatic sync leaves existing marks alone")

        remote.listsBlobs = false
        let unsupported = try await runRetrying(FakeCloud(), verifiesBlobs: true)
        XCTAssertEqual(unsupported.unrepairedBlobs, 0, "without a listing nothing is assumed missing")
    }

    /// 清单写入冲突时重新读取并重跑：另一台设备在两次读取之间写入的书与本机上传都保留，已恢复的书不重复导入。
    func testSyncRetriesAfterConcurrentChangeWithoutDuplicatingWork() async throws {
        addLocal(webBook("local", at: 10), text: "local")
        remoteManifest { $0.webBooks = [WebDAVBook(record: webBook("r", at: 10), assets: [remote.seed("r", as: "r.epub")])] }
        remote.putErrors = [.concurrentChange]
        let result = try await runRetrying()
        XCTAssertEqual(result.imported, 1, "the book restored before the conflict is counted once")
        XCTAssertEqual(log.count("web.restore"), 1)
        XCTAssertEqual(log.count("remote.fetch"), 2, "the manifest is read again before retrying")
        XCTAssertEqual(remote.puts.count, 2)
        XCTAssertEqual(Set(remote.manifest?.webBooks.map(\.record.id) ?? []), ["local", "r"])
    }

    func testUnreadableLocalIndexStopsBeforeAnyRemoteAccess() async {
        web.prepareError = CocoaError(.fileReadCorruptFile)
        do { _ = try await run(); XCTFail("unloaded library cannot be treated as empty") } catch {}
        XCTAssertTrue(log.events.isEmpty)
    }

    func testLocalDeletionFailureAfterRemoteCommitKeepsBookAndCanRetry() async throws {
        let book = webBook("a", at: 10)
        addLocal(book, text: "a")
        remoteManifest { $0.deletedBooks = ["web:a": date(50)] }
        web.removalError = CocoaError(.fileWriteOutOfSpace)
        do { _ = try await run(); XCTFail("local deletion failure cannot report success") } catch {}
        XCTAssertEqual(web.books, [book])
        XCTAssertEqual(remote.manifest?.deletedBooks?["web:a"], date(50))
        web.removalError = nil
        _ = try await run()
        XCTAssertTrue(web.books.isEmpty)
    }

    func testReadingChangeWhileManifestIsBeingWrittenRemainsPending() async throws {
        let book = webBook("a", at: 10)
        addLocal(book, text: "a")
        local.readingPositions = ["web:a": SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: date(10))]
        let before = WebDAVAutoSyncPolicy.fingerprint(local: local, web: web, wenku: wenku, options: booksAndTags)
        remote.onPut = { [self] in
            local.readingPositions["web:a"] = SyncedReadingPosition(chapterIndex: 5, fraction: nil, updatedAt: date(100))
        }
        _ = try await run()
        XCTAssertEqual(remote.manifest?.positions["web:a"]?.chapterIndex, 1)
        XCTAssertEqual(local.readingPositions["web:a"]?.chapterIndex, 5)
        let after = WebDAVAutoSyncPolicy.fingerprint(local: local, web: web, wenku: wenku, options: booksAndTags)
        XCTAssertNil(WebDAVAutoSyncPolicy.acknowledgedFingerprint(before: before, after: after))
        remote.onPut = nil
        _ = try await run()
        XCTAssertEqual(remote.manifest?.positions["web:a"]?.chapterIndex, 5)
    }

    func testSyncRetryKeepsLocalCopiesUntilAManifestWriteSucceeds() async throws {
        addLocal(webBook("a", at: 10), text: "a")
        remoteManifest { $0.deletedBooks = ["web:a": date(50)] }
        remote.putErrors = [.concurrentChange]
        let result = try await runRetrying(FakeCloud())
        XCTAssertEqual(result.removedLocal, 1)
        XCTAssertEqual(log.count("web.remove"), 1, "deletion is applied once, after the successful write")
    }

    func testSyncRetryGivesUpAfterRepeatedConflicts() async {
        remote.putError = .concurrentChange
        do {
            _ = try await runRetrying(FakeCloud())
            XCTFail("expected failure")
        } catch WebDAVSyncError.concurrentChange {
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(remote.puts.count, 3)
    }

    func testOtherErrorsAreNotRetried() async {
        remote.putError = .unexpectedResponse(500)
        do {
            _ = try await runRetrying(FakeCloud())
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(remote.puts.count, 1)
    }

    func testReportsServersWithoutManifestETag() async throws {
        let first = try await runRetrying(FakeCloud())
        XCTAssertFalse(first.lacksETag, "first manifest write has nothing to compare")
        let withETag = try await runRetrying(FakeCloud())
        XCTAssertFalse(withETag.lacksETag)
        remote.omitsETag = true
        let withoutETag = try await runRetrying(FakeCloud())
        XCTAssertTrue(withoutETag.lacksETag)
    }

    private func bookmark(_ key: String, at seconds: TimeInterval, deleted: Bool? = nil) -> ReaderBookmark {
        ReaderBookmark(id: UUID(), bookKey: key, chapterIndex: 1, chapterProgression: 0.5, chapterTitle: "章",
                       snippet: "片段", createdAt: date(seconds), updatedAt: date(seconds), deleted: deleted)
    }

    /// 书签随书籍同步：两端按 ID 合并（较新者胜，含删除），只上传清单中书籍的书签；清单写入后才套用到本机。
    func testBookmarkPersistenceFailurePropagatesAfterRemoteCommitAndRetryRecovers() async throws {
        local.bookmarkSaveError = CocoaError(.fileWriteUnknown)
        let book = wenkuBook(at: 10)
        addLocal(book, text: "content")
        let mark = bookmark("epub:" + FileContentHash.sha256(Data("content".utf8)), at: 10)
        local.bookmarks = [mark.id.uuidString: mark]
        do {
            _ = try await run()
            XCTFail("Local persistence failure must not report success")
        } catch { XCTAssertNil(local.appliedBookmarks) }
        local.bookmarkSaveError = nil
        _ = try await run()
        XCTAssertNotNil(local.appliedBookmarks)
    }

    func testBookmarksMergeForBooksInManifestOnly() async throws {
        let book = wenkuBook(at: 10)
        addLocal(book, text: "local book")
        _ = try await run()
        let hash = try XCTUnwrap(remote.manifest?.wenkuBooks.first?.assets.first?.hash)
        let mine = bookmark("epub:\(hash)", at: 20)
        let orphan = bookmark("epub:" + String(repeating: "0", count: 64), at: 20)
        var theirs = bookmark("epub:\(hash)", at: 30)
        let invalid = ReaderBookmark(id: UUID(), bookKey: "web:x", chapterIndex: 0, chapterProgression: 0, chapterTitle: nil,
                                     snippet: "", createdAt: date(1), updatedAt: date(1))
        local.bookmarks = [mine.id.uuidString: mine, orphan.id.uuidString: orphan]
        remoteManifest { $0.bookmarks = [theirs.id.uuidString: theirs, invalid.id.uuidString: invalid] }
        _ = try await run()
        XCTAssertEqual(Set(remote.manifest?.bookmarks.map { Array($0.keys) } ?? []), [mine.id.uuidString, theirs.id.uuidString],
                       "orphans stay local, invalid remote records are dropped")
        XCTAssertEqual(local.appliedBookmarks?[theirs.id.uuidString], theirs)
        XCTAssertLessThan(log.events.lastIndex(of: "remote.put") ?? .max, log.events.lastIndex(of: "local.applyBookmarks") ?? -1)

        // 另一台设备删除了书签：较新的墓碑覆盖本机。
        local.bookmarks = remote.manifest?.bookmarks ?? [:]
        theirs.deleted = true
        theirs.updatedAt = date(40)
        remoteManifest { $0.bookmarks?[theirs.id.uuidString] = theirs }
        _ = try await run()
        XCTAssertEqual(local.appliedBookmarks?[theirs.id.uuidString]?.isDeleted, true)
    }

    /// 同一文件版本的书：书库信息按修改时间合并，较新的远端信息（含封面）先套用到本机，再写回合并后的记录。
    func testEditedMetadataMergesForTheSameFileVersion() async throws {
        var mine = wenkuBook(at: 10)
        addLocal(mine, text: "book")
        _ = try await run()
        let file = try XCTUnwrap(remote.manifest?.wenkuBooks.first?.assets.first)
        var theirs = mine
        theirs.title = "其他设备改的书名"
        theirs.coverFilename = "cover.jpg"
        theirs.metadataUpdatedAt = date(20)
        let cover = remote.seed("new cover", as: "cover.jpg")
        remoteManifest { $0.wenkuBooks = [WebDAVBook(record: theirs, assets: [file, cover])] }
        _ = try await run()
        XCTAssertEqual(wenku.appliedMetadata.first?.record.title, "其他设备改的书名")
        XCTAssertEqual(wenku.appliedMetadata.first?.cover, Data("new cover".utf8))
        XCTAssertEqual(remote.manifest?.wenkuBooks.first?.record.title, "其他设备改的书名", "the merged record is written back")
        XCTAssertEqual(log.count("wenku.replace"), 0, "the book file is not downloaded again")

        // 本机修改较新：不套用远端，清单写回本机的信息。
        mine = wenku.books[0]
        mine.title = "本机更新的书名"
        mine.metadataUpdatedAt = date(30)
        wenku.books = [mine]
        _ = try await run()
        XCTAssertEqual(wenku.appliedMetadata.count, 1)
        XCTAssertEqual(remote.manifest?.wenkuBooks.first?.record.title, "本机更新的书名")
    }

    /// 远端较新检查之后下载封面，本机在网络等待期间的编辑仍须保留并上传。
    func testMetadataEditedLocallyDuringCoverDownloadWinsOverRemoteSnapshot() async throws {
        let mine = wenkuBook(at: 10)
        addLocal(mine, text: "book")
        _ = try await run()
        let file = try XCTUnwrap(remote.manifest?.wenkuBooks.first?.assets.first)
        var theirs = mine
        theirs.title = "远端旧快照"
        theirs.metadataUpdatedAt = date(20)
        theirs.coverFilename = "cover.jpg"
        let cover = remote.seed("remote cover", as: "cover.jpg")
        remoteManifest { $0.wenkuBooks = [WebDAVBook(record: theirs, assets: [file, cover])] }
        remote.onDownload = { [self] in
            wenku.books[0].title = "网络等待期间的新编辑"
            wenku.books[0].metadataUpdatedAt = date(30)
        }
        _ = try await run()
        XCTAssertTrue(wenku.appliedMetadata.isEmpty)
        XCTAssertEqual(wenku.books.first?.title, "网络等待期间的新编辑")
        XCTAssertEqual(remote.manifest?.wenkuBooks.first?.record.title, "网络等待期间的新编辑")
        XCTAssertEqual(remote.manifest?.wenkuBooks.first?.record.metadataUpdatedAt, date(30))
    }

    /// 写清单的操作先到先执行，互不交错。
    func testManifestWriteGateSerializesInArrivalOrder() async {
        let gate = WebDAVManifestWriteGate()
        var order: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await gate.run {
                order.append("sync.start")
                await withCheckedContinuation { release = $0 }
                order.append("sync.end")
            }
        }
        while release == nil { await Task.yield() }
        XCTAssertTrue(gate.isBusy)
        let second = Task { @MainActor in await gate.run { order.append("delete") } }
        let third = Task { @MainActor in await gate.run { order.append("sync2") } }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(order, ["sync.start"], "later operations wait for the running one")
        release?.resume()
        await first.value; await second.value; await third.value
        XCTAssertEqual(order, ["sync.start", "sync.end", "delete", "sync2"])
        XCTAssertFalse(gate.isBusy)
    }

    func testDeleterRetriesAfterConcurrentChange() async throws {
        remoteManifest { $0.webBooks = [WebDAVBook(record: webBook("a", at: 10), assets: [remote.seed("a", as: "a.epub")])] }
        remote.putErrors = [.concurrentChange]
        let removed = try await WebDAVCloudBookDeleter.delete(["web:a"], from: remote, at: date(100))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(remote.puts.count, 2)
        XCTAssertTrue(remote.manifest?.webBooks.isEmpty ?? false)
    }

    func testDeleterRecognizesCommittedDeletionAfterReadbackConflict() async throws {
        remoteManifest { $0.webBooks = [WebDAVBook(record: webBook("a", at: 10), assets: [remote.seed("a", as: "a.epub")])] }
        remote.errorAfterPut = .concurrentChange
        let removed = try await WebDAVCloudBookDeleter.delete(["web:a"], from: remote, at: date(100))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(remote.puts.count, 1, "fresh committed tombstone is enough; do not write again")
        XCTAssertEqual(remote.manifest?.deletedBooks?["web:a"], date(100))
        XCTAssertEqual(remote.blobs.count, 1, "logical deletion never deletes the file")
    }

    func testDeleterDoesNotTreatReaddedBookAsCommittedDeletion() async throws {
        remoteManifest {
            $0.webBooks = [WebDAVBook(record: webBook("a", at: 110), assets: [remote.seed("a", as: "a.epub")])]
            $0.deletedBooks = ["web:a": date(100)]
        }
        let removed = try await WebDAVCloudBookDeleter.delete(["web:a"], from: remote, at: date(100))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(remote.puts.count, 1, "present books still require conditional deletion")
    }

    /// 云端删除后：其他设备的本机副本被删除且不再上传，云端旧条目不再恢复；之后重新下载的新版本照常同步并清除删除记录。
    func testDeletedBooksAreRemovedLocallyAndNotRestoredUntilReAdded() async throws {
        addLocal(webBook("a", at: 10), text: "a")
        addLocal(webBook("kept", at: 10), text: "kept")
        remoteManifest {
            $0.deletedBooks = ["web:a": date(50), "web:z": date(50)]
            $0.webBooks = [WebDAVBook(record: webBook("z", at: 20), assets: [remote.seed("z", as: "z.epub")])]
        }
        let cloud = FakeCloud()
        let engine = WebDAVSyncEngine(remote: remote, local: local, web: web, wenku: wenku, options: booksAndTags,
                                      defaults: defaults, cloud: cloud) { _ in }
        _ = try await engine.run()
        XCTAssertEqual(remote.manifest?.webBooks.map(\.record.id), ["kept"], "deleted book is not uploaded, old entry dropped")
        XCTAssertTrue(cloud.web.isEmpty, "deleted book is not shown as a cloud book")
        XCTAssertEqual(web.books.map(\.id), ["kept"], "local copy of the deleted version is removed")
        XCTAssertEqual(engine.removedLocalCount, 1)
        XCTAssertLessThan(log.events.firstIndex(of: "remote.put") ?? .max, log.events.firstIndex(of: "web.remove") ?? -1,
                          "local copies are removed only after the manifest is written")

        addLocal(webBook("a", at: 60), text: "a again")
        _ = try await runCloud(cloud)
        XCTAssertEqual(Set(remote.manifest?.webBooks.map(\.record.id) ?? []), ["a", "kept"])
        XCTAssertEqual(web.books.map(\.id).sorted(), ["a", "kept"], "a newer copy is kept")
        XCTAssertEqual(remote.manifest?.deletedBooks, ["web:z": date(50)], "re-added book clears its deletion")
    }

    /// 本机已有的书不被远端较新版本替换，也不再下载；本机较新的书照常上传。
    func testCloudCatalogKeepsLocalCopiesAndStillUploads() async throws {
        let old = webBook("a", at: 10)
        addLocal(old, text: "local a")
        let newer = wenkuBook(at: 50)
        addLocal(newer, text: "local wenku")
        remoteManifest {
            $0.webBooks = [WebDAVBook(record: webBook("a", at: 20), assets: [remote.seed("remote a", as: "a.epub")])]
            $0.wenkuBooks = [WebDAVBook(record: wenkuBook(newer.id, at: 5), assets: [remote.seed("old", as: newer.filename)])]
        }
        let cloud = FakeCloud()
        _ = try await runCloud(cloud)
        XCTAssertEqual(log.count("remote.download"), 0)
        XCTAssertEqual(log.count("web.replace"), 0)
        XCTAssertEqual(web.books, [old])
        XCTAssertTrue(cloud.web.isEmpty, "a book that exists locally is not a cloud book")
        XCTAssertEqual(remote.manifest?.wenkuBooks.first?.record, newer, "newer local book is uploaded")
    }

    func testLocalCopiesAreKeptWhenManifestWriteFails() async {
        addLocal(webBook("a", at: 10), text: "a")
        remoteManifest { $0.deletedBooks = ["web:a": date(50)] }
        remote.putError = .concurrentChange
        do {
            _ = try await runCloud(FakeCloud())
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(web.books.map(\.id), ["a"])
    }

    func testCloudBooksAreNotUpdatedWhenManifestWriteFails() async {
        remoteManifest { $0.webBooks = [WebDAVBook(record: webBook("z", at: 10), assets: [remote.seed("z", as: "z.epub")])] }
        addLocal(webBook("a", at: 10), text: "a")
        remote.putError = .concurrentChange
        let cloud = FakeCloud()
        do {
            _ = try await runCloud(cloud)
            XCTFail("expected failure")
        } catch {}
        XCTAssertTrue(cloud.web.isEmpty)
    }

    func testTwoWaySyncRestoresReplacesAndUploads() async throws {
        addLocal(webBook("a", at: 10), text: "local a")
        addLocal(webBook("b", at: 30), text: "local b")
        let remoteOnly = wenkuBook(at: 1)
        remoteManifest {
            $0.webBooks = [
                WebDAVBook(record: webBook("a", at: 20), assets: [remote.seed("remote a", as: "a.epub")]),
                WebDAVBook(record: webBook("b", at: 5), assets: [remote.seed("old b", as: "b.epub")]),
            ]
            $0.wenkuBooks = [WebDAVBook(record: remoteOnly, assets: [remote.seed("remote wenku", as: remoteOnly.filename)])]
        }

        let imported = try await run()
        XCTAssertEqual(imported, 1, "only the remote-only book counts as restored")

        XCTAssertEqual(log.count("web.replace"), 1)
        XCTAssertEqual(web.received["a"], ["a.epub": Data("remote a".utf8)])
        XCTAssertEqual(web.books.first { $0.id == "a" }?.downloadedAt, date(20))
        XCTAssertEqual(wenku.received[remoteOnly.id], [remoteOnly.filename: Data("remote wenku".utf8)])
        let manifest = try XCTUnwrap(remote.manifest)
        XCTAssertEqual(manifest.webBooks.map(\.record.id), ["a", "b"])
        XCTAssertEqual(manifest.webBooks.map(\.record.downloadedAt), [date(20), date(30)])
        XCTAssertEqual(manifest.webBooks.last?.assets.map(\.hash), [sha256(Data("local b".utf8))])
        XCTAssertEqual(manifest.wenkuBooks.map(\.record), [remoteOnly])
        XCTAssertEqual(remote.puts.map(\.etag), ["\"v0\""])
        assertDownloadsDeleted()
    }

    /// 时间相同时仍以本机记录写回清单（保留书名等元数据修改），但清单已引用的文件不再上传或询问服务器。
    func testEqualTimestampsKeepLocalCopyWithoutTransfers() async throws {
        addLocal(webBook("a", at: 10), text: "same")
        remoteManifest { $0.webBooks = [WebDAVBook(record: webBook("a", at: 10), assets: [remote.seed("same", as: "a.epub")])] }

        _ = try await run()

        XCTAssertEqual(log.count("remote.download"), 0)
        XCTAssertEqual(log.count("web.replace") + log.count("web.restore"), 0)
        XCTAssertEqual(log.count("remote.upload"), 0)
        XCTAssertEqual(remote.manifest?.webBooks.first?.assets.map(\.hash), [sha256(Data("same".utf8))])
    }

    private var cachedHashes: [String: String] {
        defaults.dictionary(forKey: SettingsKey.WebDAV.fileHashes) as? [String: String] ?? [:]
    }

    func testUnchangedFilesReuseCachedHashAndChangedFilesAreRehashed() async throws {
        let book = webBook("a", at: 10)
        addLocal(book, text: "content")
        let url = try XCTUnwrap(web.files["a"]?["a.epub"])
        let identity = try XCTUnwrap(WebDAVFileHash.identity(of: url))
        let stale = String(repeating: "f", count: 64)
        defaults.set([identity: stale], forKey: SettingsKey.WebDAV.fileHashes)
        remoteManifest { $0.webBooks = [WebDAVBook(record: book, assets: [WebDAVAsset(filename: "a.epub", hash: stale)])] }

        _ = try await run()
        XCTAssertEqual(remote.manifest?.webBooks.first?.assets.map(\.hash), [stale],
                       "an unchanged file is not read again, so the cached hash is used")
        XCTAssertEqual(log.count("remote.upload"), 0)

        try Data("changed content".utf8).write(to: url)
        _ = try await run()
        let actual = sha256(Data("changed content".utf8))
        XCTAssertEqual(remote.manifest?.webBooks.first?.assets.map(\.hash), [actual])
        XCTAssertEqual(log.count("remote.upload"), 1)
        XCTAssertEqual(Array(cachedHashes.values), [actual], "the stale identity is pruned")
    }

    func testFailedSyncKeepsCachedHashesForBooksNotReached() async throws {
        addLocal(webBook("a", at: 10), text: "a")
        defaults.set(["other|1|1": String(repeating: "0", count: 64)], forKey: SettingsKey.WebDAV.fileHashes)
        remote.putError = .concurrentChange

        await assertFails(with: .concurrentChange)

        XCTAssertEqual(Set(cachedHashes.values), [String(repeating: "0", count: 64), sha256(Data("a".utf8))])
    }

    func testDuplicateManifestEntriesAreRestoredOnceAndWrittenBackOnce() async throws {
        remoteManifest {
            $0.webBooks = [
                WebDAVBook(record: webBook("a", at: 1), assets: [remote.seed("old", as: "a.epub")]),
                WebDAVBook(record: webBook("a", at: 2), assets: [remote.seed("new", as: "a.epub")]),
            ]
        }

        let imported = try await run()

        XCTAssertEqual(imported, 1)
        XCTAssertEqual(web.received["a"], ["a.epub": Data("new".utf8)])
        XCTAssertEqual(remote.manifest?.webBooks.map(\.record.downloadedAt), [date(2)])
    }

    func testMissingLocalFileFailsBeforeManifestWrite() async throws {
        web.books = [webBook("a", at: 10)]
        await assertFails(with: .invalidAsset)
        XCTAssertNil(remote.manifest)
        XCTAssertEqual(log.count("remote.put"), 0)
    }

    func testUnsafeRemoteFilenameAbortsAndDeletesDownloadedFiles() async throws {
        let book = wenkuBook(at: 1)
        remoteManifest {
            $0.wenkuBooks = [WebDAVBook(record: book, assets: [remote.seed("ok", as: book.filename),
                                                               remote.seed("escape", as: "../escape")])]
        }
        await assertFails(with: .invalidAsset)
        assertDownloadsDeleted()
        XCTAssertTrue(wenku.books.isEmpty)
        XCTAssertEqual(log.count("remote.put"), 0)
    }

    func testCancellationDuringDownloadDoesNotWriteManifest() async throws {
        let book = wenkuBook(at: 1)
        remoteManifest {
            $0.wenkuBooks = [WebDAVBook(record: book, assets: [remote.seed("one", as: "1.epub"), remote.seed("two", as: "2.jpg")])]
        }
        var task: Task<Int, Error>?
        remote.onDownload = { task?.cancel() }
        task = Task { try await self.run() }
        let result = await task!.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(log.count("remote.download"), 1, "stops before the next file")
        XCTAssertEqual(log.count("remote.put"), 0)
        XCTAssertTrue(wenku.books.isEmpty)
        assertDownloadsDeleted()
    }

    // MARK: 顺序与失败

    func testLocalStateIsAppliedOnlyAfterManifestIsWritten() async throws {
        addLocal(webBook("up", at: 10), text: "up")
        remoteManifest { $0.webBooks = [WebDAVBook(record: webBook("down", at: 1), assets: [remote.seed("down", as: "down.epub")])] }

        _ = try await run(everything)

        XCTAssertEqual(log.events, [
            "remote.verify", "remote.prepare", "remote.fetch",
            "remote.download", "web.restore", "local.mergePositions", "remote.upload",
            "remote.put",
            "local.applyTags", "local.applySeries", "local.applyBackground", "local.applyBackground", "local.applyFonts",
        ])
    }

    /// 写清单冲突时已恢复的书不回滚，其余本机设置保持原样，等待重新同步。
    func testConcurrentChangeKeepsRestoredBooksButAppliesNothingElse() async throws {
        remote.putError = .concurrentChange
        local.blockedTags = ["标签": SyncedBlockedTag(blocked: true, updatedAt: date(1))]
        remoteManifest { $0.webBooks = [WebDAVBook(record: webBook("down", at: 1), assets: [remote.seed("down", as: "down.epub")])] }

        await assertFails(with: .concurrentChange, everything)

        XCTAssertEqual(web.books.map(\.id), ["down"])
        XCTAssertNil(local.appliedTags)
        XCTAssertNil(local.appliedSeries)
        XCTAssertTrue(local.appliedBackgrounds.isEmpty)
        XCTAssertNil(local.appliedFonts)
    }

    // MARK: 选项与合并

    func testDisabledBooksLeaveRemoteBooksSeriesAndPositionsUntouched() async throws {
        addLocal(webBook("local", at: 10), text: "local")
        local.blockedTags = ["本机": SyncedBlockedTag(blocked: true, updatedAt: date(2))]
        var series = LibrarySeriesState()
        _ = series.createSeries(named: "远端系列", now: date(1), id: "s")
        let position = SyncedReadingPosition(chapterIndex: 3, fraction: nil, updatedAt: date(1))
        remoteManifest {
            $0.webBooks = [WebDAVBook(record: webBook("remote", at: 1), assets: [remote.seed("remote", as: "remote.epub")])]
            $0.librarySeries = series
            $0.positions = ["web:remote": position]
            $0.blockedTags = ["远端": SyncedBlockedTag(blocked: true, updatedAt: date(1))]
        }

        _ = try await run(WebDAVSyncOptions(books: false, tags: true, backgrounds: false, fonts: false))

        let manifest = try XCTUnwrap(remote.manifest)
        XCTAssertEqual(manifest.webBooks.map(\.record.id), ["remote"])
        XCTAssertEqual(manifest.librarySeries, series)
        XCTAssertEqual(manifest.positions, ["web:remote": position])
        XCTAssertEqual(Set(manifest.blockedTags.map { Array($0.keys) } ?? []), ["本机", "远端"])
        XCTAssertEqual(local.appliedTags.map { Set($0.keys) }, ["本机", "远端"])
        XCTAssertEqual(web.books.map(\.id), ["local"])
        XCTAssertNil(local.mergedWebBookIDs)
        XCTAssertNil(local.appliedSeries)
        XCTAssertEqual(log.count("remote.upload") + log.count("remote.download"), 0)
    }

    func testLegacyManifestReceivesLocalSeries() async throws {
        _ = local.librarySeries.createSeries(named: "本机系列", now: date(1), id: "s")
        local.librarySeries.assign(book: "web:a", to: "s", now: date(2))
        remote.manifest = WebDAVManifest()

        _ = try await run()

        let expected = LibrarySeriesState.merged(local.librarySeries, LibrarySeriesState())
        XCTAssertEqual(remote.manifest?.librarySeries, expected)
        XCTAssertEqual(local.appliedSeries, expected)
    }

    func testPositionsMergeRemoteAndKeepOnlySyncedBooks() async throws {
        addLocal(webBook("a", at: 10), text: "a")
        let book = wenkuBook(at: 10)
        addLocal(book, text: "wenku")
        let epubKey = "epub:\(sha256(Data("wenku".utf8)))"
        let older = SyncedReadingPosition(chapterIndex: 1, fraction: nil, updatedAt: date(1))
        let newer = SyncedReadingPosition(chapterIndex: 9, fraction: nil, updatedAt: date(5))
        local.readingPositions = ["web:a": older, "web:gone": older, epubKey: older, "txt:unknown": older]
        remoteManifest { $0.positions = ["web:a": newer] }

        _ = try await run()

        XCTAssertEqual(local.mergedWebBookIDs, ["a"])
        let positions = try XCTUnwrap(remote.manifest?.positions)
        XCTAssertEqual(Set(positions.keys), ["web:a", epubKey])
        XCTAssertEqual(positions["web:a"], newer)
    }

    // MARK: 阅读背景与字体

    private func background(at seconds: TimeInterval, portrait: String? = nil) -> SyncedReaderBackground {
        SyncedReaderBackground(mode: "image", color: "ffffff", portraitHash: portrait, landscapeHash: nil, updatedAt: date(seconds))
    }

    func testBackgroundsTakeNewerSidePerMode() async throws {
        let lightImage = Data("light image".utf8)
        try lightImage.write(to: local.backgroundImageURL(dark: false, landscape: false))
        local.backgrounds = [false: background(at: 10, portrait: sha256(lightImage)), true: background(at: 1)]
        let darkAsset = remote.seed("dark image", as: "dark")
        remoteManifest { $0.backgrounds = ["light": background(at: 5), "dark": background(at: 8, portrait: darkAsset.hash)] }

        _ = try await run(WebDAVSyncOptions(books: false, tags: false, backgrounds: true, fonts: false))

        XCTAssertEqual(remote.blobs[sha256(lightImage)], lightImage, "the newer local image is uploaded")
        XCTAssertEqual(remote.manifest?.backgrounds?["light"]?.updatedAt, date(10))
        XCTAssertEqual(remote.manifest?.backgrounds?["dark"]?.updatedAt, date(8))
        XCTAssertEqual(local.appliedBackgrounds[true]?.files, [darkAsset.hash: Data("dark image".utf8)])
        XCTAssertEqual(local.appliedBackgrounds[false]?.value.updatedAt, date(10))
        assertProgressCompleted(totalUnits: 3)
        assertDownloadsDeleted()
    }

    func testInvalidRemoteBackgroundImageFailsBeforeManifestWrite() async throws {
        let bad = remote.seed("bad", as: "dark")
        remoteManifest { $0.backgrounds = ["dark": background(at: 8, portrait: bad.hash)] }
        await assertFails(with: .invalidAsset, WebDAVSyncOptions(books: false, tags: false, backgrounds: true, fonts: false))
        XCTAssertEqual(log.count("remote.put"), 0)
        XCTAssertTrue(local.appliedBackgrounds.isEmpty)
        assertDownloadsDeleted()
    }

    func testFontsUploadLocalFilesAndDownloadRemoteOnes() async throws {
        let localFont = Data("local font".utf8), remoteFont = Data("remote font".utf8)
        let localHash = sha256(localFont), remoteHash = sha256(remoteFont)
        local.fontRecords = [localHash: SyncedImportedFont(hash: localHash, format: "ttf", deleted: false, updatedAt: date(1))]
        local.fontFileURLs = [localHash: file("local font")]
        remote.blobs[remoteHash] = remoteFont
        remoteManifest { $0.fonts = [remoteHash: SyncedImportedFont(hash: remoteHash, format: "otf", deleted: false, updatedAt: date(1))] }

        _ = try await run(WebDAVSyncOptions(books: false, tags: false, backgrounds: false, fonts: true))

        XCTAssertEqual(remote.blobs[localHash], localFont)
        XCTAssertEqual(Set(remote.manifest?.fonts.map { Array($0.keys) } ?? []), [localHash, remoteHash])
        XCTAssertEqual(local.appliedFonts.map { Set($0.records.keys) }, [localHash, remoteHash])
        XCTAssertEqual(local.appliedFonts?.files, [remoteHash: remoteFont])
        assertProgressCompleted(totalUnits: 3)
        assertDownloadsDeleted()
    }
}

extension WebDAVSyncEngineTests {
    func testImportAndDeletionTimestampComparisonUsesStrictlyNewerImport() {
        var deleted = ["web:a": date(50)]
        let equal = WebDAVDeletedBooks.apply(local: [webBook("a", at: 50)], remote: [], deleted: &deleted)
        XCTAssertTrue(equal.local.isEmpty)
        XCTAssertEqual(deleted["web:a"], date(50))
        let older = WebDAVDeletedBooks.apply(local: [webBook("a", at: 49)], remote: [], deleted: &deleted)
        XCTAssertTrue(older.local.isEmpty)
        let newer = WebDAVDeletedBooks.apply(local: [webBook("a", at: 51)], remote: [], deleted: &deleted)
        XCTAssertEqual(newer.local.count, 1)
        XCTAssertNil(deleted["web:a"])
    }
}

extension WebDAVSyncEngineTests {
    func testDeletionRetentionKeepsExact30DayBoundaryAndDropsOlderEntries() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let cutoff = now.addingTimeInterval(-WebDAVDeletedBooks.retentionInterval)
        let deleted = ["old": cutoff.addingTimeInterval(-1), "boundary": cutoff,
                       "recent": cutoff.addingTimeInterval(1), "today": now]
        XCTAssertEqual(WebDAVDeletedBooks.prune(deleted, at: now),
                       ["boundary": cutoff, "recent": cutoff.addingTimeInterval(1), "today": now])
        var empty = WebDAVManifest()
        WebDAVDeletedBooks.prune(in: &empty, at: now)
        XCTAssertNil(empty.deletedBooks, "do not add an empty optional field to older manifests")
    }

    func testContentSyncPersistsExpiredDeletionRemovalEvenWithoutBookSync() async throws {
        let now = date(1000)
        let old = now.addingTimeInterval(-WebDAVDeletedBooks.retentionInterval - 1)
        remoteManifest { $0.deletedBooks = ["web:old": old, "web:recent": self.date(900)] }
        let options = WebDAVSyncOptions(books: false, tags: false, backgrounds: false, fonts: false)
        let engine = WebDAVSyncEngine(remote: remote, local: local, web: web, wenku: wenku, options: options,
                                      defaults: defaults, now: now) { _ in }
        _ = try await engine.run()
        XCTAssertEqual(remote.manifest?.deletedBooks, ["web:recent": date(900)])
        XCTAssertEqual(remote.puts.count, 1)
        XCTAssertTrue(remote.blobs.isEmpty)
    }

    func testExpiredDeletionAllowsLongOfflineDeviceToUploadOldBook() async throws {
        let now = date(1000)
        let deletedAt = now.addingTimeInterval(-WebDAVDeletedBooks.retentionInterval - 1)
        let importedAt = deletedAt.addingTimeInterval(-100)
        var book = webBook("offline", at: 1)
        book = DownloadedWebNovel(novel: book.novel, fileFilename: book.fileFilename, downloadedAt: importedAt,
                                  translationSource: nil, downloadMode: nil, fileFormat: nil)
        addLocal(book, text: "offline copy")
        remoteManifest { $0.deletedBooks = [book.syncKey: deletedAt] }
        let engine = WebDAVSyncEngine(remote: remote, local: local, web: web, wenku: wenku, options: booksAndTags,
                                      defaults: defaults, now: now) { _ in }
        _ = try await engine.run()
        XCTAssertEqual(web.books.count, 1)
        XCTAssertEqual(remote.manifest?.webBooks.map(\.record.id), ["offline"])
        XCTAssertTrue(remote.manifest?.deletedBooks?.isEmpty == true)
    }

    func testNewDeletionAlsoPrunesOldRecordsAndRetainsNewestRepeatDeletion() {
        let now = date(1000)
        var manifest = WebDAVManifest()
        manifest.deletedBooks = ["web:expired": now.addingTimeInterval(-WebDAVDeletedBooks.retentionInterval - 1),
                                 "web:recent": date(900), "web:again": now.addingTimeInterval(1)]
        _ = WebDAVDeletedBooks.remove(["web:new", "web:again"], from: &manifest, at: now)
        XCTAssertEqual(manifest.deletedBooks, ["web:recent": date(900), "web:new": now, "web:again": now.addingTimeInterval(1)])
    }
}
