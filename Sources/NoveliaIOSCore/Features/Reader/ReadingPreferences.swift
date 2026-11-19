import Foundation

/// 只改变展示文本，原文件和网络缓存始终保留原文。规则最长优先、单次扫描，不递归替换。
public struct ReadingTextProjection: Codable, Equatable, Sendable {
    public enum Chinese: String, Codable, CaseIterable, Identifiable, Sendable {
        case original, simplified, traditional
        public var id: String { rawValue }
        var title: String { switch self { case .original: "保持原文"; case .simplified: "简体中文"; case .traditional: "繁體中文" } }
    }
    public var chinese: Chinese = .original
    public var replacements: [String: String] = [:]
    public var enabled = true
    public init() {}
    public var identity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return FileContentHash.sha256((try? encoder.encode(self.normalized)) ?? Data())
    }
    var normalized: Self {
        var value = self
        value.replacements = Dictionary(uniqueKeysWithValues: replacements.filter { !$0.key.isEmpty && $0.key.utf16.count <= 120 && $0.value.utf16.count <= 120 }.sorted { $0.key < $1.key }.prefix(1000).map { ($0.key, $0.value) })
        return value
    }
    /// 与简繁转换联动的 BCP-47 语言标记；保持原文时返回 nil，沿用书籍原有语言。
    public var htmlLanguageTag: String? {
        switch chinese {
        case .original: nil
        case .simplified: "zh-Hans"
        case .traditional: "zh-Hant"
        }
    }
    /// 未指定阅读字体时的地区默认字体，用于压过书内硬编码的日文／繁体字体。
    public var preferredCJKFontFamily: String? {
        switch chinese {
        case .original: nil
        case .simplified: "PingFang SC"
        case .traditional: "PingFang TC"
        }
    }
    public func apply(_ text: String) -> String {
        let converted: String
        switch chinese {
        case .original: converted = text
        case .simplified: converted = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        case .traditional: converted = ChineseConversionTable.apply(text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text)
        }
        let rules = normalized
        guard rules.enabled, !rules.replacements.isEmpty else { return converted }
        return ReplacementTrie.cached(for: rules).apply(converted)
    }
    private static let htmlTokenRegex = try! NSRegularExpression(pattern: #"(?is)<!--.*?-->|<(script|style|head)\b[^>]*>.*?</\1\s*>|<[^>]*>|[^<]+"#)
    private static let htmlLangAttrRegex = try! NSRegularExpression(pattern: #"(?i)(?<=\s)(xml:lang|lang)(\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`/]+))"#)

    /// HTML 处理文本节点，并在开启简繁转换时同步修正根标签及 CJK 元素的 lang／xml:lang，
    /// 避免同码位异体字沿用原书日文或繁体字形；不改链接、脚本、样式或资源路径。
    public func applyHTML(_ html: String) -> String {
        guard chinese != .original || (enabled && !replacements.isEmpty) else { return html }
        let languageTag = htmlLanguageTag
        let source = html as NSString
        return Self.htmlTokenRegex.matches(in: html, range: NSRange(location: 0, length: source.length)).map { match in
            let part = source.substring(with: match.range)
            if part.hasPrefix("<") {
                guard let languageTag else { return part }
                return Self.rewritingHTMLLanguage(in: part, languageTag: languageTag)
            }
            // 保留实体边界；替换文本转义，不能注入HTML。
            return part.components(separatedBy: "&").enumerated().map { index, piece in
                if index > 0, let end = piece.firstIndex(of: ";"), piece.distance(from: piece.startIndex, to: end) < 16 {
                    return "&" + piece[...end] + escape(apply(String(piece[piece.index(after: end)...])))
                }
                return (index > 0 ? "&amp;" : "") + escape(apply(piece))
            }.joined()
        }.joined()
    }
    private static func rewritingHTMLLanguage(in tag: String, languageTag: String) -> String {
        guard tag.hasPrefix("<"), !tag.hasPrefix("</"), !tag.hasPrefix("<!"), !tag.hasPrefix("<?") else { return tag }
        let afterOpen = tag.index(after: tag.startIndex)
        let nameEnd = tag[afterOpen...].firstIndex(where: { $0.isWhitespace || $0 == ">" || $0 == "/" }) ?? tag.endIndex
        let tagName = tag[afterOpen..<nameEnd].lowercased()
        let isRootHTML = tagName == "html"
        if !isRootHTML && tag.range(of: "lang", options: .caseInsensitive) == nil { return tag }

        let nsTag = tag as NSString
        let matches = htmlLangAttrRegex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length))
        var hasLang = false
        var hasXMLLang = false
        var output = ""
        var cursor = 0
        for match in matches {
            let attrName = nsTag.substring(with: match.range(at: 1))
            let lowerAttr = attrName.lowercased()
            if lowerAttr == "lang" { hasLang = true }
            if lowerAttr == "xml:lang" { hasXMLLang = true }

            let valueRange: NSRange
            let quote: String
            if match.range(at: 3).location != NSNotFound {
                valueRange = match.range(at: 3); quote = "\""
            } else if match.range(at: 4).location != NSNotFound {
                valueRange = match.range(at: 4); quote = "'"
            } else {
                valueRange = match.range(at: 5); quote = "\""
            }
            let currentValue = nsTag.substring(with: valueRange)
            guard isRootHTML || isCJKLanguageTag(currentValue) else { continue }

            output += nsTag.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let equals = nsTag.substring(with: match.range(at: 2))
            output += "\(attrName)\(equals)\(quote)\(languageTag)\(quote)"
            cursor = match.range.location + match.range.length
        }
        var result = cursor == 0 ? tag : output + nsTag.substring(from: cursor)
        if isRootHTML && (!hasLang || !hasXMLLang) {
            var additions = ""
            if !hasLang { additions += " lang=\"\(languageTag)\"" }
            if !hasXMLLang { additions += " xml:lang=\"\(languageTag)\"" }
            if result.hasSuffix("/>") {
                result.insert(contentsOf: additions, at: result.index(result.endIndex, offsetBy: -2))
            } else if result.hasSuffix(">") {
                result.insert(contentsOf: additions, at: result.index(before: result.endIndex))
            }
        }
        return result
    }
    private static func isCJKLanguageTag(_ raw: String) -> Bool {
        let primary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(maxSplits: 1, whereSeparator: { $0 == "-" || $0 == "_" })
            .first
        guard let primary else { return false }
        return primary == "zh" || primary == "ja" || primary == "jp" || primary == "ko"
    }
    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 替换规则的编译结果：前缀树一次扫描取最长命中，语义与逐键比较一致（最长优先、不递归）。
/// 编译后只读并可跨线程共享；按投影内容缓存，避免每次重排都重新排序和扫描全部规则。
final class ReplacementTrie: @unchecked Sendable {
    private final class Node {
        var children: [Character: Node] = [:]
        var value: String?
        func child(_ character: Character) -> Node {
            if let next = children[character] { return next }
            let next = Node(); children[character] = next; return next
        }
    }
    private static let lock = NSLock()
    private static var cached: [String: ReplacementTrie] = [:]
    private static var order: [String] = []
    /// 同一本书通常只有一套规则；保留少量版本即可，超出按先入先出丢弃。
    private static let cacheLimit = 8

    static func cached(for projection: ReadingTextProjection) -> ReplacementTrie {
        let key = projection.identity
        lock.lock(); defer { lock.unlock() }
        if let trie = cached[key] { return trie }
        let trie = ReplacementTrie(projection.replacements)
        cached[key] = trie
        order.append(key)
        if order.count > cacheLimit { cached[order.removeFirst()] = nil }
        return trie
    }

    private let root = Node()
    init(_ rules: [String: String]) {
        for (key, value) in rules {
            var node = root
            for character in key { node = node.child(character) }
            node.value = value
        }
    }
    func apply(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            var node = root, cursor = index, end = -1
            var matched: String?
            while cursor < characters.count, let next = node.children[characters[cursor]] {
                node = next; cursor += 1
                if let value = node.value { end = cursor; matched = value }
            }
            if let matched { result += matched; index = end }
            else { result.append(characters[index]); index += 1 }
        }
        return result
    }
}

/// 单书快照只包含阅读展示，不复制认证、同步或全局引擎开关。
struct BookReadingPreferences: Codable, Equatable {
    var fontSize: Double
    var appearance: String
    var paged: Bool
    var layout: Data?
    /// 旧记录缺字段时仍按原单书样式解释；新建文字规则不自动开启样式覆盖。
    var styleOverride: Bool? = nil
    var projection: ReadingTextProjection = .init()
    /// 最近一次设置本书文字处理的时间；旧记录缺字段时不参与同步更新时间比较。
    var projectionUpdatedAt: Date? = nil
}

/// 单书文字处理记录；`updatedAt` 用于本机与同步的较新者胜出。
struct ReaderTextProjectionRecord: Codable, Equatable {
    var projection: ReadingTextProjection
    var updatedAt: Date
}

/// 连续拖选保留起点前的选择快照，反向拖动自动还原退出区间的原选择。
struct LibraryRangeSelection {
    let original: Set<String>
    let anchor: Int
    let selects: Bool
    func selection(through end: Int, orderedKeys: [String]) -> Set<String> {
        guard orderedKeys.indices.contains(anchor), orderedKeys.indices.contains(end) else { return original }
        let keys = Set(orderedKeys[min(anchor, end)...max(anchor, end)])
        return selects ? original.union(keys) : original.subtracting(keys)
    }
}
