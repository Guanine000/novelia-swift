// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

/// 阅读器和书库读写进度的边界；App 注入同一实例，读取本地进度不依赖 WebDAV。
@MainActor
protocol ReadingPositionProviding: AnyObject {
    func all() -> [String: SyncedReadingPosition]
    func recordWeb(id: String, chapterIndex: Int)
    func recordEPUB(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?)
    func epubPosition(hash: String) -> SyncedReadingPosition?
    func recordTXT(hash: String, position: TXTReadingPosition)
    func txtPosition(hash: String) -> TXTReadingPosition?
}

/// 供同步适配合并进度；具体存储负责旧数据和时间合并规则，阅读器无需调用此能力。
@MainActor
protocol ReadingPositionSynchronizing: ReadingPositionProviding {
    func merge(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel])
}

/// 同步仅访问书库系列快照和应用入口，不读取具体书库 Store 的内部状态。
@MainActor
protocol LibrarySeriesManaging: AnyObject {
    var series: LibrarySeriesState { get }
    func applySynced(_ state: LibrarySeriesState)
}

/// 阅读计时事件与开关；由 App 连接记录实现，阅读 UI 不依赖具体统计 Store。
/// 开关变化在主执行域发布，关闭后应结束活动计时，避免后台或重复会话累计。
@MainActor
protocol ReadingTimeRecording: AnyObject {
    var isRecordingEnabled: Bool { get }
    var recordingEnabledChanges: AnyPublisher<Bool, Never> { get }
    func begin(id: UUID, book: ReadingBook)
    func checkpoint(id: UUID)
    func end(id: UUID)
}

/// 统计同步边界；快照与合并由统计实现负责，同步层不操作内部计时器或偏好键。
@MainActor
protocol ReadingStatisticsSyncing: AnyObject {
    /// 本机在远端的设备 ID，对应 `statistics/<ID>.json`；只写这一个文件。
    var syncDeviceID: String { get }
    func syncSnapshot() -> ReadingStatisticsSync
    func applySynced(_ snapshot: ReadingStatisticsSync)
}
