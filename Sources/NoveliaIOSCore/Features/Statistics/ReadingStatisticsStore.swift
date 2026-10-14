// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

@MainActor
final class ReadingStatisticsStore: ObservableObject, ReadingTimeRecording, ReadingStatisticsSyncing {
    private static let key = "reading.statistics.v1"
    private static let syncKey = "reading.statistics.devices.v1"
    private static let deviceKey = "reading.statistics.deviceID"
    private static let enabledKey = "reading.statistics.enabled"
    private static let everEnabledKey = "reading.statistics.everEnabled"
    @Published private(set) var statistics: ReadingStatistics
    @Published var isRecordingEnabled: Bool {
        didSet {
            defaults.set(isRecordingEnabled, forKey: Self.enabledKey)
            if isRecordingEnabled { defaults.set(true, forKey: Self.everEnabledKey) }
            else {
                tracker.stop(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                persist()
            }
        }
    }
    var recordingEnabledChanges: AnyPublisher<Bool, Never> { $isRecordingEnabled.eraseToAnyPublisher() }
    var hasEnabledRecording: Bool { defaults.bool(forKey: Self.everEnabledKey) }
    private let defaults: UserDefaults
    private let deviceID: String
    private var synced: ReadingStatisticsSync
    private var savedLocal: ReadingStatistics
    private var tracker: ReadingTimeTracker

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let id = defaults.string(forKey: Self.deviceKey) ?? UUID().uuidString
        deviceID = id
        defaults.set(id, forKey: Self.deviceKey)
        let saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ReadingStatistics.self, from: $0) } ?? ReadingStatistics()
        var cache = defaults.data(forKey: Self.syncKey)
            .flatMap { try? JSONDecoder().decode(ReadingStatisticsSync.self, from: $0) } ?? ReadingStatisticsSync()
        let local = ReadingStatistics.mergedMaximum(saved, cache.devices[id] ?? ReadingStatistics())
        cache.devices[id] = local
        synced = cache
        savedLocal = saved
        statistics = cache.statistics
        tracker = ReadingTimeTracker(statistics: local)
        isRecordingEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// 返回是否需要在首次启用时提示开启统计同步；“暂不开启”之后不重复弹窗。
    func setRecordingEnabled(_ enabled: Bool, webDAVEnabled: Bool, statisticsSyncEnabled: Bool) -> Bool {
        let firstEnable = enabled && !hasEnabledRecording
        isRecordingEnabled = enabled
        return firstEnable && webDAVEnabled && !statisticsSyncEnabled
    }

    func begin(id: UUID, book: ReadingBook) {
        guard isRecordingEnabled else { return }
        tracker.begin(id: id, book: book, date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
    }

    func checkpoint(id: UUID) {
        tracker.checkpoint(id: id, date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
    }

    func end(id: UUID) {
        tracker.end(id: id, date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
    }

    func syncSnapshot() -> ReadingStatisticsSync {
        tracker.checkpointActive(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
        var snapshot = synced
        snapshot.devices[deviceID] = tracker.statistics
        return snapshot
    }

    func applySynced(_ snapshot: ReadingStatisticsSync) {
        synced = .merged(snapshot, syncSnapshot())
        tracker.mergeBaseline(synced.devices[deviceID] ?? ReadingStatistics())
        if let data = try? JSONEncoder().encode(synced) { defaults.set(data, forKey: Self.syncKey) }
        persist()
    }

    private func persist() {
        let local = tracker.statistics
        if savedLocal != local {
            if let data = try? JSONEncoder().encode(local) { defaults.set(data, forKey: Self.key) }
            savedLocal = local
        }
        var snapshots = synced.devices
        snapshots[deviceID] = local
        let combined = ReadingStatistics.combined(snapshots)
        if statistics != combined { statistics = combined }
    }
}

