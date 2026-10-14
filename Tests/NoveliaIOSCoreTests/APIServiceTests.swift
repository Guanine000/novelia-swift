import Foundation
import XCTest
@testable import NoveliaIOSCore

private final class ServiceHTTPMock: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct OfflineContent: NovelContentService {
    func chapter(providerId: String, novelId: String, chapterId: String) async throws -> NovelChapter {
        NovelChapter(id: chapterId, title: "Offline", originalText: "Local", translatedText: "本地")
    }
}

final class APIServiceTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceHTTPMock.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        ServiceHTTPMock.handler = nil
    }

    private func services() throws -> APIServiceCollection {
        let configuration = APIConfiguration(
            novelAPI: URL(string: "https://novels.example.test/custom/")!,
            forumAPI: URL(string: "https://forum.example.test/discussion/v1/")!,
            bookCommentsOrigin: URL(string: "https://comments.example.test/")!,
            novelOrigin: URL(string: "https://novels.example.test")!,
            forumOrigin: URL(string: "https://forum.example.test")!,
            authentication: try AuthenticationConfiguration(origin: URL(string: "https://login.example.test")!))
        return .novelia(configuration: configuration, session: session,
                        novelToken: { "novel-test" }, forumToken: { "forum-test" })
    }

    func testConfiguredCatalogAddressAndPageTranslation() async throws {
        ServiceHTTPMock.handler = { request in
            XCTAssertEqual(request.url?.host, "novels.example.test")
            XCTAssertEqual(request.url?.path, "/custom/novel")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "page" }?.value, "0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer novel-test")
            return Data(#"{"pageNumber":3,"items":[]}"#.utf8)
        }
        let result = try await services().catalog.searchNovels(query: "book", page: 1, exactTag: false)
        XCTAssertEqual(result.pageCount, 3)
    }

    func testBookCommentsUseConfiguredOriginAndNovelSession() async throws {
        ServiceHTTPMock.handler = { request in
            XCTAssertEqual(request.url?.host, "comments.example.test")
            XCTAssertEqual(request.url?.path, "/api/v1/external/comment/novel/web-example-book")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer novel-test")
            return Data(#"{"total":0,"items":[]}"#.utf8)
        }
        let result = try await services().bookComments.novelComments(subjectKey: "web-example-book", page: 1, pageSize: 10)
        XCTAssertEqual(result.total, 0)
    }

    func testForumUsesItsOwnPrefixAndSession() async throws {
        ServiceHTTPMock.handler = { request in
            XCTAssertEqual(request.url?.host, "forum.example.test")
            XCTAssertEqual(request.url?.path, "/discussion/v1/category")
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("category/"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer forum-test")
            return Data("[]".utf8)
        }
        let categories = try await services().forum.categories()
        XCTAssertTrue(categories.isEmpty)
    }

    func testReplacingOneServiceDoesNotFallBackToNetwork() async throws {
        ServiceHTTPMock.handler = { _ in
            XCTFail("Offline replacement must not make an HTTP request")
            throw URLError(.unsupportedURL)
        }
        let base = try services()
        let replaced = APIServiceCollection(catalog: base.catalog, content: OfflineContent(),
            wenku: base.wenku, favorites: base.favorites, history: base.history,
            downloads: base.downloads, bookComments: base.bookComments, forum: base.forum)
        let chapter = try await replaced.content.chapter(providerId: "any", novelId: "any", chapterId: "one")
        XCTAssertEqual(chapter.title, "Offline")
        XCTAssertEqual(chapter.translatedText, "本地")
    }

    func testAuthenticationConfigurationPreservesRoutesAndTrustBoundary() throws {
        let production = APIConfiguration.production.authentication
        XCTAssertEqual(production.refreshURL(app: "n").absoluteString,
                       "https://auth.novelia.cc/api/v1/auth/refresh?app=n")
        XCTAssertEqual(production.refreshURL(app: "f").absoluteString,
                       "https://auth.novelia.cc/api/v1/auth/refresh?app=f")
        XCTAssertTrue(production.trusts(scheme: "https", host: "auth.novelia.cc", port: 0))
        XCTAssertFalse(production.trusts(scheme: "http", host: "auth.novelia.cc", port: 443))
        XCTAssertFalse(production.trusts(scheme: "https", host: "auth.novelia.cc.evil.test", port: 443))
        XCTAssertFalse(production.trusts(scheme: "https", host: "auth.novelia.cc", port: 8443))
        let custom = try AuthenticationConfiguration(origin: URL(string: "https://login.example.test:8443/")!,
            refreshPath: "/session/renew", loginPath: "/session/login", registerPath: "/session/register")
        XCTAssertEqual(custom.refreshURL(app: "f").path, "/session/renew")
        XCTAssertEqual(custom.loginURL(app: "n").query, "app=n&theme=system")
        XCTAssertTrue(custom.trusts(scheme: "https", host: "login.example.test", port: 8443))
        XCTAssertFalse(custom.trusts(scheme: "https", host: "login.example.test", port: 0))
    }

    func testInvalidAuthenticationConfigurationRejected() {
        for raw in ["http://login.example.test", "https://user:pass@login.example.test",
                    "https://login.example.test/path", "https://login.example.test?x=1",
                    "https://login.example.test#fragment"] {
            XCTAssertThrowsError(try AuthenticationConfiguration(origin: URL(string: raw)!))
        }
        XCTAssertThrowsError(try AuthenticationConfiguration(origin: URL(string: "https://login.example.test")!,
                                                             loginPath: "//evil.test/login"))
    }

    func testAuthenticationOriginMatchesBrowserNormalization() throws {
        let configuration = try AuthenticationConfiguration(origin: URL(string: "https://LOGIN.example.test:443/")!)
        XCTAssertEqual(configuration.origin.absoluteString, "https://login.example.test")
        XCTAssertTrue(configuration.trusts(scheme: "https", host: "login.example.test", port: 443))
    }
}
