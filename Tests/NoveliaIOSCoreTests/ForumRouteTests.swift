import Foundation
import XCTest
@testable import NoveliaIOSCore

/// 论坛、通知与小说链接的应用内路由
/// （原 scripts/test_forum_notice_routes.py 及 test_forum_markdown.py 中的路由检查）。
final class ForumRouteTests: XCTestCase {
    func testNovelRoutes() {
        XCTAssertEqual(ForumNovelRoute(url: URL(string: "https://n.novelia.cc/novel/syosetu/n123#chapter")!)?.provider, "syosetu", "web novel route")
        XCTAssertEqual(ForumNovelRoute(url: URL(string: "https://n.novelia.cc/wenku/book123")!)?.outline.id, "book123", "wenku route")
        XCTAssertEqual(ForumNovelRoute(url: URL(string: "/novel/syosetu/n123")!)?.novelID, "n123", "relative route")
        XCTAssertNil(ForumNovelRoute(url: URL(string: "https://example.com/novel/syosetu/n123")!), "external URL intercepted")
        XCTAssertEqual(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/novel/syosetu/n123")!)?.provider, "syosetu", "legacy web novel route")
        XCTAssertEqual(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/novel/syosetu/n123?source=forum#chapter")!)?.novelID, "n123", "legacy query and fragment")
        XCTAssertEqual(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/wenku/book123")!)?.outline.id, "book123", "legacy wenku route")
        XCTAssertNil(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top.example.com/novel/syosetu/n123")!), "legacy host must match exactly")
        XCTAssertEqual(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/novel")!)?.isCatalogue, true, "legacy novel catalogue")
    }

    func testNoticeRoutes() {
        XCTAssertEqual(ForumNoticeDestination(url: URL(string: "https://forum.novelia.cc/c/announcements")!), .category("announcements", ""))
        XCTAssertEqual(ForumNoticeDestination(url: URL(string: "https://forum.novelia.cc/c/feedback/")!), .category("feedback", ""))
        var url = URLComponents(string: "https://forum.novelia.cc/c/novel")!
        url.queryItems = [URLQueryItem(name: "q", value: "求书集中贴")]
        XCTAssertEqual(ForumNoticeDestination(url: url.url!), .category("novel", "求书集中贴"), "preserve decoded search")
        XCTAssertEqual(ForumNoticeDestination(url: URL(string: "https://forum.novelia.cc/rules")!), .rules)
        for raw in ["https://example.com/rules", "https://forum.novelia.cc.example.com/c/novel", "https://forum.novelia.cc@evil.example/rules",
                    "https://forum.novelia.cc/c/unknown", "https://forum.novelia.cc:8443/rules", "file:///rules", "https://forum.novelia.cc/p/42"] {
            XCTAssertNil(ForumNoticeDestination(url: URL(string: raw)!), "unexpected URL interception: \(raw)")
        }
    }

    func testPostRoutes() {
        let route = forumPostDestination(from: URL(string: "https://forum.novelia.cc/p/42#%E8%AF%84%E8%AE%BA")!)
        XCTAssertEqual(route?.postID, 42)
        XCTAssertEqual(route?.fragment, "评论")
        XCTAssertEqual(forumPostDestination(from: URL(string: "/p/7")!)?.postID, 7, "relative post link")
        XCTAssertNil(forumPostDestination(from: URL(string: "https://example.com/p/42")!), "external host")
        XCTAssertNil(forumPostDestination(from: URL(string: "https://forum.novelia.cc/c/novel")!), "not a post")
        XCTAssertTrue(isLocalForumURL(URL(string: "https://forum.novelia.cc/p/42#top")!, postID: 42))
        XCTAssertFalse(isLocalForumURL(URL(string: "https://forum.novelia.cc/p/43")!, postID: 42))
    }
}
