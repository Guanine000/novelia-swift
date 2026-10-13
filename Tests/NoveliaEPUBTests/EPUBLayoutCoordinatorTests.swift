import OSLog
import UIKit
import XCTest
import YueduCoreText
import NoveliaIOSCore
@testable import NoveliaEPUB

/// Same book + chapter + layout parameters lay out once; cancelled requests stop the work.
@MainActor
final class EPUBLayoutCoordinatorTests: XCTestCase {
    private static let paragraph = "　　月光透过窗棂洒在书桌上，她轻轻合上那本旧书，指尖还残留着纸页的温度。「明天，」她低声说，「我们再去一次那座桥吧。」"

    /// Generated chapters long enough to span many pages.
    private func source(chapters: Int = 3, paragraphs: Int = 120) -> TextChapterSource {
        let contents = (0..<chapters).map { index in
            TextChapterContent(title: "第\(index + 1)章", subtitle: nil,
                               paragraphs: Array(repeating: TextChapterParagraph(text: Self.paragraph), count: paragraphs))
        }
        return TextChapterSource(bookTitle: "测试", units: TextChapterSource.units(splitting: contents, maximumUTF16: 1_000_000),
                                 layoutIdentity: "txt|test")
    }

    private func context(_ reason: EPUBLayoutReason = .first, trace: String = DiagnosticContext.newTraceID()) -> EPUBLayoutContext {
        EPUBLayoutContext(bookID: "txt|test", trace: trace, reason: reason, totalSpine: 3, currentSpine: 0)
    }

    private var config: BrowserLayoutConfig { EPUBLayoutTests.readerConfig(workarounds: true) }

    func testConcurrentRequestsForSameKeyLayOutOnce() async throws {
        let coordinator = EPUBLayoutCoordinator()
        let container = source()
        let first = EPUBPageBook(generation: 1, coordinator: coordinator)
        let second = EPUBPageBook(generation: 2, coordinator: coordinator)
        async let a: Void = first.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956, context: context())
        async let b: Void = second.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956, context: context())
        _ = try await (a, b)
        XCTAssertEqual(coordinator.statistics.executed, 1, "\(coordinator.statistics)")
        XCTAssertEqual(coordinator.statistics.joins, 1)
        XCTAssertGreaterThan(first.pageCount(spineIndex: 0), 3)
        XCTAssertEqual(first.pageCount(spineIndex: 0), second.pageCount(spineIndex: 0))
        XCTAssertTrue(second.isChapterComplete(0))
    }

    /// Reopening the book (a new page book) reuses the completed layout from the LRU.
    func testCompletedLayoutIsReusedByNextOpen() async throws {
        let coordinator = EPUBLayoutCoordinator()
        let container = source()
        let opened = EPUBPageBook(generation: 1, coordinator: coordinator)
        try await opened.layoutChapter(1, container: container, config: config, aspectRatio: 440 / 956, context: context())
        let reopened = EPUBPageBook(generation: 2, coordinator: coordinator)
        try await reopened.layoutChapter(1, container: source(), config: config, aspectRatio: 440 / 956, context: context())
        XCTAssertEqual(coordinator.statistics.executed, 1)
        XCTAssertEqual(coordinator.statistics.memoryHits, 1)
        XCTAssertEqual(reopened.displayLists(spineIndex: 1).count, opened.displayLists(spineIndex: 1).count)
        // A repeated request on the same book is answered by the book itself.
        try await reopened.layoutChapter(1, container: container, config: config, aspectRatio: 440 / 956, context: context())
        XCTAssertEqual(coordinator.statistics.memoryHits, 1)
    }

    func testDifferentParametersOrBooksLayOutSeparately() async throws {
        let coordinator = EPUBLayoutCoordinator()
        let container = source()
        var larger = config
        larger.rootFontSize = 26
        var dark = config
        dark.textColor = .white
        for (index, variant) in [config, larger, dark].enumerated() {
            let book = EPUBPageBook(generation: index, coordinator: coordinator)
            try await book.layoutChapter(0, container: container, config: variant, aspectRatio: 440 / 956, context: context())
        }
        let otherBook = EPUBPageBook(generation: 9, coordinator: coordinator)
        var otherContext = context()
        otherContext.bookID = "txt|other"
        try await otherBook.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956, context: otherContext)
        // Without a book identity nothing is cached across page books.
        for generation in 10...11 {
            let book = EPUBPageBook(generation: generation, coordinator: coordinator)
            try await book.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956)
        }
        XCTAssertEqual(coordinator.statistics.executed, 6)
        XCTAssertEqual(coordinator.statistics.memoryHits, 0)
    }

    /// The only waiter cancels mid-chapter: the shared layout stops, and the page book keeps no partial pages.
    func testCancellingOnlyRequestCancelsLayout() async throws {
        let coordinator = EPUBLayoutCoordinator()
        let book = EPUBPageBook(generation: 1, coordinator: coordinator)
        var task: Task<Void, Error>?
        book.onPagesChanged = { if book.pageCount(spineIndex: 0) >= 1 { task?.cancel() } }
        let container = source(chapters: 1, paragraphs: 400)
        task = Task { try await book.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956, context: context()) }
        do {
            try await task!.value
            XCTFail("cancelled layout must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        for _ in 0..<20 where coordinator.runningJobCount > 0 { await Task.yield() }
        XCTAssertEqual(coordinator.statistics.cancelled, 1)
        XCTAssertEqual(coordinator.statistics.completed, 0, "the layout must stop, not run to the end")
        XCTAssertEqual(coordinator.runningJobCount, 0)
        XCTAssertEqual(coordinator.cachedLayoutCount, 0)
        XCTAssertFalse(book.hasChapter(0))
    }

    /// One of two waiters leaves (e.g. an old generation); the other still gets the full layout.
    func testCancellingOneWaiterKeepsSharedLayout() async throws {
        let coordinator = EPUBLayoutCoordinator()
        let container = source(chapters: 1, paragraphs: 300)
        let stale = EPUBPageBook(generation: 1, coordinator: coordinator)
        let current = EPUBPageBook(generation: 2, coordinator: coordinator)
        var staleTask: Task<Void, Error>?
        stale.onPagesChanged = { if stale.pageCount(spineIndex: 0) >= 1 { staleTask?.cancel() } }
        staleTask = Task { try await stale.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956, context: context()) }
        await Task.yield()
        try await current.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956, context: context())
        let staleResult = await staleTask!.result
        XCTAssertThrowsError(try staleResult.get())
        XCTAssertEqual(coordinator.statistics.executed, 1)
        XCTAssertEqual(coordinator.statistics.cancelled, 0)
        XCTAssertTrue(current.isChapterComplete(0))
        XCTAssertGreaterThan(current.pageCount(spineIndex: 0), 5)
    }

    /// A prefetch requested while the current chapter is laid out starts only after it.
    func testPrefetchWaitsForCurrentChapter() async throws {
        let coordinator = EPUBLayoutCoordinator()
        let container = source(chapters: 2, paragraphs: 200)
        let currentBook = EPUBPageBook(generation: 1, coordinator: coordinator)
        let prefetchBook = EPUBPageBook(generation: 1, coordinator: coordinator)
        var events: [Int] = []
        currentBook.onPagesChanged = { events.append(0) }
        prefetchBook.onPagesChanged = { events.append(1) }
        let config = config
        let current = Task { try await currentBook.layoutChapter(0, container: container, config: config, aspectRatio: 440 / 956, context: self.context(.first)) }
        while coordinator.runningJobCount == 0 { await Task.yield() }
        let prefetch = Task { try await prefetchBook.layoutChapter(1, container: container, config: config, aspectRatio: 440 / 956, context: self.context(.prefetch)) }
        try await current.value
        try await prefetch.value
        let firstPrefetch = try XCTUnwrap(events.firstIndex(of: 1))
        XCTAssertFalse(events[firstPrefetch...].contains(0), "prefetch pages appeared before the current chapter finished: \(events)")
    }

    /// Layout lines carry book, trace, generation, reason and cache outcome, and pass the export allowlist.
    func testLayoutLogsExplainEachRequest() async throws {
        let coordinator = EPUBLayoutCoordinator()
        let container = source()
        let trace = DiagnosticContext.newTraceID()
        let since = Date()
        for generation in 1...3 {
            let book = EPUBPageBook(generation: generation, coordinator: coordinator)
            try await book.layoutChapter(2, container: container, config: config, aspectRatio: 440 / 956,
                                         context: context(generation == 1 ? .first : .restore, trace: trace))
        }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let lines = try store.getEntries(at: store.position(date: since))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == ShareableLogPolicy.subsystem && $0.category == "epub" && $0.composedMessage.contains("trace=\(trace)") }
            .map(\.composedMessage)
        XCTAssertEqual(lines.filter { $0.hasPrefix("EPUB chapter laid out;") }.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("EPUB chapter layout reused;") && $0.contains("level=memory") }.count, 2)
        for line in lines {
            XCTAssertTrue(line.contains("spine=2, totalSpine=3"), line)
            XCTAssertEqual(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "epub", text: line), line)
        }
        print("EPUBLOG\n" + lines.joined(separator: "\n"))
    }
}
