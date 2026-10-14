// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// LocalAppServices 持有的统计存储，实现计时事件和同步快照接口；界面观察同一实例。
/// 保留统计偏好键、设备身份及既有合并规则，关闭记录时结束计时但不删除历史。
@MainActor
final class ReadingStatisticsStore: ObservableObject, ReadingTimeRecording, ReadingStatisticsSyncing {
    private static let key = "reading.statistics.v1"
    private static let syncKey = "reading.statistics.devices.v1"
    private static let deviceKey = "reading.statistics.deviceID"
    private static let enabledKey = "reading.statistics.enabled"
    private static let everEnabledKey = "reading.statistics.everEnabled"
    private static let deviceInfoKey = "reading.statistics.deviceInfo"
    @Published private(set) var statistics: ReadingStatistics
    /// 按设备拆分的统计，本机排在最前；同步后包含其他设备。
    @Published private(set) var devices: [ReadingDeviceStatistics] = []
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
    /// 本机名称与类型；名称可由用户修改，随统计同步给其他设备显示。
    private(set) var deviceInfo: ReadingDeviceInfo
    private var synced: ReadingStatisticsSync
    private var savedLocal: ReadingStatistics
    private var tracker: ReadingTimeTracker

    /// `deviceModel` 由 App 组装传入系统设备类型（iPhone、iPad），本类型不依赖 UIKit。
    init(defaults: UserDefaults = .standard, deviceModel: String = "设备") {
        self.defaults = defaults
        let id = defaults.string(forKey: Self.deviceKey) ?? UUID().uuidString
        deviceID = id
        defaults.set(id, forKey: Self.deviceKey)
        var info = defaults.data(forKey: Self.deviceInfoKey)
            .flatMap { try? JSONDecoder().decode(ReadingDeviceInfo.self, from: $0) }
            ?? ReadingDeviceInfo(name: deviceModel, model: deviceModel, updatedAt: .distantPast)
        if info.model != deviceModel {
            // 名称从未修改过（仍是旧类型）时跟随新类型。
            if info.name == info.model { info.name = deviceModel }
            info.model = deviceModel
            info.updatedAt = Date()
        }
        deviceInfo = info
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
        saveDeviceInfo()
        devices = deviceList(cache.devices)
    }

    var syncDeviceID: String { deviceID }

    /// 修改本机显示名称；空白恢复为设备类型，超长截断。下次同步时其他设备可见。
    func renameDevice(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? deviceInfo.model : String(trimmed.prefix(ReadingDeviceInfo.maxNameLength))
        guard value != deviceInfo.name else { return }
        deviceInfo.name = value
        deviceInfo.updatedAt = Date()
        saveDeviceInfo()
        devices = deviceList(currentSnapshots)
    }

    private func saveDeviceInfo() {
        if let data = try? JSONEncoder().encode(deviceInfo) { defaults.set(data, forKey: Self.deviceInfoKey) }
    }

    private var currentSnapshots: [String: ReadingStatistics] {
        var snapshots = synced.devices
        snapshots[deviceID] = tracker.statistics
        return snapshots
    }

    private func deviceList(_ snapshots: [String: ReadingStatistics]) -> [ReadingDeviceStatistics] {
        snapshots.map { id, statistics in
            let info = id == deviceID ? deviceInfo : synced.deviceInfo?[id]
            return ReadingDeviceStatistics(id: id, name: info?.name ?? "未命名设备（\(id.prefix(4))）",
                                           model: info?.model, isCurrent: id == deviceID, statistics: statistics)
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.statistics.seconds() != $1.statistics.seconds() { return $0.statistics.seconds() > $1.statistics.seconds() }
            return $0.id < $1.id
        }
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
        snapshot.deviceInfo = (snapshot.deviceInfo ?? [:]).merging([deviceID: deviceInfo]) { $1 }
        return snapshot
    }

    func applySynced(_ snapshot: ReadingStatisticsSync) {
        synced = .merged(snapshot, syncSnapshot())
        tracker.mergeBaseline(synced.devices[deviceID] ?? ReadingStatistics())
        // 本机名称只由本机修改，远端带回的本机记录不覆盖。
        synced.deviceInfo?[deviceID] = deviceInfo
        if let data = try? JSONEncoder().encode(synced) { defaults.set(data, forKey: Self.syncKey) }
        persist()
        // 其他设备可能只改了名称，总时长不变时 persist 不会刷新列表。
        devices = deviceList(currentSnapshots)
    }

    private func persist() {
        let local = tracker.statistics
        if savedLocal != local {
            if let data = try? JSONEncoder().encode(local) { defaults.set(data, forKey: Self.key) }
            savedLocal = local
        }
        let snapshots = currentSnapshots
        let combined = ReadingStatistics.combined(snapshots)
        if statistics != combined {
            statistics = combined
            devices = deviceList(snapshots)
        }
    }
}

/// 统计页按设备展示的一行。
struct ReadingDeviceStatistics: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let model: String?
    let isCurrent: Bool
    let statistics: ReadingStatistics
}

