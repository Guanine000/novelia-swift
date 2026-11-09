// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ReadingSpeedLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, chinese, japanese, english, bilingual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动识别"
        case .chinese: "中文"
        case .japanese: "日文"
        case .english: "英文"
        case .bilingual: "双语对照"
        }
    }
    var unit: String { self == .english ? "词/分钟" : "字/分钟" }
    static func detect(_ text: String) -> Self {
        let sample = text.prefix(4_000)
        if sample.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .japanese }
        if sample.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { return .chinese }
        return .english
    }
}

struct ReadingTimePoint: Equatable, Sendable {
    enum Reason: Equatable, Sendable { case forward, reset }
    var resource: Int
    var fraction: Double
    var reason: Reason = .reset
    static let start = Self(resource: 0, fraction: 0)
}

/// 单位与实际阅读顺序一致；TXT 的多个分页单元可属于同一逻辑章。
/// 构造时拒绝缺失资源，不把读取失败当作零字后给出虚假的全卷时间。
struct ReadingTimeMetrics: Equatable, Sendable {
    let words: [Int]
    let chapterGroups: [Int]
    let language: ReadingSpeedLanguage
    private let prefixes: [Double]
    private let chapterEnds: [Int]

    init(words: [Int], chapterStarts: [Int], language: ReadingSpeedLanguage) throws {
        guard !words.isEmpty, words.allSatisfy({ $0 >= 0 }) else { throw ReadingTimeError.unavailable }
        self.words = words; self.language = language
        let starts = Set(chapterStarts.filter { words.indices.contains($0) }).union([0])
        var group = 0, groups = [Int](), prefixes = [0.0]
        for index in words.indices {
            if index > 0, starts.contains(index) { group += 1 }
            groups.append(group)
            prefixes.append(prefixes.last! + Double(words[index]))
        }
        var ends = [Int](repeating: words.count, count: words.count), end = words.count
        for index in words.indices.reversed() {
            if index + 1 < words.count, groups[index + 1] != groups[index] { end = index + 1 }
            ends[index] = end
        }
        self.chapterGroups = groups; self.prefixes = prefixes; self.chapterEnds = ends
    }

    func position(_ point: ReadingTimePoint) -> Double? {
        guard words.indices.contains(point.resource), point.fraction.isFinite,
              (0...1).contains(point.fraction) else { return nil }
        return prefixes[point.resource] + Double(words[point.resource]) * point.fraction
    }

    func remaining(_ point: ReadingTimePoint) -> (chapter: Double, book: Double)? {
        guard let position = position(point) else { return nil }
        return (max(0, prefixes[chapterEnds[point.resource]] - position), max(0, prefixes.last! - position))
    }
}

enum ReadingTimeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "无法取得完整的本地文字信息，暂不能估计剩余时间。" }
}

/// 每个阅读视图独立持有的采样会话；只返回速率，不保存原文、页面轨迹或历史时间戳。
struct ReadingSpeedSampler {
    private var anchor: (point: ReadingTimePoint, words: Double, time: TimeInterval)?
    mutating func reset() { anchor = nil }

    mutating func observe(_ point: ReadingTimePoint, metrics: ReadingTimeMetrics, now: TimeInterval,
                          active: Bool) -> Double? {
        guard active, now.isFinite, let position = metrics.position(point),
              metrics.words[point.resource] > 0 else { reset(); return nil }
        let previous = anchor
        anchor = (point, position, now)
        guard point.reason == .forward, let previous else { return nil }
        let elapsed = now - previous.time, distance = position - previous.words
        // 大跳转、回读、空白/插图、快速连翻和长时间停留均重新建锚，不累计成一个大样本。
        guard (2...180).contains(elapsed), (5...1_800).contains(distance),
              point.resource >= previous.point.resource, point.resource <= previous.point.resource + 1 else { return nil }
        if point.resource == previous.point.resource, point.fraction - previous.point.fraction > 0.5 { return nil }
        let speed = distance * 60 / elapsed
        return (25...3_000).contains(speed) ? speed : nil
    }
}

/// 单个语言/阅读模式的有界速率窗口；中位数抑制少量浏览和停留样本。
struct ReadingSpeedProfile: Codable, Equatable, Sendable {
    private(set) var samples: [Double] = []
    mutating func add(_ speed: Double) {
        guard speed.isFinite, (25...3_000).contains(speed) else { return }
        samples.append(speed)
        if samples.count > 31 { samples.removeFirst(samples.count - 31) }
    }
    var speed: Double? {
        guard samples.count >= 5 else { return nil }
        let values = samples.sorted(), middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    var isValid: Bool { samples.count <= 31 && samples.allSatisfy { $0.isFinite && (25...3_000).contains($0) } }
}

enum ReadingTimeFormatting {
    static func duration(seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        if seconds == 0 { return "0 分钟" }
        if seconds < 60 { return "不足 1 分钟" }
        // 不显示秒；大值封顶后提示，避免异常数据转整数溢出。
        guard seconds < 3_600 * 10_000 else { return "超过 10000 小时" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
    }
}

extension ReadingTimeMetrics {
    static func loadTXT(_ book: TXTParsedBook, projection: ReadingTextProjection, paged: Bool) async throws -> Self {
        let task = Task.detached(priority: .utility) { try txt(book, projection: projection, paged: paged) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// 直接统计已有本地章节，不装载分页器的正文缓存，也不改写已有字数缓存。
    static func txt(_ book: TXTParsedBook, projection: ReadingTextProjection, paged: Bool) throws -> Self {
        var words = [Int](), starts = [Int](), votes: [ReadingSpeedLanguage: Int] = [:]
        for chapter in book.chapters {
            try Task.checkCancellation()
            starts.append(words.count)
            let language = ReadingSpeedLanguage.detect(projection.apply(String(chapter.body.prefix(4_000))))
            if paged {
                let cuts = TXTTextUnitCuts.cuts(utf8: chapter.body.utf8, maximumUTF8: 36_000)
                for index in 0..<(cuts.count - 1) {
                    let bytes = chapter.body.utf8
                    let lower = bytes.index(bytes.startIndex, offsetBy: cuts[index])
                    let upper = bytes.index(bytes.startIndex, offsetBy: cuts[index + 1])
                    let text = String(decoding: bytes[lower..<upper], as: UTF8.self)
                    let count = BookWordCount.count(text: projection.apply(text))
                    words.append(count); votes[language, default: 0] += count
                }
            } else {
                let count = BookWordCount.count(text: projection.apply(chapter.body))
                words.append(count); votes[language, default: 0] += count
            }
        }
        let language = votes.max { $0.value < $1.value }?.key ?? .chinese
        return try .init(words: words, chapterStarts: starts, language: language)
    }
}
