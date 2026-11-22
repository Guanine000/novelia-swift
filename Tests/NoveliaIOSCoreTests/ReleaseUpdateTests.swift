import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux 把 URLSession 放在这个模块；Apple 仍由 Foundation 提供。
#endif
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
        XCTAssertNil(store.release?.summary, "response without body omits summary")
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
        XCTAssertNil(store.release?.body, "fallback does not read the page")
        XCTAssertNil(store.release?.summary, "fallback has no summary")
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

    func testOpeningSummaryUsesCurrentReleaseProse() {
        let body = """
        这是 Novelia 1.5.0 正式版。本次新增仿真翻页动画、注脚气泡浮窗。

        ### 阅读与排版

        - **仿真翻页**：不应出现在摘要中。
        """
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(body), "这是 Novelia 1.5.0 正式版。本次新增仿真翻页动画、注脚气泡浮窗。")
        let published = "这是 Novelia 1.5.0 正式版。本次新增仿真翻页动画、注脚气泡浮窗、摘录与笔记（含 WebDAV 同步）、有声朗读（TTS）、阅读 AI（剧情总结与人物卡）以及 iPad 适配与键盘快捷键扩展。"
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(published + "\n\n### 阅读与排版\n\n- 详细列表"), published)
        XCTAssertLessThan(published.count, NoveliaReleaseNotes.summaryCharacterLimit)
        let release = NoveliaGitHubRelease(tag_name: "v1.5.0",
                                           html_url: "https://github.com/Guanine000/novelia-swift/releases/tag/v1.5.0",
                                           body: body, draft: false, prerelease: false)
        XCTAssertEqual(release.summary, "这是 Novelia 1.5.0 正式版。本次新增仿真翻页动画、注脚气泡浮窗。")
        XCTAssertEqual(release.updatePromptMessage, """
        Novelia 1.5.0 已发布。说明与安装包都在更新页面。

        这是 Novelia 1.5.0 正式版。本次新增仿真翻页动画、注脚气泡浮窗。
        """)
        XCTAssertTrue(release.shouldOffer(current: "1.4.1", ignored: ""))
    }

    func testOpeningSummarySkipsLeadingHeadingsWhitespaceAndCRLF() {
        let crlf = "\r\n \r\n## 更新内容\r\n### 细节\r\n\r\n  修复了阅读进度。\r\n\r\n- 列表不进入摘要\r\n"
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(crlf), "修复了阅读进度。")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("\r## 标题\r\r正文"), "正文")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("\u{feff}说明"), "说明")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("---\n\n正式说明。\n\n---\n"), "正式说明。")
        let wrapped = "第一行说明\n第二行仍属同段。\n\n另一段"
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(wrapped), "第一行说明 第二行仍属同段。")
    }

    func testOpeningSummaryOmitsEmptyMissingAndNullBody() throws {
        XCTAssertNil(NoveliaReleaseNotes.openingSummary(nil))
        XCTAssertNil(NoveliaReleaseNotes.openingSummary(""))
        XCTAssertNil(NoveliaReleaseNotes.openingSummary(" \n\n## 只有标题\n"))
        XCTAssertNil(NoveliaReleaseNotes.openingSummary("**"))
        let page = "https://github.com/Guanine000/novelia-swift/releases/tag/v0.9.0"
        let missing = try JSONDecoder().decode(NoveliaGitHubRelease.self, from: Data("""
        {"tag_name":"v0.9.0","html_url":"\(page)","draft":false,"prerelease":false}
        """.utf8))
        XCTAssertNil(missing.body)
        XCTAssertNil(missing.summary)
        XCTAssertEqual(missing.updatePromptMessage, "Novelia 0.9.0 已发布。说明与安装包都在更新页面。")
        XCTAssertTrue(missing.shouldOffer(current: "0.8.0", ignored: ""))
        let nullBody = try JSONDecoder().decode(NoveliaGitHubRelease.self, from: Data("""
        {"tag_name":"v0.9.0","html_url":"\(page)","draft":false,"prerelease":false,"body":null}
        """.utf8))
        XCTAssertNil(nullBody.body)
        XCTAssertNil(nullBody.summary)
        XCTAssertEqual(nullBody.updatePromptMessage, missing.updatePromptMessage)
        let blank = try JSONDecoder().decode(NoveliaGitHubRelease.self, from: Data("""
        {"tag_name":"v0.9.0","html_url":"\(page)","draft":false,"prerelease":false,"body":"  \\n## 只有标题\\n"}
        """.utf8))
        XCTAssertNil(blank.summary)
        XCTAssertFalse(NoveliaGitHubRelease(tag_name: "v0.9.0", html_url: page, body: "这是说明。",
                                            draft: false, prerelease: true).shouldOffer(current: "0.8.0", ignored: ""))
        XCTAssertFalse(NoveliaGitHubRelease(tag_name: "v0.9.0", html_url: "https://example.com/download", body: "这是说明。",
                                            draft: false, prerelease: false).shouldOffer(current: "0.8.0", ignored: ""))
    }

    func testOpeningSummaryFlattensMarkdownMarkersAndLinks() {
        let prose = """
        ## 标题

        本次包含 **加粗**、`行内代码` 与 [完整说明](https://github.com/Guanine000/novelia-swift/releases/tag/v1.5.0)。

        - 列表项
        """
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(prose), "本次包含 加粗、行内代码 与 完整说明。")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("见 ![封面](https://example.com/a.png) 与 <https://example.com/notes>。"),
                       "见 封面 与 https://example.com/notes。")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(#"保留 reader_book 键，\*不是强调\*，代码 `**原样**`。"#),
                       "保留 reader_book 键，*不是强调*，代码 **原样**。")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("[说明](https://example.com/a \"标题\") 和 [参考][notes]"), "说明 和 参考")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("见 [附录] 即可"), "见 [附录] 即可")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("1.5.0 正式版保持完整。"), "1.5.0 正式版保持完整。")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("- 修复封面\n- **修复翻页**"), "修复封面 修复翻页")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("1. 修复封面\n2. 修复翻页"), "修复封面 修复翻页")
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary("> 引用说明"), "引用说明")
    }

    func testOpeningSummaryBoundsLongParagraph() {
        XCTAssertEqual(NoveliaReleaseNotes.summaryCharacterLimit, 160)
        let exact = String(repeating: "甲", count: 160)
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(exact), exact)
        let over = String(repeating: "乙", count: 161)
        XCTAssertEqual(NoveliaReleaseNotes.openingSummary(over), String(repeating: "乙", count: 159) + "…")
        let body = "## 标题\n\n" + String(repeating: "字", count: 180) + "\n\n第二段不应出现\n\n### 阅读与排版\n"
        let summary = NoveliaReleaseNotes.openingSummary(body)
        XCTAssertEqual(summary, String(repeating: "字", count: 159) + "…")
        XCTAssertEqual(summary?.count, 160)
        XCTAssertFalse(summary?.contains("第二段") == true)
        XCTAssertFalse(summary?.contains("阅读") == true)
    }

    /// API 正文进入摘要；限流后的网页回退即使响应里有说明文字，也不解析。
    func testAPISummaryIsKeptAndFallbackDoesNotParseHTML() async {
        let name = "NoveliaSummaryTest-\(UUID())"
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
            ReleaseMock.payload = ""
            ReleaseMock.sawAuthorization = false
        }
        ReleaseMock.status = 200
        ReleaseMock.rateLimited = false
        ReleaseMock.fallbackURL = nil
        ReleaseMock.sawAuthorization = false
        ReleaseMock.requestedHosts = []
        ReleaseMock.payload = githubReleaseJSON(tag: "v0.9.0", body: "这是说明。\n\n### 详情\n\n- 条目")
        let store = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
        let available = await store.checkManually()
        XCTAssertEqual(available, .available)
        XCTAssertEqual(store.release?.summary, "这是说明。")
        XCTAssertFalse(store.release?.summary?.contains("条目") == true)
        store.ignore(store.release!)
        XCTAssertNil(store.release)

        ReleaseMock.payload = githubReleaseJSON(tag: "v0.9.1", body: NSNull())
        let nullBody = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.8.0")
        let nullResult = await nullBody.checkManually()
        XCTAssertEqual(nullResult, .available)
        XCTAssertEqual(nullBody.release?.tag_name, "v0.9.1")
        XCTAssertNil(nullBody.release?.summary)

        ReleaseMock.status = 403
        ReleaseMock.rateLimited = true
        ReleaseMock.fallbackURL = "https://github.com/Guanine000/novelia-swift/releases/tag/v1.0.0"
        ReleaseMock.payload = "<html><body>这是不应解析的网页正文</body></html>"
        let fallback = NoveliaUpdateStore(defaults: defaults, session: session, currentVersion: "0.9.1")
        let fallbackResult = await fallback.checkManually()
        XCTAssertEqual(fallbackResult, .available)
        XCTAssertEqual(fallback.release?.tag_name, "v1.0.0")
        XCTAssertNil(fallback.release?.body)
        XCTAssertNil(fallback.release?.summary)
        XCTAssertFalse(ReleaseMock.sawAuthorization)
        XCTAssertEqual(Array(ReleaseMock.requestedHosts.suffix(2)), ["api.github.com", "github.com"])
    }
}

private func githubReleaseJSON(tag: String, body: Any) -> String {
    let object: [String: Any] = [
        "tag_name": tag,
        "html_url": "https://github.com/Guanine000/novelia-swift/releases/tag/\(tag)",
        "draft": false,
        "prerelease": false,
        "body": body,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
