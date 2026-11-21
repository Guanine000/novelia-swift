// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

/// LocalAppServices 持有的本地进度存储，阅读与同步通过同一实例访问。
/// 保留 readingPositions.v1、web/epub/txt 身份和旧位置读取；位置转换由阅读引擎负责。
/// 首次读取后在内存保留全部位置，翻页记录不再重复解码；写入仍立即落盘，异常退出不丢进度。
/// 缓存只对本实例有效，同一偏好存储不得再创建第二个实例写入进度。
@MainActor
final class ReadingPositionStore: ReadingPositionSynchronizing {
    private let changeSubject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }
    private let defaults: UserDefaults
    private var cache: [String: SyncedReadingPosition]?
    private var dirtyKeysCache: Set<String>?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private static let key = "readingPositions.v1"
    private static let dirtyKeysStorageKey = "readingPositions.dirtyKeys.v1"
    private static let syncedBaselineKey = "readingPositions.syncedBaseline.v1"

    var dirtyPositionKeys: Set<String> {
        if let dirtyKeysCache { return dirtyKeysCache }
        let loaded = Set(defaults.stringArray(forKey: Self.dirtyKeysStorageKey) ?? [])
        dirtyKeysCache = loaded
        return loaded
    }

    var hasSyncedPositionBaseline: Bool {
        defaults.bool(forKey: Self.syncedBaselineKey)
    }

    func markPositionsSynced(_ syncedTimestamps: [String: Date]) {
        var remaining = dirtyPositionKeys
        let current = all()
        for (key, syncedAt) in syncedTimestamps {
            // 若同步期间用户又翻页推进了 updatedAt，则保留该键待下次同步。
            if let latest = current[key], latest.updatedAt > syncedAt { continue }
            remaining.remove(key)
        }
        saveDirtyKeys(remaining)
        if !defaults.bool(forKey: Self.syncedBaselineKey) {
            defaults.set(true, forKey: Self.syncedBaselineKey)
        }
    }

    func resetSyncBaseline() {
        defaults.set(false, forKey: Self.syncedBaselineKey)
        saveDirtyKeys(Set(all().keys))
    }

    func all() -> [String: SyncedReadingPosition] {
        if let cache { return cache }
        let loaded = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: SyncedReadingPosition].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    func mergePosition(key: String, position: SyncedReadingPosition, replacingEqualTimestamp: Bool) {
        var next = all()
        guard position.updatedAt > (next[key]?.updatedAt ?? .distantPast) || (replacingEqualTimestamp && position.updatedAt == next[key]?.updatedAt) else { return }
        next[key] = position
        save(next, dirtyKeysToMark: [key])
    }

    func recordWeb(id: String, chapterIndex: Int) {
        let positionKey = "web:\(id)"
        var positions = all()
        positions[positionKey] = SyncedReadingPosition(chapterIndex: chapterIndex, fraction: nil, updatedAt: Date())
        save(positions, dirtyKeysToMark: [positionKey])
    }

    func recordEPUB(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?) {
        recordEPUB(hash: hash, fraction: fraction, spineIndex: spineIndex, chapterOffset: chapterOffset,
                   chapterProgression: chapterProgression, nativeChapterOffset: nil, nativeSourceHash: nil)
    }

    func recordEPUB(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?,
                    nativeChapterOffset: Int?, nativeSourceHash: String?) {
        let positionKey = "epub:\(hash)"
        var positions = all()
        positions[positionKey] = SyncedReadingPosition(chapterIndex: spineIndex,
            fraction: min(1, max(0, fraction)), updatedAt: Date(), chapterOffset: chapterOffset,
            nativeChapterOffset: nativeChapterOffset, nativeSourceHash: nativeSourceHash, chapterProgression: chapterProgression.map { min(1, max(0, $0)) })
        save(positions, dirtyKeysToMark: [positionKey])
    }

    func epubPosition(hash: String) -> SyncedReadingPosition? { all()["epub:\(hash)"] }

    /// 滚动和分页阅读器共用的 TXT 阅读位置，以书籍文件哈希同步。
    func recordTXT(hash: String, position: TXTReadingPosition) {
        let positionKey = "txt:\(hash)"
        var positions = all()
        positions[positionKey] = SyncedReadingPosition(chapterIndex: position.chapter, fraction: nil, updatedAt: Date(),
            chapterOffset: position.offset, unit: position.unit, unitCount: position.unitCount)
        save(positions, dirtyKeysToMark: [positionKey])
    }

    func txtPosition(hash: String) -> TXTReadingPosition? {
        if let synced = all()["txt:\(hash)"], let chapter = synced.chapterIndex {
            return TXTReadingPosition(chapter: chapter, unit: synced.unit, offset: synced.chapterOffset, unitCount: synced.unitCount)
        }
        // 0.12.0（52）测试构建将 TXT 阅读位置保存在仅本地使用的键中。
        return TXTReadingPosition.legacy(hash: hash, defaults: defaults)
    }

    @discardableResult
    func pruneFilePositions(keepingHashes: Set<String>, olderThan cutoff: Date) -> Int {
        let positions = all()
        var removedKeys: Set<String> = []
        let kept = positions.filter { key, position in
            guard let hash = Self.fileHash(fromKey: key) else { return true }
            let keep = keepingHashes.contains(hash) || position.updatedAt >= cutoff
            if !keep { removedKeys.insert(key) }
            return keep
        }
        save(kept)
        if !removedKeys.isEmpty {
            saveDirtyKeys(dirtyPositionKeys.subtracting(removedKeys))
        }
        return positions.count - kept.count
    }

    /// `epub:<哈希>` 与 `txt:<哈希>` 的文件哈希；其他身份返回 nil。
    private static func fileHash(fromKey key: String) -> String? {
        for prefix in ["epub:", "txt:"] where key.hasPrefix(prefix) { return String(key.dropFirst(prefix.count)) }
        return nil
    }

    func merge(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {
        var positions = all()
        let progress = ReadingProgressStore(defaults: defaults)
        var locallyBackfilled: Set<String> = []
        var changedWebBookIDs: Set<String> = []

        for book in webBooks {
            let key = "web:\(book.id)"
            if positions[key] == nil, let index = progress.chapterIndex(novelID: book.id) {
                positions[key] = SyncedReadingPosition(
                    chapterIndex: index, fraction: nil,
                    updatedAt: progress.updatedAt(novelID: book.id) ?? .distantPast)
                locallyBackfilled.insert(key)
            }
        }

        // 只逐键比较远端有值且发生实际变更的条目，避免每次同步无差别回写全部书目的进度。
        for (key, remotePosition) in remote {
            let localPosition = positions[key]
            if let localPosition {
                if localPosition == remotePosition { continue }
                let winner = SyncedReadingPosition.merged([key: localPosition], [key: remotePosition])[key]
                if let winner, winner != localPosition {
                    positions[key] = winner
                    if key.hasPrefix("web:") { changedWebBookIDs.insert(String(key.dropFirst(4))) }
                }
            } else {
                positions[key] = remotePosition
                if key.hasPrefix("web:") { changedWebBookIDs.insert(String(key.dropFirst(4))) }
            }
        }

        if !changedWebBookIDs.isEmpty {
            for book in webBooks where changedWebBookIDs.contains(book.id) {
                if let position = positions["web:\(book.id)"], let index = position.chapterIndex {
                    progress.save(chapterIndex: index, updatedAt: position.updatedAt, novelID: book.id)
                }
            }
        }
        save(positions, dirtyKeysToMark: locallyBackfilled)
    }

    private func save(_ positions: [String: SyncedReadingPosition], dirtyKeysToMark: Set<String> = []) {
        if !dirtyKeysToMark.isEmpty {
            saveDirtyKeys(dirtyPositionKeys.union(dirtyKeysToMark))
        }
        guard positions != cache else { return }
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: Self.key)
            cache = positions
            changeSubject.send()
        }
    }

    private func saveDirtyKeys(_ keys: Set<String>) {
        guard keys != dirtyKeysCache else { return }
        dirtyKeysCache = keys
        if keys.isEmpty {
            defaults.removeObject(forKey: Self.dirtyKeysStorageKey)
        } else {
            defaults.set(Array(keys).sorted(), forKey: Self.dirtyKeysStorageKey)
        }
    }
}
