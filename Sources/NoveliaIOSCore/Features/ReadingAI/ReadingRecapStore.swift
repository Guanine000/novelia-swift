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
    /// 梗概要能驱动界面刷新：保存后直接反映到面板，不必重开。
    @Published private(set) var stories: [String: BookStorySummary]
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
    /// 梗概生成归 Store 持有：关闭回顾面板、甚至退出去看别的书都不该打断它，
    /// 结果直接落盘，下次打开直接看到。只有显式取消才停。
    @Published private(set) var storyProgress: [String: String] = [:]
    @Published private(set) var storyErrors: [String: String] = [:]
    private var storyTasks: [String: Task<Void, Never>] = [:]
    func isBuildingStory(book: String) -> Bool { storyTasks[key(book)] != nil }
    /// 界面侧准备阶段失败（多半是阅读位置已变化）也要让用户看到，不能静默什么都不发生。
    func reportStoryError(_ text: String, book: String) { storyErrors[key(book)] = text }
    func cancelStory(book: String) {
        let id = key(book)
        storyTasks[id]?.cancel(); storyTasks[id] = nil
        storyProgress[id] = nil
    }
    func startStory(book: String, chapters: [RecapChapter], previous: BookStorySummary?,
                    identity: String, coveredThrough: Int, partialChapterUTF16: Int? = nil, ai: ReadingAIStore) {
        let id = key(book)
        guard storyTasks[id] == nil else { return }
        storyErrors[id] = nil
        storyProgress[id] = "准备载入正文…"
        storyTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await StorySummaryGenerator.generate(chapters: chapters, previous: previous, ai: ai) { [weak self] text in
                    self?.storyProgress[id] = text
                }
                try Task.checkCancellation()
                if let fingerprint = try? StorySummaryGenerator.fingerprint(identity: identity, configuration: ai.configuration) {
                    let value = BookStorySummary(coveredThrough: coveredThrough, partialChapterUTF16: partialChapterUTF16, text: text, fingerprint: fingerprint, updatedAt: Date())
                    self.saveStory(value, book: book)
                }
            } catch is CancellationError {
            } catch {
                self.storyErrors[id] = error.localizedDescription
            }
            self.storyProgress[id] = nil
            self.storyTasks[id] = nil
        }
    }
    func saveStory(_ value: BookStorySummary, book: String) {
        guard value.coveredThrough >= 0, value.coveredThrough > 0 || (value.partialChapterUTF16 ?? 0) > 0,
              !value.text.isEmpty, value.text.utf16.count <= 4_000 else { return }
        let id = key(book)
        if stories[id] == nil, stories.count >= 64, let removed = stories.keys.sorted().first { stories.removeValue(forKey: removed) }
        stories[id] = value
        if let data = try? JSONEncoder().encode(stories) { defaults.set(data, forKey: Self.storiesKey) }
    }
}

/// ReaderSettings 持有的本机「世界观词条」存储：按系列或单书 workID 组织，支持手工维护与防剧透 AI 提取。
@MainActor
final class WorldviewLexiconStore: ObservableObject {
    private static let storageKey = "reader.worldview.entries.v1"
    private static let maximumEntries = 2_000
    private static let maximumBytes = 8 * 1_024 * 1_024

    @Published private(set) var entries: [WorldviewEntry] = []
    @Published private(set) var extractionProgress: [String: String] = [:]
    @Published private(set) var extractionErrors: [String: String] = [:]
    @Published private(set) var lastExtractionSummary: [String: String] = [:]

    private let defaults: UserDefaults
    private var extractionTasks: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           data.count <= Self.maximumBytes,
           let decoded = try? JSONDecoder().decode([WorldviewEntry].self, from: data) {
            entries = Array(decoded.prefix(Self.maximumEntries))
        }
    }

    func entries(for workID: String, query: String = "", category: WorldviewCategory? = nil) -> [WorldviewEntry] {
        entries
            .filter { item in
                guard item.workID == workID else { return false }
                if let category, item.category != category { return false }
                return item.matches(query: query)
            }
            .sorted { lhs, rhs in
                if lhs.category != rhs.category {
                    let li = WorldviewCategory.allCases.firstIndex(of: lhs.category) ?? 99
                    let ri = WorldviewCategory.allCases.firstIndex(of: rhs.category) ?? 99
                    return li < ri
                }
                return lhs.term.localizedStandardCompare(rhs.term) == .orderedAscending
            }
    }

    func count(for workID: String) -> Int {
        entries.reduce(0) { $0 + ($1.workID == workID ? 1 : 0) }
    }

    func upsert(_ entry: WorldviewEntry) {
        let trimmedTerm = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty, !trimmedSummary.isEmpty else { return }
        var normalized = entry
        normalized.term = String(trimmedTerm.prefix(60))
        normalized.summary = String(trimmedSummary.prefix(400))
        normalized.aliases = Array(Set(
            entry.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != normalized.normalizedTerm }
        )).sorted()
        normalized.updatedAt = Date()
        if let idx = entries.firstIndex(where: { $0.id == normalized.id }) {
            entries[idx] = normalized
        } else {
            entries.append(normalized)
            if entries.count > Self.maximumEntries {
                entries.removeFirst(entries.count - Self.maximumEntries)
            }
        }
        persist()
    }

    func delete(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before { persist() }
    }

    /// 合并 AI 提取出的词条：按词条名/别名去重，绝不覆盖用户手工编辑过的词条。
    @discardableResult
    func mergeExtracted(_ incoming: [WorldviewEntry], workID: String) -> Int {
        guard !incoming.isEmpty else { return 0 }
        var changed = 0
        for item in incoming {
            let termKey = item.normalizedTerm
            guard !termKey.isEmpty else { continue }
            if let idx = entries.firstIndex(where: { existing in
                guard existing.workID == workID else { return false }
                if existing.normalizedTerm == termKey { return true }
                return existing.aliases.contains { $0.lowercased() == termKey }
            }) {
                // 手工维护过的词条绝不被自动提取覆盖
                guard !entries[idx].isManual else { continue }
                var updated = entries[idx]
                let mergedAliases = Set(updated.aliases + item.aliases)
                    .filter { $0.lowercased() != updated.normalizedTerm }
                updated.aliases = Array(mergedAliases).sorted()
                if item.summary.count > updated.summary.count {
                    updated.summary = item.summary
                }
                updated.updatedAt = Date()
                entries[idx] = updated
                changed += 1
            } else {
                var added = item
                added.workID = workID
                entries.append(added)
                changed += 1
            }
        }
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        if changed > 0 { persist() }
        return changed
    }

    /// 书籍加入系列时，把原单书键下的世界观词条迁移到系列 ID，避免移入系列后丢失。
    func migrateWork(from: String, to: String) {
        guard from != to else { return }
        var changed = false
        for idx in entries.indices where entries[idx].workID == from {
            entries[idx].workID = to
            changed = true
        }
        if changed { persist() }
    }

    func isExtracting(workID: String) -> Bool {
        extractionTasks[workID] != nil
    }

    func cancelExtraction(workID: String) {
        extractionTasks[workID]?.cancel()
        extractionTasks[workID] = nil
        extractionProgress[workID] = nil
    }

    func startExtraction(
        workID: String,
        chapters: [RecapChapter],
        sourceBookKey: String?,
        sourceBookTitle: String?,
        ai: ReadingAIStore
    ) {
        guard extractionTasks[workID] == nil else { return }
        extractionErrors[workID] = nil
        lastExtractionSummary[workID] = nil
        extractionProgress[workID] = "准备扫描已读正文…"
        let existingTerms = entries(for: workID).map(\.term)
        extractionTasks[workID] = Task { [weak self] in
            guard let self else { return }
            do {
                let extracted = try await WorldviewExtractionPlan.extract(
                    chapters: chapters,
                    workID: workID,
                    sourceBookKey: sourceBookKey,
                    sourceBookTitle: sourceBookTitle,
                    existingTerms: existingTerms,
                    ai: ai
                ) { [weak self] status in
                    self?.extractionProgress[workID] = status
                }
                try Task.checkCancellation()
                let count = self.mergeExtracted(extracted, workID: workID)
                self.lastExtractionSummary[workID] = count > 0
                    ? "已新增或补充 \(count) 条世界观词条"
                    : "所选已读正文中未发现新的世界观词条"
            } catch is CancellationError {
            } catch {
                self.extractionErrors[workID] = error.localizedDescription
            }
            self.extractionProgress[workID] = nil
            self.extractionTasks[workID] = nil
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries), data.count <= Self.maximumBytes else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
