import Foundation
import SwiftUI
import UIKit

// 论坛 Markdown 解析、剧透处理，以及论坛和小说链接路由。
// 论坛视图与 Swift 包测试共用的纯逻辑。

struct ForumPostRoute: Identifiable {
    let postID: Int64
    let fragment: String?
    var id: String { "\(postID)#\(fragment ?? "")" }
}

func forumPostDestination(from url: URL, configuration: APIConfiguration = .production) -> ForumPostRoute? {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let host = components?.host?.lowercased()
    let isForumHost = configuration.recognizesForumURL(url)
    let isRelativeForumPath = host == nil && url.scheme == nil && url.path.hasPrefix("/")
    guard isForumHost || isRelativeForumPath else { return nil }
    let segments = url.path.split(separator: "/")
    guard segments.count >= 2, segments[0] == "p", let id = Int64(segments[1]) else { return nil }
    return ForumPostRoute(postID: id, fragment: components?.fragment?.removingPercentEncoding ?? components?.fragment)
}

func isLocalForumURL(_ url: URL, postID: Int64, configuration: APIConfiguration = .production) -> Bool {
    guard let destination = forumPostDestination(from: url, configuration: configuration) else { return false }
    return destination.postID == postID
}

func forumSpoilerMarkdown(_ markdown: String) -> String {
    // 链接文字被标为剧透时，将整个链接保留在可揭示的范围内。
    guard let links = try? NSRegularExpression(pattern: "\\[((?:!!!!|!!))([^\\]]+?)\\1\\]\\(([^)]+)\\)") else { return markdown }
    let source = markdown as NSString
    let codeRanges = forumInlineCodeRanges(markdown)
    let result = NSMutableString(string: markdown)
    for match in links.matches(in: markdown, range: NSRange(location: 0, length: source.length)).reversed() {
        guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
        let marker = source.substring(with: match.range(at: 1))
        let label = source.substring(with: match.range(at: 2))
        let target = source.substring(with: match.range(at: 3))
        result.replaceCharacters(in: match.range, with: "\(marker)[\(label)](\(target))\(marker)")
    }
    return result as String
}

func forumInlineCodeRanges(_ markdown: String) -> [NSRange] {
    let code = try? NSRegularExpression(pattern: "(?<!`)(`+)(?!`)[\\s\\S]*?(?<!`)\\1(?!`)")
    return code?.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).map(\.range) ?? []
}

func forumSpoilerMatches(_ markdown: String, pattern: NSRegularExpression) -> [NSTextCheckingResult] {
    let codeRanges = forumInlineCodeRanges(markdown)
    return pattern.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).filter { match in
        !codeRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
    }
}

/// `conceal` 用于设置隐藏剧透文字的样式；这里始终移除其链接。
func renderInlineMarkdown(_ markdown: String, spoilersRevealed: Bool, pattern: NSRegularExpression,
                          conceal: (inout AttributedString) -> Void = { _ in }) -> AttributedString {
    let normalized = forumSpoilerMarkdown(markdown)
    let ns = normalized as NSString
    let matches = forumSpoilerMatches(normalized, pattern: pattern)
    var result = AttributedString()
    var cursor = 0
    for match in matches {
        let capturedRange = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
        guard capturedRange.location != NSNotFound else { continue }
        let spoilerRange = capturedRange
        let markerRange = NSRange(location: match.range.location, length: spoilerRange.location - match.range.location)
        if markerRange.location > cursor {
            result += (try? forumInlineAttributes(ns.substring(with: NSRange(location: cursor, length: markerRange.location - cursor))))
                ?? AttributedString(ns.substring(with: NSRange(location: cursor, length: markerRange.location - cursor)))
        }
        var spoiler = (try? forumInlineAttributes(ns.substring(with: spoilerRange))) ?? AttributedString(ns.substring(with: spoilerRange))
        if !spoilersRevealed {
            // 隐藏内容不能打开不可见的链接；揭示后，在下一次渲染时
            // 恢复原始 Markdown 链接属性。
            spoiler.link = nil
            conceal(&spoiler)
        }
        result += spoiler
        cursor = NSMaxRange(match.range)
    }
    if cursor < ns.length {
        let tail = ns.substring(from: cursor)
        result += (try? forumInlineAttributes(tail)) ?? AttributedString(tail)
    }
    return result
}

enum ForumMarkdownMode {
    case article
    case comment
}

func forumCommentMarkdownForSubmission(_ markdown: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "!!!!([\\s\\S]+?)!!!!") else { return markdown }
    let range = NSRange(markdown.startIndex..., in: markdown)
    return regex.stringByReplacingMatches(in: markdown, range: range, withTemplate: "!!$1!!")
}

enum ForumNoticeDestination: Hashable {
    case category(String, String)
    case rules

    init?(url: URL, configuration: APIConfiguration = .production) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              configuration.recognizesForumURL(url, includeWWW: false),
              components.user == nil, components.password == nil,
              (components.port ?? 443) == (configuration.forumOrigin.port ?? 443) else { return nil }
        let segments = components.path.split(separator: "/")
        if segments == ["rules"] { self = .rules; return }
        guard segments.count == 2, segments[0] == "c",
              ["announcements", "feedback", "novel"].contains(String(segments[1])) else { return nil }
        self = .category(String(segments[1]), components.queryItems?.first(where: { $0.name == "q" })?.value ?? "")
    }
}

struct ForumMarkdownBlock: Identifiable {
    enum Kind {
        case paragraph
        case heading(Int)
        case unorderedItem
        case orderedItem(Int)
        case quote
        case code
        case divider
        case table([[String]])
        case starRating(Double)
        case details(String)
    }

    let id: Int
    let kind: Kind
    let text: String
    let anchor: String?
}

func parseForumMarkdown(_ markdown: String, mode: ForumMarkdownMode = .article) -> [ForumMarkdownBlock] {
    var blocks: [ForumMarkdownBlock] = []
    var paragraph: [String] = []
    var codeLines: [String] = []
    var inCodeFence = false
    var headingAnchorCounts: [String: Int] = [:]

    func append(_ kind: ForumMarkdownBlock.Kind, _ text: String, anchor: String? = nil) {
        blocks.append(ForumMarkdownBlock(id: blocks.count, kind: kind, text: text, anchor: anchor))
    }
    func flushParagraph() {
        let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { append(.paragraph, text) }
        paragraph.removeAll(keepingCapacity: true)
    }

    let lines = markdown.components(separatedBy: .newlines)
    var index = 0
    while index < lines.count {
        let rawLine = lines[index]
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if (line.hasPrefix("```") || line.hasPrefix("~~~")) {
            flushParagraph()
            if inCodeFence {
                append(.code, codeLines.joined(separator: "\n"))
                codeLines.removeAll(keepingCapacity: true)
                inCodeFence = false
            } else {
                inCodeFence = true
            }
            index += 1
            continue
        }
        if inCodeFence {
            codeLines.append(rawLine)
            index += 1
            continue
        }
        if let details = line.firstMatch(of: /^:::\s*details(?:\s+(.*))?$/) {
            flushParagraph()
            let title = String(details.1 ?? "")
            index += 1
            var content: [String] = []
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != ":::" {
                content.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }
            append(.details(title), content.joined(separator: "\n"))
            continue
        }
        if let star = line.firstMatch(of: /^:::\s*star\s+([0-9]+(?:\.[0-9]+)?)\s*$/),
           let value = Double(star.1) {
            flushParagraph()
            append(.starRating(min(5, max(0, value))), "")
            index += 1
            if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == ":::" { index += 1 }
            continue
        }
        if index + 1 < lines.count, line.contains("|"),
           forumTableCells(lines[index + 1]).allSatisfy({ $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }),
           !forumTableCells(lines[index + 1]).isEmpty,
           forumTableCells(rawLine).count == forumTableCells(lines[index + 1]).count {
            flushParagraph()
            let header = forumTableCells(rawLine)
            var rows = [header]
            index += 2
            while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let cells = forumTableCells(lines[index])
                rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
                index += 1
            }
            append(.table(rows), "")
            continue
        }
        if line.isEmpty {
            flushParagraph()
            index += 1
            continue
        }
        if mode == .article, let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
            flushParagraph()
            let title = String(match.2)
            let baseAnchor = forumHeadingSlug(title)
            let duplicateCount = headingAnchorCounts[baseAnchor, default: 0]
            headingAnchorCounts[baseAnchor] = duplicateCount + 1
            let anchor = duplicateCount == 0 ? baseAnchor : "\(baseAnchor)-\(duplicateCount)"
            append(.heading(match.1.count), title, anchor: anchor)
        } else if mode == .article, let match = line.firstMatch(of: /^[-+*]\s+(.+)$/) {
            flushParagraph()
            append(.unorderedItem, String(match.1))
        } else if mode == .article, let match = line.firstMatch(of: /^(\d+)[.)]\s+(.+)$/), let number = Int(match.1) {
            flushParagraph()
            append(.orderedItem(number), String(match.2))
        } else if mode == .article, let match = line.firstMatch(of: /^>\s?(.*)$/) {
            flushParagraph()
            append(.quote, String(match.1))
        } else if mode == .article, isForumMarkdownDivider(line) {
            flushParagraph()
            append(.divider, "")
        } else {
            paragraph.append(line)
        }
        index += 1
    }
    flushParagraph()
    if inCodeFence, !codeLines.isEmpty { append(.code, codeLines.joined(separator: "\n")) }
    return blocks
}

func isForumMarkdownDivider(_ line: String) -> Bool {
    let compact = line.filter { !$0.isWhitespace }
    guard compact.count >= 3, let marker = compact.first, "-*_".contains(marker) else { return false }
    return compact.allSatisfy { $0 == marker }
}

func forumHeadingSlug(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: "-")
}

func forumTableCells(_ line: String) -> [String] {
    var cells: [String] = []
    var cell = ""
    var escaped = false
    var inCode = false
    for character in line.trimmingCharacters(in: .whitespaces) {
        if escaped { cell.append(character); escaped = false; continue }
        if character == "\\" { escaped = true; cell.append(character); continue }
        if character == "`" { inCode.toggle() }
        if character == "|", !inCode { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
        else { cell.append(character) }
    }
    cells.append(cell.trimmingCharacters(in: .whitespaces))
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
    if trimmed.hasSuffix("|"), cells.last == "" { cells.removeLast() }
    return cells
}

func forumInlineAttributes(_ input: String) throws -> AttributedString {
    // 拆分删除线范围前先规范化带删除线的链接文字，
    // 为 Foundation 解析器保留完整的 Markdown 链接。
    let text = input.replacingOccurrences(of: "\\[~~([^\\]]+?)~~\\]\\(([^)]+)\\)", with: "~~[$1]($2)~~", options: .regularExpression)
        .replacingOccurrences(of: "</?(?:del|s|strike)>", with: "~~", options: [.regularExpression, .caseInsensitive])
    guard let expression = try? NSRegularExpression(pattern: "~~([\\s\\S]+?)~~") else {
        return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
    let source = text as NSString
    var result = AttributedString()
    var cursor = 0
    for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        result += try AttributedString(markdown: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        var struck = try AttributedString(markdown: source.substring(with: match.range(at: 1)), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        struck.strikethroughStyle = .single
        result += struck
        cursor = NSMaxRange(match.range)
    }
    result += try AttributedString(markdown: source.substring(from: cursor), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    return result
}

struct ForumNovelRoute: Hashable {
    let isCatalogue: Bool
    let provider: String?
    let novelID: String
    var outline: WenkuNovelOutline {
        WenkuNovelOutline(id: novelID, title: "正在加载…")
    }
    init?(url: URL, configuration: APIConfiguration = .production) {
        let host = url.host?.lowercased()
        guard configuration.recognizesNovelURL(url) || (host == nil && url.scheme == nil) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        isCatalogue = parts == ["novel"]
        if isCatalogue { provider = nil; novelID = "" }
        else if parts.count == 3, parts[0] == "novel" { provider = parts[1]; novelID = parts[2] }
        else if parts.count == 2, parts[0] == "wenku" { provider = nil; novelID = parts[1] }
        else { return nil }
    }
}

// MARK: - 缓存

/// 仅编译一次的剧透语法：`!!text!!` 或 `!!!!text!!!!`。
let forumSpoilerPattern = try! NSRegularExpression(pattern: "!!!!([\\s\\S]+?)!!!!|!!([\\s\\S]+?)!!")

/// 已解析的论坛 Markdown。SwiftUI 在每次滚动或状态变化时重新计算视图主体，
/// 如果不缓存，长帖子和评论列表就会反复解析相同文本。
final class ForumMarkdownCache: @unchecked Sendable {
    static let shared = ForumMarkdownCache()

    private final class Blocks { let value: [ForumMarkdownBlock]; init(_ value: [ForumMarkdownBlock]) { self.value = value } }
    private final class Inline { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    private final class Flag { let value: Bool; init(_ value: Bool) { self.value = value } }

    // NSCache 支持线程安全，并在内存压力下释放条目。
    private let blocks = NSCache<NSString, Blocks>()
    private let inline = NSCache<NSString, Inline>()
    private let spoilers = NSCache<NSString, Flag>()

    init(countLimit: Int = 600) {
        blocks.countLimit = countLimit
        inline.countLimit = countLimit * 4
        spoilers.countLimit = countLimit * 4
    }

    func blocks(_ markdown: String, mode: ForumMarkdownMode) -> [ForumMarkdownBlock] {
        let key = "\(mode)\u{0}\(markdown)" as NSString
        if let cached = blocks.object(forKey: key) { return cached.value }
        let parsed = parseForumMarkdown(markdown, mode: mode)
        blocks.setObject(Blocks(parsed), forKey: key)
        return parsed
    }

    func hasSpoilers(_ markdown: String) -> Bool {
        let key = markdown as NSString
        if let cached = spoilers.object(forKey: key) { return cached.value }
        let value = !forumSpoilerMatches(forumSpoilerMarkdown(markdown), pattern: forumSpoilerPattern).isEmpty
        spoilers.setObject(Flag(value), forKey: key)
        return value
    }

    /// 隐藏剧透的缓存包含调用方样式，因此每次应传入相同的 `conceal`。
    func inline(_ markdown: String, spoilersRevealed: Bool,
                conceal: (inout AttributedString) -> Void = { _ in }) -> AttributedString {
        let key = "\(spoilersRevealed ? 1 : 0)\u{0}\(markdown)" as NSString
        if let cached = inline.object(forKey: key) { return cached.value }
        let rendered = renderInlineMarkdown(markdown, spoilersRevealed: spoilersRevealed, pattern: forumSpoilerPattern,
                                            conceal: conceal)
        inline.setObject(Inline(rendered), forKey: key)
        return rendered
    }
}
