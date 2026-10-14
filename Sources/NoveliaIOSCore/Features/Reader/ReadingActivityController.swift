// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// LocalAppServices 持有的计时事件桥接；只依赖 ReadingTimeRecording，供 UI 观察开关并发送事件。
/// 记录开关与会话累计由注入实现负责，阅读器不直接依赖统计存储。
@MainActor
final class ReadingActivityController: ObservableObject {
    @Published private(set) var isRecordingEnabled: Bool
    private let recorder: any ReadingTimeRecording
    private var subscription: AnyCancellable?

    init(recorder: any ReadingTimeRecording) {
        self.recorder = recorder
        isRecordingEnabled = recorder.isRecordingEnabled
        // 协议要求记录实现在主执行域发布开关，保持 UI 状态更新与事件处理顺序一致。
        subscription = recorder.recordingEnabledChanges.sink { [weak self] enabled in
            self?.isRecordingEnabled = enabled
        }
    }

    func begin(id: UUID, book: ReadingBook) { recorder.begin(id: id, book: book) }
    func checkpoint(id: UUID) { recorder.checkpoint(id: id) }
    func end(id: UUID) { recorder.end(id: id) }
}

/// App 组装可注入此实现关闭计时；保留相同事件接口，无需修改阅读器或清理历史统计。
@MainActor
final class DisabledReadingTimeRecorder: ReadingTimeRecording {
    var isRecordingEnabled: Bool { false }
    var recordingEnabledChanges: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    func begin(id: UUID, book: ReadingBook) {}
    func checkpoint(id: UUID) {}
    func end(id: UUID) {}
}
