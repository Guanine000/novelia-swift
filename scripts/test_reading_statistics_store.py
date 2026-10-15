#!/usr/bin/env python3
"""Exercise the production statistics store with isolated preferences; no user data or network."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/NoveliaIOSCore/Features/Statistics/ReadingStatisticsStore.swift').read_text()
contracts = (root/'Sources/NoveliaIOSCore/Domain/LocalServiceContracts.swift').read_text()
contracts = contracts[contracts.index('@MainActor\nprotocol ReadingTimeRecording'):]
store = contracts + source[source.index('@MainActor\nfinal class ReadingStatisticsStore'):]
harness = r'''
import Foundation
import Combine
import Security
'''+store+r'''
final class MemoryDeviceIDs: ReadingDeviceIDStoring {
    var id: String?
    var accepts = true
    init(_ id: String? = nil) { self.id = id }
    func load() -> String? { id }
    func save(_ id: String) -> Bool { if accepts { self.id = id }; return accepts }
}

@main
@MainActor
struct StatisticsStoreCheck {
    static func main() throws {
        var suites: [String] = []
        defer { for suite in suites { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) } }
        func prefs() -> UserDefaults {
            let suite = "StatisticsStoreCheck.\(UUID())"
            suites.append(suite)
            return UserDefaults(suiteName: suite)!
        }
        func snapshot(_ seconds: Double, id: String = "book") -> ReadingStatistics {
            var value = ReadingStatistics()
            let date = Date(timeIntervalSince1970: 1_000_000)
            value.record(book: ReadingBook(id: id, title: "Book", kind: .txt),
                         from: date, to: date.addingTimeInterval(seconds), duration: seconds)
            return value
        }
        let fresh = prefs(), freshIDs = MemoryDeviceIDs(), first = ReadingStatisticsStore(defaults: fresh, deviceIDs: freshIDs)
        precondition(!first.isRecordingEnabled && !first.hasEnabledRecording)
        let session = UUID(), book = ReadingBook(id: "book", title: "Book", kind: .txt)
        first.begin(id: session, book: book)
        first.end(id: session)
        precondition(first.statistics.books.isEmpty, "disabled recording must never create records")
        precondition(first.setRecordingEnabled(true, webDAVEnabled: true, statisticsSyncEnabled: false))
        precondition(first.hasEnabledRecording)
        _ = first.setRecordingEnabled(false, webDAVEnabled: true, statisticsSyncEnabled: false)
        precondition(!first.setRecordingEnabled(true, webDAVEnabled: true, statisticsSyncEnabled: false), "offer appears once")
        first.begin(id: session, book: book)
        first.isRecordingEnabled = false
        let frozen = first.statistics
        first.checkpoint(id: session)
        first.end(id: session)
        precondition(first.statistics == frozen, "switching off must stop the active session")
        let reload = ReadingStatisticsStore(defaults: fresh, deviceIDs: freshIDs)
        precondition(!reload.isRecordingEnabled && reload.hasEnabledRecording)
        precondition(reload.statistics == frozen)

        let withoutWebDAV = ReadingStatisticsStore(defaults: prefs(), deviceIDs: MemoryDeviceIDs())
        precondition(!withoutWebDAV.setRecordingEnabled(true, webDAVEnabled: false, statisticsSyncEnabled: false))
        _ = withoutWebDAV.setRecordingEnabled(false, webDAVEnabled: true, statisticsSyncEnabled: false)
        precondition(!withoutWebDAV.setRecordingEnabled(true, webDAVEnabled: true, statisticsSyncEnabled: false))
        let alreadySyncing = ReadingStatisticsStore(defaults: prefs(), deviceIDs: MemoryDeviceIDs())
        precondition(!alreadySyncing.setRecordingEnabled(true, webDAVEnabled: true, statisticsSyncEnabled: true))

        let legacy = prefs(), legacyIDs = MemoryDeviceIDs()
        legacy.set("device-a", forKey: "reading.statistics.deviceID")
        legacy.set(try JSONEncoder().encode(snapshot(30)), forKey: "reading.statistics.v1")
        let migrated = ReadingStatisticsStore(defaults: legacy, deviceIDs: legacyIDs)
        precondition(!migrated.isRecordingEnabled)
        precondition(migrated.statistics.seconds() == 30)
        let remote = ReadingStatisticsSync(devices: ["device-b": snapshot(40)])
        migrated.applySynced(remote)
        precondition(migrated.statistics.seconds() == 70)
        migrated.applySynced(remote)
        precondition(migrated.statistics.seconds() == 70, "repeated downloads must not add again")
        let upload = migrated.syncSnapshot()
        precondition(upload.devices["device-a"]!.seconds() == 30, "never upload a combined total as local time")
        precondition(upload.devices["device-b"]!.seconds() == 40)
        let restored = ReadingStatisticsStore(defaults: legacy, deviceIDs: legacyIDs)
        precondition(restored.statistics.seconds() == 70)
        precondition(restored.syncSnapshot().devices["device-a"]!.seconds() == 30)
        let named = ReadingStatisticsStore(defaults: legacy, deviceModel: "iPad", deviceIDs: legacyIDs)
        precondition(named.devices.count == 2 && named.devices[0].isCurrent && named.devices[0].name == "iPad")
        named.renameDevice("  书房 iPad  ")
        precondition(named.deviceInfo.name == "书房 iPad")
        precondition(named.syncSnapshot().deviceInfo?["device-a"]?.name == "书房 iPad")
        named.renameDevice("")
        precondition(named.deviceInfo.name == "iPad", "blank name falls back to the model")
        var renamedRemote = ReadingStatisticsSync(devices: ["device-b": snapshot(40)],
                                                  deviceInfo: ["device-b": ReadingDeviceInfo(name: "手机", model: "iPhone", updatedAt: Date())])
        named.applySynced(renamedRemote)
        precondition(named.devices.contains { $0.id == "device-b" && $0.name == "手机" && !$0.isCurrent })
        precondition(named.statistics.seconds() == 70, "renaming does not change totals")
        renamedRemote.deviceInfo = ["device-a": ReadingDeviceInfo(name: "别人", model: "iPhone", updatedAt: .distantFuture)]
        named.applySynced(renamedRemote)
        precondition(named.deviceInfo.name == "iPad" && named.devices[0].name == "iPad", "remote records never rename this device")
        precondition(ReadingStatisticsStore(defaults: legacy, deviceModel: "iPad", deviceIDs: legacyIDs).devices.contains { $0.name == "手机" })

        precondition(legacyIDs.id == "device-a", "upgrading keeps the existing device ID and binds it to the keychain")

        // 备份恢复到新设备：偏好被复制，Keychain 没有带过去。
        let cloned = prefs()
        for (key, value) in legacy.dictionaryRepresentation() where key.hasPrefix("reading.statistics") { cloned.set(value, forKey: key) }
        let newDevice = ReadingStatisticsStore(defaults: cloned, deviceModel: "iPhone", deviceIDs: MemoryDeviceIDs())
        precondition(newDevice.syncDeviceID != "device-a", "a restored backup gets its own device ID")
        precondition(newDevice.deviceInfo.name == "iPhone", "the copied device name stays with the original device")
        let clonedUpload = newDevice.syncSnapshot()
        precondition((clonedUpload.devices[newDevice.syncDeviceID]?.seconds() ?? 0) == 0, "copied local time is not claimed")
        precondition(clonedUpload.devices["device-a"]!.seconds() == 30 && clonedUpload.deviceInfo?["device-a"]?.name == "iPad")
        precondition(newDevice.statistics.seconds() == 70, "totals are unchanged after reassigning the copy")
        let relaunch = ReadingStatisticsStore(defaults: cloned, deviceModel: "iPhone", deviceIDs: MemoryDeviceIDs(newDevice.syncDeviceID))
        precondition(relaunch.syncDeviceID == newDevice.syncDeviceID && relaunch.statistics.seconds() == 70, "the new ID is stable")

        // 已有 Keychain ID 的设备恢复了别的设备的偏好。
        let restoredOver = prefs()
        for (key, value) in legacy.dictionaryRepresentation() where key.hasPrefix("reading.statistics") { restoredOver.set(value, forKey: key) }
        let existing = ReadingStatisticsStore(defaults: restoredOver, deviceIDs: MemoryDeviceIDs("device-c"))
        precondition(existing.syncDeviceID == "device-c" && existing.syncSnapshot().devices["device-a"]!.seconds() == 30)

        // Keychain 写入失败：不标记绑定，下次启动仍沿用同一 ID。
        let failing = MemoryDeviceIDs(); failing.accepts = false
        let unbound = prefs()
        let unboundID = ReadingStatisticsStore(defaults: unbound, deviceIDs: failing).syncDeviceID
        precondition(ReadingStatisticsStore(defaults: unbound, deviceIDs: failing).syncDeviceID == unboundID)
        print("Statistics store: default off, first-enable offer, pause, legacy migration, sync idempotence, persistence, device names and backup-restored device IDs passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='novelia-statistics-store-') as folder:
    folder = Path(folder)
    fixture = folder / 'StoreCheck.swift'
    fixture.write_text(harness)
    binary = folder / 'store-check'
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'ModuleCache'),
                    str(root / 'Sources/NoveliaIOSCore/Domain/ReadingActivity.swift'), str(root / 'Sources/NoveliaIOSCore/Features/Statistics/ReadingStatistics.swift'), str(fixture), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
