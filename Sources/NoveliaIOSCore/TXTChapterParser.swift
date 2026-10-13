import Foundation
import Combine
import CoreFoundation
import OSLog

enum TXTDiagnosticLog {
    static let logger = Logger(subsystem: "cc.novelia.ios.port", category: "txt")
}

/// Reads common plain-text encodings used by downloaded and user-supplied novels.
/// File reads, caching and diagnostics live in `TXTBookCache`; this type only converts bytes.
enum TXTTextDecoder {
    static let attemptedEncodings = "UTF-8/BOM-Unicode/GB18030/GBK/Big5/Shift_JIS"

    static func decode(data: Data) -> String? {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }

        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        for charset in ["GB18030", "GBK", "Big5", "Shift_JIS"] {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { continue }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }
}

enum TXTTextDecodingError: LocalizedError {
    case unrecognizedEncoding

    var errorDescription: String? {
        "无法识别 TXT 编码或文件内容为空。支持 UTF-8、UTF-16、UTF-32、GB18030/GBK、Big5 和 Shift_JIS。"
    }
}

/// Detects common TXT chapter headings with an independent, conservative Swift implementation.
/// The multi-pass design was informed by the public documentation of Qingdu Reader
/// (Apache-2.0): https://github.com/zengchen666/qingdu-reader
/// No Qingdu source code is incorporated here.
struct TXTChapter: Identifiable, Hashable, Sendable {
    let index: Int
    let title: String
    let body: String
    let volumeTitle: String?

    var id: Int { index }
}

struct TXTChapterRule: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var pattern: String
    var explanation: String
    var isEnabled: Bool
    let isBuiltIn: Bool

    static let builtInDefaults = [
        TXTChapterRule(id: "chinese-numbered", name: "中文编号章节", pattern: #"^第\s*[0-9０-９零〇一二两兩三四五六七八九十百千万萬亿億]+\s*(章|回|节|節|卷|集|部|篇|話|话)\s*.*$"#, explanation: "匹配“第一章”“第 12 回”“第三卷”等标题。", isEnabled: true, isBuiltIn: true),
        TXTChapterRule(id: "standalone-volume", name: "独立卷标题", pattern: #"^(?:卷|部)\s*[0-9０-９零〇一二两兩三四五六七八九十百千万萬亿億]+\s*.*$"#, explanation: "识别单独写作“卷二”或“部二”的分卷标题。", isEnabled: true, isBuiltIn: true),
        TXTChapterRule(id: "special-title", name: "特殊章节标题", pattern: #"^(序|序章|序言|楔子|前言|引子|正文|后记|後記|尾声|尾聲|终章|終章|番外|番外篇)(?:[：:、.．\s—-].{0,20})?$"#, explanation: "识别序章、楔子、番外、后记、尾声等无编号标题。", isEnabled: true, isBuiltIn: true),
        TXTChapterRule(id: "english-chapter", name: "英文 Chapter 标题", pattern: #"^(?:chapter|chap\.)\s+([0-9]+|[ivxlcdm]+)(?:\s*[:：.、—-]?\s*.*)?$"#, explanation: "匹配“Chapter 12: Reunion”等英文标题。", isEnabled: true, isBuiltIn: true),
        TXTChapterRule(id: "numbered-list", name: "数字点号标题", pattern: #"^[0-9０-９零〇一二两兩三四五六七八九十百千]+[、.．]\s*.{1,24}$"#, explanation: "匹配“1. 标题”或“一、标题”；要求编号递增以降低误判。", isEnabled: true, isBuiltIn: true)
    ]
}

struct TXTChapterRuleConfiguration: Sendable {
    let enabledBuiltInIDs: Set<String>
    let enabledCustomRules: [TXTChapterRule]

    /// Identifies the rules that shape a parse; part of the TXT cache key.
    var fingerprint: String {
        let builtIn = enabledBuiltInIDs.sorted().joined(separator: ",")
        let custom = enabledCustomRules.map { "\($0.id)=\($0.pattern)" }.joined(separator: "\u{1F}")
        return builtIn + "|" + custom
    }

    static let defaults = TXTChapterRuleConfiguration(
        enabledBuiltInIDs: Set(TXTChapterRule.builtInDefaults.map(\.id)),
        enabledCustomRules: []
    )
}

@MainActor
final class TXTChapterRuleStore: ObservableObject {
    static let shared = TXTChapterRuleStore()

    @Published private(set) var rules: [TXTChapterRule]
    private let defaults: UserDefaults
    private let storageKey = "txtChapterRules.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "txtChapterRules.v1"),
           let saved = try? JSONDecoder().decode([TXTChapterRule].self, from: data) {
            let customRules = saved.filter { !$0.isBuiltIn }
            let savedByID = Dictionary(saved.filter(\.isBuiltIn).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            rules = TXTChapterRule.builtInDefaults.map { base in
                guard let savedRule = savedByID[base.id] else { return base }
                var merged = base
                merged.isEnabled = savedRule.isEnabled
                return merged
            } + customRules
        } else {
            rules = TXTChapterRule.builtInDefaults
        }
    }

    var configuration: TXTChapterRuleConfiguration {
        TXTChapterRuleConfiguration(
            enabledBuiltInIDs: Set(rules.filter { $0.isBuiltIn && $0.isEnabled }.map(\.id)),
            enabledCustomRules: rules.filter { !$0.isBuiltIn && $0.isEnabled }
        )
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        persist()
    }

    func saveCustomRule(_ rule: TXTChapterRule) {
        guard !rule.isBuiltIn else { return }
        if let index = rules.firstIndex(where: { $0.id == rule.id && !$0.isBuiltIn }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        persist()
    }

    func deleteCustomRule(_ rule: TXTChapterRule) {
        guard !rule.isBuiltIn else { return }
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum TXTChapterParser {
    private enum HeadingKind {
        case chapter(unit: String, number: Int?)
        case volume
        case special
    }

    private struct Heading {
        let line: Int
        let title: String
        let kind: HeadingKind
    }

    private struct CustomMatcher {
        let id: String
        let regex: NSRegularExpression
    }

    private static let numberedHeading = try! NSRegularExpression(
        pattern: #"^第\s*([0-9０-９零〇一二两兩三四五六七八九十百千万萬亿億]+)\s*(章|回|节|節|卷|集|部|篇|話|话)\s*(.*)$"#
    )
    private static let standaloneVolume = try! NSRegularExpression(
        pattern: #"^(?:卷|部)\s*([0-9０-９零〇一二两兩三四五六七八九十百千万萬亿億]+)\s*(.*)$"#
    )
    private static let englishHeading = try! NSRegularExpression(
        pattern: #"^(?:chapter|chap\.)\s+([0-9]+|[ivxlcdm]+)(?:\s*[:：.、—-]?\s*(.*))?$"#,
        options: [.caseInsensitive]
    )
    private static let genericNumberHeading = try! NSRegularExpression(
        pattern: #"^([0-9０-９零〇一二两兩三四五六七八九十百千]+)[、.．]\s*(.{1,24})$"#
    )
    private static let specialHeading = try! NSRegularExpression(
        pattern: #"^(序|序章|序言|楔子|前言|引子|正文|后记|後記|尾声|尾聲|终章|終章|番外|番外篇)(?:[：:、.．\s—-]*(.{0,20}))?$"#
    )

    /// Counts the cache logs next to each parse.
    struct Statistics: Equatable, Sendable {
        let lines: Int
        let headings: Int
        let fellBackToFullText: Bool
    }

    static func parse(_ text: String, rules: TXTChapterRuleConfiguration = .defaults) -> [TXTChapter] {
        parseWithStatistics(text, rules: rules).chapters
    }

    static func parseWithStatistics(_ text: String, rules: TXTChapterRuleConfiguration = .defaults) -> (chapters: [TXTChapter], statistics: Statistics) {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return ([TXTChapter(index: 0, title: "全文", body: text, volumeTitle: nil)], Statistics(lines: 0, headings: 0, fellBackToFullText: true))
        }
        let customMatchers = rules.enabledCustomRules.compactMap { rule -> CustomMatcher? in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
            return CustomMatcher(id: rule.id, regex: regex)
        }

        var headings: [Heading] = []
        for (index, line) in lines.enumerated() {
            if let heading = parseHeading(line, lineIndex: index, rules: rules, customMatchers: customMatchers) {
                headings.append(heading)
            }
        }
        headings = removeLeadingTableOfContents(headings, lines: lines)
        headings = enforceIncreasingNumbers(headings)

        let chapterHeadings = headings.filter {
            if case .chapter = $0.kind { return true }
            if case .special = $0.kind { return true }
            return false
        }
        guard chapterHeadings.count >= 3 else {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([TXTChapter(index: 0, title: "全文", body: body, volumeTitle: nil)],
                    Statistics(lines: lines.count, headings: chapterHeadings.count, fellBackToFullText: true))
        }

        var result: [TXTChapter] = []
        var nextHeadingLineByLine: [Int: Int] = [:]
        for index in headings.indices {
            nextHeadingLineByLine[headings[index].line] = index + 1 < headings.count
                ? headings[index + 1].line
                : lines.count
        }
        var currentVolume: String?
        var cursor = 0
        for heading in headings {
            if case .volume = heading.kind {
                currentVolume = heading.title
                cursor = max(cursor, heading.line + 1)
                continue
            }
            guard case .chapter = heading.kind else {
                if case .special = heading.kind {} else { continue }
                if heading.line > cursor {
                    appendChapter(title: "前言", lines: lines, range: cursor..<heading.line, volume: currentVolume, to: &result)
                }
                cursor = heading.line + 1
                let nextLine = nextHeadingLineByLine[heading.line] ?? lines.count
                appendChapter(title: heading.title, lines: lines, range: cursor..<nextLine, volume: currentVolume, to: &result)
                cursor = nextLine
                continue
            }

            if heading.line > cursor {
                let prefaceText = lines[cursor..<heading.line].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefaceText.isEmpty {
                    result.append(TXTChapter(index: result.count, title: "前言", body: prefaceText, volumeTitle: currentVolume))
                }
            }
            cursor = heading.line + 1
            let nextBoundary = nextHeadingLineByLine[heading.line] ?? lines.count
            appendChapter(title: heading.title, lines: lines, range: cursor..<nextBoundary, volume: currentVolume, to: &result)
            cursor = nextBoundary
        }

        let chapters = result.isEmpty
            ? [TXTChapter(index: 0, title: "全文", body: text.trimmingCharacters(in: .whitespacesAndNewlines), volumeTitle: nil)]
            : result.enumerated().map { index, chapter in
                TXTChapter(index: index, title: chapter.title, body: chapter.body, volumeTitle: chapter.volumeTitle)
            }
        return (chapters, Statistics(lines: lines.count, headings: chapterHeadings.count, fellBackToFullText: false))
    }

    private static func parseHeading(
        _ rawLine: String,
        lineIndex: Int,
        rules: TXTChapterRuleConfiguration,
        customMatchers: [CustomMatcher]
    ) -> Heading? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "　\u{FEFF}")))
        guard !line.isEmpty, line.count <= 40 else { return nil }
        let range = NSRange(line.startIndex..., in: line)

        if rules.enabledBuiltInIDs.contains("chinese-numbered"),
           let match = numberedHeading.firstMatch(in: line, range: range),
           let numberRange = Range(match.range(at: 1), in: line),
           let unitRange = Range(match.range(at: 2), in: line),
           let titleRange = Range(match.range(at: 3), in: line) {
            let numberText = String(line[numberRange])
            let unit = String(line[unitRange])
            let suffix = cleanSuffix(String(line[titleRange]))
            guard isPlausibleTitle(line: line, suffix: suffix) else { return nil }
            let title = line
            if unit == "卷" || unit == "部" { return Heading(line: lineIndex, title: title, kind: .volume) }
            return Heading(line: lineIndex, title: title, kind: .chapter(unit: unit, number: chineseNumber(numberText)))
        }

        if rules.enabledBuiltInIDs.contains("standalone-volume"),
           let match = standaloneVolume.firstMatch(in: line, range: range),
           let suffixRange = Range(match.range(at: 2), in: line) {
            let suffix = cleanSuffix(String(line[suffixRange]))
            guard isPlausibleTitle(line: line, suffix: suffix) else { return nil }
            return Heading(line: lineIndex, title: line, kind: .volume)
        }

        if rules.enabledBuiltInIDs.contains("english-chapter"),
           let match = englishHeading.firstMatch(in: line, range: range),
           let numberRange = Range(match.range(at: 1), in: line) {
            let numberText = String(line[numberRange])
            let suffix = match.range(at: 2).location == NSNotFound
                ? ""
                : Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
            guard isPlausibleTitle(line: line, suffix: suffix) else { return nil }
            return Heading(line: lineIndex, title: line, kind: .chapter(unit: "english", number: Int(numberText)))
        }

        if rules.enabledBuiltInIDs.contains("numbered-list"),
           let match = genericNumberHeading.firstMatch(in: line, range: range),
           let numberRange = Range(match.range(at: 1), in: line) {
            let numberText = String(line[numberRange])
            guard isPlausibleTitle(line: line, suffix: line) else { return nil }
            return Heading(line: lineIndex, title: line, kind: .chapter(unit: "generic", number: chineseNumber(numberText)))
        }

        if rules.enabledBuiltInIDs.contains("special-title"),
           let match = specialHeading.firstMatch(in: line, range: range) {
            let title = (Range(match.range, in: line).map { String(line[$0]) } ?? line)
            guard !endsWithSentencePunctuation(title) else { return nil }
            return Heading(line: lineIndex, title: title, kind: .special)
        }

        for matcher in customMatchers {
            guard let match = matcher.regex.firstMatch(in: line, range: range), match.range == range else { continue }
            guard isPlausibleTitle(line: line, suffix: "") else { return nil }
            return Heading(line: lineIndex, title: line, kind: .chapter(unit: "custom-\(matcher.id)", number: nil))
        }
        return nil
    }

    private static func cleanSuffix(_ suffix: String) -> String {
        suffix.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "　:：、.．—-")))
    }

    private static func isPlausibleTitle(line: String, suffix: String) -> Bool {
        guard line.count <= 40, suffix.count <= 24, !endsWithSentencePunctuation(line) else { return false }
        let first = suffix.first
        let rejectedStarts = CharacterSet(charactersIn: "的了着过吧，,、：:。；;！？!?…")
        if let first, first.unicodeScalars.contains(where: rejectedStarts.contains) { return false }
        return true
    }

    private static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？；…,.!?;".contains(last)
    }

    private static func removeLeadingTableOfContents(_ headings: [Heading], lines: [String]) -> [Heading] {
        guard headings.count >= 4 else { return headings }
        let earlyLimit = min(max(80, lines.count / 5), 500)
        var removed = Set<Int>()
        var start = 0
        while start < headings.count {
            guard headings[start].line < earlyLimit else { break }
            var end = start + 1
            while end < headings.count,
                  headings[end].line < earlyLimit,
                  headings[end].line - headings[end - 1].line <= 4,
                  visibleCharacterCount(lines[(headings[end - 1].line + 1)..<headings[end].line]) <= 72 {
                end += 1
            }
            if end - start >= 4 {
                for index in start..<end { removed.insert(index) }
            }
            start = max(end, start + 1)
        }
        return headings.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
    }

    private static func enforceIncreasingNumbers(_ headings: [Heading]) -> [Heading] {
        var lastNumberByUnit: [String: Int] = [:]
        var accepted: [Heading] = []
        for heading in headings {
            switch heading.kind {
            case .volume:
                lastNumberByUnit.removeAll()
                accepted.append(heading)
            case let .chapter(unit, number):
                if let number {
                    if let last = lastNumberByUnit[unit], number <= last { continue }
                    lastNumberByUnit[unit] = number
                }
                accepted.append(heading)
            case .special:
                accepted.append(heading)
            }
        }
        return accepted
    }

    private static func appendChapter(
        title: String,
        lines: [String],
        range: Range<Int>,
        volume: String?,
        to chapters: inout [TXTChapter]
    ) {
        guard range.lowerBound <= range.upperBound, range.upperBound <= lines.count else { return }
        let body = lines[range].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        chapters.append(TXTChapter(index: chapters.count, title: title, body: body, volumeTitle: volume))
    }

    private static func visibleCharacterCount(_ lines: ArraySlice<String>) -> Int {
        lines.reduce(0) { $0 + $1.filter { !$0.isWhitespace }.count }
    }

    private static func chineseNumber(_ value: String) -> Int? {
        let fullWidth = Dictionary(uniqueKeysWithValues: zip("０１２３４５６７８９", "0123456789"))
        let normalized = String(value.map { fullWidth[$0] ?? $0 })
        if let number = Int(normalized) { return number }

        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000, "万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000]
        guard normalized.allSatisfy({ digits[$0] != nil || units[$0] != nil }) else { return nil }
        if !normalized.contains(where: { units[$0] != nil }) {
            return normalized.reduce(0) { $0 * 10 + (digits[$1] ?? 0) }
        }

        var total = 0
        var section = 0
        var number = 0
        for character in normalized {
            if let digit = digits[character] {
                number = digit
            } else if let unit = units[character] {
                if unit < 10_000 {
                    section += max(number, 1) * unit
                    number = 0
                } else {
                    total += (section + number) * unit
                    section = 0
                    number = 0
                }
            }
        }
        return total + section + number
    }
}
