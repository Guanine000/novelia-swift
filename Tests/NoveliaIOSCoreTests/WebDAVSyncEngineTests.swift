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
    var onDownload: (() -> Void)?
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
        guard let manifest else { return (WebDAVManifest(), nil, false) }
        return (try roundTrip(manifest), "\"v\(puts.count)\"", true)
    }

    func putManifest(_ manifest: WebDAVManifest, etag: String?, existed: Bool) async throws {
        log.events.append("remote.put")
        puts.append(Put(etag: etag, existed: existed))
        if let putError { throw putError }
        self.manifest = try roundTrip(manifest)
    }

    func uploadBlob(_ file: URL, hash: String) async throws {
        log.events.append("remote.upload")
        let data = try Data(contentsOf: file)
        XCTAssertEqual(sha256(data), hash, "blobs are stored under their content hash")
        blobs[hash] = data
    }

    func downloadBlob(_ hash: String) async throws -> URL {
        log.events.append("remote.download")
        guard let data = blobs[hash] else { throw WebDAVSyncError.unexpectedResponse(404) }
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

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

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
                       [WebDAVAsset(filename: "a.epub", hash: sha256(Data("web a".utf8)))])
        XCTAssertEqual(manifest.wenkuBooks.map(\.record), [book])
        XCTAssertEqual(manifest.wenkuBooks.first?.assets.map(\.filename), ["cover.jpg", book.filename].sorted())
        XCTAssertEqual(remote.blobs.count, 3)
        XCTAssertEqual(remote.puts.map(\.existed), [false])
        XCTAssertEqual(remote.puts.map(\.etag), [nil])
        assertProgressCompleted(totalUnits: 4)
        XCTAssertEqual(progress.last?.detail, "同步完成")
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
