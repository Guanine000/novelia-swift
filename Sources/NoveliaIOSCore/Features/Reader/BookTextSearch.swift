import Foundation

/// 书内搜索：逐章取出正文纯文本查找关键词，结果以章节与章内比例表示，两种阅读引擎都按此跳转。
/// 纯文本的提取规则与 `EPUBChapterProgress.textLength` 一致（去掉标签间空白、head/script/style、注释与标签，
/// 字符实体计为一个字符），因此章内比例与阅读位置的换算口径相同。只搜索本机内容，不为在线小说逐章联网。
enum BookTextSearch {
    struct Hit: Identifiable, Equatable, Sendable {
        let chapterIndex: Int
        /// 匹配开头在章内的比例 0–1。
        let progression: Double
        /// 匹配前后的上下文。
        let before: String
        let match: String
        let after: String
        let utf16Offset: Int
        var id: String { "\(chapterIndex)-\(utf16Offset)" }
    }

    static let maxHits = 500
    private static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]

    static func plainText(html: String) -> String {
        var text = html.replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression)
        for pattern in [#"(?is)<head\b.*?</head\s*>"#, #"(?is)<(script|style)\b.*?</\1\s*>"#, #"(?s)<!--.*?-->"#, #"<[^>]*>"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return decodeEntities(text)
    }

    /// 实体解码为单个字符，与 `textLength` 的计数一致；无法识别的实体用占位字符。字数统计（`BookWordCount`）共用。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let regex = try? NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);"#)
        let source = text as NSString
        var result = ""
        var cursor = 0
        regex?.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = source.substring(with: match.range(at: 1))
            var replacement = "_"
            if body.hasPrefix("#x") || body.hasPrefix("#X"), let value = UInt32(body.dropFirst(2), radix: 16),
               let scalar = Unicode.Scalar(value), value <= 0xFFFF {
                replacement = String(Character(scalar))
            } else if body.hasPrefix("#"), let value = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(value), value <= 0xFFFF {
                replacement = String(Character(scalar))
            } else if let value = named[body.lowercased()] {
                replacement = value
            }
            result += replacement
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    /// 一章纯文本中的全部匹配。
    static func matches(in text: String, query: String, chapterIndex: Int, limit: Int = maxHits) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let length = max(text.utf16.count, 1)
        var hits: [Hit] = []
        var searchStart = text.startIndex
        while hits.count < limit, let range = text.range(of: needle, options: options, range: searchStart..<text.endIndex) {
            let offset = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex)
            let beforeStart = text.index(range.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
            let afterEnd = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
            hits.append(Hit(chapterIndex: chapterIndex, progression: min(1, Double(offset) / Double(length)),
                            before: Self.flatten(text[beforeStart..<range.lowerBound]),
                            match: String(text[range]), after: Self.flatten(text[range.upperBound..<afterEnd]),
                            utf16Offset: offset))
            searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
        }
        return hits
    }

    /// 依次搜索各章；取消时停止并返回已找到的结果。`onChapter` 报告已完成的章数，用于进度显示。
    static func search(query: String, chapterCount: Int, limit: Int = maxHits,
                       chapterText: (Int) async throws -> String,
                       onChapter: (Int) -> Void = { _ in }) async -> [Hit] {
        var hits: [Hit] = []
        for index in 0..<max(0, chapterCount) {
            if Task.isCancelled || hits.count >= limit { break }
            if let text = try? await chapterText(index) {
                hits += matches(in: text, query: query, chapterIndex: index, limit: limit - hits.count)
            }
            onChapter(index + 1)
        }
        return hits
    }

    private static func flatten(_ text: Substring) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
