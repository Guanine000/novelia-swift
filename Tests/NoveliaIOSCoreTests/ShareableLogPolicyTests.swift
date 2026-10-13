import XCTest
@testable import NoveliaIOSCore

final class ShareableLogPolicyTests: XCTestCase {
    func testReviewedDiagnosticsKeepUsefulNumbers() {
        let text = "TXT chapters parsed; lines=400, chapters=12, elapsedMs=3"
        XCTAssertEqual(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "txt", text: text), text)
        let error = "Novel EPUB request failed before receiving an HTTP response; domain=NSURLErrorDomain, code=-1009, elapsedMs=45"
        XCTAssertEqual(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "novel-download", text: error), error)
    }

    func testSystemAndUnreviewedMessagesAreExcluded() {
        for category in ["txt", "unknown", "lifecycle"] {
            for secret in ["B6713B51-406C-49F6-B152-CAF6527A3322", "/private/var/mobile/Containers/Data/Application/id/book.epub", "https://host.test/path?token=secret", "Authorization: Bearer secret", "person@example.test", "我的书名与正文"] {
                XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: secret))
            }
        }
        XCTAssertNil(ShareableLogPolicy.message(subsystem: "com.apple.network", category: "txt", text: "TXT decode succeeded; bytes=123, elapsedMs=2"))
    }

    func testKnownPrefixesNeverCopyFreeText() {
        let secret = "UUID=B6713B51-406C-49F6-B152-CAF6527A3322 token=secret /Users/name/book.epub"
        for (category, prefix) in [("enginediag", "ENGINE_DIAG "), ("epubcontainer", "TOC nav entries="), ("novel-download", "Starting novel EPUB download;")] {
            let output = ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: prefix + secret)
            XCTAssertNotNil(output)
            XCTAssertFalse(output?.contains(secret) ?? true)
        }
    }

    func testSuffixNewlineAndForgedFieldsCannotPass() {
        let valid = "TXT decode succeeded; bytes=123, elapsedMs=2"
        for suffix in ["\n", "\nAuthorization: Bearer secret", " UUID=secret", "\u{2028}secret"] {
            XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "txt", text: valid + suffix))
        }
        XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "novel-download", text: "Novel EPUB request failed before receiving an HTTP response; domain=person@example.test, code=-1, elapsedMs=2"))
    }
}

final class EPUBLogExportTests: XCTestCase {
    private func export(_ category: String, _ text: String) -> String? {
        ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: text)
    }

    func testEPUBSummariesKeepCountsCodesAndTimings() {
        let lines: [(String, String)] = [
            ("epub", "EPUB import started"),
            ("epub", "EPUB import completed; bytes=5120394, elapsedMs=233"),
            ("epub", "EPUB import failed; stage=registration, domain=app, code=0, elapsedMs=12"),
            ("epub", "EPUB import failed; stage=copy, domain=NSCocoaErrorDomain, code=260, elapsedMs=3"),
            ("epub", "EPUB open started"),
            ("epub", "EPUB open succeeded; spine=48, toc=45, pages=12, elapsedMs=812"),
            ("epub", "EPUB open failed; stage=container, error=opf, code=0, elapsedMs=40"),
            ("epub", "EPUB open cancelled; elapsedMs=95"),
            ("epub", "EPUB chapter laid out; spine=3, pages=27, elapsedMs=311"),
            ("epub", "EPUB chapter layout failed; spine=7, error=resource, code=0, elapsedMs=20"),
            ("epub", "EPUB chapter layout failed; spine=7, error=posix, code=-2, elapsedMs=20"),
            ("epub", "EPUB chapter layout cancelled; spine=4, elapsedMs=8"),
            ("epubcontainer", "TOC nav mapped; entries=45, mapped=44"),
            ("enginediag", "EPUB layout trace summary; spine=2, events=3073, html=0, css=0, selector=812, style=2253, ingestion=8, adapter=0, allocation=0"),
        ]
        for (category, text) in lines {
            XCTAssertEqual(export(category, text), text, text)
        }
    }

    func testEPUBSummariesRejectFreeTextInFields() {
        for text in [
            "EPUB open failed; stage=layout, error=章节资源缺失：OEBPS/私人.xhtml, code=0, elapsedMs=1",
            "EPUB import failed; stage=copy, domain=/Users/name/book.epub, code=1, elapsedMs=1",
            "EPUB import failed; stage=copy, domain=NoveliaIOS.WenkuLocalLibraryError, code=1, elapsedMs=1",
            "EPUB chapter laid out; spine=3, pages=27, elapsedMs=311 title=我的书",
            "TOC nav mapped; entries=45, mapped=44 navHref=OEBPS/nav.xhtml",
        ] {
            XCTAssertNil(export(text.hasPrefix("TOC") ? "epubcontainer" : "epub", text), text)
        }
    }

    func testDomainLabelHidesAppErrorTypes() {
        XCTAssertEqual(ShareableLogPolicy.domainLabel(NSCocoaErrorDomain), NSCocoaErrorDomain)
        XCTAssertEqual(ShareableLogPolicy.domainLabel("NoveliaIOS.WenkuLocalLibraryError"), "app")
    }

    /// 0.11.3（49）的导出情况：一秒内有 3073 条相同跟踪事件，混杂少量实际事件。
    func testRepeatedEventsCollapseIntoOneCountedLine() {
        var lines = [ShareableLogLine(secondsAgo: 60, level: "info", category: "txt", message: "TXT decode succeeded; bytes=8969801, elapsedMs=64")]
        let storm = "EPUB layout trace event (Debug -EPUBEngineTrace only); details omitted for privacy"
        lines += Array(repeating: ShareableLogLine(secondsAgo: 54, level: "fault", category: "enginediag", message: storm), count: 3073)
        lines.append(ShareableLogLine(secondsAgo: 53, level: "info", category: "epubcontainer", message: "TOC nav mapped; entries=45, mapped=44"))
        lines.append(ShareableLogLine(secondsAgo: 53, level: "fault", category: "enginediag", message: storm))
        let output = ShareableLogAggregator.collapse(lines)
        XCTAssertEqual(output, [
            "-60s [info] [txt] TXT decode succeeded; bytes=8969801, elapsedMs=64",
            "-54s [fault] [enginediag] \(storm) (×3073)",
            "-53s [info] [epubcontainer] TOC nav mapped; entries=45, mapped=44",
            "-53s [fault] [enginediag] \(storm)",
        ])
    }

    func testRunSpanningSecondsShowsTimeRange() {
        let lines = [55, 54, 54].map { ShareableLogLine(secondsAgo: $0, level: "info", category: "epub", message: "EPUB open started") }
        XCTAssertEqual(ShareableLogAggregator.collapse(lines), ["-55s…-54s [info] [epub] EPUB open started (×3)"])
        XCTAssertEqual(ShareableLogAggregator.collapse([]), [])
    }
}

/// 结构化缓存与排版日志（trace、书籍标记、source、reason、cacheHit、thread、mono）。
final class StructuredDiagnosticsExportTests: XCTestCase {
    private func exported(_ category: String, _ text: String) -> String? {
        ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: text)
    }

    func testStructuredLinesPass() {
        let lines = [
            ("txt", "TXT open requested; trace=1a2b3c4d, source=open, mode=paged, mono=81234567"),
            ("txt", "TXT decode succeeded; trace=1a2b3c4d, book=0f0e0d0c, source=import, reason=first, cacheHit=false, bytes=8969801, elapsedMs=63, thread=background, mono=81234567"),
            ("txt", "TXT chapters parsed; trace=1a2b3c4d, book=0f0e0d0c, source=open, reason=first, cacheHit=false, lines=237923, chapters=1675, elapsedMs=611, thread=background, mono=81235178"),
            ("txt", "TXT cache hit; trace=99aa88bb, book=0f0e0d0c, source=open, reason=reopen, level=parsed, cacheHit=true, chapters=1675, elapsedMs=0, thread=background, mono=81239000"),
            ("txt", "TXT cache hit; trace=99aa88bb, book=0f0e0d0c, source=import, reason=reopen, level=decoded, cacheHit=true, bytes=8969801, elapsedMs=0, thread=background, mono=81239000"),
            ("txt", "TXT import skipped duplicate; trace=99aa88bb, book=0f0e0d0c, elapsedMs=91, mono=81239000"),
            ("epub", "EPUB open started; kind=txt, trace=1a2b3c4d, source=open, mono=81240000"),
            ("epub", "TXT open started; kind=txt, trace=1a2b3c4d, source=open, mono=81240000"),
            ("epub", "Online open failed; kind=online, trace=1a2b3c4d, stage=layout, error=url, code=-1009, elapsedMs=812, mono=81240000"),
            ("epub", "TXT chapter laid out; book=0f0e0d0c, trace=1a2b3c4d, gen=2, spine=19, totalSpine=1802, currentSpine=19, reason=first, pages=14, cacheHit=false, elapsedMs=120, thread=main, mono=81240000"),
            ("epub", "Online chapter layout failed; book=0f0e0d0c, trace=1a2b3c4d, gen=1, spine=7, totalSpine=300, currentSpine=6, reason=prefetch, error=url, code=-1009, elapsedMs=30, thread=main, mono=81240000"),
            ("epub", "EPUB open succeeded; kind=epub, trace=1a2b3c4d, book=0f0e0d0c, totalSpine=48, toc=45, currentSpine=3, currentChapterPages=27, restored=true, elapsedMs=812, mono=81240000"),
            ("epub", "EPUB chapter laid out; book=0f0e0d0c, trace=1a2b3c4d, gen=2, spine=3, totalSpine=48, currentSpine=3, reason=restore, pages=27, cacheHit=false, elapsedMs=383, thread=main, mono=81240000"),
            ("epub", "EPUB chapter layout reused; book=0f0e0d0c, trace=1a2b3c4d, gen=3, spine=4, totalSpine=48, currentSpine=3, reason=prefetch, pages=9, cacheHit=true, level=inflight, elapsedMs=40, thread=main, mono=81240000"),
            ("epub", "EPUB chapter layout cancelled; book=0f0e0d0c, trace=1a2b3c4d, gen=2, spine=2, totalSpine=48, currentSpine=3, reason=prefetch, elapsedMs=8, thread=main, mono=81240000"),
            ("epub", "EPUB relayout scheduled; trace=1a2b3c4d, gen=2, reason=rotate, cancelledTasks=3, mono=81240000"),
            ("epub", "EPUB reader closed; trace=1a2b3c4d, gen=3, cancelledTasks=2, mono=81240000"),
        ]
        for (category, line) in lines {
            XCTAssertEqual(exported(category, line), line, line)
        }
    }

    func testStructuredFieldsRejectFreeText() {
        for line in [
            "TXT decode succeeded; trace=1a2b3c4d, book=/Users/a/b.txt, source=import, reason=first, cacheHit=false, bytes=1, elapsedMs=1, thread=background, mono=1",
            "TXT cache hit; trace=1a2b3c4d, book=0f0e0d0c, source=小说, reason=reopen, level=parsed, cacheHit=true, chapters=1, elapsedMs=0, thread=background, mono=1",
            "TXT chapters parsed; trace=1A2B3C4D, book=0f0e0d0c, source=open, reason=first, cacheHit=false, lines=1, chapters=1, elapsedMs=1, thread=background, mono=1",
            "TXT chapters parsed; trace=1a2b3c4d, book=0f0e0d0c, source=open, reason=first, cacheHit=false, lines=1, chapters=1, elapsedMs=1, thread=worker, mono=1",
        ] {
            XCTAssertNil(exported("txt", line), line)
        }
        XCTAssertNil(exported("epub", "EPUB chapter laid out; book=0f0e0d0c, trace=1a2b3c4d, gen=2, spine=3, totalSpine=48, currentSpine=3, reason=第一章, pages=27, cacheHit=false, elapsedMs=383, thread=main, mono=1"))
    }
}
