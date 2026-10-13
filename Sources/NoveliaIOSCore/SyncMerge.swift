import Combine
import Foundation

// Records shared through manual WebDAV sync and the rules that merge local and remote copies.

struct SyncedReadingPosition: Codable, Equatable {
    /// Web novels: chapter index. EPUBs: spine index (absent before offsets were stored).
    /// TXT (`txt:<hash>`): chapter index under the reader's chapter rules.
    var chapterIndex: Int?
    /// EPUBs: progress through the whole book, kept for older app versions.
    var fraction: Double?
    var updatedAt: Date
    /// EPUBs: UTF-16 offset of the page's first text in the chapter source, which
    /// survives re-pagination after font or layout changes.
    var chapterOffset: Int? = nil
    /// TXT only: paged unit and unit count; `chapterOffset` is then the offset in that unit.
    /// Older app versions ignore both when decoding.
    var unit: Int? = nil
    var unitCount: Int? = nil

    /// A remote position replaces the local one when it is at least as recent.
    static func merged(_ local: [String: Self], _ remote: [String: Self]) -> [String: Self] {
        var result = local
        for (key, value) in remote where value.updatedAt >= (result[key]?.updatedAt ?? .distantPast) {
            result[key] = value
        }
        return result
    }
}

struct SyncedBlockedTag: Codable, Equatable {
    var blocked: Bool
    var updatedAt: Date
}

@MainActor
final class BlockedTagsStore: ObservableObject {
    static let shared = BlockedTagsStore()
    @Published private(set) var tags: [String]
    @Published private(set) var wenkuTags: [String: [String]]
    private let defaults: UserDefaults
    private(set) var syncStates: [String: SyncedBlockedTag]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        syncStates = defaults.data(forKey: "blockedNovelTags.sync.v1")
            .flatMap { try? JSONDecoder().decode([String: SyncedBlockedTag].self, from: $0) } ?? [:]
        for tag in defaults.stringArray(forKey: "blockedNovelTags") ?? [] where syncStates[tag] == nil {
            syncStates[tag] = SyncedBlockedTag(blocked: true, updatedAt: .distantPast)
        }
        tags = syncStates.filter { $0.value.blocked }.map(\.key).sorted()
        wenkuTags = defaults.dictionary(forKey: "knownWenkuTags") as? [String: [String]] ?? [:]
    }
    func contains(_ tag: String) -> Bool { tags.contains(tag.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func add(_ tag: String) {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !tags.contains(value) else { return }
        syncStates[value] = SyncedBlockedTag(blocked: true, updatedAt: Date()); persist()
    }
    func remove(_ tag: String) {
        syncStates[tag] = SyncedBlockedTag(blocked: false, updatedAt: Date()); persist()
    }
    static func merged(_ local: [String: SyncedBlockedTag], _ remote: [String: SyncedBlockedTag]) -> [String: SyncedBlockedTag] {
        var result = local
        for (tag, value) in remote where !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existing = result[tag] {
                if value.updatedAt > existing.updatedAt || (value.updatedAt == existing.updatedAt && !value.blocked) {
                    result[tag] = value
                }
            } else { result[tag] = value }
        }
        return result
    }
    func applySynced(_ remote: [String: SyncedBlockedTag]) {
        syncStates = Self.merged(syncStates, remote); persist()
    }
    private func persist() {
        tags = syncStates.filter { $0.value.blocked }.map(\.key).sorted()
        defaults.set(tags, forKey: "blockedNovelTags")
        if let data = try? JSONEncoder().encode(syncStates) { defaults.set(data, forKey: "blockedNovelTags.sync.v1") }
    }
    func hides(_ genres: [String]) -> Bool { genres.contains(where: contains) }
    func rememberWenku(id: String, tags: [String]) {
        guard wenkuTags[id] != tags else { return }
        wenkuTags[id] = tags; defaults.set(wenkuTags, forKey: "knownWenkuTags")
    }
}

struct SyncedReaderBackground: Codable {
    var mode: String
    var color: String
    var portraitHash: String?
    var landscapeHash: String?
    var updatedAt: Date
}

struct SyncedImportedFont: Codable {
    var hash: String
    var format: String
    var deleted: Bool
    var updatedAt: Date
    static func merged(_ local: [String: Self], _ remote: [String: Self]) -> [String: Self] {
        var result = remote
        for (hash, value) in local {
            if let other = result[hash], other.updatedAt > value.updatedAt || (other.updatedAt == value.updatedAt && other.deleted) { continue }
            result[hash] = value
        }
        return result
    }
}
