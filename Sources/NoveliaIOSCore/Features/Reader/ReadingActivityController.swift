// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// The reading UI observes recording state without depending on a statistics store.
@MainActor
final class ReadingActivityController: ObservableObject {
    @Published private(set) var isRecordingEnabled: Bool
    private let recorder: any ReadingTimeRecording
    private var subscription: AnyCancellable?

    init(recorder: any ReadingTimeRecording) {
        self.recorder = recorder
        isRecordingEnabled = recorder.isRecordingEnabled
        // Recording providers publish on the main actor, as required by their interface.
        subscription = recorder.recordingEnabledChanges.sink { [weak self] enabled in
            self?.isRecordingEnabled = enabled
        }
    }

    func begin(id: UUID, book: ReadingBook) { recorder.begin(id: id, book: book) }
    func checkpoint(id: UUID) { recorder.checkpoint(id: id) }
    func end(id: UUID) { recorder.end(id: id) }
}

/// Composition can disable the statistics integration without changing a reader.
@MainActor
final class DisabledReadingTimeRecorder: ReadingTimeRecording {
    var isRecordingEnabled: Bool { false }
    var recordingEnabledChanges: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    func begin(id: UUID, book: ReadingBook) {}
    func checkpoint(id: UUID) {}
    func end(id: UUID) {}
}
