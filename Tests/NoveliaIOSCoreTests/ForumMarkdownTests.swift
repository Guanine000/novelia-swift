import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NoveliaIOSCore

/// Forum Markdown blocks, inline attributes and spoilers (formerly scripts/test_forum_markdown.py).
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

        // Short separator cells (as in forum post 263), reproduced with synthetic content.
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
}
