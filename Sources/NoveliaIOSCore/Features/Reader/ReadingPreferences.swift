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
    /// HTML只处理文本节点，不改链接、属性、脚本、样式或资源路径。
    public func applyHTML(_ html: String) -> String {
        guard chinese != .original || (enabled && !replacements.isEmpty) else { return html }
        let expression = try! NSRegularExpression(pattern: #"(?is)<!--.*?-->|<(script|style|head)\b[^>]*>.*?</\1\s*>|<[^>]*>|[^<]+"#)
        let source = html as NSString
        return expression.matches(in: html, range: NSRange(location: 0, length: source.length)).map { match in
            let part = source.substring(with: match.range)
            guard !part.hasPrefix("<") else { return part }
            // 保留实体边界；替换文本转义，不能注入HTML。
            return part.components(separatedBy: "&").enumerated().map { index, piece in
                if index > 0, let end = piece.firstIndex(of: ";"), piece.distance(from: piece.startIndex, to: end) < 16 {
                    return "&" + piece[...end] + escape(apply(String(piece[piece.index(after: end)...])))
                }
                return (index > 0 ? "&amp;" : "") + escape(apply(piece))
            }.joined()
        }.joined()
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
