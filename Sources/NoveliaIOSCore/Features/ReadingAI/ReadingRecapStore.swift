// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// ReaderSettings 持有本机最后阅读时间与有界回顾缓存；独立于时长统计，不参与 WebDAV。
@MainActor
final class ReadingRecapStore: ObservableObject {
    @Published var promptAfterDays: Int {
        didSet { defaults.set(promptAfterDays, forKey: Self.daysKey) }
    }
    private let defaults: UserDefaults
    private static let daysKey = "reader.recap.promptDays.v1"
    private static let datesKey = "reader.recap.lastRead.v1"
    private static let cacheKey = "reader.recap.cache.v1"
    private static let storiesKey = "reader.recap.stories.v1"
    private var dates: [String: Date]
    private var cache: [String: ReadingRecap]
    private var stories: [String: BookStorySummary]
    private var recentPrompts: [String: Date] = [:]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let days = defaults.object(forKey: Self.daysKey) as? Int ?? 7
        promptAfterDays = [0, 3, 7, 14, 30].contains(days) ? days : 7
        dates = defaults.data(forKey: Self.datesKey).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        cache = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode([String: ReadingRecap].self, from: $0) } ?? [:]
        stories = defaults.data(forKey: Self.storiesKey).flatMap { try? JSONDecoder().decode([String: BookStorySummary].self, from: $0) } ?? [:]
        if dates.count > 2_048 { dates = [:] }
        if cache.count > 32 { cache = [:] }
        if stories.count > 64 { stories = [:] }
    }
    private func key(_ book: String) -> String { FileContentHash.sha256(Data(book.utf8)) }
    func shouldPrompt(book: String, boundary: Int, now: Date = Date()) -> Bool {
        guard promptAfterDays > 0, boundary > 0, let date = dates[key(book)] else { return false }
        return now.timeIntervalSince(date) >= Double(promptAfterDays) * 86_400
    }
    /// 同一打开过程中的引擎切换可能重建视图，短时间内只认领一次提示。
    func claimPrompt(book: String, boundary: Int, now: Date = Date()) -> Bool {
        let id = key(book)
        guard shouldPrompt(book: book, boundary: boundary, now: now),
              recentPrompts[id].map({ now.timeIntervalSince($0) >= 1_800 }) ?? true else { return false }
        recentPrompts = recentPrompts.filter { now.timeIntervalSince($0.value) < 1_800 }
        recentPrompts[id] = now
        return true
    }
    func recordReading(book: String, now: Date = Date()) {
        dates[key(book)] = now
        if dates.count > 2_048, let oldest = dates.min(by: { $0.value < $1.value })?.key { dates.removeValue(forKey: oldest) }
        if let data = try? JSONEncoder().encode(dates) { defaults.set(data, forKey: Self.datesKey) }
    }
    func cached(plan: ReadingRecapPlan, book: String) -> ReadingRecap? {
        guard let value = cache[key(book)], value.cacheKey == plan.cacheKey, value.boundary == plan.boundary,
              (1...5).contains(value.events.count), value.events.allSatisfy({ $0.chapter >= 0 && $0.chapter < plan.boundary }),
              let verified = try? plan.result(events: value.events), verified == value else { return nil }
        return verified
    }
    func save(_ recap: ReadingRecap, book: String) {
        guard (1...5).contains(recap.events.count), let encoded = try? JSONEncoder().encode(recap), encoded.count < 32_768 else { return }
        let id = key(book)
        if cache[id] == nil, cache.count >= 32, let removed = cache.keys.sorted().first { cache.removeValue(forKey: removed) }
        cache[id] = recap
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
    }
    /// 全书梗概：每本书一份，随边界推进增量更新，比近期回顾缓存少得多。
    func story(book: String) -> BookStorySummary? { stories[key(book)] }
    func saveStory(_ value: BookStorySummary, book: String) {
        guard value.coveredThrough > 0, !value.text.isEmpty, value.text.utf16.count <= 4_000 else { return }
        let id = key(book)
        if stories[id] == nil, stories.count >= 64, let removed = stories.keys.sorted().first { stories.removeValue(forKey: removed) }
        stories[id] = value
        if let data = try? JSONEncoder().encode(stories) { defaults.set(data, forKey: Self.storiesKey) }
    }
}
