import XCTest
import YueduCoreText
@testable import NoveliaEPUB

/// The reader no longer installs the engine trace hook; these tests measure what that hook
/// produced and check the per-chapter summary that replaces it.
final class EPUBLayoutLogTests: XCTestCase {
    /// Before: one OSLog fault per trace event. After: one info line per chapter.
    @MainActor
    func testEngineTraceVolumeVersusChapterSummaries() async throws {
        for name in ["justified_cjk", "epub3_refines"] {
            let container = try await EPUBContainer.open(fileURL: EPUBMetadataTests.fixture(name))
            var traced = EPUBLayoutTests.readerConfig(workarounds: true)
            let tally = EPUBLayoutTraceTally()
            traced.onDiagnostic = { tally.record($0) }
            let tracedBook = EPUBPageBook(generation: 1)
            let plainBook = EPUBPageBook(generation: 2)
            let plain = EPUBLayoutTests.readerConfig(workarounds: true)
            XCTAssertNil(plain.onDiagnostic, "reader config must not install the trace hook")
            var tracedTime = Duration.zero, plainTime = Duration.zero
            for spine in container.spine.indices {
                let clock = ContinuousClock()
                tracedTime += try await clock.measure {
                    try await tracedBook.layoutChapter(spine, container: container, config: traced, aspectRatio: 440 / 956)
                }
                plainTime += try await clock.measure {
                    try await plainBook.layoutChapter(spine, container: container, config: plain, aspectRatio: 440 / 956)
                }
                XCTAssertEqual(tracedBook.pageCount(spineIndex: spine), plainBook.pageCount(spineIndex: spine),
                               "trace hook must not change pagination")
            }
            let events = tally.snapshot.values.reduce(0, +)
            print("LOGVOLUME \(name): chapters=\(container.spine.count) traceEvents(before)=\(events) chapterSummaries(after)=\(container.spine.count) traced=\(tracedTime) plain=\(plainTime) \(tally.summary(spineIndex: 0))")
            // The CJK fixture has real paragraphs: the trace emits hundreds of events per chapter.
            if name == "justified_cjk" { XCTAssertGreaterThan(events, 100) }
        }
    }

    func testTraceSummaryFormat() {
        let tally = EPUBLayoutTraceTally()
        for stage in [CSSFrontendDiagnostic.Stage.style, .style, .selector, .ingestion] {
            tally.record(CSSFrontendDiagnostic(stage: stage, stylesheet: nil, semanticPath: "body/p[1]", property: nil, message: "私人正文"))
        }
        XCTAssertEqual(tally.summary(spineIndex: 2),
                       "EPUB layout trace summary; spine=2, events=4, html=0, css=0, selector=1, style=2, ingestion=1, adapter=0, allocation=0")
    }

    func testFailureKindsAreFixedNames() {
        XCTAssertEqual(EPUBLayoutLog.failure(CancellationError()).kind, "cancelled")
        XCTAssertEqual(EPUBLayoutLog.failure(HTMLLayoutError.resourceFailure("OEBPS/私人.png")).kind, "resource")
        XCTAssertEqual(EPUBLayoutLog.failure(EPUBError.missingOPF).kind, "opf")
        let posix = EPUBLayoutLog.failure(NSError(domain: NSPOSIXErrorDomain, code: 2))
        XCTAssertEqual(posix.kind, "posix")
        XCTAssertEqual(posix.code, 2)
        XCTAssertEqual(EPUBLayoutLog.failure(NSError(domain: "/Users/name", code: 9)).kind, "other")
        XCTAssertFalse(EPUBLayoutLog.traceEnabled, "trace is opt-in via -EPUBEngineTrace")
    }
}
