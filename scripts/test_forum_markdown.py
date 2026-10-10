#!/usr/bin/env python3
"""Exercise the app's actual Markdown parser and link attributes on macOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'iOSApp/ForumViews.swift').read_text()
def section(start, end):
    return source[source.index(start):source.index(end, source.index(start))]
code = 'import Foundation\nimport SwiftUI\n'
code += section('enum ForumMarkdownMode', 'private func forumCommentMarkdownForSubmission')
code += section('private struct ForumMarkdownBlock', 'private func isForumMarkdownDivider')
code += section('private func isForumMarkdownDivider', 'private struct Forum')
code += section('private func forumTableCells', 'private func forumInlineAttributes')
code += section('private func forumInlineAttributes', 'private struct ForumNovelRoute')
code += 'private enum NoveliaStyle { static let ink = Color.black }\n'
code += section('private func forumSpoilerMarkdown', 'private struct ForumStarRating')
wenku = (root / 'Sources/NoveliaIOSCore/WenkuNovel.swift').read_text()
code += wenku[:wenku.index('public struct WenkuNovelDetail')]
code += source[source.index('private struct ForumNovelRoute'):]
code += r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
for mode in [ForumMarkdownMode.article, .comment] {
    let source = "第一行\n[下载](https://example.com/download)\n说明文字\n[源码](https://example.com/source)"
    let blocks = parseForumMarkdown(source, mode: mode)
    check(blocks.count == 1 && blocks[0].text == source, "soft line breaks collapsed")
    let rendered = try! forumInlineAttributes(blocks[0].text)
    check(String(rendered.characters).components(separatedBy: "\n").count == 4, "inline renderer lost line breaks")
    check(rendered.runs.filter { $0.link != nil }.count == 2, "line-break parsing damaged links")
}
let rawLink = try! forumInlineAttributes("第一行\nhttps://example.com/download\n尾行")
check(rawLink.runs.contains { $0.link?.absoluteString == "https://example.com/download" }, "bare URL link missing")
private let table = parseForumMarkdown("| 名称 | 链接 |\n| :--- | ---: |\n| A | [B](https://n.novelia.cc/novel/x/y) |\n\n尾段")
check(table.count == 2, "table/paragraph boundaries")
if case let .table(rows) = table[0].kind {
    check(rows.count == 2 && rows[1][0] == "A", "table rows")
} else { fatalError("table missing") }

// Forum post 263 uses two hyphens per separator cell; shortened synthetic
// content reproduces its structure without redistributing the author's prose.
for mode in [ForumMarkdownMode.article, .comment] {
    for delimiter in ["-", "--", "---", ":-", "-:", ":--:"] {
        let blocks = parseForumMarkdown("| 评分 | 链接 | 评语 | 日期 |\n| \(delimiter) | \(delimiter) | \(delimiter) | \(delimiter) |\n| ☆☆☆☆☆ | [小说](https://books.fishhawk.top/novel/hameln/example) | **更新** | 20250226 |\n|  | *分隔* | | |\n\n后文", mode: mode)
        check(blocks.count == 2, "short delimiter block boundaries")
        if case let .table(rows) = blocks[0].kind {
            check(rows.count == 3 && rows.allSatisfy { $0.count == 4 }, "four-column table")
            check(rows[2] == ["", "*分隔*", "", ""], "blank cells preserved")
        } else { fatalError("short delimiter not recognized") }
    }
}
private let mismatched = parseForumMarkdown("| a | b |\n| -- |\n| c | d |")
check(!mismatched.contains { if case .table = $0.kind { return true }; return false }, "mismatched header/delimiter must not become table")
check(forumTableCells("a | | b") == ["a", "", "b"], "unframed interior empty cell")
check(forumTableCells(" | b") == ["b"], "leading pipe boundary")
check(forumTableCells("| a\\|b | `x|y` |") == ["a\\|b", "`x|y`"], "escaped and code pipes")
for mode in [ForumMarkdownMode.article, .comment] {
    let stars = parseForumMarkdown("::: star 4.5\n:::\n\n正文", mode: mode)
    check(stars.count == 2, "rating closing directive")
    if case let .starRating(value) = stars[0].kind { check(value == 4.5, "half stars") }
    else { fatalError("rating missing") }
}
private let codeBlock = parseForumMarkdown("```\n::: star 5\n| a |\n| --- |\n```", mode: .comment)
check(codeBlock.count == 1, "fenced literal")
if case .code = codeBlock[0].kind {} else { fatalError("fence parsed as directive") }
for value in ["~~[小说](https://n.novelia.cc/novel/x/y)~~", "[~~小说~~](https://n.novelia.cc/novel/x/y)", "<del>[小说](https://n.novelia.cc/novel/x/y)</del>"] {
    let rendered = try forumInlineAttributes(value)
    check(String(rendered.characters) == "小说", "strike label")
    check(rendered.runs.contains { $0.link?.absoluteString == "https://n.novelia.cc/novel/x/y" }, "strike removed link")
    check(rendered.runs.contains { $0.strikethroughStyle != nil }, "strike missing")
}

private let spoilerPattern = try NSRegularExpression(pattern: "!!!!([\\s\\S]+?)!!!!|!!([\\s\\S]+?)!!")
for sample in ["!!文字中的[链接](https://example.com/spoiler-link)!!", "!!!![小说](https://n.novelia.cc/novel/x/y)!!!!", "[!!小说!!](https://n.novelia.cc/novel/x/y)", "[!!!!小说!!!!](https://n.novelia.cc/novel/x/y)", "`!!示例!!` 正文 !![链接](https://example.com/spoiler-link)!!"] {
    let revealed = renderInlineMarkdown(sample, spoilersRevealed: true, pattern: spoilerPattern)
    check(revealed.runs.contains { $0.link != nil }, "revealed spoiler link missing")
    let hidden = renderInlineMarkdown(sample, spoilersRevealed: false, pattern: spoilerPattern)
    check(!hidden.runs.contains { $0.link != nil }, "hidden spoiler link remains actionable")
}
check(forumSpoilerMatches("`!!示例!!`", pattern: spoilerPattern).isEmpty, "inline code treated as spoiler")
check(forumSpoilerMatches("``!!示例!!``", pattern: spoilerPattern).isEmpty, "double-backtick code treated as spoiler")
check(forumSpoilerMarkdown("`[!!示例!!](https://example.com)`") == "`[!!示例!!](https://example.com)`", "link syntax inside code changed")
private let adjacent = renderInlineMarkdown("[前半](https://n.novelia.cc/novel/x/y)!!遮挡!![后半](https://n.novelia.cc/novel/x/y)", spoilersRevealed: true, pattern: spoilerPattern)
check(adjacent.runs.filter { $0.link != nil }.count == 2, "links beside spoiler lost")
check(ForumNovelRoute(url: URL(string: "https://n.novelia.cc/novel/syosetu/n123#chapter")!)?.provider == "syosetu", "web novel route")
check(ForumNovelRoute(url: URL(string: "https://n.novelia.cc/wenku/book123")!)?.outline.id == "book123", "wenku route")
check(ForumNovelRoute(url: URL(string: "/novel/syosetu/n123")!)?.novelID == "n123", "relative route")
check(ForumNovelRoute(url: URL(string: "https://example.com/novel/syosetu/n123")!) == nil, "external URL intercepted")
check(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/novel/syosetu/n123")!)?.provider == "syosetu", "legacy web novel route")
check(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/novel/syosetu/n123?source=forum#chapter")!)?.novelID == "n123", "legacy query and fragment")
check(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/wenku/book123")!)?.outline.id == "book123", "legacy wenku route")
check(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top.example.com/novel/syosetu/n123")!) == nil, "legacy host must match exactly")
check(ForumNovelRoute(url: URL(string: "https://books.fishhawk.top/novel")!)?.isCatalogue == true, "legacy novel catalogue")
print("Forum Markdown and native novel route regression checks passed")
'''
with tempfile.TemporaryDirectory(prefix='novelia-markdown-') as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(code)
    subprocess.run(['swift', '-module-cache-path', str(Path(directory) / 'ModuleCache'), '-enable-bare-slash-regex', str(path)], check=True)
