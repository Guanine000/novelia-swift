import Foundation
import SwiftUI
import UIKit

// 论坛 Markdown 解析、剧透处理、远程图片分段，以及论坛和小说链接路由。
// 论坛视图与 Swift 包测试共用的纯逻辑。图片字节由界面按分段里的地址下载。

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
        if let details = forumCaptures(line, ForumLinePattern.details) {
            flushParagraph()
            let title = details[0] ?? ""
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
        if let star = forumCaptures(line, ForumLinePattern.star),
           let raw = star.first.flatMap({ $0 }), let value = Double(raw) {
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
        if mode == .article, let match = forumCaptures(line, ForumLinePattern.heading) {
            flushParagraph()
            let title = match[1] ?? ""
            let baseAnchor = forumHeadingSlug(title)
            let duplicateCount = headingAnchorCounts[baseAnchor, default: 0]
            headingAnchorCounts[baseAnchor] = duplicateCount + 1
            let anchor = duplicateCount == 0 ? baseAnchor : "\(baseAnchor)-\(duplicateCount)"
            append(.heading((match[0] ?? "").count), title, anchor: anchor)
        } else if mode == .article, let match = forumCaptures(line, ForumLinePattern.bullet) {
            flushParagraph()
            append(.unorderedItem, match[0] ?? "")
        } else if mode == .article, let match = forumCaptures(line, ForumLinePattern.numbered), let number = Int(match[0] ?? "") {
            flushParagraph()
            append(.orderedItem(number), match[1] ?? "")
        } else if mode == .article, let match = forumCaptures(line, ForumLinePattern.quote) {
            flushParagraph()
            append(.quote, match[0] ?? "")
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

/// SwiftUI 的 `Text` 不会绘制 `AttributedString` 里的远程图片，空 alt 的单元格因此是空白。
/// 把图片从行内文本里拆出来，交给界面用实际宽高加载；代码块和未揭示剧透里的图片语法保持原样。
struct ForumMarkdownImage: Equatable {
    var alt: String
    var destination: String
    /// 图片本身就是链接文字时的目标。普通图片为 nil。
    var link: String?
}

enum ForumInlineSegment: Equatable {
    case text(String)
    case image(ForumMarkdownImage)

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

func forumInlineSegments(_ markdown: String, spoilersRevealed: Bool = true) -> [ForumInlineSegment] {
    let source = spoilersRevealed ? forumMarkdownRemovingSpoilerMarkers(markdown) : markdown
    let matches = forumMarkdownImageExpression.matches(in: source, range: NSRange(source.startIndex..., in: source))
    guard !matches.isEmpty else { return [.text(source)] }
    let codeRanges = forumInlineCodeRanges(source)
    let spoilerRanges = spoilersRevealed ? [] : forumSpoilerMatches(source, pattern: forumSpoilerPattern).map(\.range)
    var pieces: [ForumInlineSegment] = []
    var cursor = source.startIndex
    var acceptedImage = false

    func appendText(upTo end: String.Index) {
        guard end > cursor else { return }
        pieces.append(.text(String(source[cursor..<end])))
        cursor = end
    }

    for match in matches {
        guard let imageRange = Range(match.range, in: source),
              let altRange = Range(match.range(at: 1), in: source),
              let destinationRange = Range(match.range(at: 2), in: source),
              imageRange.lowerBound >= cursor else { continue }
        if forumMarkdownIsEscaped(source, at: imageRange.lowerBound) { continue }
        if forumIntersects(match.range, codeRanges) || forumIntersects(match.range, spoilerRanges) { continue }
        let destination = forumCleanMarkdownDestination(String(source[destinationRange]))
        guard !destination.isEmpty else { continue }
        let alt = String(source[altRange]).trimmingCharacters(in: .whitespaces)
        if let enclosure = forumEnclosingLink(in: source, image: imageRange) {
            let label = source[source.index(after: enclosure.open)..<enclosure.close]
            // 链接文字里还有别的内容时保持整段链接，避免拆掉可点的文字。
            if label.trimmingCharacters(in: .whitespaces) != source[imageRange].trimmingCharacters(in: .whitespaces) {
                continue
            }
            appendText(upTo: enclosure.open)
            let link = forumCleanMarkdownDestination(enclosure.destination)
            pieces.append(.image(ForumMarkdownImage(alt: alt, destination: destination, link: link.isEmpty ? nil : link)))
            cursor = enclosure.end
            acceptedImage = true
            continue
        }
        appendText(upTo: imageRange.lowerBound)
        pieces.append(.image(ForumMarkdownImage(alt: alt, destination: destination, link: nil)))
        cursor = imageRange.upperBound
        acceptedImage = true
    }
    appendText(upTo: source.endIndex)
    guard acceptedImage else { return [.text(source)] }
    return pieces.filter { segment in
        guard case .text(let text) = segment else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 正文图片只接受 http/https。相对地址相对 `base`（论坛站点来源）解析，不交给论坛 API。
func forumMarkdownImageURL(_ destination: String, relativeTo base: URL) -> URL? {
    let trimmed = forumCleanMarkdownDestination(destination)
    guard !trimmed.isEmpty, !forumMarkdownRejectsScheme(trimmed) else { return nil }
    let candidate = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
    if let url = forumStrictHTTPURL(candidate) { return url }
    if candidate.contains("://") {
        guard let encoded = forumPercentEncodedURLString(candidate) else { return nil }
        return forumStrictHTTPURL(encoded)
    }
    let relative = forumPercentEncodedURLString(candidate) ?? candidate
    guard let resolved = URL(string: relative, relativeTo: base)?.absoluteURL else { return nil }
    return forumStrictHTTPURL(resolved.absoluteString)
}

/// 图片外层链接。绝对地址只保留 http/https；没有协议的路径原样返回，方便沿用小说/论坛路由。
func forumMarkdownActionURL(_ destination: String) -> URL? {
    let trimmed = forumCleanMarkdownDestination(destination)
    guard !trimmed.isEmpty, !forumMarkdownRejectsScheme(trimmed) else { return nil }
    if trimmed.hasPrefix("//") {
        return forumStrictHTTPURL("https:" + trimmed)
    }
    if let url = URL(string: trimmed) {
        if let scheme = url.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else { return nil }
            return url
        }
        return url
    }
    guard let encoded = forumPercentEncodedURLString(trimmed) else { return nil }
    return URL(string: encoded)
}

private let forumMarkdownImageExpression: NSRegularExpression = {
    let pattern = #"!\[([^\]]*)\]\(\s*(<[^>\r\n]+>|[^)\s]+)(?:\s+(?:"[^"\r\n]*"|'[^'\r\n]*'|\([^)\r\n]*\)))?\s*\)"#
    do { return try NSRegularExpression(pattern: pattern) }
    catch { preconditionFailure("论坛图片正则无效：\(pattern)") }
}()

private struct ForumLinkEnclosure {
    var open: String.Index
    var close: String.Index
    var destination: String
    var end: String.Index
}

private func forumMarkdownRemovingSpoilerMarkers(_ markdown: String) -> String {
    let matches = forumSpoilerMatches(markdown, pattern: forumSpoilerPattern)
    guard !matches.isEmpty else { return markdown }
    let source = markdown as NSString
    let result = NSMutableString(string: markdown)
    for match in matches.reversed() {
        let inner = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        guard inner.location != NSNotFound else { continue }
        result.replaceCharacters(in: match.range, with: source.substring(with: inner))
    }
    return result as String
}

private func forumMarkdownIsEscaped(_ source: String, at index: String.Index) -> Bool {
    var slashes = 0
    var cursor = index
    while cursor > source.startIndex {
        let previous = source.index(before: cursor)
        if source[previous] != "\\" { break }
        slashes += 1
        cursor = previous
    }
    return slashes % 2 == 1
}

private func forumIntersects(_ range: NSRange, _ others: [NSRange]) -> Bool {
    others.contains { NSIntersectionRange(range, $0).length > 0 }
}

/// 同一行上、图片位于某个 `[...](...)` 文字中时返回该链接。调用方再用文字是否只有这张图决定拆不拆。
private func forumEnclosingLink(in source: String, image: Range<String.Index>) -> ForumLinkEnclosure? {
    var cursor = image.lowerBound
    var open: String.Index?
    while cursor > source.startIndex {
        let previous = source.index(before: cursor)
        let character = source[previous]
        if character == "\n" || character == "\r" || character == ")" || character == "]" { break }
        if character == "[", !forumMarkdownIsEscaped(source, at: previous) {
            open = previous
            break
        }
        cursor = previous
    }
    guard let open else { return nil }
    var forward = image.upperBound
    while forward < source.endIndex {
        let character = source[forward]
        if character == "\n" || character == "\r" { return nil }
        let next = source.index(after: forward)
        if character == "]", next < source.endIndex, source[next] == "(", !forumMarkdownIsEscaped(source, at: forward) {
            guard let parsed = forumParseLinkDestination(in: source, from: forward) else { return nil }
            return ForumLinkEnclosure(open: open, close: forward, destination: parsed.destination, end: parsed.end)
        }
        forward = next
    }
    return nil
}

private func forumParseLinkDestination(in source: String, from closeBracket: String.Index) -> (destination: String, end: String.Index)? {
    var cursor = source.index(after: closeBracket)
    guard cursor < source.endIndex, source[cursor] == "(" else { return nil }
    cursor = source.index(after: cursor)
    while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\t" {
        cursor = source.index(after: cursor)
    }
    guard cursor < source.endIndex else { return nil }
    let destination: String
    if source[cursor] == "<" {
        let start = source.index(after: cursor)
        var end = start
        while end < source.endIndex, source[end] != ">", source[end] != "\n", source[end] != "\r" {
            end = source.index(after: end)
        }
        guard end < source.endIndex, source[end] == ">" else { return nil }
        destination = String(source[start..<end])
        cursor = source.index(after: end)
    } else {
        let start = cursor
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "\\" {
                let skipped = source.index(after: cursor)
                cursor = skipped < source.endIndex ? source.index(after: skipped) : skipped
                continue
            }
            if character == ")" || character == " " || character == "\t" || character == "\n" || character == "\r" { break }
            cursor = source.index(after: cursor)
        }
        guard cursor > start else { return nil }
        destination = String(source[start..<cursor])
    }
    while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\t" {
        cursor = source.index(after: cursor)
    }
    if cursor < source.endIndex, let endDelimiter = forumMarkdownTitleEnd(source[cursor]) {
        cursor = source.index(after: cursor)
        while cursor < source.endIndex, source[cursor] != endDelimiter, source[cursor] != "\n", source[cursor] != "\r" {
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex, source[cursor] == endDelimiter else { return nil }
        cursor = source.index(after: cursor)
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\t" {
            cursor = source.index(after: cursor)
        }
    }
    guard cursor < source.endIndex, source[cursor] == ")" else { return nil }
    return (destination, source.index(after: cursor))
}

private func forumMarkdownTitleEnd(_ character: Character) -> Character? {
    switch character {
    case "\"": return "\""
    case "'": return "'"
    case "(": return ")"
    default: return nil
    }
}

private func forumCleanMarkdownDestination(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.count >= 2, value.hasPrefix("<"), value.hasSuffix(">") {
        value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value
}

private func forumMarkdownRejectsScheme(_ value: String) -> Bool {
    if value.hasPrefix("//") { return false }
    guard let colon = value.firstIndex(of: ":") else { return false }
    let scheme = value[..<colon]
    guard !scheme.isEmpty, !scheme.contains("/"),
          scheme.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "+" || $0 == "-" || $0 == "." }) else { return false }
    let lowered = scheme.lowercased()
    return lowered != "http" && lowered != "https"
}

private func forumStrictHTTPURL(_ string: String) -> URL? {
    guard let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty else { return nil }
    return url
}

private func forumPercentEncodedURLString(_ value: String) -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)
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
    private final class SegmentList { let value: [ForumInlineSegment]; init(_ value: [ForumInlineSegment]) { self.value = value } }

    // NSCache 支持线程安全，并在内存压力下释放条目。
    private let blocks = NSCache<NSString, Blocks>()
    private let inline = NSCache<NSString, Inline>()
    private let spoilers = NSCache<NSString, Flag>()
    private let segments = NSCache<NSString, SegmentList>()

    init(countLimit: Int = 600) {
        blocks.countLimit = countLimit
        inline.countLimit = countLimit * 4
        spoilers.countLimit = countLimit * 4
        segments.countLimit = countLimit * 4
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

    /// 与行内属性分开缓存。剧透是否揭示会改变图片是否从标记里拆出来。
    func inlineSegments(_ markdown: String, spoilersRevealed: Bool) -> [ForumInlineSegment] {
        let key = "\(spoilersRevealed ? 1 : 0)\u{0}\(markdown)" as NSString
        if let cached = segments.object(forKey: key) { return cached.value }
        let parsed = forumInlineSegments(markdown, spoilersRevealed: spoilersRevealed)
        segments.setObject(SegmentList(parsed), forKey: key)
        return parsed
    }
}

/// 行首语法用 Foundation 正则，避免 Swift Regex（运行时要求 iOS 16）。
private enum ForumLinePattern {
    static let details = forumLineExpression(#"^:::\s*details(?:\s+(.*))?$"#)
    static let star = forumLineExpression(#"^:::\s*star\s+([0-9]+(?:\.[0-9]+)?)\s*$"#)
    static let heading = forumLineExpression(#"^(#{1,6})\s+(.+)$"#)
    static let bullet = forumLineExpression(#"^[-+*]\s+(.+)$"#)
    static let numbered = forumLineExpression(#"^(\d+)[.)]\s+(.+)$"#)
    static let quote = forumLineExpression(#"^>\s?(.*)$"#)
}

private func forumLineExpression(_ pattern: String) -> NSRegularExpression {
    do { return try NSRegularExpression(pattern: pattern) }
    catch { preconditionFailure("论坛行正则无效：\(pattern)") }
}

/// 捕获组从 1 开始，下标 0 对应第一个括号。整行不匹配时返回 nil。
private func forumCaptures(_ line: String, _ expression: NSRegularExpression) -> [String?]? {
    let full = NSRange(line.startIndex..., in: line)
    guard let match = expression.firstMatch(in: line, range: full),
          match.range.location == full.location, match.range.length == full.length else { return nil }
    return (1..<match.numberOfRanges).map { index in
        let piece = match.range(at: index)
        guard piece.location != NSNotFound, let range = Range(piece, in: line) else { return nil }
        return String(line[range])
    }
}
