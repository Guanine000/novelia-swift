import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NoveliaIOSCore

/// 论坛 Markdown 块、行内属性和剧透（原 scripts/test_forum_markdown.py）。
final class ForumMarkdownTests: XCTestCase {
    private let spoilerPattern = try! NSRegularExpression(pattern: "!!!!([\\s\\S]+?)!!!!|!!([\\s\\S]+?)!!")

    func testSoftLineBreaksAndLinksSurvive() throws {
        for mode in [ForumMarkdownMode.article, .comment] {
            let source = "第一行\n[下载](https://example.com/download)\n说明文字\n[源码](https://example.com/source)"
            let blocks = parseForumMarkdown(source, mode: mode)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks.first?.text, source, "soft line breaks collapsed")
            let rendered = try forumInlineAttributes(blocks[0].text)
            XCTAssertEqual(String(rendered.characters).components(separatedBy: "\n").count, 4, "inline renderer lost line breaks")
            XCTAssertEqual(rendered.runs.filter { $0.link != nil }.count, 2, "line-break parsing damaged links")
        }
        let rawLink = try forumInlineAttributes("第一行\nhttps://example.com/download\n尾行")
        XCTAssertTrue(rawLink.runs.contains { $0.link?.absoluteString == "https://example.com/download" }, "bare URL link missing")
    }

    func testTables() {
        let table = parseForumMarkdown("| 名称 | 链接 |\n| :--- | ---: |\n| A | [B](https://n.novelia.cc/novel/x/y) |\n\n尾段")
        XCTAssertEqual(table.count, 2, "table/paragraph boundaries")
        guard case let .table(rows) = table[0].kind else { return XCTFail("table missing") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][0], "A")

        // 较短的分隔单元格（如论坛帖子 263），使用合成内容复现。
        for mode in [ForumMarkdownMode.article, .comment] {
            for delimiter in ["-", "--", "---", ":-", "-:", ":--:"] {
                let blocks = parseForumMarkdown("| 评分 | 链接 | 评语 | 日期 |\n| \(delimiter) | \(delimiter) | \(delimiter) | \(delimiter) |\n| ☆☆☆☆☆ | [小说](https://books.fishhawk.top/novel/hameln/example) | **更新** | 20250226 |\n|  | *分隔* | | |\n\n后文", mode: mode)
                XCTAssertEqual(blocks.count, 2, "short delimiter block boundaries")
                guard case let .table(rows) = blocks[0].kind else { return XCTFail("short delimiter \(delimiter) not recognized") }
                XCTAssertTrue(rows.count == 3 && rows.allSatisfy { $0.count == 4 }, "four-column table")
                XCTAssertEqual(rows[2], ["", "*分隔*", "", ""], "blank cells preserved")
            }
        }
        let mismatched = parseForumMarkdown("| a | b |\n| -- |\n| c | d |")
        XCTAssertFalse(mismatched.contains { if case .table = $0.kind { return true }; return false },
                       "mismatched header/delimiter must not become table")
        XCTAssertEqual(forumTableCells("a | | b"), ["a", "", "b"], "unframed interior empty cell")
        XCTAssertEqual(forumTableCells(" | b"), ["b"], "leading pipe boundary")
        XCTAssertEqual(forumTableCells("| a\\|b | `x|y` |"), ["a\\|b", "`x|y`"], "escaped and code pipes")
    }

    func testStarRatingAndFencedCode() {
        for mode in [ForumMarkdownMode.article, .comment] {
            let stars = parseForumMarkdown("::: star 4.5\n:::\n\n正文", mode: mode)
            XCTAssertEqual(stars.count, 2, "rating closing directive")
            guard case let .starRating(value) = stars[0].kind else { return XCTFail("rating missing") }
            XCTAssertEqual(value, 4.5, "half stars")
        }
        let codeBlock = parseForumMarkdown("```\n::: star 5\n| a |\n| --- |\n```", mode: .comment)
        XCTAssertEqual(codeBlock.count, 1, "fenced literal")
        guard case .code = codeBlock[0].kind else { return XCTFail("fence parsed as directive") }
    }

    func testStrikethroughKeepsLinks() throws {
        for value in ["~~[小说](https://n.novelia.cc/novel/x/y)~~", "[~~小说~~](https://n.novelia.cc/novel/x/y)",
                      "<del>[小说](https://n.novelia.cc/novel/x/y)</del>"] {
            let rendered = try forumInlineAttributes(value)
            XCTAssertEqual(String(rendered.characters), "小说", "strike label")
            XCTAssertTrue(rendered.runs.contains { $0.link?.absoluteString == "https://n.novelia.cc/novel/x/y" }, "strike removed link")
            XCTAssertTrue(rendered.runs.contains { $0.strikethroughStyle != nil }, "strike missing")
        }
    }

    func testSpoilersHideLinksUntilRevealed() {
        for sample in ["!!文字中的[链接](https://example.com/spoiler-link)!!", "!!!![小说](https://n.novelia.cc/novel/x/y)!!!!",
                       "[!!小说!!](https://n.novelia.cc/novel/x/y)", "[!!!!小说!!!!](https://n.novelia.cc/novel/x/y)",
                       "`!!示例!!` 正文 !![链接](https://example.com/spoiler-link)!!"] {
            let revealed = renderInlineMarkdown(sample, spoilersRevealed: true, pattern: spoilerPattern)
            XCTAssertTrue(revealed.runs.contains { $0.link != nil }, "revealed spoiler link missing: \(sample)")
            var concealed = 0
            let hidden = renderInlineMarkdown(sample, spoilersRevealed: false, pattern: spoilerPattern) { _ in concealed += 1 }
            XCTAssertFalse(hidden.runs.contains { $0.link != nil }, "hidden spoiler link remains actionable: \(sample)")
            XCTAssertGreaterThan(concealed, 0, "concealment styling not applied: \(sample)")
        }
        XCTAssertTrue(forumSpoilerMatches("`!!示例!!`", pattern: spoilerPattern).isEmpty, "inline code treated as spoiler")
        XCTAssertTrue(forumSpoilerMatches("``!!示例!!``", pattern: spoilerPattern).isEmpty, "double-backtick code treated as spoiler")
        XCTAssertEqual(forumSpoilerMarkdown("`[!!示例!!](https://example.com)`"), "`[!!示例!!](https://example.com)`",
                       "link syntax inside code changed")
        let adjacent = renderInlineMarkdown("[前半](https://n.novelia.cc/novel/x/y)!!遮挡!![后半](https://n.novelia.cc/novel/x/y)",
                                            spoilersRevealed: true, pattern: spoilerPattern)
        XCTAssertEqual(adjacent.runs.filter { $0.link != nil }.count, 2, "links beside spoiler lost")
    }

    func testCommentSubmissionUsesDoubleSpoilerMarkers() {
        XCTAssertEqual(forumCommentMarkdownForSubmission("前!!!!剧透!!!!后"), "前!!剧透!!后")
    }

    /// 帖子正文里的远程图（含 details 中的表格）必须从 Markdown 拆成可加载的地址，而不是留给不会画远程图的 Text。
    func testRemoteImagesInDetailsTableAndInlineText() {
        let markdown = """
        说明
        ::: details 实机截图
        | ![](https://free.picui.cn/free/a.png) | ![](https://free.picui.cn/free/b.png) |
        | --- | --- |
        | ![](https://free.picui.cn/free/c.png) | ![](https://free.picui.cn/free/d.png) |
        :::
        """
        let blocks = parseForumMarkdown(markdown)
        XCTAssertEqual(blocks.count, 2)
        guard case .paragraph = blocks[0].kind else { return XCTFail("lead paragraph") }
        guard case .details(let title) = blocks[1].kind else { return XCTFail("details") }
        XCTAssertEqual(title, "实机截图")
        let inner = parseForumMarkdown(blocks[1].text)
        XCTAssertEqual(inner.count, 1)
        guard case .table(let rows) = inner[0].kind else { return XCTFail("screenshot table") }
        XCTAssertEqual(rows.count, 2)
        let urls = rows.flatMap { $0 }.map { cell -> String? in
            let segments = forumInlineSegments(cell)
            guard segments.count == 1, case .image(let image) = segments[0] else { return nil }
            XCTAssertNil(image.link)
            XCTAssertEqual(image.alt, "")
            return forumMarkdownImageURL(image.destination, relativeTo: APIConfiguration.production.forumOrigin)?.absoluteString
        }
        XCTAssertEqual(urls, [
            "https://free.picui.cn/free/a.png",
            "https://free.picui.cn/free/b.png",
            "https://free.picui.cn/free/c.png",
            "https://free.picui.cn/free/d.png",
        ])

        for mode in [ForumMarkdownMode.article, .comment] {
            let paragraph = parseForumMarkdown("见 ![](https://example.com/a.png) 图", mode: mode)
            XCTAssertEqual(paragraph.count, 1)
            let segments = forumInlineSegments(paragraph[0].text)
            XCTAssertEqual(segments.count, 3)
            guard case .text(let before) = segments[0], case .image(let image) = segments[1], case .text(let after) = segments[2] else {
                return XCTFail("mixed paragraph \(mode)")
            }
            XCTAssertEqual(before, "见 ")
            XCTAssertEqual(image.destination, "https://example.com/a.png")
            XCTAssertEqual(after, " 图")
        }

        let stacked = forumInlineSegments("![](https://example.com/a.png)\n![](https://example.com/b.png)")
        XCTAssertEqual(stacked.count, 2)
        XCTAssertTrue(stacked.allSatisfy(\.isImage))

        let titled = forumInlineSegments("![](https://example.com/a.png \"标题\")")
        guard case .image(let titledImage) = titled.first else { return XCTFail("title") }
        XCTAssertEqual(titledImage.destination, "https://example.com/a.png")

        let bracketed = forumInlineSegments("![](<https://example.com/a b.png>)")
        guard case .image(let bracketedImage) = bracketed.first else { return XCTFail("angle") }
        XCTAssertEqual(bracketedImage.destination, "https://example.com/a b.png")

        let linked = forumInlineSegments("[![封面](https://example.com/a.png)](https://n.novelia.cc/novel/x/y)")
        guard linked.count == 1, case .image(let linkedImage) = linked[0] else { return XCTFail("linked image") }
        XCTAssertEqual(linkedImage.alt, "封面")
        XCTAssertEqual(linkedImage.destination, "https://example.com/a.png")
        XCTAssertEqual(linkedImage.link, "https://n.novelia.cc/novel/x/y")

        let richer = "[see ![x](https://example.com/a.png)](https://example.com/go)"
        XCTAssertEqual(forumInlineSegments(richer), [.text(richer)], "image inside a text link must stay a link")
        let plainLink = "[下载](https://example.com/download)"
        XCTAssertEqual(forumInlineSegments(plainLink), [.text(plainLink)])
        let coded = "文字 `![](https://example.com/a.png)` 结束"
        XCTAssertEqual(forumInlineSegments(coded), [.text(coded)])
        let escaped = "\\![](https://example.com/a.png)"
        XCTAssertEqual(forumInlineSegments(escaped), [.text(escaped)])

        let fenced = parseForumMarkdown("```\n![](https://example.com/a.png)\n```")
        XCTAssertEqual(fenced.count, 1)
        guard case .code = fenced[0].kind else { return XCTFail("fence") }
        XCTAssertTrue(fenced[0].text.contains("![](https://example.com/a.png)"))
    }

    func testSpoilerImagesStayHiddenUntilRevealed() {
        let wrapped = "!!!!![](https://example.com/a.png)!!!!"
        XCTAssertEqual(forumInlineSegments(wrapped, spoilersRevealed: false), [.text(wrapped)])
        let shown = forumInlineSegments(wrapped, spoilersRevealed: true)
        guard shown.count == 1, case .image(let image) = shown[0] else { return XCTFail("revealed spoiler image \(shown)") }
        XCTAssertEqual(image.destination, "https://example.com/a.png")

        let mixed = "前文 !!隐藏 ![](https://example.com/a.png)!!"
        let hidden = forumInlineSegments(mixed, spoilersRevealed: false)
        XCTAssertEqual(hidden, [.text(mixed)])
        let revealed = forumInlineSegments(mixed, spoilersRevealed: true)
        XCTAssertFalse(revealed.contains { if case .text(let text) = $0 { return text.contains("!!") }; return false })
        guard case .image(let revealedImage) = revealed.last else { return XCTFail("revealed mixed") }
        XCTAssertEqual(revealedImage.destination, "https://example.com/a.png")

        let outside = forumInlineSegments("![](https://example.com/a.png)\n!!隐藏!!", spoilersRevealed: false)
        XCTAssertEqual(outside.count, 2)
        XCTAssertTrue(outside[0].isImage)
        guard case .text(let spoiler) = outside[1] else { return XCTFail("outside spoiler") }
        XCTAssertTrue(spoiler.contains("!!隐藏!!"))

        // `!![文字](url)!!` 含有 `![文字](url)`，不能被当成图片，否则剧透链接会被拆掉。
        let spoilerLink = "!![测试链接](https://n.novelia.cc/novel/hameln/test)!!"
        XCTAssertEqual(forumInlineSegments(spoilerLink, spoilersRevealed: false), [.text(spoilerLink)])
        XCTAssertEqual(
            forumInlineSegments(spoilerLink, spoilersRevealed: true),
            [.text("[测试链接](https://n.novelia.cc/novel/hameln/test)")]
        )
    }

    func testMarkdownImageURLsAcceptOnlyHTTP() {
        let base = APIConfiguration.production.forumOrigin
        XCTAssertEqual(
            forumMarkdownImageURL("https://free.picui.cn/free/a.png", relativeTo: base)?.absoluteString,
            "https://free.picui.cn/free/a.png"
        )
        XCTAssertEqual(
            forumMarkdownImageURL("//cdn.example.com/a.png", relativeTo: base)?.absoluteString,
            "https://cdn.example.com/a.png"
        )
        XCTAssertEqual(
            forumMarkdownImageURL("/uploads/a.png", relativeTo: base)?.absoluteString,
            "https://forum.novelia.cc/uploads/a.png"
        )
        XCTAssertEqual(
            forumMarkdownImageURL("https://example.com/a b.png", relativeTo: base)?.absoluteString,
            "https://example.com/a%20b.png"
        )
        XCTAssertNil(forumMarkdownImageURL("javascript:alert(1)", relativeTo: base))
        XCTAssertNil(forumMarkdownImageURL("file:///tmp/a.png", relativeTo: base))
        XCTAssertNil(forumMarkdownImageURL("", relativeTo: base))

        let novel = forumMarkdownActionURL("/novel/kakuyomu/123")
        XCTAssertEqual(novel?.path, "/novel/kakuyomu/123")
        XCTAssertNil(novel?.scheme)
        XCTAssertEqual(forumMarkdownActionURL("https://n.novelia.cc/novel/x/y")?.host, "n.novelia.cc")
        XCTAssertNil(forumMarkdownActionURL("javascript:alert(1)"))
    }

    /// 预览回复与分页重叠或顺序不同时，每次请求下一页并去重，不会卡在同一页或重复显示。
    func testReplyPagingAdvancesPagesAndSkipsShownReplies() {
        struct Reply: Identifiable, Equatable { let id: Int }
        var paging = ReplyPaging()
        let preview = [Reply(id: 1), Reply(id: 2)]
        XCTAssertEqual(paging.nextPage, 0)
        let first = paging.accept((1...3).map(Reply.init), shown: preview, pageSize: 3)
        XCTAssertEqual(first, [Reply(id: 3)])
        XCTAssertEqual(paging.nextPage, 1, "the next request asks for a new page even though only one reply was new")
        XCTAssertFalse(paging.isExhausted)
        let last = paging.accept([Reply(id: 4), Reply(id: 4)], shown: preview + first, pageSize: 3)
        XCTAssertEqual(last, [Reply(id: 4)], "duplicates inside a page are dropped")
        XCTAssertTrue(paging.isExhausted, "a short page ends paging")
    }
}
