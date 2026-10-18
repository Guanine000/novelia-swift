import CryptoKit
import Foundation
import XCTest
@testable import NoveliaIOSCore

private struct Reply {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var failure: URLError.Code? = nil
}

/// 按「方法 路径」回应的内存 WebDAV 服务器；未配置的请求返回 404。
private final class WebDAVMock: URLProtocol {
    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [String: Data] = [:]

    static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Reply)?

    static func reset() { replies = [:]; requests = []; bodies = [:]; handler = nil }
    /// 同一请求可排队多次回应，最后一个回应会一直重复使用。
    static func on(_ key: String, _ replies: Reply...) { self.replies[key] = replies }
    static var keys: [String] { requests.map(key) }
    static func key(_ request: URLRequest) -> String { "\(request.httpMethod ?? "GET") \(request.url!.path)" }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let key = Self.key(request)
        Self.requests.append(request)
        if let stream = request.httpBodyStream { Self.bodies[key] = Self.read(stream) }
        var queue = Self.replies[key] ?? [Reply(status: 404)]
        let reply = Self.handler?(request, Self.bodies[key] ?? request.httpBody ?? Data())
            ?? (queue.count > 1 ? queue.removeFirst() : queue[0])
        Self.replies[key] = queue
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                                              headerFields: reply.headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// WebDAV HTTP 客户端：地址校验、目录创建、清单条件写入、blob 传输与重定向限制。
final class WebDAVClientTests: XCTestCase {
    private let root = "/dav/NoveliaSync/v1"
    private var configuration: URLSessionConfiguration!

    override func setUp() {
        WebDAVMock.reset()
        configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVMock.self]
    }

    private func client(_ address: String = "https://dav.example/dav/") throws -> WebDAVClient {
        try WebDAVClient(address: address, username: "user", password: "pa:ss", configuration: configuration)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertSyncError<T>(_ expected: WebDAVSyncError, _ body: () async throws -> T,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WebDAVSyncError, expected, file: file, line: line)
        }
    }

    // MARK: 地址

    func testAddressMustBePlainHTTPSFolder() throws {
        for address in ["http://dav.example/dav/", "https:///dav/", "https://user:pw@dav.example/dav/",
                        "https://dav.example/dav/?a=1", "https://dav.example/dav/#top", "not a url"] {
            XCTAssertThrowsError(try client(address), address) { XCTAssertEqual($0 as? WebDAVSyncError, .invalidURL) }
        }
        let accepted = try client("HTTPS://dav.example:8443/dav/")
        XCTAssertEqual(accepted.root.port, 8443)
        XCTAssertEqual(accepted.root.path, "/dav/NoveliaSync/v1")
    }

    func testRequestsCarryBasicAuthorization() async throws {
        WebDAVMock.on("PROPFIND /dav", Reply(status: 207))
        try await client().verifyConnection()
        let request = try XCTUnwrap(WebDAVMock.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("user:pa:ss".utf8).base64EncodedString())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
    }

    func testVerifyConnectionReportsMissingFolderAndAuthFailure() async throws {
        await assertSyncError(.unexpectedResponse(404)) { try await self.client().verifyConnection() }
        WebDAVMock.on("PROPFIND /dav", Reply(status: 401))
        await assertSyncError(.unexpectedResponse(401)) { try await self.client().verifyConnection() }
    }

    // MARK: 目录

    func testPrepareFoldersCreatesOnlyMissingFoldersInOrder() async throws {
        WebDAVMock.on("PROPFIND /dav/NoveliaSync", Reply(status: 207))
        WebDAVMock.on("MKCOL \(root)", Reply(status: 201))
        WebDAVMock.on("MKCOL \(root)/blobs", Reply(status: 405))
        try await client().prepareFolders()
        XCTAssertEqual(WebDAVMock.keys, [
            "PROPFIND /dav/NoveliaSync",
            "PROPFIND \(root)", "MKCOL \(root)",
            "PROPFIND \(root)/blobs", "MKCOL \(root)/blobs",
        ])
    }

    func testPrepareFoldersChecksAgainAfterLostCreateResponse() async throws {
        WebDAVMock.on("PROPFIND /dav/NoveliaSync", Reply(status: 404), Reply(status: 207))
        WebDAVMock.on("MKCOL /dav/NoveliaSync", Reply(failure: .networkConnectionLost))
        WebDAVMock.on("PROPFIND \(root)", Reply(status: 207))
        WebDAVMock.on("PROPFIND \(root)/blobs", Reply(status: 207))
        try await client().prepareFolders()
        XCTAssertEqual(WebDAVMock.keys.filter { $0.hasPrefix("MKCOL") }, ["MKCOL /dav/NoveliaSync"],
                       "the folder created before the connection dropped is not created twice")
    }

    func testPrepareFoldersRejectsFailedCreate() async throws {
        WebDAVMock.on("PROPFIND /dav/NoveliaSync", Reply(status: 207))
        WebDAVMock.on("MKCOL \(root)", Reply(status: 409))
        await assertSyncError(.unexpectedResponse(409)) { try await self.client().prepareFolders() }
    }

    // MARK: 清单

    func testMissingManifestStartsEmpty() async throws {
        let (manifest, etag, existed) = try await client().fetchManifest()
        XCTAssertTrue(manifest.webBooks.isEmpty && manifest.wenkuBooks.isEmpty && manifest.positions.isEmpty)
        XCTAssertNil(etag)
        XCTAssertFalse(existed)
    }

    func testFetchManifestReturnsETagAndRetriesLostConnection() async throws {
        let body = Data(#"{"version":1,"webBooks":[],"wenkuBooks":[],"positions":{"web:a":{"chapterIndex":3,"updatedAt":0}}}"#.utf8)
        WebDAVMock.on("GET \(root)/index.json", Reply(failure: .networkConnectionLost),
                      Reply(status: 200, headers: ["ETag": "\"v7\""], body: body))
        let (manifest, etag, existed) = try await client().fetchManifest()
        XCTAssertEqual(manifest.positions["web:a"]?.chapterIndex, 3)
        XCTAssertEqual(etag, "\"v7\"")
        XCTAssertTrue(existed)
        XCTAssertEqual(WebDAVMock.requests.count, 2)
    }

    func testFetchManifestRejectsUnknownVersionAndServerErrors() async throws {
        WebDAVMock.on("GET \(root)/index.json", Reply(status: 200, headers: ["ETag": "\"v2\""], body: Data(#"{"version":2,"webBooks":[],"wenkuBooks":[],"positions":{}}"#.utf8)))
        await assertSyncError(.unsupportedManifest) { try await self.client().fetchManifest() }
        WebDAVMock.on("GET \(root)/index.json", Reply(status: 500))
        await assertSyncError(.unexpectedResponse(500)) { try await self.client().fetchManifest() }
    }

    func testPutManifestUsesConditionalHeaders() async throws {
        let key = "PUT \(root)/index.json"
        WebDAVMock.on(key, Reply(status: 201, headers: ["ETag": "\"saved\""]))
        var manifest = WebDAVManifest()
        manifest.blockedTags = ["标签": SyncedBlockedTag(blocked: true, updatedAt: Date(timeIntervalSince1970: 1))]

        try await client().putManifest(manifest, etag: "\"v7\"", existed: true)
        try await client().putManifest(manifest, etag: nil, existed: false)
        await assertSyncError(.unsupportedConditions) { try await self.client().putManifest(manifest, etag: nil, existed: true) }
        let headers = WebDAVMock.requests.map {
            [$0.value(forHTTPHeaderField: "If-Match"), $0.value(forHTTPHeaderField: "If-None-Match")]
        }
        XCTAssertEqual(headers, [["\"v7\"", nil], [nil, "*"]],
                       "existing files without a version must never be overwritten")
        XCTAssertEqual(WebDAVMock.requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try JSONDecoder().decode(WebDAVManifest.self, from: XCTUnwrap(WebDAVMock.bodies[key]))
        XCTAssertEqual(sent.blockedTags, manifest.blockedTags)
    }

    func testPutManifestReportsConcurrentChange() async throws {
        WebDAVMock.on("PUT \(root)/index.json", Reply(status: 412))
        await assertSyncError(.concurrentChange) {
            try await self.client().putManifest(WebDAVManifest(), etag: "\"old\"", existed: true)
        }
    }

    // MARK: blob

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WebDAVClientTests-\(UUID())")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUploadBlobSkipsExistingAndCreatesMissing() async throws {
        let data = Data("book".utf8)
        let hash = sha256(data)
        let file = try temporaryFile(data)
        WebDAVMock.on("PROPFIND \(root)/blobs/\(hash)", Reply(status: 207))
        try await client().uploadBlob(file, hash: hash)
        XCTAssertEqual(WebDAVMock.keys, ["PROPFIND \(root)/blobs/\(hash)"])

        WebDAVMock.reset()
        WebDAVMock.on("PUT \(root)/blobs/\(hash)", Reply(status: 412))
        try await client().uploadBlob(file, hash: hash)
        XCTAssertEqual(WebDAVMock.keys, ["PROPFIND \(root)/blobs/\(hash)", "PUT \(root)/blobs/\(hash)"],
                       "412 means another device uploaded the same content first")
        XCTAssertEqual(WebDAVMock.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "*")
    }

    func testBlobRejectsInvalidHashWithoutRequest() async throws {
        let file = try temporaryFile(Data())
        await assertSyncError(.invalidAsset) { try await self.client().uploadBlob(file, hash: "../index.json") }
        await assertSyncError(.invalidAsset) { try await self.client().downloadBlob(String(repeating: "A", count: 64)) }
        XCTAssertTrue(WebDAVMock.requests.isEmpty)
    }

    func testDownloadBlobVerifiesContentHash() async throws {
        let data = Data("book".utf8)
        let hash = sha256(data)
        WebDAVMock.on("GET \(root)/blobs/\(hash)", Reply(status: 200, body: data))
        let file = try await client().downloadBlob(hash)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), data)

        let other = sha256(Data("other".utf8))
        WebDAVMock.on("GET \(root)/blobs/\(other)", Reply(status: 200, body: data))
        await assertSyncError(.invalidAsset) { try await self.client().downloadBlob(other) }
        await assertSyncError(.missingBlob) { try await self.client().downloadBlob(self.sha256(Data())) }
    }

    func testListBlobsReadsHashesAndToleratesUnsupportedServers() async throws {
        let a = sha256(Data("a".utf8)), b = sha256(Data("b".utf8))
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/NoveliaSync/v1/blobs/</d:href></d:response>
          <d:response><d:href>/dav/NoveliaSync/v1/blobs/\(a)</d:href></d:response>
          <d:response><d:href>https://dav.example/dav/NoveliaSync/v1/blobs/\(b)</d:href></d:response>
          <d:response><d:href>/dav/NoveliaSync/v1/blobs/.DS_Store</d:href></d:response>
        </d:multistatus>
        """
        WebDAVMock.on("PROPFIND \(root)/blobs", Reply(status: 207, body: Data(body.utf8)))
        let listed = try await client().listBlobs()
        XCTAssertEqual(listed, [a, b])
        XCTAssertEqual(WebDAVMock.requests.last?.value(forHTTPHeaderField: "Depth"), "1")
        WebDAVMock.on("PROPFIND \(root)/blobs", Reply(status: 405))
        let unsupported = try await client().listBlobs()
        XCTAssertNil(unsupported, "servers that cannot list keep syncing without repair")
    }

    // MARK: 生命周期

    /// 带 delegate 的 URLSession 在失效前一直被系统持有；每次同步都会新建客户端。
    func testReleasingClientReleasesItsSession() async throws {
        weak var session: URLSession?
        var client: WebDAVClient? = try client()
        session = client?.session
        try? await client?.verifyConnection()
        client = nil
        for _ in 0..<100 where session != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(session)
    }

    // MARK: 重定向

    func testRedirectsStayOnSameHTTPSHostAndPort() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://dav.example/dav/")!
        let task = session.dataTask(with: original)
        func allows(_ destination: String) -> Bool {
            var allowed: Bool?
            WebDAVRedirectGuard().urlSession(
                session, task: task,
                willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 301, httpVersion: nil, headerFields: nil)!,
                newRequest: URLRequest(url: URL(string: destination)!)) { allowed = $0 != nil }
            return allowed ?? false
        }
        XCTAssertTrue(allows("https://dav.example/dav/moved/"))
        XCTAssertTrue(allows("https://dav.example:443/dav/"))
        XCTAssertFalse(allows("http://dav.example/dav/"), "downgrade to HTTP")
        XCTAssertFalse(allows("https://other.example/dav/"), "different host")
        XCTAssertFalse(allows("https://dav.example:8443/dav/"), "different port")
    }

    func testErrorMessagesExplainCommonStatuses() {
        XCTAssertTrue(WebDAVSyncError.unexpectedResponse(401).localizedDescription.contains("401"))
        XCTAssertTrue(WebDAVSyncError.unexpectedResponse(418).localizedDescription.contains("HTTP 418"))
        XCTAssertNotEqual(WebDAVSyncError.unexpectedResponse(403).localizedDescription,
                          WebDAVSyncError.unexpectedResponse(418).localizedDescription)
    }
}

private func seconds(_ value: TimeInterval, book: String = "book") -> ReadingStatistics {
    var statistics = ReadingStatistics()
    let date = Date(timeIntervalSince1970: 1_000_000)
    statistics.record(book: ReadingBook(id: book, title: "书", kind: .epub),
                      from: date, to: date.addingTimeInterval(value), duration: value)
    return statistics
}

/// 阅读统计的远端格式：每台设备一个文件，旧合并文件只读。
extension WebDAVClientTests {
    func testStatisticsListCreatesMissingFolder() async throws {
        WebDAVMock.on("MKCOL \(root)/statistics", Reply(status: 201))
        let entries = try await client().listDeviceStatistics()
        XCTAssertEqual(entries, [])
        XCTAssertEqual(WebDAVMock.keys, ["PROPFIND \(root)/statistics", "MKCOL \(root)/statistics"])
        XCTAssertEqual(WebDAVMock.requests[0].value(forHTTPHeaderField: "Depth"), "1")
    }

    func testStatisticsListReadsDeviceFilesFromMultistatus() async throws {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/NoveliaSync/v1/statistics/</D:href></D:response>
          <D:response><D:href>/dav/NoveliaSync/v1/statistics/dev-a.json</D:href>
            <D:propstat><D:prop><D:getetag>"e1"</D:getetag></D:prop></D:propstat></D:response>
          <D:response><D:href>https://dav.example/dav/NoveliaSync/v1/statistics/B2.json</D:href>
            <D:propstat><D:prop><D:getlastmodified>Tue, 14 Oct 2026 09:00:00 GMT</D:getlastmodified>
            <D:getcontentlength>42</D:getcontentlength></D:prop></D:propstat></D:response>
          <D:response><D:href>/dav/NoveliaSync/v1/statistics/notes.txt</D:href></D:response>
          <D:response><D:href>/dav/NoveliaSync/v1/statistics/bad%20id.json</D:href></D:response>
          <D:response><D:href>/dav/NoveliaSync/v1/statistics/dev-a.json</D:href></D:response>
        </D:multistatus>
        """
        WebDAVMock.on("PROPFIND \(root)/statistics", Reply(status: 207, body: Data(body.utf8)))
        let entries = try await client().listDeviceStatistics()
        XCTAssertEqual(entries, [ReadingStatisticsRemoteEntry(deviceID: "dev-a", version: "\"e1\""),
                                 ReadingStatisticsRemoteEntry(deviceID: "B2", version: "Tue, 14 Oct 2026 09:00:00 GMT|42")])
        let request = String(data: WebDAVMock.bodies["PROPFIND \(root)/statistics"] ?? WebDAVMock.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(request.contains("getetag"), "listing asks for versions so unchanged files are not downloaded")
    }

    func testStatisticsDeviceFileIsWrittenWithoutConditionsAndValidatedOnRead() async throws {
        let file = ReadingDeviceStatisticsFile(
            deviceID: "dev-a", device: ReadingDeviceInfo(name: "我的 iPad", model: "iPad", updatedAt: Date(timeIntervalSince1970: 5)),
            statistics: seconds(30))
        WebDAVMock.on("PUT \(root)/statistics/dev-a.json", Reply(status: 201, headers: ["ETag": "\"p1\""]))
        let etag = try await client().putDeviceStatistics(try JSONEncoder().encode(file), deviceID: "dev-a")
        XCTAssertEqual(etag, "\"p1\"")
        let put = try XCTUnwrap(WebDAVMock.requests.last)
        XCTAssertNil(put.value(forHTTPHeaderField: "If-Match"))
        XCTAssertNil(put.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertFalse(WebDAVMock.keys.contains { $0.contains("reading-statistics.json") }, "legacy file is never written")

        WebDAVMock.on("GET \(root)/statistics/dev-a.json", Reply(body: try JSONEncoder().encode(file)))
        let fetched = try await client().fetchDeviceStatistics("dev-a")
        XCTAssertEqual(fetched, file)
        var renamed = file
        renamed.deviceID = "dev-b"
        WebDAVMock.on("GET \(root)/statistics/dev-c.json", Reply(body: try JSONEncoder().encode(renamed)))
        let mismatched = try await client().fetchDeviceStatistics("dev-c")
        XCTAssertNil(mismatched, "file content must match its name")
        let unsafe = try await client().fetchDeviceStatistics("../index")
        XCTAssertNil(unsafe)
    }

    func testLegacyStatisticsIsOptionalAndInvalidContentIsIgnored() async throws {
        let missing = try await client().fetchLegacyReadingStatistics()
        XCTAssertNil(missing)
        let path = "\(root)/reading-statistics.json"
        WebDAVMock.on("GET \(path)", Reply(body: try JSONEncoder().encode(ReadingStatisticsSync(version: 2))))
        let unsupported = try await client().fetchLegacyReadingStatistics()
        XCTAssertNil(unsupported)
        let legacy = ReadingStatisticsSync(devices: ["old": seconds(10)])
        WebDAVMock.on("GET \(path)", Reply(body: try JSONEncoder().encode(legacy)))
        let fetched = try await client().fetchLegacyReadingStatistics()
        XCTAssertEqual(fetched, legacy)
    }

    func testOldCacheWithoutDeviceInfoStillDecodes() throws {
        let old = Data(#"{"version":1,"devices":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(ReadingStatisticsSync.self, from: old)
        XCTAssertNil(decoded.deviceInfo)
        XCTAssertTrue(decoded.isValid)
    }
}

/// 内存中的统计远端：按设备保存文件与版本，记录各类请求。
private final class StatisticsMemoryRemote: ReadingStatisticsRemote {
    var legacy: ReadingStatisticsSync?
    var files: [String: ReadingDeviceStatisticsFile] = [:]
    var versions: [String: String] = [:]
    var writes: [ReadingDeviceStatisticsFile] = []
    var fetches: [String] = []
    var legacyReads = 0
    /// 为 false 时模拟不提供任何版本信息的服务器。
    var reportsVersions = true

    func fetchLegacyReadingStatistics() async throws -> ReadingStatisticsSync? { legacyReads += 1; return legacy }
    func listDeviceStatistics() async throws -> [ReadingStatisticsRemoteEntry] {
        files.keys.sorted().map { ReadingStatisticsRemoteEntry(deviceID: $0, version: reportsVersions ? versions[$0] : nil) }
    }
    func fetchDeviceStatistics(_ deviceID: String) async throws -> ReadingDeviceStatisticsFile? {
        fetches.append(deviceID)
        return files[deviceID]
    }
    func putDeviceStatistics(_ data: Data, deviceID: String) async throws -> String? {
        let file = try JSONDecoder().decode(ReadingDeviceStatisticsFile.self, from: data)
        writes.append(file)
        store(file)
        return reportsVersions ? versions[deviceID] : nil
    }
    func store(_ file: ReadingDeviceStatisticsFile) {
        files[file.deviceID] = file
        versions[file.deviceID] = "\"\(UUID().uuidString)\""
    }
}

extension WebDAVClientTests {
    func testSynchronizerMergesEveryDeviceAndLegacyButWritesOnlyItsOwnFile() async throws {
        let remote = StatisticsMemoryRemote()
        remote.legacy = ReadingStatisticsSync(devices: ["c": seconds(10)])
        remote.store(ReadingDeviceStatisticsFile(
            deviceID: "b", device: ReadingDeviceInfo(name: "iPad", model: "iPad", updatedAt: Date(timeIntervalSince1970: 1)),
            statistics: seconds(30)))
        let synchronizer = ReadingStatisticsSynchronizer(remote: remote)
        let (merged, cache) = try await synchronizer.sync(ReadingStatisticsSync(devices: ["a": seconds(20)]), deviceID: "a")
        XCTAssertEqual(merged.statistics.seconds(), 60)
        XCTAssertEqual(merged.deviceInfo?["b"]?.name, "iPad")
        XCTAssertEqual(remote.writes.map(\.deviceID), ["a"])
        XCTAssertEqual(remote.writes.last?.statistics.seconds(), 20, "never upload other devices' time as local time")

        let (again, _) = try await synchronizer.sync(merged, deviceID: "a", cache: cache)
        XCTAssertEqual(again.statistics.seconds(), 60, "repeated sync must not add again")
        XCTAssertEqual(remote.files["a"]?.statistics.seconds(), 20)
    }

    /// 第二次同步：远端没变、本机也没变时，只列一次目录，不下载、不上传，旧版文件也不再读。
    func testCacheSkipsUnchangedDownloadsUploadsAndLegacyChecks() async throws {
        let remote = StatisticsMemoryRemote()
        remote.legacy = ReadingStatisticsSync(devices: ["c": seconds(10)])
        remote.store(ReadingDeviceStatisticsFile(deviceID: "b", device: nil, statistics: seconds(30)))
        let synchronizer = ReadingStatisticsSynchronizer(remote: remote)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let (first, cache) = try await synchronizer.sync(ReadingStatisticsSync(devices: ["a": seconds(20)]),
                                                         deviceID: "a", now: now)
        XCTAssertEqual(remote.fetches, ["b"])
        XCTAssertEqual(remote.writes.count, 1)
        XCTAssertEqual(remote.legacyReads, 1)

        remote.fetches = []
        let (second, cache2) = try await synchronizer.sync(first, deviceID: "a", cache: cache, now: now.addingTimeInterval(60))
        XCTAssertEqual(second.statistics.seconds(), 60)
        XCTAssertEqual(remote.fetches, [], "unchanged device files are not downloaded")
        XCTAssertEqual(remote.writes.count, 1, "unchanged local file is not uploaded")
        XCTAssertEqual(remote.legacyReads, 1, "legacy file is checked at most once a day")

        // 其他设备更新后只下载那一个文件；本机读了更多书才上传。
        remote.store(ReadingDeviceStatisticsFile(deviceID: "b", device: nil, statistics: seconds(45)))
        var local = second
        local.devices["a"] = seconds(25)
        let (third, cache3) = try await synchronizer.sync(local, deviceID: "a", cache: cache2, now: now.addingTimeInterval(120))
        XCTAssertEqual(remote.fetches, ["b"])
        XCTAssertEqual(remote.writes.count, 2)
        XCTAssertEqual(third.statistics.seconds(), 80)

        _ = try await synchronizer.sync(third, deviceID: "a", cache: cache3, now: now.addingTimeInterval(ReadingStatisticsSyncCache.legacyCheckInterval + 1))
        XCTAssertEqual(remote.legacyReads, 2)
    }

    func testCacheReuploadsWhenOwnFileWasDeletedAndRefetchesWithoutVersions() async throws {
        let remote = StatisticsMemoryRemote()
        remote.reportsVersions = false
        remote.store(ReadingDeviceStatisticsFile(deviceID: "b", device: nil, statistics: seconds(30)))
        let synchronizer = ReadingStatisticsSynchronizer(remote: remote)
        let (merged, cache) = try await synchronizer.sync(ReadingStatisticsSync(devices: ["a": seconds(20)]), deviceID: "a")
        remote.fetches = []
        remote.files["a"] = nil
        _ = try await synchronizer.sync(merged, deviceID: "a", cache: cache)
        XCTAssertEqual(remote.writes.count, 2, "deleted local file is uploaded again")
        XCTAssertEqual(remote.fetches, ["b"], "files without any version are always read")
    }

    func testStatisticsCacheDecodesMissingFields() throws {
        var cache = try JSONDecoder().decode(ReadingStatisticsSyncCache.self, from: Data("{}".utf8))
        XCTAssertNil(cache.format, "caches without a format are refreshed once")
        cache.format = ReadingStatisticsSyncCache.currentFormat
        XCTAssertEqual(cache, ReadingStatisticsSyncCache())
    }

    func testFolderCacheSkipsChecksUntilCleared() async throws {
        let suite = "WebDAVFolderCacheTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = WebDAVFolderCache(defaults: defaults)
        for folder in ["/dav", "/dav/NoveliaSync", root, "\(root)/blobs"] {
            WebDAVMock.on("PROPFIND \(folder)", Reply(status: 207))
        }
        let cached = try WebDAVClient(address: "https://dav.example/dav/", username: "user", password: "pw",
                                      configuration: configuration, folderCache: cache)
        try await cached.verifyConnection()
        try await cached.prepareFolders()
        XCTAssertEqual(WebDAVMock.requests.count, 4)
        try await cached.verifyConnection()
        try await cached.prepareFolders()
        XCTAssertEqual(WebDAVMock.requests.count, 4, "prepared folders are not checked again")
        let otherUser = try WebDAVClient(address: "https://dav.example/dav/", username: "other", password: "pw",
                                         configuration: configuration, folderCache: cache)
        try await otherUser.prepareFolders()
        XCTAssertEqual(WebDAVMock.requests.count, 7, "cache is per account")
        cache.clear()
        try await cached.prepareFolders()
        XCTAssertEqual(WebDAVMock.requests.count, 10)
    }

    /// 两台设备基于同一份旧远端各自写入，也不会丢掉对方的时长。
    func testDevicesSyncingAtTheSameTimeDoNotOverwriteEachOther() async throws {
        let remote = StatisticsMemoryRemote()
        let synchronizer = ReadingStatisticsSynchronizer(remote: remote)
        _ = try await synchronizer.sync(ReadingStatisticsSync(devices: ["a": seconds(20)]), deviceID: "a")
        _ = try await synchronizer.sync(ReadingStatisticsSync(devices: ["b": seconds(30)]), deviceID: "b")
        let (later, _) = try await synchronizer.sync(ReadingStatisticsSync(devices: ["a": seconds(20)]), deviceID: "a")
        XCTAssertEqual(later.statistics.seconds(), 50)
    }

    /// 从未改名的设备（名称时间为 distantPast）也要在其他设备上显示名称；旧缓存缺名称时重新读取。
    func testDefaultDeviceNamesReachOtherDevicesEvenWithCache() async throws {
        let remote = StatisticsMemoryRemote()
        remote.store(ReadingDeviceStatisticsFile(
            deviceID: "b", device: ReadingDeviceInfo(name: "iPad", model: "iPad", updatedAt: .distantPast),
            statistics: seconds(30)))
        let synchronizer = ReadingStatisticsSynchronizer(remote: remote)
        let local = ReadingStatisticsSync(devices: ["a": seconds(20)],
                                          deviceInfo: ["a": ReadingDeviceInfo(name: "iPhone", model: "iPhone", updatedAt: .distantPast)])
        let (merged, _) = try await synchronizer.sync(local, deviceID: "a")
        XCTAssertEqual(merged.deviceInfo?["b"]?.name, "iPad")
        XCTAssertEqual(merged.deviceInfo?["a"]?.name, "iPhone")

        // 0.20.0(72) 留下的缓存没有格式字段：版本已记录但名称未合并，应丢弃版本重新读取一次。
        let staleJSON = try JSONSerialization.data(withJSONObject: ["deviceVersions": remote.versions])
        let staleCache = try JSONDecoder().decode(ReadingStatisticsSyncCache.self, from: staleJSON)
        remote.fetches = []
        let (healed, healedCache) = try await synchronizer.sync(local, deviceID: "a", cache: staleCache)
        XCTAssertEqual(remote.fetches, ["a", "b"])
        XCTAssertEqual(healed.deviceInfo?["b"]?.name, "iPad")
        XCTAssertEqual(healedCache.format, ReadingStatisticsSyncCache.currentFormat)

        remote.fetches = []
        _ = try await synchronizer.sync(healed, deviceID: "a", cache: healedCache)
        XCTAssertEqual(remote.fetches, [], "unchanged files are skipped again after the refresh")
    }

    func testSynchronizerRejectsUnsafeDeviceID() async {
        await assertSyncError(.invalidStatistics) {
            try await ReadingStatisticsSynchronizer(remote: StatisticsMemoryRemote()).sync(ReadingStatisticsSync(), deviceID: "../x")
        }
    }
}
extension WebDAVClientTests {
    func testStrongETagNormalizationRejectsWeakOrMalformedValues() {
        XCTAssertEqual(WebDAVClient.strongETag("bare"), "\"bare\"")
        XCTAssertEqual(WebDAVClient.strongETag(" \"quoted\" "), "\"quoted\"")
        for bad in ["W/\"weak\"", "*", "", "\"broken", "a b", "a\nb", "\"a\",\"b\""] {
            XCTAssertNil(WebDAVClient.strongETag(bad), bad)
        }
    }

    func testMissingStrongVersionCannotFallBackToUnconditionalWrite() async throws {
        for value in [nil, "W/\"weak\"", "*"] as [String?] {
            await assertSyncError(.unsupportedConditions) {
                try await self.client().putManifest(WebDAVManifest(), etag: value, existed: true)
            }
        }
        XCTAssertTrue(WebDAVMock.requests.isEmpty)
    }

    func testOnlyOfficialNutcloudEndpointSendsBareConditionalVersion() async throws {
        for host in ["dav.jianguoyun.com", "dav.jianguoyun.com.example", "dav.example"] {
            WebDAVMock.reset()
            WebDAVMock.on("PUT \(root)/index.json", Reply(status: 204, headers: ["ETag": "\"saved\""]))
            try await client("https://\(host)/dav/").putManifest(WebDAVManifest(), etag: "\"abc\"", existed: true)
            XCTAssertEqual(WebDAVMock.requests.last?.value(forHTTPHeaderField: "If-Match"),
                           host == "dav.jianguoyun.com" ? "abc" : "\"abc\"")
            XCTAssertEqual(WebDAVMock.requests.last?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        }
    }

    private func property(_ href: String? = nil, etag: String = "new", status: String = "200 OK", namespace: String = "DAV:") -> Data {
        Data("""
        <d:multistatus xmlns:d="\(namespace)"><d:response><d:href>\(href ?? root + "/index.json")</d:href>
        <d:propstat><d:prop><d:getetag>\(etag)</d:getetag></d:prop><d:status>HTTP/1.1 \(status)</d:status></d:propstat>
        </d:response></d:multistatus>
        """.utf8)
    }

    func testPropertyVersionReadsFreshBodyAndChecksReadCondition() async throws {
        var old = WebDAVManifest(), fresh = WebDAVManifest()
        old.blockedTags = ["old": SyncedBlockedTag(blocked: true, updatedAt: Date())]
        fresh.blockedTags = ["fresh": SyncedBlockedTag(blocked: true, updatedAt: Date())]
        WebDAVMock.on("GET \(root)/index.json", Reply(body: try JSONEncoder().encode(old)),
                      Reply(body: try JSONEncoder().encode(fresh)), Reply(status: 412))
        WebDAVMock.on("PROPFIND \(root)/index.json", Reply(status: 207, body: property()))
        let (manifest, version, existed) = try await client().fetchManifest()
        XCTAssertTrue(existed)
        XCTAssertEqual(version, "\"new\"")
        XCTAssertEqual(manifest.blockedTags, fresh.blockedTags)
        XCTAssertEqual(WebDAVMock.requests[2].value(forHTTPHeaderField: "If-Match"), "\"new\"")
        XCTAssertEqual(WebDAVMock.requests[1].value(forHTTPHeaderField: "Depth"), "0")
    }

    func testPropertyFallbackRejectsWrongResourceFailedPropertyAndForeignNamespace() async throws {
        for body in [property("https://other.example\(root)/index.json"), property(root + "/wrong.json"),
                     property(status: "404 Not Found"), property(namespace: "urn:fake"),
                     property(etag: "W/\"weak\""), Data("<invalid".utf8)] {
            WebDAVMock.reset()
            WebDAVMock.on("GET \(root)/index.json", Reply(body: try JSONEncoder().encode(WebDAVManifest())))
            WebDAVMock.on("PROPFIND \(root)/index.json", Reply(status: 207, body: body))
            await assertSyncError(.unsupportedConditions) { try await self.client().fetchManifest() }
            XCTAssertFalse(WebDAVMock.keys.contains { $0.hasPrefix("PUT") })
        }
    }

    func testPropertyFallbackRejectsIgnoredReadConditionOrChangingVersion() async throws {
        for response in [Reply(status: 200), Reply(status: 304)] {
            WebDAVMock.reset()
            WebDAVMock.on("GET \(root)/index.json", Reply(body: Data()), Reply(body: Data()), response)
            WebDAVMock.on("PROPFIND \(root)/index.json", Reply(status: 207, body: property()))
            await assertSyncError(.unsupportedConditions) { try await self.client().fetchManifest() }
        }
        WebDAVMock.reset()
        WebDAVMock.on("GET \(root)/index.json", Reply(), Reply(headers: ["ETag": "changed"]))
        WebDAVMock.on("PROPFIND \(root)/index.json", Reply(status: 207, body: property()))
        await assertSyncError(.concurrentChange) { try await self.client().fetchManifest() }
    }

    /// 模拟同一坚果云目录；忽略临时文件 PUT 的 If-None-Match，MOVE 的 Overwrite:F 才保护共享目标。
    private func nutcloudServer(moveReplies: [Int] = [], changedSource: Bool = false, ignoresOverwrite: Bool = false) {
        var files: [String: Data] = [:]
        var statuses = moveReplies
        WebDAVMock.handler = { request, body in
            let path = request.url!.path
            switch request.httpMethod {
            case "PUT":
                if let condition = request.value(forHTTPHeaderField: "If-Match"),
                   files[path].map({ FileContentHash.sha256($0) }) != condition { return Reply(status: 412) }
                files[path] = body; return Reply(status: 201)
            case "GET":
                guard let data = files[path] else { return Reply(status: 404) }
                return Reply(headers: ["ETag": FileContentHash.sha256(data)], body: changedSource && path.hasSuffix(".cache") ? Data("changed".utf8) : data)
            case "MOVE":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F")
                if !statuses.isEmpty { return Reply(status: statuses.removeFirst()) }
                let destination = URL(string: request.value(forHTTPHeaderField: "Destination")!, relativeTo: request.url)!.path
                if files[destination] != nil && !ignoresOverwrite { return Reply(status: 409) }
                files[destination] = files.removeValue(forKey: path)
                return Reply(status: 201)
            case "DELETE": files.removeValue(forKey: path); return Reply(status: 204)
            case "MKCOL": return Reply(status: 405)
            default: return Reply(status: 404)
            }
        }
    }

    func testNutcloudInitialCreationUsesMoveAndSecondDeviceCannotOverwrite() async throws {
        nutcloudServer()
        let first = try client("https://dav.jianguoyun.com/dav/")
        let second = try client("https://dav.jianguoyun.com/dav/")
        var original = WebDAVManifest(), replacement = WebDAVManifest()
        original.blockedTags = ["first": SyncedBlockedTag(blocked: true, updatedAt: Date())]
        replacement.blockedTags = ["second": SyncedBlockedTag(blocked: true, updatedAt: Date())]
        try await first.putManifest(original, etag: nil, existed: false)
        await assertSyncError(.concurrentChange) { try await second.putManifest(replacement, etag: nil, existed: false) }
        let (saved, _, _) = try await first.fetchManifest()
        XCTAssertEqual(saved.blockedTags, original.blockedTags)
        XCTAssertFalse(WebDAVMock.keys.contains("PUT \(root)/index.json"))
        XCTAssertFalse(WebDAVMock.keys.contains("DELETE \(root)/index.json"))
        let sources = WebDAVMock.requests.filter { $0.httpMethod == "PUT" && $0.url!.lastPathComponent.hasPrefix("novelia-upload-") }.map { $0.url!.path }
        XCTAssertEqual(Set(sources).count, 6)
        for source in sources { XCTAssertTrue(WebDAVMock.keys.contains("DELETE \(source)")) }
    }

    func testNutcloudMoveUsesBoundedRetryThenSameTargetPath() async throws {
        nutcloudServer(moveReplies: [409, 404])
        try await client("https://dav.jianguoyun.com/dav/").putManifest(WebDAVManifest(), etag: nil, existed: false)
        let moves = WebDAVMock.requests.filter { $0.httpMethod == "MOVE" }
        XCTAssertEqual(moves.count, 5, "three probe creation attempts, duplicate rejection, then real creation")
        let target = try XCTUnwrap(moves.first?.value(forHTTPHeaderField: "Destination"))
        XCTAssertEqual(Array(moves.prefix(3)).map { $0.value(forHTTPHeaderField: "Destination") },
                       [target, target, URL(string: target)!.path])
        XCTAssertEqual(Set(moves.prefix(3).map { $0.url!.path }).count, 1)
    }

    func testNutcloudMoveFailureNeverDeletesOrPutsTarget() async throws {
        for status in [403, 412, 500] {
            WebDAVMock.reset()
            nutcloudServer(moveReplies: [status])
            await assertSyncError(status == 412 ? .concurrentChange : .unexpectedResponse(status)) {
                try await self.client("https://dav.jianguoyun.com/dav/").putManifest(WebDAVManifest(), etag: nil, existed: false)
            }
            XCTAssertTrue(WebDAVMock.keys.contains { $0.hasPrefix("DELETE \(root)/novelia-upload-") })
            XCTAssertFalse(WebDAVMock.keys.contains("PUT \(root)/index.json"))
            XCTAssertFalse(WebDAVMock.keys.contains("DELETE \(root)/index.json"))
        }
    }

    func testNutcloudMoveStopsIfTemporarySourceChanges() async throws {
        nutcloudServer(moveReplies: [409], changedSource: true)
        await assertSyncError(.concurrentChange) {
            try await self.client("https://dav.jianguoyun.com/dav/").putManifest(WebDAVManifest(), etag: nil, existed: false)
        }
        XCTAssertEqual(WebDAVMock.requests.filter { $0.httpMethod == "MOVE" }.count, 1)
    }
}

extension WebDAVClientTests {
    func testIgnoredMoveOverwriteStopsBeforeTouchingRealManifest() async throws {
        nutcloudServer(ignoresOverwrite: true)
        await assertSyncError(.unsupportedConditions) {
            try await self.client("https://dav.jianguoyun.com/dav/").putManifest(WebDAVManifest(), etag: nil, existed: false)
        }
        XCTAssertFalse(WebDAVMock.requests.contains { $0.url?.path == root + "/index.json" })
        XCTAssertFalse(WebDAVMock.requests.contains { $0.value(forHTTPHeaderField: "Destination")?.hasSuffix("/index.json") == true })
    }

    func testTwoDevicesCreateAtTheSameTimeHaveOneWinner() async throws {
        nutcloudServer()
        let a = try client("https://dav.jianguoyun.com/dav/"), b = try client("https://dav.jianguoyun.com/dav/")
        func attempt(_ client: WebDAVClient) async throws -> Bool {
            do { try await client.putManifest(WebDAVManifest(), etag: nil, existed: false); return true }
            catch WebDAVSyncError.concurrentChange { return false }
        }
        async let first = attempt(a)
        async let second = attempt(b)
        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertFalse(WebDAVMock.keys.contains("DELETE \(root)/index.json"))
    }
}

extension WebDAVClientTests {
    func testUpdateWithoutReturnedVersionVerifiesSavedBody() async throws {
        let manifest = WebDAVManifest()
        var saved = Data()
        WebDAVMock.handler = { request, body in
            if request.httpMethod == "PUT" { saved = body; return Reply(status: 204) }
            return Reply(headers: ["ETag": "new"], body: saved)
        }
        try await client().putManifest(manifest, etag: "old", existed: true)
        WebDAVMock.handler = nil
        WebDAVMock.on("PUT \(root)/index.json", Reply(status: 204))
        WebDAVMock.on("GET \(root)/index.json", Reply(headers: ["ETag": "other"], body: Data("another writer".utf8)))
        await assertSyncError(.concurrentChange) { try await self.client().putManifest(manifest, etag: "old", existed: true) }
    }
}
