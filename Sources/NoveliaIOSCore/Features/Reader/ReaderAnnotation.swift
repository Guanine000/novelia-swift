// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 单书文字标注：高亮/摘录与可选笔记。
///
/// 位置以章内 UTF-16 范围和文本引文为主，页码、视图矩形和分页偏移都不持久化；
/// 原生分页、Readium 与滚动模式各自把范围和引文映射到自己的渲染坐标。
/// `quote`/`prefix`/`suffix` 对应 W3C TextQuoteSelector 的思路，重新排版或换引擎后
/// 先按引文定位；`startUTF16`/`endUTF16` 只是同一次排版下的快速缓存。
struct ReaderAnnotation: Codable, Equatable, Identifiable, Sendable {
    enum Color: String, Codable, CaseIterable, Sendable {
        case yellow, green, blue, pink, purple

        var title: String {
            switch self {
            case .yellow: "黄色"
            case .green: "绿色"
            case .blue: "蓝色"
            case .pink: "粉色"
            case .purple: "紫色"
            }
        }
    }

    static let maxQuoteLength = 500
    static let maxContextLength = 200
    static let maxNoteLength = 4_000
    static let maxBookKeyLength = 200
    static let validKeyPrefixes = ["epub:", "txt:", "webepub:", "online:"]

    let id: UUID
    let bookKey: String
    var chapterIndex: Int
    /// 网络小说的稳定章节 ID；本地 EPUB/TXT 为 nil。
    var chapterID: String?
    /// EPUB 资源路径；TXT 与在线小说为 nil。
    var resourceHref: String?
    /// 章内比例，仅作为引文歧义时的定位提示。
    var progression: Double?
    var startUTF16: Int
    var endUTF16: Int
    var quote: String
    var prefix: String
    var suffix: String
    var projectionIdentity: String
    var color: Color
    var note: String
    let createdAt: Date
    var updatedAt: Date
    var deleted: Bool?

    var isDeleted: Bool { deleted == true }
    var length: Int { max(0, endUTF16 - startUTF16) }
    var range: NSRange { NSRange(location: startUTF16, length: length) }

    static func isValidBookKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maxBookKeyLength
            && validKeyPrefixes.contains { key.hasPrefix($0) }
    }

    var isValid: Bool {
        guard Self.isValidBookKey(bookKey), chapterIndex >= 0,
              (chapterID?.count ?? 0) <= 1_000, (resourceHref?.utf8.count ?? 0) <= 2_048,
              startUTF16 >= 0, endUTF16 > startUTF16,
              !quote.isEmpty, quote.utf16.count <= Self.maxQuoteLength,
              prefix.utf16.count <= Self.maxContextLength, suffix.utf16.count <= Self.maxContextLength,
              projectionIdentity.utf8.count <= 128, note.utf16.count <= Self.maxNoteLength,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite
        else { return false }
        if let progression {
            guard progression.isFinite, (0...1).contains(progression) else { return false }
        }
        return true
    }

    /// 同一章且范围相交视为重叠；两端的稳定章节 ID 都存在时必须一致。
    static func overlaps(_ lhs: ReaderAnnotation, _ rhs: ReaderAnnotation) -> Bool {
        guard !lhs.isDeleted, !rhs.isDeleted, lhs.bookKey == rhs.bookKey, lhs.chapterIndex == rhs.chapterIndex else {
            return false
        }
        if let left = lhs.chapterID, let right = rhs.chapterID, left != right { return false }
        return lhs.startUTF16 < rhs.endUTF16 && rhs.startUTF16 < lhs.endUTF16
    }

    /// 按 ID 合并，较新的修改或删除墓碑胜出；时间相同时保留本机。
    static func merged(_ local: [String: ReaderAnnotation],
                       _ remote: [String: ReaderAnnotation]) -> [String: ReaderAnnotation] {
        var result = local.filter { $0.key == $0.value.id.uuidString && $0.value.isValid }
        for (key, value) in remote where key == value.id.uuidString && value.isValid {
            if value.updatedAt > (result[key]?.updatedAt ?? .distantPast) { result[key] = value }
        }
        return result
    }

    /// 从章文本中截取标注范围前后的上下文，用于引文歧义时区分重复文本。
    static func context(in text: String, range: NSRange, maximum: Int = 80) -> (prefix: String, suffix: String) {
        let source = text as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length else {
            return ("", "")
        }
        let beforeStart = max(0, range.location - maximum)
        let afterEnd = min(source.length, NSMaxRange(range) + maximum)
        return (
            source.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
            source.substring(with: NSRange(location: NSMaxRange(range), length: afterEnd - NSMaxRange(range)))
        )
    }
}

/// 把持久化引文重新定位到当前章文本；偏移仍匹配时直接使用，否则按引文和上下文查找。
enum ReaderAnnotationResolver {
    /// 返回章节 UTF-16 范围；找不到或有无法区分的多个候选时返回 nil，交给界面标记失效。
    static func resolve(_ annotation: ReaderAnnotation, in text: String) -> NSRange? {
        let source = text as NSString
        let range = annotation.range
        if range.location >= 0, NSMaxRange(range) <= source.length,
           source.substring(with: range) == annotation.quote {
            return range
        }
        let candidates = occurrences(of: annotation.quote, in: source)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        let prefix = annotation.prefix
        let suffix = annotation.suffix
        let expected = annotation.progression.map { Int($0 * Double(source.length)) }
        let scored = candidates.map { candidate -> (range: NSRange, score: Int, distance: Int) in
            let before = source.substring(with: NSRange(location: 0, length: candidate.location))
            let afterStart = NSMaxRange(candidate)
            let after = source.substring(from: afterStart)
            let prefixScore = commonSuffix(before, prefix)
            let suffixScore = commonPrefix(after, suffix)
            let distance = expected.map { abs(candidate.location - $0) } ?? 0
            return (candidate, prefixScore + suffixScore, distance)
        }
        let bestScore = scored.map(\.score).max() ?? 0
        let best = scored.filter { $0.score == bestScore }
        guard !best.isEmpty else { return nil }
        let nearest = best.min { $0.distance < $1.distance }!
        let nearestCount = best.filter { $0.distance == nearest.distance }.count
        return nearestCount == 1 ? nearest.range : nil
    }

    private static func occurrences(of quote: String, in source: NSString) -> [NSRange] {
        guard !quote.isEmpty else { return [] }
        var result: [NSRange] = []
        var cursor = 0
        while cursor < source.length {
            let found = source.range(of: quote, options: [], range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound else { break }
            result.append(found)
            cursor = NSMaxRange(found)
        }
        return result
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16), right = Array(rhs.utf16)
        var count = 0
        while count < left.count, count < right.count, left[count] == right[count] { count += 1 }
        return count
    }

    private static func commonSuffix(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16), right = Array(rhs.utf16)
        var count = 0
        while count < left.count, count < right.count,
              left[left.count - 1 - count] == right[right.count - 1 - count] { count += 1 }
        return count
    }
}
