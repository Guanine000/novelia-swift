import Foundation

/// 只改变展示文本，原文件和网络缓存始终保留原文。规则最长优先、单次扫描，不递归替换。
public struct ReadingTextProjection: Codable, Equatable, Sendable {
    public enum Chinese: String, Codable, CaseIterable, Identifiable {
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
        case .traditional: converted = text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text
        }
        let rules = normalized.replacements
        guard enabled, !rules.isEmpty else { return converted }
        let keys = rules.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        var result = "", cursor = converted.startIndex
        while cursor < converted.endIndex {
            if let key = keys.first(where: { converted[cursor...].hasPrefix($0) }) {
                result += rules[key] ?? ""; cursor = converted.index(cursor, offsetBy: key.count)
            } else { result.append(converted[cursor]); cursor = converted.index(after: cursor) }
        }
        return result
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
