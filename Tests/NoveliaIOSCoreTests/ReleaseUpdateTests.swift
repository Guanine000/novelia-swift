import Foundation
import XCTest
@testable import NoveliaIOSCore

private final class ReleaseMock: URLProtocol {
    nonisolated(unsafe) static var hits = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var payload = ""
    nonisolated(unsafe) static var sawAuthorization = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.hits += 1
        if request.value(forHTTPHeaderField: "Authorization") != nil { Self.sawAuthorization = true }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 启动时检查 GitHub release（原 scripts/test_release_updates.py）。
@MainActor
final class ReleaseUpdateTests: XCTestCase {
    func testVersionParsing() {
        XCTAssertGreaterThan(NoveliaReleaseVersion("v0.10.0")!, NoveliaReleaseVersion("0.9.9")!, "numeric comparison")
        for invalid in ["0.8.1-test.1", "v0.8", "0.x.0", "", "0.8.1+34"] {
            XCTAssertNil(NoveliaReleaseVersion(invalid), "invalid version \(invalid)")
        }
    }

    func testStartupCheck() async {
        let name = "NoveliaUpdatesTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseMock.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ReleaseMock.hits = 0; ReleaseMock.status = 200; ReleaseMock.sawAuthorization = false
        ReleaseMock.payload = #"{"tag_name":"v0.8.1","html_url":"https://github.com/Guanine000/novelia-swift/releases/tag/v0.8.1","draft":false,"prerelease":false}"#

        let store = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
        await store.check()
        XCTAssertEqual(store.release?.version?.display, "0.8.1", "new stable offered")
        await store.check()
        XCTAssertEqual(ReleaseMock.hits, 1, "once per launch")
        store.ignore(store.release!)
        XCTAssertNil(store.release, "ignore closes alert")

        let nextLaunch = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
        await nextLaunch.check()
        XCTAssertNil(nextLaunch.release, "ignored persists")
        ReleaseMock.payload = ReleaseMock.payload.replacingOccurrences(of: "0.8.1", with: "0.8.2")
        await nextLaunch.check(force: true)
        XCTAssertNotNil(nextLaunch.release, "later release offered")

        defaults.set(false, forKey: NoveliaUpdateStore.enabledKey)
        let hits = ReleaseMock.hits
        await nextLaunch.check(force: true)
        XCTAssertEqual(ReleaseMock.hits, hits, "disabled avoids HTTP")
        defaults.set(true, forKey: NoveliaUpdateStore.enabledKey)

        nextLaunch.release = nil
        ReleaseMock.status = 403
        await nextLaunch.check(force: true)
        XCTAssertNil(nextLaunch.release, "HTTP error silent")
        ReleaseMock.status = 200
        ReleaseMock.payload = "invalid json"
        await nextLaunch.check(force: true)
        XCTAssertNil(nextLaunch.release, "malformed response silent")
        XCTAssertFalse(ReleaseMock.sawAuthorization, "public API needs no token")
    }

    func testOfferRules() {
        let release = NoveliaGitHubRelease(tag_name: "v0.8.2", html_url: "https://github.com/Guanine000/novelia-swift/releases/tag/v0.8.2",
                                           draft: false, prerelease: false)
        XCTAssertFalse(release.shouldOffer(current: "0.8.2", ignored: ""), "equal suppressed")
        XCTAssertFalse(release.shouldOffer(current: "0.9.0", ignored: ""), "downgrade suppressed")
        XCTAssertFalse(NoveliaGitHubRelease(tag_name: "v0.8.2", html_url: "https://example.com/download", draft: false, prerelease: false)
            .shouldOffer(current: "0.8.0", ignored: ""), "untrusted URL suppressed")
        XCTAssertFalse(NoveliaGitHubRelease(tag_name: "v0.8.2", html_url: release.html_url, draft: false, prerelease: true)
            .shouldOffer(current: "0.8.0", ignored: ""), "prerelease suppressed")
    }
}
