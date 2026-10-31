// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

/// 网络小说身份与文件对应表。只由网络小说入口启用，文库继续使用文件哈希。
struct WebNovelEPUBContext: Equatable {
    let bookKey: String
    let fileHash: String
    let chapterIDs: [String: String]
    let legacyHashes: Set<String>

    static func key(provider: String, novel: String) -> String {
        "webepub:" + FileContentHash.sha256(Data("\(provider.utf8.count):\(provider)\(novel)".utf8))
    }
    func chapterID(index: Int, paths: [String]) -> String? {
        paths.indices.contains(index) ? chapterIDs[paths[index]] : nil
    }
    func index(chapterID: String, paths: [String]) -> Int? {
        let matches = paths.indices.filter { chapterIDs[paths[$0]] == chapterID }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct WebNovelEPUBBinding: Codable, Equatable, Sendable {
    let chapterID: String
    let updatedAt: Date
    var deleted: Bool? = nil
}
struct WebNovelEPUBMap: Codable, Equatable, Sendable {
    var version = 1
    let bookKey: String
    let fileHash: String
    var bindings: [String: WebNovelEPUBBinding]
    var key: String { bookKey + ":" + fileHash }
    var isValid: Bool {
        version == 1 && bookKey.hasPrefix("webepub:") && bookKey.count == 72
            && WebDAVAsset.isValidHash(fileHash) && bindings.count <= 100_000
            && bindings.allSatisfy { !$0.key.isEmpty && $0.key.count <= 4096 && !$0.value.chapterID.isEmpty
                && $0.value.chapterID.count <= 1000 && $0.value.updatedAt.timeIntervalSince1970.isFinite }
    }
    var chapterIDs: [String: String] {
        let active = bindings.filter { $0.value.deleted != true }
        let counts = Dictionary(grouping: active.values, by: \.chapterID).mapValues(\.count)
        return active.filter { counts[$0.value.chapterID] == 1 }.mapValues(\.chapterID)
    }
    static func merged(_ local: [String: Self], _ remote: [String: Self]) -> [String: Self] {
        var result = local.filter { $0.key == $0.value.key && $0.value.isValid }
        for (key, map) in remote where key == map.key && map.isValid {
            var next = result[key] ?? map
            for (path, binding) in map.bindings where binding.updatedAt > (next.bindings[path]?.updatedAt ?? .distantPast) {
                next.bindings[path] = binding
            }
            result[key] = next
        }
        return result
    }
}

/// ReaderSettings 所有的映射；按文件哈希保存，支持离线打开和多设备补全。原 EPUB 不改写。
@MainActor
final class WebNovelEPUBMapStore: ObservableObject {
    @Published private(set) var maps: [String: WebNovelEPUBMap]
    private let defaults: UserDefaults
    private let storageKey = "reader.webEPUBMaps.v1"
    init(defaults: UserDefaults) {
        self.defaults = defaults
        maps = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: WebNovelEPUBMap].self, from: $0) } ?? [:]
        maps = maps.filter { $0.key == $0.value.key && $0.value.isValid }
    }
    func merge(_ remote: [String: WebNovelEPUBMap]) throws {
        let next = WebNovelEPUBMap.merged(maps, remote)
        guard next != maps else { return }
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: storageKey)
        maps = next
    }
    func context(bookKey: String, hash: String) -> WebNovelEPUBContext {
        WebNovelEPUBContext(bookKey: bookKey, fileHash: hash,
            chapterIDs: maps[bookKey + ":" + hash]?.chapterIDs ?? [:],
            legacyHashes: Set(maps.values.filter { $0.bookKey == bookKey }.map(\.fileHash)).union([hash]))
    }
}

/// 只迁移被核验过的章节，保留旧哈希记录与原时间。派生 UUID 使多次迁移及107/108副本归并可重试。
@MainActor
enum WebNovelEPUBMigration {
    static func migrate(context: WebNovelEPUBContext, paths: [String], settings: ReaderSettings) throws {
        let oldKey = "epub:\(context.fileHash)"
        let records = settings.bookmarks.records
        var incoming: [String: ReaderBookmark] = [:]
        for old in records.values where old.bookKey == oldKey {
            guard let chapter = context.chapterID(index: old.chapterIndex, paths: paths) else { continue }
            // 107/108 曾按旧UUID与新哈希派生副本；只在能证明关系时回溯原始UUID。
            var root = old.id
            var visited: Set<UUID> = []
            while visited.insert(root).inserted,
                  let ancestor = records.values.first(where: { candidate in
                      guard candidate.id != root, candidate.bookKey.hasPrefix("epub:") else { return false }
                      return context.legacyHashes.contains { hash in
                          derived(candidate.id, key: "epub:\(hash)") == root
                      }
                  }) { root = ancestor.id }
            let id = derived(root, key: context.bookKey)
            let copy = ReaderBookmark(id: id, bookKey: context.bookKey, chapterIndex: old.chapterIndex,
                chapterProgression: old.chapterProgression, chapterTitle: old.chapterTitle, snippet: old.snippet,
                createdAt: old.createdAt, updatedAt: old.updatedAt, deleted: old.deleted, chapterID: chapter)
            incoming = ReaderBookmark.merged(incoming, [id.uuidString: copy])
        }
        try settings.bookmarks.applyMigration(incoming)
        if var saved = settings.positions.epubPosition(hash: context.fileHash), let index = saved.chapterIndex,
           let chapter = context.chapterID(index: index, paths: paths) {
            saved.chapterID = chapter; saved.chapterOffset = nil; saved.fraction = nil
            saved.chapterProgression = saved.chapterProgression ?? 0
            settings.positions.mergePosition(key: context.bookKey, position: saved, replacingEqualTimestamp: true)
        }
    }
    static func derived(_ id: UUID, key: String) -> UUID {
        let seed = FileContentHash.sha256(Data("\(id.uuidString)|\(key)".utf8))
        return UUID(uuidString: "\(seed.prefix(8))-\(seed.dropFirst(8).prefix(4))-\(seed.dropFirst(12).prefix(4))-\(seed.dropFirst(16).prefix(4))-\(seed.dropFirst(20).prefix(12))")!
    }
}

extension ReaderSettings {
    func epubPosition(hash: String, context: WebNovelEPUBContext?, paths: [String]) -> SyncedReadingPosition? {
        guard let context, var saved = positions.all()[context.bookKey], let chapter = saved.chapterID else {
            return epubPosition(hash: hash)
        }
        guard let index = context.index(chapterID: chapter, paths: paths) else { return nil }
        saved.chapterIndex = index; saved.chapterOffset = nil; saved.fraction = nil
        return saved
    }
    func recordEPUBPosition(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?,
                            context: WebNovelEPUBContext?, paths: [String]) {
        recordEPUBPosition(hash: hash, fraction: fraction, spineIndex: spineIndex, chapterOffset: chapterOffset, chapterProgression: chapterProgression)
        guard let context, let chapter = context.chapterID(index: spineIndex, paths: paths) else { return }
        positions.mergePosition(key: context.bookKey, position: SyncedReadingPosition(chapterIndex: spineIndex, fraction: nil,
            updatedAt: Date(), chapterProgression: chapterProgression ?? 0, chapterID: chapter))
    }
    func missingWebEPUBChapter(context: WebNovelEPUBContext?, paths: [String]) -> Bool {
        guard let context, let chapter = positions.all()[context.bookKey]?.chapterID else { return false }
        return context.index(chapterID: chapter, paths: paths) == nil
    }
}

/// ID状态使用独立清单，108及更旧客户端无法过滤掉它。每次条件提交前重读，并保留远端已存在的小说状态。
@MainActor
enum WebNovelEPUBIdentitySync {
    static func run(remote: any WebDAVRemote, local: any WebDAVSyncLocalState) async throws {
        try await remote.verifyConnection()
        try await remote.prepareFolders()
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (old, etag, exists) = try await remote.fetchManifest()
            guard old.version == 1 else { throw WebDAVSyncError.unsupportedManifest }
            var next = old
            next.positions = SyncedReadingPosition.merged(
                local.readingPositions.filter { valid($0.key, $0.value) }, old.positions.filter { valid($0.key, $0.value) })
            next.bookmarks = ReaderBookmark.merged(local.bookmarks, old.bookmarks ?? [:])
                .filter { $0.key == $0.value.id.uuidString && $0.value.isValid && $0.value.bookKey.hasPrefix("webepub:") }
            next.webEPUBMaps = WebNovelEPUBMap.merged(local.webEPUBMaps, old.webEPUBMaps ?? [:])
            do {
                try await remote.putManifest(next, etag: etag, existed: exists)
            } catch WebDAVSyncError.concurrentChange where attempt < 2 { continue }
            try local.applyWebEPUBMaps(next.webEPUBMaps ?? [:])
            try local.applyBookmarks(next.bookmarks ?? [:])
            local.mergeReadingPositions(next.positions, webBooks: [])
            return
        }
        throw WebDAVSyncError.concurrentChange
    }
    private static func valid(_ key: String, _ position: SyncedReadingPosition) -> Bool {
        key.hasPrefix("webepub:") && WebDAVAsset.isValidHash(String(key.dropFirst(8))) && position.chapterID?.isEmpty == false
            && (position.chapterID?.count ?? 0) <= 1000 && position.updatedAt.timeIntervalSince1970.isFinite
            && position.chapterProgression.map { $0.isFinite && (0...1).contains($0) } == true
    }
}

/// 目录对应只使用标题、卷名及唯一有序对应；不读取网站正文，也不按文件序号套网站ID。
/// 两端锚点发生交叉时停用顺序推断；删章/插章导致多种对应时保留歧义。
enum WebNovelEPUBTOCMatcher {
    struct Entry: Equatable, Sendable {
        let path: String
        let title: String
        let volume: String?
        init(path: String, title: String, volume: String? = nil) {
            self.path = path; self.title = title; self.volume = volume
        }
    }
    private static func normalized(_ title: String) -> String { title.filter { !$0.isWhitespace && !$0.isNewline } }

    /// 一次准备标题倒排表，避免长篇目录按章节两两比较。无效/重复源站ID不参与自动对应。
    private struct Directory {
        let rows: [Entry]
        let options: [Set<String>]
        let remote: [NovelChapter]
        let indices: [String: Int]
        init(local: [Entry], remote: [NovelChapter], saved: [NovelChapter]) {
            self.remote = remote
            let groupedRemote = Dictionary(grouping: remote.indices, by: { remote[$0].id })
            let remoteIndices = groupedRemote.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { !$0.key.isEmpty }
            indices = remoteIndices
            var titleIDs: [String: Set<String>] = [:], volumes: [String: Set<String>] = [:]
            for chapter in remote + saved where !chapter.id.isEmpty {
                for title in [chapter.title, chapter.originalTitle].compactMap({ $0 }) {
                    let value = normalized(title)
                    if !value.isEmpty { titleIDs[value, default: []].insert(chapter.id) }
                }
                for volume in [chapter.volumeTitle, chapter.originalVolumeTitle].compactMap({ $0 }) {
                    let value = normalized(volume)
                    if !value.isEmpty { volumes[chapter.id, default: []].insert(value) }
                }
            }
            let grouped = Dictionary(grouping: local, by: \.path)
            var seen: Set<String> = []
            let preparedRows = local.filter { seen.insert($0.path).inserted }
            rows = preparedRows
            options = preparedRows.map { row in
                let entries = grouped[row.path] ?? []
                guard Set(entries.map { normalized($0.title) }).count == 1,
                      Set(entries.compactMap { $0.volume.map(normalized) }).count <= 1 else { return [] }
                let ids = titleIDs[normalized(row.title)] ?? []
                // 旧标题被另一ID复用或目录ID重复，不能通过去除旧ID把冲突伪装成唯一对应。
                guard ids.count <= 512, ids.allSatisfy({ remoteIndices[$0] != nil }) else { return [] }
                return Set(ids.filter { id in
                    guard let volume = row.volume.map(normalized), !volume.isEmpty,
                          let candidates = volumes[id], !candidates.isEmpty else { return true }
                    return candidates.contains(volume)
                })
            }
        }
        func anchors(_ mapping: [String: String]) -> [(Int, Int)]? {
            let counts = Dictionary(grouping: mapping.values, by: { $0 }).mapValues(\.count)
            let result = rows.indices.compactMap { i -> (Int, Int)? in
                guard let id = mapping[rows[i].path], counts[id] == 1, let j = indices[id] else { return nil }
                return (i, j)
            }
            guard zip(result, result.dropFirst()).allSatisfy({ $0.0.1 < $0.1.1 }) else { return nil }
            return [(-1, -1)] + result + [(rows.count, remote.count)]
        }
    }
    static func match(local: [Entry], remote: [NovelChapter], saved: [NovelChapter], existing: [String: String]) -> [String: String] {
        let directory = Directory(local: local, remote: remote, saved: saved)
        let used = Set(existing.values)
        let options = directory.options.map { $0.subtracting(used) }
        let counts = options.reduce(into: [String: Int]()) { result, ids in
            for id in ids { result[id, default: 0] += 1 }
        }
        var proposed: [String: String] = [:]
        for i in directory.rows.indices where existing[directory.rows[i].path] == nil {
            if options[i].count == 1, let id = options[i].first, counts[id] == 1 { proposed[directory.rows[i].path] = id }
        }
        let known = existing.merging(proposed) { old, _ in old }
        guard let anchors = directory.anchors(known) else { return proposed }
        // 每一段分别求最早和最晚可行的有序子序列。二者相同的项在所有可行对应中都唯一。
        // 全段无法对应时不跳过本机未知/已删除章猜配；候选重复时保留多种可能。
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            let range = (left.0 + 1)..<right.0
            guard !range.isEmpty else { continue }
            var earliest: [Int: Int] = [:], latest: [Int: Int] = [:]
            var cursor = left.1 + 1
            for i in range {
                while cursor < right.1 && !options[i].contains(remote[cursor].id) { cursor += 1 }
                guard cursor < right.1 else { break }
                earliest[i] = cursor; cursor += 1
            }
            guard earliest.count == range.count else { continue }
            cursor = right.1 - 1
            for i in range.reversed() {
                while cursor > left.1 && !options[i].contains(remote[cursor].id) { cursor -= 1 }
                guard cursor > left.1 else { break }
                latest[i] = cursor; cursor -= 1
            }
            for i in range where earliest[i] == latest[i] {
                guard let j = earliest[i], known[directory.rows[i].path] == nil else { continue }
                proposed[directory.rows[i].path] = remote[j].id
            }
        }
        return proposed
    }
    /// 手动候选保留原目录顺序；仅在锚点顺序一致时收窄区间，未知标题由完整目录兜底。
    static func candidates(path: String, local: [Entry], remote: [NovelChapter], saved: [NovelChapter], existing: [String: String]) -> [String] {
        let directory = Directory(local: local, remote: remote, saved: saved)
        guard let i = directory.rows.firstIndex(where: { $0.path == path }) else { return [] }
        var lower = -1, upper = remote.count
        if let anchors = directory.anchors(existing) {
            lower = anchors.last(where: { $0.0 < i })?.1 ?? -1
            upper = anchors.first(where: { $0.0 > i })?.1 ?? remote.count
        }
        let used = Set(existing.filter { $0.key != path }.values)
        return remote.indices.filter { $0 > lower && $0 < upper && directory.options[i].contains(remote[$0].id) && !used.contains(remote[$0].id) }.map { remote[$0].id }
    }
}

/// 已下载文件之间的纯本地继承。两边所有正文资源都参与唯一性检查，未确认的旧资源也不能忽略。
/// 不覆盖目标文件的确认/删除记录，保留来源时间；不推断新增或修订正文的章节ID。
enum WebNovelEPUBFileMatcher {
    struct Resource {
        let path: String
        let signature: String?
        init(path: String, heading: String, body: String) {
            self.path = path
            let normalize: (String) -> String = { $0.filter { !$0.isWhitespace && !$0.isNewline } }
            let text = normalize(body), title = normalize(heading)
            signature = text.isEmpty || text.contains("该章节缺失。") || text.contains("翻译缺失。") ? nil :
                FileContentHash.sha256(Data("\(title.utf8.count):\(title)\(text)".utf8))
        }
    }
    static func inherit(old: [Resource], new: [Resource], source: WebNovelEPUBMap, target: WebNovelEPUBMap) -> WebNovelEPUBMap {
        guard source.bookKey == target.bookKey, source.fileHash != target.fileHash else { return target }
        var result = target
        let previous = Dictionary(grouping: old.filter { $0.signature != nil }, by: { $0.signature! })
        let updated = Dictionary(grouping: new.filter { $0.signature != nil }, by: { $0.signature! })
        let oldPaths = Dictionary(grouping: old, by: \.path), newPaths = Dictionary(grouping: new, by: \.path)
        let ids = source.chapterIDs
        var used = Set(target.bindings.values.map(\.chapterID))
        for (signature, entries) in updated where entries.count == 1 {
            let path = entries[0].path
            guard newPaths[path]?.count == 1, target.bindings[path] == nil,
                  let originals = previous[signature], originals.count == 1, oldPaths[originals[0].path]?.count == 1,
                  let id = ids[originals[0].path], !used.contains(id), let binding = source.bindings[originals[0].path] else { continue }
            result.bindings[path] = binding
            used.insert(id)
        }
        return result
    }
}
