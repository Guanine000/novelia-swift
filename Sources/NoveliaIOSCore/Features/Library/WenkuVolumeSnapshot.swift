import Foundation

/// 只比较稳定分卷ID，不把章节数、译文覆盖率或目录排序变化视为新卷。
struct WenkuVolumeSnapshot: Codable, Equatable, Sendable {
    enum Catalog: String, Codable, Sendable { case original, translated }
    let catalog: Catalog
    let volumeIDs: Set<String>
    let checkedAt: Date

    static func make(from detail: WenkuNovelDetail, now: Date = Date()) -> Self? {
        let originals = Set(detail.volumeJp.map(\.volumeId).filter { !$0.isEmpty })
        if !originals.isEmpty { return .init(catalog: .original, volumeIDs: originals, checkedAt: now) }
        let translated = Set(detail.volumeZh.filter { !$0.isEmpty })
        guard !translated.isEmpty else { return nil }
        return .init(catalog: .translated, volumeIDs: translated, checkedAt: now)
    }
    func newVolumeIDs(since previous: Self?) -> Set<String> {
        guard let previous, previous.catalog == catalog else { return [] }
        return volumeIDs.subtracting(previous.volumeIDs)
    }
}

struct WenkuVolumeCheckReport {
    enum Status: Equatable { case initial, compared, catalogChanged, unavailable }
    let status: Status
    let snapshot: WenkuVolumeSnapshot?
    let previousCheck: Date?
    let newVolumeIDs: Set<String>
}

/// App书库状态持有的本机检查历史；账号和作品共同决定基准身份。
struct WenkuVolumeHistory: Codable {
    private var snapshots: [String: WenkuVolumeSnapshot] = [:]
    mutating func record(_ detail: WenkuNovelDetail, account: String, now: Date = Date()) -> WenkuVolumeCheckReport {
        let identity = (try? JSONEncoder().encode([account, detail.id])) ?? Data()
        let key = FileContentHash.sha256(identity)
        let previous = snapshots[key]
        guard let current = WenkuVolumeSnapshot.make(from: detail, now: now) else {
            return .init(status: .unavailable, snapshot: nil, previousCheck: previous?.checkedAt, newVolumeIDs: [])
        }
        let status: WenkuVolumeCheckReport.Status = previous == nil ? .initial : (previous?.catalog == current.catalog ? .compared : .catalogChanged)
        snapshots[key] = current
        return .init(status: status, snapshot: current, previousCheck: previous?.checkedAt, newVolumeIDs: current.newVolumeIDs(since: previous))
    }
}
