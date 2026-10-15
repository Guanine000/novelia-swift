import Foundation
import XCTest
@testable import NoveliaIOSCore

private final class ReleaseMock: URLProtocol {
    nonisolated(unsafe) static var hits = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var payload = ""
    nonisolated(unsafe) static var sawAuthorization = false
    nonisolated(unsafe) static var rateLimited = false
    nonisolated(unsafe) static var fallbackURL: String?
    nonisolated(unsafe) static var requestedHosts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.hits += 1
        Self.requestedHosts.append(request.url!.host!)
        if request.value(forHTTPHeaderField: "Authorization") != nil { Self.sawAuthorization = true }
        let isFallback = request.url?.host == "github.com"
        let finalURL = isFallback ? Self.fallbackURL.flatMap(URL.init(string:)) : nil
        let status = finalURL != nil ? 200 : Self.status
        let headers = !isFallback && Self.rateLimited ? ["X-RateLimit-Remaining": "0"] : nil
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: finalURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
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
        func v(_ text: String) -> NoveliaReleaseVersion { NoveliaReleaseVersion(text)! }
        XCTAssertGreaterThan(v("v0.10.0"), v("0.9.9"), "numeric comparison")
        // 兼容的标签写法。
        XCTAssertEqual(v("v0.8"), v("0.8.0"), "missing parts count as zero")
        XCTAssertEqual(v("V1"), v("1.0.0"))
        XCTAssertEqual(v("release-0.20.0"), v("0.20.0"))
        XCTAssertEqual(v("Novelia-v0.20.0"), v("0.20.0"))
        XCTAssertEqual(v("0.8.1+34"), v("0.8.1"), "build metadata is ignored")
        XCTAssertEqual(v("1.2.3.4").parts, [1, 2, 3, 4])
        XCTAssertGreaterThan(v("1.2.3.1"), v("1.2.3"))
        XCTAssertEqual(v("v0.19.2-test.2").display, "0.19.2-test.2")
        XCTAssertEqual(v("v0.8").display, "0.8.0")
        // 预发布按 SemVer 排序。
        XCTAssertLessThan(v("0.20.0-test.1"), v("0.20.0"))
        XCTAssertGreaterThan(v("0.20.0-test.1"), v("0.19.9"))
        XCTAssertLessThan(v("0.20.0-test.2"), v("0.20.0-test.10"), "numeric identifiers compare numerically")
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
        XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"), "numeric identifiers sort before letters")
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-beta"))
        XCTAssertNotEqual(v("0.20.0-test.1"), v("0.20.0"))
        for invalid in ["0.x.0", "", "v", "1.2.3.4.5", "1..2", "0.8.1-", "0.8.1-te st", "0.8.1+", "1.0/2", "测试0.8.1", "1.2.3_4"] {
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
        let shortTag = NoveliaGitHubRelease(tag_name: "v0.9", html_url: "https://github.com/Guanine000/novelia-swift/releases/tag/v0.9",
                                            draft: false, prerelease: false)
        XCTAssertTrue(shortTag.shouldOffer(current: "0.8.2", ignored: ""), "two-part tag is understood")
        XCTAssertFalse(shortTag.shouldOffer(current: "0.9.0", ignored: ""), "0.9 equals 0.9.0")
        XCTAssertFalse(shortTag.shouldOffer(current: "0.8.2", ignored: shortTag.version!.display), "ignored by display string")
        XCTAssertTrue(release.shouldOffer(current: "0.8.2-test.3", ignored: ""), "stable beats a test build of the same number")
    }

    /// 手动检查：启动检查关闭、版本被忽略时仍会提示；同版本报告已是最新；请求失败报告失败。
    func testManualCheck() async {
        let name = "NoveliaManualUpdateTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseMock.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ReleaseMock.status = 200
        ReleaseMock.payload = #"{"tag_name":"v0.9.0","html_url":"https://github.com/Guanine000/novelia-swift/releases/tag/v0.9.0","draft":false,"prerelease":false}"#
        defaults.set(false, forKey: NoveliaUpdateStore.enabledKey)
        defaults.set("0.9.0", forKey: NoveliaUpdateStore.ignoredKey)

        let older = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
        let available = await older.checkManually()
        XCTAssertEqual(available, .available)
        XCTAssertEqual(older.release?.tag_name, "v0.9.0")

        let current = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.9.0")
        let upToDate = await current.checkManually()
        XCTAssertEqual(upToDate, .upToDate(current: "0.9.0"))
        XCTAssertNil(current.release)

        ReleaseMock.status = 500
        let failed = await current.checkManually()
        XCTAssertEqual(failed, .failed)
        ReleaseMock.status = 200

        // 重复点击：进行中的检查不另发请求，第二次返回 inProgress，界面不显示“无法获取”。
        async let first = current.checkManually()
        async let second = current.checkManually()
        let results = await [first, second]
        XCTAssertEqual(Set(results.map { "\($0)" }), ["upToDate(current: \"0.9.0\")", "inProgress"])
    }

    func testRateLimitUsesTrustedReleasePageAndReportsLimitIfBothFail() async {
        let name = "NoveliaFallbackTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseMock.self]
        let session = URLSession(configuration: config)
        defer {
            defaults.removePersistentDomain(forName: name)
            session.invalidateAndCancel()
            ReleaseMock.status = 200
            ReleaseMock.rateLimited = false
            ReleaseMock.fallbackURL = nil
        }
        ReleaseMock.status = 403
        ReleaseMock.rateLimited = true
        ReleaseMock.sawAuthorization = false
        ReleaseMock.requestedHosts = []
        ReleaseMock.payload = #"{"message":"API rate limit exceeded"}"#
        ReleaseMock.fallbackURL = "https://github.com/Guanine000/novelia-swift/releases/tag/v0.9.0"
        let store = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
        let available = await store.checkManually()
        XCTAssertEqual(available, .available)
        XCTAssertEqual(store.release?.tag_name, "v0.9.0")
        XCTAssertEqual(ReleaseMock.requestedHosts, ["api.github.com", "github.com"])
        XCTAssertFalse(ReleaseMock.sawAuthorization)

        let current = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.9.0")
        let result = await current.checkManually()
        XCTAssertEqual(result, .upToDate(current: "0.9.0"))
        // 重定向必须仍属于指定仓库的正式发布页，不能把登录页、其他仓库或测试版当作最新正式版。
        for invalid in [nil, "https://example.com/releases/tag/v1.0.0",
                        "https://github.com/other/repo/releases/tag/v1.0.0",
                        "https://github.com/login", "https://github.com/Guanine000/novelia-swift/releases/latest",
                        "https://github.com/Guanine000/novelia-swift/releases/tag/v1.0.0-test.1"] as [String?] {
            ReleaseMock.fallbackURL = invalid
            let failed = await current.checkManually()
            XCTAssertEqual(failed, .rateLimited)
        }
    }
}
