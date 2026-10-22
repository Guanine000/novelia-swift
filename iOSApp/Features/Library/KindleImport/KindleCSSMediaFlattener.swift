import Foundation

/// 按 Kindle（KF8）设备的视角求值 `amzn-*` 媒体查询，供 AZW3／MOBI 转换后的 EPUB 使用。
///
/// Kindle 书常把 KF8 专用样式写在 `@media amzn-kf8 { … }` 中，把旧设备的后备样式写在 `@media amzn-mobi { … }` 中；
/// 其他阅读器不认识这些媒体类型，导致 KF8 样式整块失效。这里把 `amzn-kf8`／`amzn-et` 视为成立、
/// `amzn-mobi`／`amzn-mobi7` 视为不成立，成立的块原位展开（保持层叠顺序），不成立的块删除，
/// 与标准条件组合时只去掉 amzn 部分。不认识的 `amzn-*` 条件原样保留。
///
/// 纯函数、输出确定，转换结果的内容哈希因此稳定。样式表结构不完整（括号或注释未闭合）时原样返回，
/// 不让单个样式表导致整本书转换失败。
enum KindleCSSMediaFlattener {
    /// 媒体查询列表的求值结果。
    enum MediaResult: Equatable {
        /// 不含可求值的 amzn 条件，原样保留。
        case unchanged
        /// 在 Kindle 上恒成立：去掉媒体条件。
        case always
        /// 在 Kindle 上恒不成立：删除对应样式。
        case never
        /// 去掉 amzn 条件后剩余的标准查询列表。
        case reduced(String)
    }

    private static let trueConditions: Set<String> = ["amzn-kf8", "amzn-et"]
    private static let falseConditions: Set<String> = ["amzn-mobi", "amzn-mobi7"]

    // MARK: 样式表

    /// 展开样式表中的 `@media` 块；任何结构错误都返回原文。
    static func flatten(_ css: String) -> String {
        guard css.range(of: "amzn-", options: .caseInsensitive) != nil else { return css }
        let scalars = Array(css.unicodeScalars)
        guard let result = flatten(scalars, from: 0, to: scalars.count) else { return css }
        return result
    }

    /// 处理 `[start, end)` 区间；返回 nil 表示结构不完整。
    private static func flatten(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> String? {
        var output = String.UnicodeScalarView()
        var index = start
        var copyStart = start
        while index < end {
            let c = s[index]
            if c == "/", index + 1 < end, s[index + 1] == "*" {
                guard let close = commentEnd(s, from: index, to: end) else { return nil }
                index = close
                continue
            }
            if c == "\"" || c == "'" {
                guard let close = stringEnd(s, from: index, to: end) else { return nil }
                index = close
                continue
            }
            if c == "@", isMediaKeyword(s, at: index, end: end) {
                guard let brace = preludeEnd(s, from: index + 6, to: end), s[brace] == "{",
                      let close = blockEnd(s, openBrace: brace, to: end),
                      let inner = flatten(s, from: brace + 1, to: close) else { return nil }
                output.append(contentsOf: s[copyStart..<index])
                let prelude = String(String.UnicodeScalarView(s[(index + 6)..<brace]))
                switch evaluate(prelude) {
                case .unchanged:
                    output.append(contentsOf: s[index...brace])
                    output.append(contentsOf: inner.unicodeScalars)
                    output.append("}")
                case .always:
                    output.append(contentsOf: inner.unicodeScalars)
                case .never:
                    break
                case .reduced(let query):
                    output.append(contentsOf: "@media \(query) {".unicodeScalars)
                    output.append(contentsOf: inner.unicodeScalars)
                    output.append("}")
                }
                index = close + 1
                copyStart = index
                continue
            }
            index += 1
        }
        output.append(contentsOf: s[copyStart..<end])
        return String(output)
    }

    private static func isMediaKeyword(_ s: [Unicode.Scalar], at index: Int, end: Int) -> Bool {
        guard index + 6 <= end else { return false }
        let word = String(String.UnicodeScalarView(s[(index + 1)..<(index + 6)])).lowercased()
        guard word == "media" else { return false }
        // `@media-foo` 之类的标识符不是 @media 规则。
        if index + 6 < end {
            let next = s[index + 6]
            if next == "-" || next == "_" || CharacterSet.alphanumerics.contains(next) { return false }
        }
        return true
    }

    /// 返回注释结束后的位置。
    private static func commentEnd(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> Int? {
        var index = start + 2
        while index + 1 < end {
            if s[index] == "*", s[index + 1] == "/" { return index + 2 }
            index += 1
        }
        return nil
    }

    /// 返回字符串结束引号之后的位置；支持反斜杠转义。
    private static func stringEnd(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> Int? {
        let quote = s[start]
        var index = start + 1
        while index < end {
            if s[index] == "\\" { index += 2; continue }
            if s[index] == quote { return index + 1 }
            if s[index] == "\n" { return nil }
            index += 1
        }
        return nil
    }

    /// 找到 @media 前导部分结束处的 `{` 或 `;`（跳过字符串、注释与括号）。
    private static func preludeEnd(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> Int? {
        var index = start
        var depth = 0
        while index < end {
            let c = s[index]
            if c == "/", index + 1 < end, s[index + 1] == "*" {
                guard let close = commentEnd(s, from: index, to: end) else { return nil }
                index = close
                continue
            }
            if c == "\"" || c == "'" {
                guard let close = stringEnd(s, from: index, to: end) else { return nil }
                index = close
                continue
            }
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            if depth == 0, c == "{" || c == ";" { return index }
            if c == "}" { return nil }
            index += 1
        }
        return nil
    }

    /// 返回与 `openBrace` 匹配的 `}` 位置。
    private static func blockEnd(_ s: [Unicode.Scalar], openBrace: Int, to end: Int) -> Int? {
        var index = openBrace + 1
        var depth = 1
        while index < end {
            let c = s[index]
            if c == "/", index + 1 < end, s[index + 1] == "*" {
                guard let close = commentEnd(s, from: index, to: end) else { return nil }
                index = close
                continue
            }
            if c == "\"" || c == "'" {
                guard let close = stringEnd(s, from: index, to: end) else { return nil }
                index = close
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: 媒体查询

    /// 求值一个媒体查询列表（`@media` 前导或 HTML 的 `media` 属性）。
    static func evaluate(_ mediaQueryList: String) -> MediaResult {
        let cleaned = removingComments(mediaQueryList)
        guard cleaned.range(of: "amzn-", options: .caseInsensitive) != nil else { return .unchanged }
        var kept: [String] = []
        var touched = false
        for query in splitTopLevel(cleaned, separator: ",") {
            switch evaluateQuery(query) {
            case .unchanged:
                kept.append(query.trimmingCharacters(in: .whitespacesAndNewlines))
            case .always:
                return .always
            case .never:
                touched = true
            case .reduced(let reduced):
                touched = true
                kept.append(reduced)
            }
        }
        guard touched else { return .unchanged }
        return kept.isEmpty ? .never : .reduced(kept.joined(separator: ", "))
    }

    private static func evaluateQuery(_ query: String) -> MediaResult {
        var words = query.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
        guard !words.isEmpty else { return .unchanged }
        var negated = false
        var only = false
        switch words[0].lowercased() {
        case "not": negated = true; words.removeFirst()
        case "only": only = true; words.removeFirst()
        default: break
        }
        // 以独立的 `and` 分隔条件；括号中的特性表达式保持完整。
        var conditions: [String] = []
        var current: [String] = []
        var depth = 0
        for word in words {
            if depth == 0, word.lowercased() == "and" {
                conditions.append(current.joined(separator: " "))
                current = []
                continue
            }
            depth += word.filter { $0 == "(" }.count - word.filter { $0 == ")" }.count
            current.append(word)
        }
        conditions.append(current.joined(separator: " "))

        var amznValue = true
        var sawAmzn = false
        var rest: [String] = []
        for condition in conditions {
            let key = condition.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).lowercased()
            if trueConditions.contains(key) {
                sawAmzn = true
            } else if falseConditions.contains(key) {
                sawAmzn = true
                amznValue = false
            } else if key.hasPrefix("amzn-") {
                return .unchanged
            } else {
                rest.append(condition)
            }
        }
        guard sawAmzn else { return .unchanged }

        if negated {
            // not (amzn ∧ rest)：amzn 为假则恒成立；为真则等价于 not rest。
            guard amznValue else { return .always }
            guard let first = rest.first else { return .never }
            let prefix = first.hasPrefix("(") ? "not all and " : "not "
            return .reduced(prefix + rest.joined(separator: " and "))
        }
        guard amznValue else { return .never }
        guard let first = rest.first else { return .always }
        let prefix = only && !first.hasPrefix("(") ? "only " : ""
        return .reduced(prefix + rest.joined(separator: " and "))
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            if depth == 0, character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func removingComments(_ text: String) -> String {
        text.replacingOccurrences(of: "/\\*.*?\\*/", with: " ", options: .regularExpression)
    }

    // MARK: HTML

    private static let styleBlock = try! NSRegularExpression(
        pattern: "(<style\\b[^>]*>)(.*?)(</style\\s*>)", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let mediaTag = try! NSRegularExpression(
        pattern: "<(?:link|style)\\b[^>]*\\bmedia\\s*=\\s*(\"[^\"]*\"|'[^']*')[^>]*>", options: [.caseInsensitive])

    /// 处理 XHTML 中的 `<style>` 内容及 `<link>`／`<style>` 的 `media` 属性。
    static func flattenMarkup(_ html: String) -> String {
        guard html.range(of: "amzn-", options: .caseInsensitive) != nil else { return html }
        var result = html
        // 先处理 media 属性：不成立的 `<style>` 整个删除，因此必须在展开内容之前定位完整块。
        result = replacing(styleBlock, in: result) { match, text in
            let open = text.substring(with: match.range(at: 1))
            let body = text.substring(with: match.range(at: 2))
            let close = text.substring(with: match.range(at: 3))
            guard let newOpen = rewriteMediaAttribute(in: open) else { return "" }
            return newOpen + flatten(body) + close
        }
        result = replacing(mediaTag, in: result) { match, text in
            let tag = text.substring(with: match.range)
            guard tag.lowercased().hasPrefix("<link") else { return tag }
            return rewriteMediaAttribute(in: tag) ?? ""
        }
        return result
    }

    /// 返回改写后的开始标签；nil 表示该元素在 Kindle 上不生效、应删除。
    private static func rewriteMediaAttribute(in tag: String) -> String? {
        let attribute = try! NSRegularExpression(
            pattern: "\\s+media\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
        let ns = tag as NSString
        guard let match = attribute.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return tag }
        let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
        switch evaluate(ns.substring(with: valueRange)) {
        case .unchanged: return tag
        case .always: return ns.replacingCharacters(in: match.range, with: "")
        case .never: return nil
        case .reduced(let query):
            let escaped = query.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            return ns.replacingCharacters(in: match.range, with: " media=\"\(escaped)\"")
        }
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String,
                                  with transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = text as NSString
        var output = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            output += transform(match, ns)
            last = match.range.location + match.range.length
        }
        output += ns.substring(from: last)
        return output
    }
}
