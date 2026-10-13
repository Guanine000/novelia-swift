import Foundation
import XCTest
@testable import NoveliaIOSCore

private enum Outcome {
    case status(Int)
    case failure(URLError.Code)
}

private final class TransportMock: URLProtocol {
    nonisolated(unsafe) static var outcomes: [Outcome] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let outcome = Self.outcomes.isEmpty ? .status(200) : Self.outcomes.removeFirst()
        switch outcome {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("body".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private func jwt(_ subject: String, _ exp: Double) -> String {
    let bytes = try! JSONSerialization.data(withJSONObject: ["sub": subject, "exp": exp])
    return "header." + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}

/// 两个 API 客户端共用的请求处理：数据与下载请求的重试及 401 续期。
final class TransportTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransportMock.self]
        session = URLSession(configuration: config)
        TransportMock.outcomes = []
        TransportMock.requests = []
        NoveliaSessionRenewal.transientRetryDelay = .milliseconds(10)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        NoveliaSessionRenewal.transientRetryDelay = .seconds(1)
    }

    private func request(_ method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.invalid/api/thing")!)
        request.httpMethod = method
        return request
    }

    private func status(_ response: URLResponse) -> Int? { (response as? HTTPURLResponse)?.statusCode }

    func testGatewayErrorRetriedOnceForGET() async throws {
        TransportMock.outcomes = [.status(502), .status(200)]
        let (_, response) = try await NoveliaSessionRenewal.data(session: session, request: request(), app: "t", tokenProvider: { nil })
        XCTAssertEqual(status(response), 200)
        XCTAssertEqual(TransportMock.requests.count, 2)
    }

    func testRetryHappensOnlyOnce() async throws {
        TransportMock.outcomes = [.status(503), .status(503), .status(200)]
        let (_, response) = try await NoveliaSessionRenewal.data(session: session, request: request(), app: "t", tokenProvider: { nil })
        XCTAssertEqual(status(response), 503)
        XCTAssertEqual(TransportMock.requests.count, 2)
    }

    func testChangesAreNeverRetried() async throws {
        for method in ["POST", "PATCH", "PUT", "DELETE"] {
            TransportMock.requests = []
            TransportMock.outcomes = [.status(502)]
            let (_, response) = try await NoveliaSessionRenewal.data(session: session, request: request(method), app: "t", tokenProvider: { nil })
            XCTAssertEqual(status(response), 502, method)
            XCTAssertEqual(TransportMock.requests.count, 1, method)
        }
    }

    func testDroppedConnectionRetriedButTimeoutIsNot() async throws {
        TransportMock.outcomes = [.failure(.networkConnectionLost), .status(200)]
        let (_, response) = try await NoveliaSessionRenewal.data(session: session, request: request(), app: "t", tokenProvider: { nil })
        XCTAssertEqual(status(response), 200)
        XCTAssertEqual(TransportMock.requests.count, 2)

        TransportMock.requests = []
        TransportMock.outcomes = [.failure(.timedOut), .status(200)]
        do {
            _ = try await NoveliaSessionRenewal.data(session: session, request: request(), app: "t", tokenProvider: { nil })
            XCTFail("timeout should surface")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(TransportMock.requests.count, 1)
    }

    func testDownloadRenewsTokenAfter401() async throws {
        let current = jwt("alice", Date().timeIntervalSince1970 + 3600)
        let renewed = jwt("alice", Date().timeIntervalSince1970 + 7200)
        await NoveliaSessionRenewal.shared.register(app: "download-test") { renewed }
        TransportMock.outcomes = [.status(401), .status(200)]
        let (file, response) = try await NoveliaSessionRenewal.download(
            session: session, request: request(), app: "download-test", tokenProvider: { current })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(status(response), 200)
        XCTAssertEqual(TransportMock.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer \(current)", "Bearer \(renewed)"])
    }

    func testTimeoutsAreShared() {
        XCTAssertEqual(NoveliaRequestTimeout.api, 30)
        XCTAssertEqual(NoveliaRequestTimeout.wenkuVolume, 120)
        XCTAssertEqual(NoveliaRequestTimeout.generatedNovelFile, 180)
    }
}
