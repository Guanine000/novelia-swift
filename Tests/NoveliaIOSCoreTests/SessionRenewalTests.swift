import Foundation
import XCTest
@testable import NoveliaIOSCore

private func jwt(_ subject: String, _ exp: Double) -> String {
    let bytes = try! JSONSerialization.data(withJSONObject: ["sub": subject, "exp": exp])
    return "header." + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}

private actor Counter {
    var count = 0
    func bump() { count += 1 }
}

private final class RenewalMock: URLProtocol {
    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var status = 401
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        let code = Self.calls == 1 ? Self.status : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 令牌续期协调器（原 scripts/test_session_renewal.py）。
final class SessionRenewalTests: XCTestCase {
    func testTokenRenewal() async {
        let expired = jwt("alice", 1), fresh = jwt("alice", Date().timeIntervalSince1970 + 3600)
        let counter = Counter(), coordinator = NoveliaSessionRenewal()
        await coordinator.register(app: "n") {
            await counter.bump()
            try? await Task.sleep(nanoseconds: 100_000_000)
            return fresh
        }
        async let a = coordinator.token(app: "n", current: expired)
        async let b = coordinator.token(app: "n", current: expired)
        let values = await (a, b)
        XCTAssertEqual(values.0, fresh)
        XCTAssertEqual(values.1, fresh)
        let calls = await counter.count
        XCTAssertEqual(calls, 1, "concurrent renewals share one request")
        let untouched = await coordinator.token(app: "f", current: expired)
        XCTAssertEqual(untouched, expired, "other app unaffected")
        let anonymous = await coordinator.token(app: "n", current: nil)
        XCTAssertNil(anonymous)
        await coordinator.register(app: "n") { nil }
        let offline = await coordinator.token(app: "n", current: expired)
        XCTAssertEqual(offline, expired, "transient failure keeps the session")
        await coordinator.register(app: "n") { jwt("bob", Date().timeIntervalSince1970 + 3600) }
        let switched = await coordinator.token(app: "n", current: expired)
        XCTAssertEqual(switched, expired, "a token for another account is rejected")
    }

    func testUnauthorizedRetryIsBounded() async throws {
        let fresh = jwt("alice", Date().timeIntervalSince1970 + 3600)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenewalMock.self]
        let session = URLSession(configuration: config)
        let request = URLRequest(url: URL(string: "https://example.invalid/api")!)
        await NoveliaSessionRenewal.shared.register(app: "n") { jwt("alice", Date().timeIntervalSince1970 + 7200) }

        RenewalMock.calls = 0; RenewalMock.status = 401
        let result = try await NoveliaSessionRenewal.data(session: session, request: request, app: "n", tokenProvider: { fresh })
        XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(RenewalMock.calls, 2, "one retry after 401")

        RenewalMock.calls = 0; RenewalMock.status = 500
        _ = try await NoveliaSessionRenewal.data(session: session, request: request, app: "n", tokenProvider: { fresh })
        XCTAssertEqual(RenewalMock.calls, 1, "server errors are not retried")

        RenewalMock.calls = 0; RenewalMock.status = 401
        _ = try await NoveliaSessionRenewal.data(session: session, request: request, app: "n", tokenProvider: { nil })
        XCTAssertEqual(RenewalMock.calls, 1, "anonymous requests are not retried")
    }
}
