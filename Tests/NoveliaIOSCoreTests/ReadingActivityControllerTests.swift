import Combine
import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
private final class RecordingSpy: ReadingTimeRecording {
    @Published var isRecordingEnabled = false
    var recordingEnabledChanges: AnyPublisher<Bool, Never> { $isRecordingEnabled.eraseToAnyPublisher() }
    var events: [String] = []
    func begin(id: UUID, book: ReadingBook) { events.append("begin:\(book.id)") }
    func checkpoint(id: UUID) { events.append("checkpoint") }
    func end(id: UUID) { events.append("end") }
}

@MainActor
final class ReadingActivityControllerTests: XCTestCase {
    func testRecordingStateAndEventsUseInjectedProvider() {
        let spy = RecordingSpy()
        let controller = ReadingActivityController(recorder: spy)
        XCTAssertFalse(controller.isRecordingEnabled)
        spy.isRecordingEnabled = true
        XCTAssertTrue(controller.isRecordingEnabled)
        let session = UUID()
        controller.begin(id: session, book: ReadingBook(id: "book", title: "Book", kind: .txt))
        controller.checkpoint(id: session)
        controller.end(id: session)
        XCTAssertEqual(spy.events, ["begin:book", "checkpoint", "end"])
        spy.isRecordingEnabled = false
        XCTAssertFalse(controller.isRecordingEnabled)
    }

    func testReadingWorksWithDisabledStatisticsIntegration() {
        let controller = ReadingActivityController(recorder: DisabledReadingTimeRecorder())
        let session = UUID()
        controller.begin(id: session, book: ReadingBook(id: "book", title: "Book", kind: .online))
        controller.checkpoint(id: session)
        controller.end(id: session)
        XCTAssertFalse(controller.isRecordingEnabled)
    }

    func testIndependentProvidersDoNotShareRecordingState() {
        let first = RecordingSpy(), second = RecordingSpy()
        let left = ReadingActivityController(recorder: first)
        let right = ReadingActivityController(recorder: second)
        first.isRecordingEnabled = true
        XCTAssertTrue(left.isRecordingEnabled)
        XCTAssertFalse(right.isRecordingEnabled)
    }
}
