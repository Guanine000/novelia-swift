// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

/// Reading owns persisted positions; readers and library can operate without WebDAV.
@MainActor
protocol ReadingPositionProviding: AnyObject {
    func all() -> [String: SyncedReadingPosition]
    func recordWeb(id: String, chapterIndex: Int)
    func recordEPUB(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?)
    func epubPosition(hash: String) -> SyncedReadingPosition?
    func recordTXT(hash: String, position: TXTReadingPosition)
    func txtPosition(hash: String) -> TXTReadingPosition?
}

@MainActor
protocol ReadingPositionSynchronizing: ReadingPositionProviding {
    func merge(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel])
}

@MainActor
protocol LibrarySeriesManaging: AnyObject {
    var series: LibrarySeriesState { get }
    func applySynced(_ state: LibrarySeriesState)
}

@MainActor
protocol ReadingTimeRecording: AnyObject {
    var isRecordingEnabled: Bool { get }
    var recordingEnabledChanges: AnyPublisher<Bool, Never> { get }
    func begin(id: UUID, book: ReadingBook)
    func checkpoint(id: UUID)
    func end(id: UUID)
}

@MainActor
protocol ReadingStatisticsSyncing: AnyObject {
    func syncSnapshot() -> ReadingStatisticsSync
    func applySynced(_ snapshot: ReadingStatisticsSync)
}
