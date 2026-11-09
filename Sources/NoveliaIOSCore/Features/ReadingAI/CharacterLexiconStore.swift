// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// ReaderSettings 持有的本机人物资料；稳定作品 ID 使用用户明确选择的系列 ID，不按名称归并。
/// 卷序、人物 UUID 与逐事实出处分离；自动生成按完整章节落盘，疑点单独标记，不自动合并同名人物。
@MainActor
final class CharacterLexiconStore: ObservableObject, CharacterSyncLocal {
    private struct Archive: Codable {
        var version = 1
        var orders: [String: [String]] = [:]
        var entities: [CharacterEntity] = []
        var scans: [String: CharacterScanCheckpoint]? = nil
        var rejected: [String]? = nil
        var sync: CharacterSyncState? = nil
    }
    @Published private(set) var entities: [CharacterEntity] = []
    private var archive = Archive()
    private let defaults: UserDefaults
    private static let key = "reader.characters.archive.v1"
    private var damaged = false
    private let portraitDirectory: URL?
    let extractionCache: CharacterExtractionCache
    init(defaults: UserDefaults, portraitDirectory: URL? = nil) {
        self.defaults = defaults
        self.portraitDirectory = portraitDirectory
        extractionCache = CharacterExtractionCache(defaults: defaults)
        if let data = defaults.data(forKey: Self.key) {
            if data.count <= 16 * 1_024 * 1_024, let value = try? JSONDecoder().decode(Archive.self, from: data), value.version == 1 {
                archive = value; entities = value.entities
            } else { damaged = true }
        }
        if !damaged { archive.entities = normalizedFactIDs(archive.entities); entities = archive.entities }
        if !damaged, archive.sync == nil {
            do { archive.sync = try localChanges(from: Archive(), to: archive, base: .init(), date: Date(timeIntervalSince1970: 1)) }
            catch { damaged = true }
        }
    }
    func order(work: String) -> [String] { archive.orders[work] ?? [] }
    private func commit(_ proposed: Archive, applyingSync: Bool = false) throws {
        var value = proposed
        value.entities = normalizedFactIDs(value.entities)
        guard !damaged else { throw CharacterLexiconError.damaged }
        if !applyingSync {
            value.sync = try localChanges(from: archive, to: value, base: value.sync ?? .init(), date: nextSyncDate())
        }
        let previousImages = archive.sync?.portraitHashes ?? []
        guard (value.rejected?.count ?? 0) <= 20_000, value.entities.count <= 2_000, value.entities.reduce(0, { $0 + $1.facts.count }) <= 20_000,
              let data = try? JSONEncoder().encode(value), data.count <= 16 * 1_024 * 1_024 else { throw CharacterLexiconError.storage }
        defaults.set(data, forKey: Self.key); archive = value; entities = value.entities
        for hash in previousImages.subtracting(value.sync?.portraitHashes ?? []) { discardUnreferencedPortrait(hash) }
    }
    private func normalizedFactIDs(_ source: [CharacterEntity]) -> [CharacterEntity] {
        var seen: Set<String> = []
        return source.map { entity in
            var value = entity
            value.facts = value.facts.map { fact in
                var result = fact
                if !seen.insert(fact.id).inserted { result.id = UUID().uuidString; seen.insert(result.id) }
                return result
            }
            return value
        }
    }
    private func nextSyncDate() -> Date {
        let state = archive.sync ?? .init()
        let dates = state.facts.values.map(\.updatedAt) + state.orders.values.map(\.updatedAt) + state.portraits.values.map(\.updatedAt) + state.scans.values.map(\.updatedAt)
        return max(Date(), (dates.max() ?? .distantPast).addingTimeInterval(0.001))
    }
    private func factMap(_ value: Archive) throws -> [String: CharacterSyncFact] {
        var result: [String: CharacterSyncFact] = [:]
        for entity in value.entities {
            for fact in entity.facts {
                guard result[fact.id] == nil else { throw CharacterLexiconError.damaged }
                result[fact.id] = .init(entity: entity.id, work: entity.work, fact: fact)
            }
        }
        return result
    }
    private func localChanges(from old: Archive, to new: Archive, base: CharacterSyncState, date: Date) throws -> CharacterSyncState {
        var state = base
        let before = try factMap(old), after = try factMap(new)
        for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
            state.facts[id] = .init(value: after[id], updatedAt: date)
        }
        for work in Set(old.orders.keys).union(new.orders.keys) where old.orders[work] != new.orders[work] {
            state.orders[work] = .init(value: new.orders[work], updatedAt: date)
        }
        let surviving = Set(new.entities.map(\.id))
        for id in old.entities.map(\.id) where !surviving.contains(id) && state.portraits[id]?.value != nil {
            state.portraits[id] = .init(value: nil, updatedAt: date)
        }
        for key in Set(old.scans?.keys.map { $0 } ?? []).union(new.scans?.keys.map { $0 } ?? []) where old.scans?[key] != new.scans?[key] {
            state.scans[key] = .init(value: new.scans?[key], updatedAt: date)
        }
        // 否决记录按整表赋值而不是并集：重建人物卡要能撤销它，
        // 而调用方传入的 Archive 始终是完整状态，不存在只带增量的情况。
        state.rejected = Set(new.rejected ?? [])
        return try state.validated()
    }
    func characterSnapshot() throws -> CharacterSyncState {
        guard !damaged else { throw CharacterLexiconError.damaged }
        return try (archive.sync ?? .init()).validated()
    }
    func applyCharacters(_ remote: CharacterSyncState) throws {
        let merged = try CharacterSyncState.merged(characterSnapshot(), remote)
        var next = archive
        var grouped: [String: CharacterEntity] = [:]
        for record in merged.facts.values {
            guard let value = record.value, !merged.rejected.contains(Self.evidenceKey(value.fact)) else { continue }
            if let existing = grouped[value.entity], existing.work != value.work { throw WebDAVSyncError.invalidAsset }
            if grouped[value.entity] == nil { grouped[value.entity] = .init(id: value.entity, work: value.work, facts: []) }
            grouped[value.entity]?.facts.append(value.fact)
        }
        next.entities = grouped.values.sorted { $0.id < $1.id }.map { entity in
            var value = entity; value.facts.sort { $0.id < $1.id }; return value
        }
        next.orders = merged.orders.compactMapValues(\.value)
        next.rejected = merged.rejected.sorted()
        next.scans = merged.scans.compactMapValues(\.value)
        next.sync = merged
        try commit(next, applyingSync: true)
    }
    func portrait(for id: String, scope: CharacterScope) -> CharacterPortrait? {
        guard scope.visible(entities).contains(where: { $0.id == id }), let value = archive.sync?.portraits[id]?.value,
              scope.identities[value.book] == value.identity,
              let rank = scope.volumes.firstIndex(of: value.book), let current = scope.volumes.firstIndex(of: scope.currentBook), rank <= current,
              rank < current || scope.currentChapter >= value.boundary else { return nil }
        if let boundaries = scope.readBoundaries, (boundaries[value.book] ?? -1) < value.boundary { return nil }
        return value
    }
    func setPortrait(_ data: Data?, entity id: String, scope: CharacterScope) throws {
        guard !damaged, scope.visible(entities).contains(where: { $0.id == id }) else { throw CharacterLexiconError.scope }
        var next = archive
        var state = next.sync ?? .init()
        let value: CharacterPortrait?
        var createdHash: String?
        if let data {
            guard let identity = scope.identities[scope.currentBook] else { throw CharacterLexiconError.missing }
            let hash = FileContentHash.sha256(data)
            try installPortrait(data, hash: hash); createdHash = hash
            value = .init(hash: hash, book: scope.currentBook, identity: identity, boundary: scope.currentChapter)
        } else { value = nil }
        state.portraits[id] = .init(value: value, updatedAt: nextSyncDate()); next.sync = state
        do { try commit(next) }
        catch { if let hash = createdHash { discardUnreferencedPortrait(hash) }; throw error }
    }
    func portraitFile(_ hash: String) -> URL? {
        guard WebDAVAsset.isValidHash(hash), let directory = portraitDirectory else { return nil }
        let file = directory.appendingPathComponent(hash + ".jpg")
        guard let attributes = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= 1_024 * 1_024,
              let data = try? Data(contentsOf: file), Self.validPortrait(data), FileContentHash.sha256(data) == hash else { return nil }
        return file
    }
    nonisolated static func validPortrait(_ data: Data) -> Bool {
        data.count >= 4 && data.count <= 1_024 * 1_024 && data.starts(with: [0xff, 0xd8, 0xff]) && data.suffix(2) == Data([0xff, 0xd9])
    }
    func installPortrait(_ data: Data, hash: String) throws {
        guard !damaged, let directory = portraitDirectory, WebDAVAsset.isValidHash(hash), Self.validPortrait(data), FileContentHash.sha256(data) == hash else { throw WebDAVSyncError.invalidAsset }
        if portraitFile(hash) != nil { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let used = try urls.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard used + data.count <= 616 * 1_024 * 1_024 else { throw CharacterLexiconError.storage }
        try data.write(to: directory.appendingPathComponent(hash + ".jpg"), options: .atomic)
    }
    func discardUnreferencedPortrait(_ hash: String) {
        guard WebDAVAsset.isValidHash(hash), archive.sync?.portraitHashes.contains(hash) != true, let directory = portraitDirectory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(hash + ".jpg"))
    }
    func confirmOrder(work: String, volumes: [String]) throws {
        guard !volumes.isEmpty, Set(volumes).count == volumes.count else { throw CharacterLexiconError.scope }
        var next = archive; next.orders[work] = volumes; try commit(next)
    }
    /// 单书直达人物卡的 work 键迁移：书被移入系列时，把以书键保存的卷序、人物与逐书检查点搬到系列 ID 下。
    /// 仅当来源已有卷序且目标尚无独立数据时执行，不覆盖目标既有数据；事实只换归属，book/identity 与证据不变。
    /// 移出系列不回迁：多书系列无法映射回单书，数据留在系列 ID 下，重新移入原系列即恢复。
    func migrateWork(from: String, to: String) throws {
        guard !damaged, from != to, let volumes = archive.orders[from], archive.orders[to] == nil else { return }
        var next = archive
        next.orders[to] = volumes; next.orders[from] = nil
        next.entities = next.entities.map { entity in
            entity.work == from ? CharacterEntity(id: entity.id, work: to, facts: entity.facts) : entity
        }
        if next.scans != nil {
            for book in volumes {
                let source = Self.scanKey(work: from, book: book)
                guard let checkpoint = next.scans?[source] else { continue }
                next.scans?[Self.scanKey(work: to, book: book)] = checkpoint
                next.scans?.removeValue(forKey: source)
            }
        }
        try commit(next)
    }
    @discardableResult
    func accept(_ candidate: CharacterCandidate, scope: CharacterScope) throws -> String {
        guard archive.orders[scope.work] == scope.volumes, !candidate.facts.isEmpty,
              candidate.facts.allSatisfy({ scope.permits($0) }) else { throw CharacterLexiconError.scope }
        guard candidate.facts.allSatisfy({ Self.valid($0) }) else { throw CharacterLexiconError.evidence }
        let id = UUID().uuidString
        var next = archive
        next.entities.append(.init(id: id, work: scope.work, facts: candidate.facts))
        try commit(next); return id
    }
    nonisolated static func valid(_ fact: CharacterFact) -> Bool {
        (fact.relatedName.map { !$0.isEmpty && $0.utf16.count <= 100 && fact.quote.range(of: $0, options: .literal) != nil } ?? true)
            && fact.chapter >= 0 && fact.offset >= 0 && !fact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fact.name.utf16.count <= 100
            && !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fact.text.utf16.count <= 300
            && (10...600).contains(fact.quote.utf16.count) && (fact.quote.range(of: fact.name, options: .literal) != nil || fact.attribution.map {
                $0.chapter >= 0 && $0.offset >= 0
                    && (($0.book != nil && $0.book != fact.book && $0.identity != nil) || ($0.chapter <= fact.chapter && ($0.chapter < fact.chapter || $0.offset <= fact.offset)))
                    && (1...600).contains($0.quote.utf16.count) && $0.quote.range(of: fact.name, options: .literal) != nil
            } == true)
    }
    func scannedThrough(work: String, book: String, signature: String) -> Int {
        let value = archive.scans?[Self.scanKey(work: work, book: book)]
        return value?.signature == signature ? max(0, value?.nextChapter ?? 0) : 0
    }
    private static func scanKey(work: String, book: String) -> String {
        FileContentHash.sha256(Data((work + "|" + book).utf8))
    }
    /// 人物更新与章节检查点同事务提交；新事实不覆盖旧事实，同名但没有明确ID的候选保持独立。
    func applyAutomatic(_ candidates: [CharacterCandidate], plan: CharacterExtractionPlan, signature: String) throws {
        guard archive.orders[plan.scope.work] == plan.scope.volumes else { throw CharacterLexiconError.scope }
        var next = archive
        let rejected = Set(next.rejected ?? [])
        for candidate in candidates {
            let facts = candidate.facts.filter { fact in
                !rejected.contains(Self.evidenceKey(fact)) && fact.book == plan.book && fact.identity == plan.identity && plan.chunks.contains { chunk in
                    chunk.chapter == fact.chapter && fact.offset >= chunk.offset && fact.offset < chunk.offset + chunk.text.utf16.count
                }
            }
            guard !facts.isEmpty else { continue }
            guard facts.allSatisfy({ plan.scope.permits($0) && Self.valid($0) }) else { throw CharacterLexiconError.evidence }
            if let index = next.entities.firstIndex(where: { $0.id == candidate.id && $0.work == plan.scope.work }) {
                let previousFacts = next.entities[index].facts
                var seen = Set(previousFacts.map(Self.factKey))
                next.entities[index].facts += facts.filter { seen.insert(Self.factKey($0)).inserted }.map { fact in
                    var value = fact
                    if let category = fact.category, category != "经历",
                       previousFacts.contains(where: { $0.category == category && $0.text != fact.text }) { value.needsReview = true }
                    return value
                }
            } else {
                let sameName = plan.scope.visible(next.entities).contains { $0.name == candidate.name }
                let values = facts.map { fact -> CharacterFact in
                    var value = fact
                    if sameName { value.needsReview = true }
                    return value
                }
                next.entities.append(.init(id: candidate.id, work: plan.scope.work, facts: values))
            }
        }
        let end = (plan.chunks.map(\.chapter).max() ?? -1) + 1
        if next.scans == nil { next.scans = [:] }
        let key = Self.scanKey(work: plan.scope.work, book: plan.book)
        let old = next.scans?[key]
        let previous = old?.signature == signature ? old?.nextChapter ?? 0 : 0
        next.scans?[key] = .init(signature: signature, nextChapter: max(previous, end))
        try commit(next)
    }
    func completeEmptyChapter(book: String, identity: String, chapter: Int, scope: CharacterScope, signature: String) throws {
        guard archive.orders[scope.work] == scope.volumes, scope.identities[book] == identity,
              scope.permits(book: book, chapter: chapter) else { throw CharacterLexiconError.scope }
        var next = archive
        if next.scans == nil { next.scans = [:] }
        let key = Self.scanKey(work: scope.work, book: book)
        let old = next.scans?[key]
        let previous = old?.signature == signature ? old?.nextChapter ?? 0 : 0
        next.scans?[key] = .init(signature: signature, nextChapter: max(previous, chapter + 1))
        try commit(next)
    }
    private static func evidenceKey(_ fact: CharacterFact) -> String {
        FileContentHash.sha256(Data("\(fact.book)|\(fact.identity)|\(fact.chapter)|\(fact.offset)|\(fact.name)|\(fact.quote)".utf8))
    }
    private static func factKey(_ fact: CharacterFact) -> String {
        "\(fact.book)|\(fact.identity)|\(fact.chapter)|\(fact.offset)|\(fact.name)|\(fact.text)|\(fact.quote)"
    }
    /// 重建人物卡：清空本作品的人物、逐书检查点与请求缓存，并清空"已否决"记录，
    /// 让用户之前删掉的条目也能重新被提取出来。卷序保留。
    /// 否决记录是按内容哈希存的、不区分作品：这里整表清空，其他作品下次重扫时
    /// 被删条目同样可能重新出现，这是本次重建的已知代价。
    /// 角色图片随人物一起失效（sync 记录由 commit 写成墓碑）。
    func reset(scope: CharacterScope) throws {
        guard archive.orders[scope.work] == scope.volumes else { throw CharacterLexiconError.scope }
        var next = archive
        next.entities.removeAll { $0.work == scope.work }
        next.rejected = []
        if next.scans != nil {
            for book in scope.volumes { next.scans?.removeValue(forKey: Self.scanKey(work: scope.work, book: book)) }
        }
        try commit(next)
        extractionCache.removeAll(work: scope.work)
    }
    /// 当前阅读范围内的同名多卡，供"校准重复人物"逐个确认合并。
    /// 只按完全相同的显示名分组；别名不同、名字相近的都不自动归组。
    func duplicates(scope: CharacterScope) -> [CharacterDuplicateGroup] {
        Dictionary(grouping: scope.visible(entities), by: \.name)
            .filter { $0.value.count > 1 }
            .map { .init(name: $0.key, members: $0.value.sorted {
                $0.facts.count != $1.facts.count ? $0.facts.count > $1.facts.count
                    : ($0.facts.first?.chapter ?? 0) < ($1.facts.first?.chapter ?? 0)
            }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// 整卡删除：先把该人物全部事实记为已否决证据，再移除人物。
    /// 只删个人事实而不记指纹的话，换模型或重扫同版本正文会把整张卡重新生成出来。
    func removeEntity(_ id: String, scope: CharacterScope) throws {
        guard let index = archive.entities.firstIndex(where: { $0.id == id && $0.work == scope.work }) else { throw CharacterLexiconError.scope }
        var next = archive
        if next.rejected == nil { next.rejected = [] }
        for fact in next.entities[index].facts {
            let key = Self.evidenceKey(fact)
            if next.rejected?.contains(key) != true { next.rejected?.append(key) }
        }
        next.entities.removeAll { $0.id == id }
        try commit(next)
    }
    func confirm(fact: String, entity: String, scope: CharacterScope) throws {
        guard let i = archive.entities.firstIndex(where: { $0.id == entity && $0.work == scope.work }),
              let j = archive.entities[i].facts.firstIndex(where: { $0.id == fact && scope.permits($0) }) else { throw CharacterLexiconError.scope }
        var next = archive; next.entities[i].facts[j].needsReview = false; try commit(next)
    }
    /// 用户明确选择目标后追加已核验候选；一个事务保留原人物与各条事实的获知位置。
    func append(_ candidate: CharacterCandidate, to entity: String, scope: CharacterScope) throws {
        guard archive.orders[scope.work] == scope.volumes,
              let index = archive.entities.firstIndex(where: { $0.id == entity && $0.work == scope.work }),
              !scope.visible([archive.entities[index]]).isEmpty, !candidate.facts.isEmpty,
              candidate.facts.allSatisfy({ scope.permits($0) && Self.valid($0) }) else { throw CharacterLexiconError.scope }
        var next = archive
        let existing = Set(next.entities[index].facts.map { "\($0.book)|\($0.identity)|\($0.chapter)|\($0.offset)|\($0.name)|\($0.text)|\($0.quote)" })
        next.entities[index].facts += candidate.facts.filter {
            !existing.contains("\($0.book)|\($0.identity)|\($0.chapter)|\($0.offset)|\($0.name)|\($0.text)|\($0.quote)")
        }
        try commit(next)
    }
    func merge(_ source: String, into target: String, scope: CharacterScope) throws {
        guard source != target, let a = archive.entities.first(where: { $0.id == source && $0.work == scope.work }),
              let index = archive.entities.firstIndex(where: { $0.id == target && $0.work == scope.work }),
              scope.visible([a]).isEmpty == false, scope.visible([archive.entities[index]]).isEmpty == false else { throw CharacterLexiconError.scope }
        var next = archive
        if next.sync?.portraits[target]?.value == nil, let image = next.sync?.portraits[source]?.value {
            next.sync?.portraits[target] = .init(value: image, updatedAt: nextSyncDate())
        }
        var seen = Set(next.entities[index].facts.map { "\($0.book):\($0.identity):\($0.chapter):\($0.offset):\($0.name):\($0.text)" })
        next.entities[index].facts += a.facts.filter { seen.insert("\($0.book):\($0.identity):\($0.chapter):\($0.offset):\($0.name):\($0.text)").inserted }
        next.entities.removeAll { $0.id == source }; try commit(next)
    }
    func split(fact: String, from entity: String, scope: CharacterScope) throws {
        guard let index = archive.entities.firstIndex(where: { $0.id == entity && $0.work == scope.work }),
              let value = archive.entities[index].facts.first(where: { $0.id == fact && scope.permits($0) }) else { throw CharacterLexiconError.scope }
        var next = archive
        next.entities[index].facts.removeAll { $0.id == fact }
        next.entities.append(.init(id: UUID().uuidString, work: scope.work, facts: [value]))
        next.entities.removeAll { $0.facts.isEmpty }; try commit(next)
    }
    func edit(fact: String, entity: String, text: String, scope: CharacterScope) throws {
        guard let i = archive.entities.firstIndex(where: { $0.id == entity && $0.work == scope.work }),
              let j = archive.entities[i].facts.firstIndex(where: { $0.id == fact && scope.permits($0) }) else { throw CharacterLexiconError.scope }
        var next = archive
        next.entities[i].facts[j].text = text.trimmingCharacters(in: .whitespacesAndNewlines); next.entities[i].facts[j].manual = true
        guard Self.valid(next.entities[i].facts[j]) else { throw CharacterLexiconError.evidence }
        try commit(next)
    }
    func remove(fact: String, entity: String, scope: CharacterScope) throws {
        guard let index = archive.entities.firstIndex(where: { $0.id == entity && $0.work == scope.work }),
              archive.entities[index].facts.contains(where: { $0.id == fact && scope.permits($0) }) else { throw CharacterLexiconError.scope }
        var next = archive
        if let value = next.entities[index].facts.first(where: { $0.id == fact }) {
            let key = Self.evidenceKey(value)
            if next.rejected == nil { next.rejected = [] }
            if next.rejected?.contains(key) != true { next.rejected?.append(key) }
        }
        next.entities[index].facts.removeAll { $0.id == fact }; next.entities.removeAll { $0.facts.isEmpty }; try commit(next)
    }
}

struct CharacterScanCheckpoint: Codable, Equatable {
    let signature: String
    let nextChapter: Int
}

/// 单人补细节：扫描阶段每人只建一条档，打开卡片后按需对这个名字再跑一次。
/// 只处理指定的少量章节，产出仍走同一套逐条核验，再追加到现有卡片。
@MainActor
enum CharacterDetailUpdater {    static func enrich(name: String, entityID: String, book: String, identity: String, chapters: [RecapChapter],
                       scope: CharacterScope, store: CharacterLexiconStore, ai: ReadingAIStore,
                       maximumRequests: Int = 6, beforeRequest: () throws -> Void = {}, progress: (String) -> Void = { _ in }) async throws -> Int {
        guard ai.isReadyForGeneration else { throw ai.configuration.isEnabled ? ReadingAIError.missingKey : ReadingAIError.disabled }
        guard scope.identities[book] == identity else { throw CharacterLexiconError.changed }
        let configuration = ai.configuration
        var requests = 0, added = 0
        for chapter in chapters {
            try Task.checkCancellation()
            let plan = try CharacterExtractionPlan(scope: scope, book: book, identity: identity, chapters: [chapter])
            for chunk in plan.chunks {
                try Task.checkCancellation()
                guard requests < maximumRequests else { return added }
                guard ai.configuration == configuration else { throw CancellationError() }
                progress("正在补充「\(name)」 · 第\(chapter.index + 1)章")
                let request = try plan.detailRequest(chunk, name: name, outputTokens: configuration.maximumOutputTokens)
                try beforeRequest(); requests += 1
                let output: String
                do { output = try await ai.generate(request).text }
                catch is CancellationError { throw CancellationError() }
                catch { continue }   // 单块失败不影响其他章节，用户可再点一次
                guard let candidates = try? plan.validate(output, chunk: chunk) else { continue }
                for candidate in candidates where candidate.name == name {
                    let fresh = candidate.facts.filter { CharacterLexiconStore.valid($0) }
                    guard !fresh.isEmpty else { continue }
                    try store.append(.init(id: candidate.id, facts: fresh), to: entityID, scope: scope)
                    added += fresh.count
                }
            }
        }
        return added
    }
}

/// 单章完成才落盘；失败/取消保留前面完整章节的检查点，不持久化本章半成品。
@MainActor
enum CharacterAutomaticUpdater {
    static func signature(identity: String, scope: CharacterScope, configuration: ReadingAIConfiguration) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let model = String(decoding: try encoder.encode(configuration), as: UTF8.self)
        return FileContentHash.sha256(Data(("automatic-v2|" + CharacterExtractionPlan.promptVersion + "|" + identity + "|" + scope.volumes.joined(separator: "|") + "|" + model).utf8))
    }
    /// 一次提取的产物：签名随结果一起返回，落盘阶段不再读配置，便于并发提取后按章序提交。
    struct Extraction: Sendable {
        let signature: String
        let candidates: [CharacterCandidate]
        /// 该章此前已完成，本次没有真正请求。
        let skipped: Bool
    }
    /// 只做提取，不写档案：并发时多章可以同时跑，落盘仍按章序串行。
    static func extract(plan: CharacterExtractionPlan, store: CharacterLexiconStore, ai: ReadingAIStore,
                        beforeRequest: () throws -> Void = {}, progress: (Int, Int) -> Void) async throws -> Extraction {
        let configuration = ai.configuration
        guard plan.chapterCount == 1, store.order(work: plan.scope.work) == plan.scope.volumes else { throw CharacterLexiconError.scope }
        guard configuration.isEnabled else { throw ReadingAIError.disabled }
        let signature = try signature(identity: plan.identity, scope: plan.scope, configuration: configuration)
        if let chapter = plan.chunks.first?.chapter,
           chapter < store.scannedThrough(work: plan.scope.work, book: plan.book, signature: signature) {
            return .init(signature: signature, candidates: [], skipped: true)
        }
        let visible = plan.scope.visible(store.entities)
        let seed = visible.map { CharacterCandidate(id: $0.id, facts: $0.facts.filter { $0.needsReview != true }) }.filter { !$0.facts.isEmpty }
        let result = try await CharacterGenerator.generate(plan: plan, ai: ai, cache: store.extractionCache, seed: seed,
            beforeRequest: beforeRequest, progress: progress)
        try Task.checkCancellation()
        guard ai.configuration == configuration else { throw CancellationError() }
        return .init(signature: signature, candidates: result, skipped: false)
    }
    /// 按章序落盘；成功一章才推进一章的检查点。
    static func apply(_ extraction: Extraction, plan: CharacterExtractionPlan, store: CharacterLexiconStore) throws {
        try store.applyAutomatic(extraction.candidates, plan: plan, signature: extraction.signature)
    }
    /// 单章提取并立即落盘；顺序扫描与单元测试使用这个入口。
    static func update(plan: CharacterExtractionPlan, store: CharacterLexiconStore, ai: ReadingAIStore,
                       beforeRequest: () throws -> Void = {}, progress: (Int, Int) -> Void) async throws {
        let extraction = try await extract(plan: plan, store: store, ai: ai, beforeRequest: beforeRequest, progress: progress)
        try apply(extraction, plan: plan, store: store)
    }
}
