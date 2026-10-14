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
'''+store+r'''
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
        let fresh = prefs(), first = ReadingStatisticsStore(defaults: fresh)
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
        let reload = ReadingStatisticsStore(defaults: fresh)
        precondition(!reload.isRecordingEnabled && reload.hasEnabledRecording)
        precondition(reload.statistics == frozen)

        let withoutWebDAV = ReadingStatisticsStore(defaults: prefs())
        precondition(!withoutWebDAV.setRecordingEnabled(true, webDAVEnabled: false, statisticsSyncEnabled: false))
        _ = withoutWebDAV.setRecordingEnabled(false, webDAVEnabled: true, statisticsSyncEnabled: false)
        precondition(!withoutWebDAV.setRecordingEnabled(true, webDAVEnabled: true, statisticsSyncEnabled: false))
        let alreadySyncing = ReadingStatisticsStore(defaults: prefs())
        precondition(!alreadySyncing.setRecordingEnabled(true, webDAVEnabled: true, statisticsSyncEnabled: true))

        let legacy = prefs()
        legacy.set("device-a", forKey: "reading.statistics.deviceID")
        legacy.set(try JSONEncoder().encode(snapshot(30)), forKey: "reading.statistics.v1")
        let migrated = ReadingStatisticsStore(defaults: legacy)
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
        let restored = ReadingStatisticsStore(defaults: legacy)
        precondition(restored.statistics.seconds() == 70)
        precondition(restored.syncSnapshot().devices["device-a"]!.seconds() == 30)
        print("Statistics store: default off, first-enable offer, pause, legacy migration, sync idempotence and persistence passed")
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
