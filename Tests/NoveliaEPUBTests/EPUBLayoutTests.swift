import CoreText
import UIKit
import XCTest
import YueduCoreText
@testable import NoveliaEPUB

/// Whole-book layout checks for justified CJK text.
///
/// A "gap" is a CJK glyph whose advance, minus the kern the engine added, exceeds 1.3 em:
/// the half-character holes Core Text leaves when it squeezes punctuation on a partly
/// kerned line. A "width mismatch" is a line whose drawn width differs from its laid-out
/// width by more than 1 pt, i.e. text that would run past the margin.
final class EPUBLayoutTests: XCTestCase {
    struct Report: CustomStringConvertible {
        var pages = 0
        var lines = 0
        var gaps = 0
        var widthMismatches = 0
        var examples: [String] = []
        var description: String {
            "pages=\(pages) lines=\(lines) gaps=\(gaps) widthMismatches=\(widthMismatches)"
                + examples.map { "\n  \($0)" }.joined()
        }
    }

    /// The reader's default page on a 440 × 956 pt phone (see EPUBReaderStyle).
    @MainActor
    static func readerConfig(workarounds: Bool) -> BrowserLayoutConfig {
        let size = CGSize(width: 440, height: 956)
        let insets = UIEdgeInsets(top: 64, left: 20, bottom: 72, right: 20)
        var config = BrowserLayoutConfig()
        config.renderWidth = size.width - insets.left - insets.right
        config.renderHeight = size.height - insets.top - insets.bottom
        config.rootFontSize = 21
        config.contentInsets = insets
        config.defaultTextAlignment = .natural
        if workarounds { EPUBPageBook.applyEngineWorkarounds(to: &config) }
        return config
    }

    @MainActor
    static func scan(_ url: URL, workarounds: Bool = true) async throws -> Report {
        let container = try await EPUBContainer.open(fileURL: url)
        let config = readerConfig(workarounds: workarounds)
        let book = EPUBPageBook(generation: 1)
        var report = Report()
        for spine in container.spine.indices {
            try await book.layoutChapter(spine, container: container, config: config, aspectRatio: 440 / 956)
            let lists = book.displayLists(spineIndex: spine)
            report.pages += lists.count
            for list in lists {
                for item in list.items {
                    guard case .text(let text) = item, text.text.count > 1 else { continue }
                    report.lines += 1
                    let attributed = text.attributedText
                    let line = CTLineCreateWithAttributedString(attributed)
                    let drawn = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
                    let mismatch = abs(drawn - text.rect.rawValue.width) > 1
                    var gap = false
                    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                        let count = CTRunGetGlyphCount(run)
                        var advances = [CGSize](repeating: .zero, count: count)
                        var indices = [CFIndex](repeating: 0, count: count)
                        CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
                        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
                        for (advance, index) in zip(advances, indices) {
                            let kern = (attributed.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                            // Only CJK glyphs: dashes and ellipses are legitimately wider than 1.3 em.
                            let scalar = (attributed.string as NSString).character(at: index)
                            if scalar >= 0x3000, advance.width - CGFloat(kern) > text.font.pointSize * 1.3 { gap = true }
                        }
                    }
                    if gap { report.gaps += 1 }
                    if mismatch { report.widthMismatches += 1 }
                    if (gap || mismatch), report.examples.count < 5 {
                        report.examples.append("\(text.text) [drawn \(Int(drawn)) / laid out \(Int(text.rect.rawValue.width))]")
                    }
                }
            }
        }
        return report
    }

    func testJustifiedCJKHasNoGaps() async throws {
        let report = try await Self.scan(try EPUBMetadataTests.fixture("justified_cjk"))
        XCTAssertGreaterThan(report.lines, 50, "fixture should produce many justified lines")
        XCTAssertEqual(report.gaps, 0, report.description)
        XCTAssertEqual(report.widthMismatches, 0, report.description)
    }

    /// Guards the workaround: it fails once YueduCoreText no longer leaves gaps without it,
    /// which is the signal to remove `EPUBPageBook.applyEngineWorkarounds`.
    func testEngineStillNeedsWorkaround() async throws {
        let report = try await Self.scan(try EPUBMetadataTests.fixture("justified_cjk"), workarounds: false)
        XCTAssertGreaterThan(report.gaps, 0, "YueduCoreText justifies cleanly without the workaround; remove it. \(report)")
    }

    /// Reading positions are stored as a chapter offset; every page must map back to itself.
    @MainActor
    func testPageOffsetsRoundTrip() async throws {
        let container = try await EPUBContainer.open(fileURL: try EPUBMetadataTests.fixture("justified_cjk"))
        let book = EPUBPageBook(generation: 1)
        try await book.layoutChapter(0, container: container, config: Self.readerConfig(workarounds: true), aspectRatio: 440 / 956)
        let count = book.pageCount(spineIndex: 0)
        XCTAssertGreaterThan(count, 2)
        var previous = -1
        for page in 0..<count {
            let offset = try XCTUnwrap(book.sourceOffset(spineIndex: 0, pageIndex: page), "page \(page)")
            XCTAssertGreaterThan(offset, previous, "offsets increase")
            previous = offset
            XCTAssertEqual(book.pageIndex(spineIndex: 0, containingSourceOffset: offset), page)
            XCTAssertEqual(book.pageIndex(spineIndex: 0, containingSourceOffset: offset + 1), page)
        }
    }

    /// After a font size change the reader reopens on the page that draws the same text.
    @MainActor
    func testOffsetSurvivesRepagination() async throws {
        let container = try await EPUBContainer.open(fileURL: try EPUBMetadataTests.fixture("justified_cjk"))
        let original = EPUBPageBook(generation: 1)
        try await original.layoutChapter(0, container: container, config: Self.readerConfig(workarounds: true), aspectRatio: 440 / 956)
        var larger = Self.readerConfig(workarounds: true)
        larger.rootFontSize = 27
        let resized = EPUBPageBook(generation: 2)
        try await resized.layoutChapter(0, container: container, config: larger, aspectRatio: 440 / 956)
        XCTAssertGreaterThan(resized.pageCount(spineIndex: 0), original.pageCount(spineIndex: 0))
        for page in 0..<original.pageCount(spineIndex: 0) {
            let offset = try XCTUnwrap(original.sourceOffset(spineIndex: 0, pageIndex: page))
            let target = try XCTUnwrap(resized.pageIndex(spineIndex: 0, containingSourceOffset: offset))
            let drawn = resized.displayLists(spineIndex: 0)[target].items.contains { item in
                guard case .text(let text) = item else { return false }
                return NSLocationInRange(offset, text.sourceRange)
            }
            XCTAssertTrue(drawn, "page \(page) text not on resized page \(target)")
        }
    }

    /// `scripts/scan_epub_layout.sh <book.epub>` runs this against any local EPUB.
    func testScanExternalBook() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCAN_EPUB"], !path.isEmpty else {
            throw XCTSkip("Set SCAN_EPUB (via scripts/scan_epub_layout.sh) to scan a local book.")
        }
        let url = URL(fileURLWithPath: path)
        let current = try await Self.scan(url)
        let without = try await Self.scan(url, workarounds: false)
        for (label, report) in [("with workaround", current), ("without workaround", without)] {
            print("SCAN_RESULT \(label): pages=\(report.pages) lines=\(report.lines) gaps=\(report.gaps) widthMismatches=\(report.widthMismatches)")
            for example in report.examples { print("SCAN_EXAMPLE   \(example)") }
        }
    }
}
