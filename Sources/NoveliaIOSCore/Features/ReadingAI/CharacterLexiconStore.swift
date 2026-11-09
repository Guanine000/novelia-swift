// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// ReaderSettings 持有的本机人物资料；稳定作品 ID 使用用户明确选择的系列 ID，不按名称归并。
/// 卷序、人物 UUID 与逐事实出处分离；候选只在确认收录后落盘，不自动合并同名人物。
@MainActor
final class CharacterLexiconStore: ObservableObject {
    private struct Archive: Codable {
        var version = 1
        var orders: [String: [String]] = [:]
        var entities: [CharacterEntity] = []
    }
    @Published private(set) var entities: [CharacterEntity] = []
    private var archive = Archive()
    private let defaults: UserDefaults
    private static let key = "reader.characters.archive.v1"
    private var damaged = false
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            if data.count <= 4 * 1_024 * 1_024, let value = try? JSONDecoder().decode(Archive.self, from: data), value.version == 1 {
                archive = value; entities = value.entities
            } else { damaged = true }
        }
    }
    func order(work: String) -> [String] { archive.orders[work] ?? [] }
    private func commit(_ value: Archive) throws {
        guard !damaged else { throw CharacterLexiconError.damaged }
        guard value.entities.count <= 2_000, value.entities.reduce(0, { $0 + $1.facts.count }) <= 20_000,
              let data = try? JSONEncoder().encode(value), data.count <= 4 * 1_024 * 1_024 else { throw CharacterLexiconError.storage }
        defaults.set(data, forKey: Self.key); archive = value; entities = value.entities
    }
    func confirmOrder(work: String, volumes: [String]) throws {
        guard !volumes.isEmpty, Set(volumes).count == volumes.count else { throw CharacterLexiconError.scope }
        var next = archive; next.orders[work] = volumes; try commit(next)
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
    static func valid(_ fact: CharacterFact) -> Bool {
        fact.chapter >= 0 && fact.offset >= 0 && !fact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fact.name.utf16.count <= 100
            && !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fact.text.utf16.count <= 300
            && (10...300).contains(fact.quote.utf16.count) && fact.quote.range(of: fact.name, options: .literal) != nil
    }
    func merge(_ source: String, into target: String, scope: CharacterScope) throws {
        guard source != target, let a = archive.entities.first(where: { $0.id == source && $0.work == scope.work }),
              let index = archive.entities.firstIndex(where: { $0.id == target && $0.work == scope.work }),
              scope.visible([a]).isEmpty == false, scope.visible([archive.entities[index]]).isEmpty == false else { throw CharacterLexiconError.scope }
        var next = archive
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
        var next = archive; next.entities[index].facts.removeAll { $0.id == fact }; next.entities.removeAll { $0.facts.isEmpty }; try commit(next)
    }
}
