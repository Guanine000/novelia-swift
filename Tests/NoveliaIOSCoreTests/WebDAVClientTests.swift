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

    static func reset() { replies = [:]; requests = []; bodies = [:] }
    /// 同一请求可排队多次回应，最后一个回应会一直重复使用。
    static func on(_ key: String, _ replies: Reply...) { self.replies[key] = replies }
    static var keys: [String] { requests.map(key) }
    static func key(_ request: URLRequest) -> String { "\(request.httpMethod ?? "GET") \(request.url!.path)" }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = Self.key(request)
        Self.requests.append(request)
        if let stream = request.httpBodyStream { Self.bodies[key] = Self.read(stream) }
        var queue = Self.replies[key] ?? [Reply(status: 404)]
        let reply = queue.count > 1 ? queue.removeFirst() : queue[0]
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
        WebDAVMock.on("GET \(root)/index.json", Reply(status: 200, body: Data(#"{"version":2,"webBooks":[],"wenkuBooks":[],"positions":{}}"#.utf8)))
        await assertSyncError(.unsupportedManifest) { try await self.client().fetchManifest() }
        WebDAVMock.on("GET \(root)/index.json", Reply(status: 500))
        await assertSyncError(.unexpectedResponse(500)) { try await self.client().fetchManifest() }
    }

    func testPutManifestUsesConditionalHeaders() async throws {
        let key = "PUT \(root)/index.json"
        WebDAVMock.on(key, Reply(status: 201))
        var manifest = WebDAVManifest()
        manifest.blockedTags = ["标签": SyncedBlockedTag(blocked: true, updatedAt: Date(timeIntervalSince1970: 1))]

        try await client().putManifest(manifest, etag: "\"v7\"", existed: true)
        try await client().putManifest(manifest, etag: nil, existed: false)
        try await client().putManifest(manifest, etag: nil, existed: true)
        let headers = WebDAVMock.requests.map {
            [$0.value(forHTTPHeaderField: "If-Match"), $0.value(forHTTPHeaderField: "If-None-Match")]
        }
        XCTAssertEqual(headers, [["\"v7\"", nil], [nil, "*"], [nil, nil]],
                       "update with ETag, create only when absent, unconditional when the server sent no ETag")
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
        await assertSyncError(.unexpectedResponse(404)) { try await self.client().downloadBlob(self.sha256(Data())) }
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

extension WebDAVClientTests {
    func testStatisticsMissingStartsEmptyInSeparateFile() async throws {
        let (snapshot, etag, existed) = try await client().fetchReadingStatistics()
        XCTAssertTrue(snapshot.devices.isEmpty)
        XCTAssertNil(etag)
        XCTAssertFalse(existed)
        XCTAssertEqual(WebDAVMock.keys, ["GET \(root)/reading-statistics.json"])
    }

    func testStatisticsFetchAndPutUseConditionalHeaders() async throws {
        let path = "\(root)/reading-statistics.json"
        let snapshot = ReadingStatisticsSync()
        WebDAVMock.on("GET \(path)", Reply(headers: ["ETag": "\"s1\""], body: try JSONEncoder().encode(snapshot)))
        WebDAVMock.on("PUT \(path)", Reply(status: 201))
        let (_, etag, existed) = try await client().fetchReadingStatistics()
        XCTAssertEqual(etag, "\"s1\"")
        XCTAssertTrue(existed)
        try await client().putReadingStatistics(snapshot, etag: etag, existed: existed)
        try await client().putReadingStatistics(snapshot, etag: nil, existed: false)
        let puts = WebDAVMock.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts[0].value(forHTTPHeaderField: "If-Match"), "\"s1\"")
        XCTAssertEqual(puts[1].value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertFalse(WebDAVMock.keys.contains { $0.contains("index.json") })
    }

    func testStatisticsRejectsUnconditionalOverwriteAndUnsupportedVersion() async throws {
        await assertSyncError(.missingStatisticsETag) {
            try await self.client().putReadingStatistics(ReadingStatisticsSync(), etag: nil, existed: true)
        }
        XCTAssertTrue(WebDAVMock.requests.isEmpty)
        let invalid = ReadingStatisticsSync(version: 2)
        WebDAVMock.on("GET \(root)/reading-statistics.json", Reply(body: try JSONEncoder().encode(invalid)))
        await assertSyncError(.invalidStatistics) { try await self.client().fetchReadingStatistics() }
    }

    func testStatisticsRejectsConflict() async throws {
        WebDAVMock.on("PUT \(root)/reading-statistics.json", Reply(status: 412))
        await assertSyncError(.concurrentChange) {
            try await self.client().putReadingStatistics(ReadingStatisticsSync(), etag: "\"old\"", existed: true)
        }
    }
}

private final class StatisticsMemoryRemote: ReadingStatisticsRemote {
    var snapshots: [ReadingStatisticsSync] = []
    var conflicts = 0
    var writes: [ReadingStatisticsSync] = []
    var reads = 0
    func fetchReadingStatistics() async throws -> (ReadingStatisticsSync, String?, Bool) {
        let value = snapshots[min(reads, snapshots.count - 1)]
        reads += 1
        return (value, "\"\(reads)\"", true)
    }
    func putReadingStatistics(_ snapshot: ReadingStatisticsSync, etag: String?, existed: Bool) async throws {
        writes.append(snapshot)
        if conflicts > 0 { conflicts -= 1; throw WebDAVSyncError.concurrentChange }
    }
}

extension WebDAVClientTests {
    func testStatisticsConcurrentWriteRetriesFreshMerge() async throws {
        let remote = StatisticsMemoryRemote()
        var remoteStats = ReadingStatistics(), localStats = ReadingStatistics()
        let now = Date()
        let book = ReadingBook(id: "book", title: "书", kind: .epub)
        localStats.record(book: book, from: now, to: now.addingTimeInterval(20), duration: 20)
        remoteStats.record(book: book, from: now, to: now.addingTimeInterval(30), duration: 30)
        remote.snapshots = [ReadingStatisticsSync(), ReadingStatisticsSync(devices: ["b": remoteStats])]
        remote.conflicts = 1
        let merged = try await ReadingStatisticsSynchronizer(remote: remote).sync(.init(devices: ["a": localStats]))
        XCTAssertEqual(remote.reads, 2)
        XCTAssertEqual(merged.statistics.seconds(), 50)
        XCTAssertEqual(remote.writes.last, merged)
    }

    func testStatisticsStopsAfterThreeConflictsWithoutChangingLocal() async {
        let remote = StatisticsMemoryRemote()
        remote.snapshots = [ReadingStatisticsSync()]
        remote.conflicts = 3
        await assertSyncError(.concurrentChange) {
            try await ReadingStatisticsSynchronizer(remote: remote).sync(ReadingStatisticsSync())
        }
        XCTAssertEqual(remote.reads, 3)
        XCTAssertEqual(remote.writes.count, 3)
    }
}
