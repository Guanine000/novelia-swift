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
wenku = (root / 'Sources/NoveliaIOSCore/WenkuNovel.swift').read_text()
code += wenku[:wenku.index('public struct WenkuNovelDetail')]
code += source[source.index('private struct ForumNovelRoute'):]
code += r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private let table = parseForumMarkdown("| 名称 | 链接 |\n| :--- | ---: |\n| A | [B](https://n.novelia.cc/novel/x/y) |\n\n尾段")
check(table.count == 2, "table/paragraph boundaries")
if case let .table(rows) = table[0].kind {
    check(rows.count == 2 && rows[1][0] == "A", "table rows")
} else { fatalError("table missing") }
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
