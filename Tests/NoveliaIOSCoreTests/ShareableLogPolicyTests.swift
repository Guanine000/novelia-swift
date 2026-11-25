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

    /// 跳页诊断：重排落点、位置变化（含普通翻页）、阅读区尺寸、前后台切换与 Readium 位置。
    func testPositionDiagnosticsPass() {
        let lines = [
            ("epub", "EPUB relayout positioned; trace=1a2b3c4d, gen=4, reason=themeChange, spine=3, fromPage=11, fromPages=27, toPage=11, toPages=27, anchor=offset, resumed=false, mono=81240000"),
            ("epub", "TXT relayout positioned; trace=1a2b3c4d, gen=5, reason=resize, spine=3, fromPage=11, fromPages=27, toPage=0, toPages=28, anchor=fraction, resumed=true, mono=81240000"),
            ("epub", "EPUB position changed; trace=1a2b3c4d, gen=4, cause=turnForward, fromSpine=3, fromPage=11, fromPages=27, toSpine=3, toPage=12, toPages=27, mono=81240000"),
            ("epub", "Online position changed; trace=1a2b3c4d, gen=4, cause=other, fromSpine=3, fromPage=11, fromPages=27, toSpine=4, toPage=0, toPages=9, mono=81240000"),
            ("epub", "EPUB viewport changed; trace=1a2b3c4d, from=402x780, to=402x812, mono=81240000"),
            ("lifecycle", "Scene phase changed; phase=background"),
            ("readium", "Readium EPUB opened: 48 resources, 1203 positions"),
            ("readium", "Readium position changed; kind=epub, cause=unattributed, fromResource=3, fromProgress=412, toResource=4, toProgress=0, total=87, mono=81240000"),
            ("readium", "Readium position changed; kind=txt, cause=open, fromResource=-1, fromProgress=-1, toResource=0, toProgress=1000, total=-1, mono=81240000"),
        ]
        for (category, line) in lines {
            XCTAssertEqual(exported(category, line), line, line)
        }
        for line in [
            "Readium position changed; kind=epub, cause=书名, fromResource=3, fromProgress=412, toResource=4, toProgress=0, total=87, mono=1",
            "EPUB position changed; trace=1a2b3c4d, gen=4, cause=turnForward, fromSpine=3, fromPage=11, fromPages=27, toSpine=3, toPage=12, toPages=27, mono=1 href=OEBPS/a.xhtml",
            "Readium EPUB opened: 48 resources, 1203 positions /Users/name/book.epub",
            "Scene phase changed; phase=background\nsecret",
        ] {
            XCTAssertNil(exported(line.hasPrefix("Readium") ? "readium" : (line.hasPrefix("Scene") ? "lifecycle" : "epub"), line), line)
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

/// 阅读诊断格式化函数的输出必须全部通过允许清单，否则事件会在导出时被静默丢弃。
final class ReaderDiagnosticMessageTests: XCTestCase {
    private func passes(_ category: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: text), text,
                       text, file: file, line: line)
    }

    func testEveryFormatterPassesThePolicy() {
        typealias M = ReaderDiagnosticMessage
        for reason in ShareableLogPolicy.layoutReasons {
            passes("epub", M.relayoutScheduled(trace: "1a2b3c4d", generation: 3, reason: reason, cancelledTasks: 2))
            passes("epub", M.relayoutPositioned(label: "EPUB", trace: "1a2b3c4d", generation: 3, reason: reason, spine: 4,
                                                fromPage: 7, fromPages: 20, toPage: 7, toPages: 21, anchor: "fraction", resumed: true))
        }
        passes("epub", M.readerClosed(trace: "1a2b3c4d", generation: 3, cancelledTasks: 0))
        for (label, kind) in [("EPUB", "epub"), ("TXT", "txt"), ("Online", "online")] {
            passes("epub", M.openSucceeded(label: label, kind: kind, trace: "1a2b3c4d", book: "0f0e0d0c", totalSpine: 48, toc: 45,
                                           currentSpine: 3, currentChapterPages: 27, restored: false, elapsedMs: 812))
        }
        for cause in ShareableLogPolicy.positionCauses {
            passes("epub", M.positionChanged(label: "TXT", trace: "1a2b3c4d", generation: 3, cause: cause, fromSpine: 1, fromPage: 5,
                                             fromPages: 12, toSpine: 2, toPage: 0, toPages: 9))
            passes("readium", M.readiumPositionChanged(kind: "epub", cause: cause, fromResource: 3, fromProgress: 412,
                                                       toResource: 4, toProgress: 0, total: 87))
        }
        passes("epub", M.viewportChanged(trace: "1a2b3c4d", fromWidth: 402, fromHeight: 780, toWidth: 874, toHeight: 402))
        passes("epub", M.issueMarked(engine: "native"))
        passes("readium", M.issueMarked(engine: "readium"))
        passes("readium", M.readiumOpened(resources: 48, positions: 1203))
        for when in ["tap", "swipe", "outerSwipe", "settled"] {
            passes("readium", M.readiumPageState(when: when, resource: -1, offset: 3216, width: 402, content: 4824))
        }
        for when in ["tap", "swipe", "outerSwipe", "locationCallback", "issue", "navigationComplete"] {
            passes("readium", M.readiumSnapshot(session: "1234abcd", nav: 2, op: 17, when: when,
                model: 3, page: -1, view: 0, candidates: 2, offset: 0, width: 1373, content: 15103, loading: true, moving: false))
        }
        for reason in ["redirect", "boundary", "fixedLayout", "noDirection", "noPage", "ambiguous", "loading", "moving", "mismatch", "invalidSize", "busy", "stale", "completed", "failed"] {
            for direction in ["left", "right", "unknown"] {
                let message = M.readiumSwipeDecision(session: "1234abcd", nav: 2, op: 17, direction: direction, reason: reason)
                passes("readium", message)
                XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "readium", text: message + " url=/private/book.xhtml"))
            }
        }
        passes("readium", M.readiumWebViewCreated(count: 3))
        for direction in ["left", "right"] { passes("readium", M.readiumSwipeRedirected(direction: direction, resource: 14)) }
        passes("readium", M.readiumResourceLoadFailed(resource: 7))
        passes("readium", M.readiumOpenFailed(domain: NSCocoaErrorDomain, code: 260, elapsedMs: 42))
        passes("readium", M.readiumOpenFailed(domain: "Custom.SwiftError", code: 1, elapsedMs: 15))
        for phase in ["active", "inactive", "background", "unknown"] { passes("lifecycle", M.scenePhase(phase)) }
        passes("lifecycle", M.memoryWarning())
        passes("lifecycle", "Application launched, version 1.0.0 (93)")
    }

    func testAppDiagnosticMessagesPassAndRejectFreeText() {
        typealias A = AppDiagnosticMessage
        passes("txt", A.txtImportFailed(stage: "copy", domain: NSCocoaErrorDomain, code: 260, elapsedMs: 12))
        passes("txt", A.txtImportFailed(stage: "registration", domain: "CustomError", code: 1, elapsedMs: 8))
        passes("txt", A.txtReaderLoadFailed(mode: "scroll", domain: NSPOSIXErrorDomain, code: 2))
        passes("txt", A.txtReaderLoadFailed(mode: "paged", domain: "CustomError", code: 3))
        passes("epub", "EPUB import failed; stage=repair, domain=app, code=1, elapsedMs=45")
        for format in ShareableLogPolicy.kindleFormats + ["unknown-ext"] {
            passes("kindleimport", A.kindleImportStarted(format: format))
            passes("kindleimport", A.kindleImportCompleted(format: format, epubBytes: 1024, elapsedMs: 88))
            for reason in ShareableLogPolicy.kindleFailureReasons + ["unexpected"] {
                passes("kindleimport", A.kindleImportFailed(stage: "convert", format: format, reason: reason, domain: "Custom", code: 0, elapsedMs: 10))
            }
        }
        passes("novel-download", A.novelDownloadRequestFailed(domain: NSURLErrorDomain, code: -1009, elapsedMs: 50))
        passes("novel-download", A.novelDownloadCompleted(bytes: 4096, elapsedMs: 210))
        passes("novel-download", A.novelDownloadRejected(status: 502, elapsedMs: 90))
        passes("novel-download", A.novelDownloadRejected(status: 0, elapsedMs: 15))
        for trigger in ShareableLogPolicy.syncTriggers {
            passes("webdav", A.webdavSyncStarted(trigger: trigger, content: true, statistics: false))
            passes("webdav", A.webdavSyncCompleted(trigger: trigger, content: true, statistics: true, imported: 2, removed: 1, repaired: 0, elapsedMs: 512))
            for stage in ShareableLogPolicy.syncStages {
                passes("webdav", A.webdavSyncCancelled(trigger: trigger, stage: stage, elapsedMs: 100))
                passes("webdav", A.webdavSyncFailed(trigger: trigger, stage: stage, domain: NSURLErrorDomain, code: -1001, elapsedMs: 300))
            }
        }
        for engine in ShareableLogPolicy.speechEngines + ["other"] {
            passes("speech", A.speechStarted(engine: engine, chapter: 3, paused: false))
            for reason in ShareableLogPolicy.speechStopReasons {
                passes("speech", A.speechStopped(engine: engine, reason: reason))
            }
            for stage in ShareableLogPolicy.speechFailureStages {
                passes("speech", A.speechFailed(engine: engine, stage: stage))
            }
        }
        for format in ShareableLogPolicy.aiFormats {
            passes("reading-ai", A.aiRequestCompleted(format: format, stream: true, chars: 1200, elapsedMs: 3400))
            passes("reading-ai", A.aiRequestCancelled(format: format, elapsedMs: 220))
            for err in ShareableLogPolicy.aiErrorKinds + ["unknown"] {
                passes("reading-ai", A.aiRequestFailed(format: format, error: err, status: 429, elapsedMs: 410))
            }
        }
        for scope in ShareableLogPolicy.authScopes {
            for outcome in ShareableLogPolicy.authOutcomes {
                passes("auth", A.authSessionRefreshed(scope: scope, outcome: outcome, status: 401, domain: NSURLErrorDomain, code: -1009))
            }
            for reason in ShareableLogPolicy.authClearReasons {
                passes("auth", A.authSessionCleared(scope: scope, reason: reason))
            }
        }
        for host in ShareableLogPolicy.echHosts + ["secret.example.com"] {
            passes("ech", A.echRequest(host: host, outcome: "ok", status: 200, stage: "response_headers", reason: "none", resolver: "alidns_ip", family: "ipv4", customDoH: false, elapsedMs: 120))
            passes("ech", A.echRequest(host: host, outcome: "failed", status: -1, stage: "tls", reason: "ech_rejected", resolver: "other", family: "ipv6", customDoH: true, elapsedMs: 450))
            passes("ech", A.echProbe(host: host, ok: true, stage: "tls", reason: "none", resolver: "cloudflare_ip", family: "ipv4", customDoH: false, elapsedMs: 95))
            passes("ech", A.echProbe(host: host, ok: false, stage: "doh_ech", reason: "timeout", resolver: "other", family: "none", customDoH: true, elapsedMs: 2000))
        }
        XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: "ech",
                                                text: "ECH request; url=https://n.novelia.cc/secret"))
        for mode in ShareableLogPolicy.toolboxInspectModes {
            passes("epubtoolbox", A.epubToolboxInspectCompleted(mode: mode, issues: 4, drm: false, elapsedMs: 32))
            for reason in ShareableLogPolicy.toolboxFailureReasons {
                passes("epubtoolbox", A.epubToolboxInspectFailed(mode: mode, reason: reason, domain: NSCocoaErrorDomain, code: 260, elapsedMs: 12))
            }
        }
        for action in ShareableLogPolicy.toolboxActions {
            passes("epubtoolbox", A.epubToolboxActionCompleted(action: action, items: 5, bytes: 204800, elapsedMs: 650))
            for reason in ShareableLogPolicy.toolboxFailureReasons {
                passes("epubtoolbox", A.epubToolboxActionFailed(action: action, reason: reason, domain: "CustomError", code: 1, elapsedMs: 40))
            }
        }
        // 确保自由文本与凭据无法通过新增分类的白名单。
        for (category, invalid) in [
            ("kindleimport", "Kindle import failed; stage=convert, format=book.azw3, reason=drm, domain=app, code=0, elapsedMs=1, mono=1"),
            ("webdav", "WebDAV sync failed; trigger=manual, stage=content, domain=https://dav.example/u, code=401, elapsedMs=1, mono=1"),
            ("speech", "Speech started; engine=edge, chapter=1, paused=false, mono=1 text=正文"),
            ("reading-ai", "ReadingAI request failed; format=responses, error=sk-secret, status=401, elapsedMs=1, mono=1"),
            ("auth", "Auth session refreshed; scope=novel, outcome=failed, status=401, domain=app, code=0, mono=1 token=abc"),
            ("epubtoolbox", "EPUB toolbox action failed; action=process, reason=/private/book.epub, domain=app, code=0, elapsedMs=1, mono=1"),
        ] {
            XCTAssertNil(ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: invalid), invalid)
        }
    }

    func testCollapseByLaunchMarksBoundariesAndSkipsEmptySections() {
        let prev = [
            ShareableLogLine(secondsAgo: 120, level: "notice", category: "lifecycle", message: "Application launched, version 1.0.0 (93)"),
            ShareableLogLine(secondsAgo: 110, level: "error", category: "webdav", message: "WebDAV sync failed; trigger=manual, stage=content, domain=NSURLErrorDomain, code=-1009, elapsedMs=50, mono=1"),
            ShareableLogLine(secondsAgo: 108, level: "error", category: "webdav", message: "WebDAV sync failed; trigger=manual, stage=content, domain=NSURLErrorDomain, code=-1009, elapsedMs=50, mono=1"),
        ]
        let curr = [
            ShareableLogLine(secondsAgo: 5, level: "notice", category: "lifecycle", message: "Application launched, version 1.0.0 (93)"),
        ]
        let output = ShareableLogAggregator.collapseByLaunch([
            (label: "Launch aaaaaaaa (previous)", lines: prev),
            (label: "Launch empty (previous)", lines: []),
            (label: "Launch bbbbbbbb (current)", lines: curr),
        ])
        XCTAssertEqual(output, [
            "--- Launch aaaaaaaa (previous) ---",
            "-120s [notice] [lifecycle] Application launched, version 1.0.0 (93)",
            "-110s…-108s [error] [webdav] WebDAV sync failed; trigger=manual, stage=content, domain=NSURLErrorDomain, code=-1009, elapsedMs=50, mono=1 (×2)",
            "--- Launch bbbbbbbb (current) ---",
            "-5s [notice] [lifecycle] Application launched, version 1.0.0 (93)",
        ])
    }
}

final class DiagnosticJournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEntriesSurviveANewLaunchAndUnreviewedTextIsDropped() {
        let first = DiagnosticJournal(directory: directory, launch: "aaaaaaaa")
        first.append(level: "notice", category: "lifecycle", message: "Application launched, version 1.0.0 (93)")
        first.append(level: "notice", category: "lifecycle", message: "我的书名与正文")
        first.append(level: "notice", category: "readium", message: ReaderDiagnosticMessage.readiumWebViewCreated(count: 1))
        first.flush()

        let second = DiagnosticJournal(directory: directory, launch: "bbbbbbbb")
        second.append(level: "notice", category: "lifecycle", message: ReaderDiagnosticMessage.scenePhase("active"))
        second.flush()

        let earlier = second.entries(since: .distantPast, excludingLaunch: second.launch)
        XCTAssertEqual(earlier.map(\.launch), ["aaaaaaaa", "aaaaaaaa"])
        XCTAssertEqual(earlier.first?.message, "Application launched, version 1.0.0 (93)")
        XCTAssertEqual(second.entries(since: .distantPast).count, 3)
    }

    func testOldEntriesAreFilteredByDate() {
        let journal = DiagnosticJournal(directory: directory, launch: "aaaaaaaa")
        journal.append(level: "notice", category: "lifecycle", message: ReaderDiagnosticMessage.memoryWarning(mono: 1),
                       date: Date(timeIntervalSinceNow: -8 * 86_400))
        journal.append(level: "notice", category: "lifecycle", message: ReaderDiagnosticMessage.memoryWarning(mono: 2))
        journal.flush()
        let recent = journal.entries(since: Date(timeIntervalSinceNow: -7 * 86_400))
        XCTAssertEqual(recent.map(\.message), ["Memory warning received; mono=2"])
    }

    func testRotationKeepsSizeBoundedAndRecentEntries() throws {
        let journal = DiagnosticJournal(directory: directory, launch: "aaaaaaaa", maxBytes: 2_048)
        for index in 0..<200 {
            journal.append(level: "notice", category: "readium", message: ReaderDiagnosticMessage.readiumWebViewCreated(count: index, mono: index))
        }
        journal.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, 2)
        for file in files {
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 2_048)
        }
        let entries = journal.entries(since: .distantPast)
        XCTAssertEqual(entries.last?.message, ReaderDiagnosticMessage.readiumWebViewCreated(count: 199, mono: 199))
        XCTAssertLessThan(entries.count, 200)
    }

    func testHighVolumeCategoryDoesNotEvictOtherShareableCategories() {
        let journal = DiagnosticJournal(directory: directory, launch: "aaaaaaaa", maxBytes: 2_048)
        journal.append(level: "notice", category: "lifecycle", message: "Application launched, version 1.0.0 (93)")
        for index in 0..<200 {
            journal.append(level: "notice", category: "readium", message: ReaderDiagnosticMessage.readiumWebViewCreated(count: index, mono: index))
        }
        journal.flush()

        let messages = journal.entries(since: .distantPast).map(\.message)
        XCTAssertTrue(messages.contains("Application launched, version 1.0.0 (93)"))
        XCTAssertTrue(messages.contains(ReaderDiagnosticMessage.readiumWebViewCreated(count: 199, mono: 199)))
    }

    func testTamperedLinesAreSkipped() throws {
        let journal = DiagnosticJournal(directory: directory, launch: "aaaaaaaa")
        journal.append(level: "notice", category: "lifecycle", message: ReaderDiagnosticMessage.scenePhase("active"))
        journal.flush()
        let url = directory.appendingPathComponent("journal.log")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("1\taaaaaaaa\tnotice\tlifecycle\tAuthorization: Bearer secret\nnot a record\n".utf8))
        try handle.close()
        XCTAssertEqual(journal.entries(since: .distantPast).map(\.message), ["Scene phase changed; phase=active"])
    }
}

final class ShareableLogBudgetTests: XCTestCase {
    func testReservedCategorySlotsSurviveHighVolumeTail() {
        let categories = Array(repeating: "readium", count: 20)
            + ["lifecycle", "epub", "txt"]
            + Array(repeating: "readium", count: 20)
        let selected = ShareableLogBudget.selectedIndices(categories: categories, maxLines: 10, reservedPerCategory: 2)

        XCTAssertEqual(selected.count, 10)
        XCTAssertTrue(selected.contains(20))
        XCTAssertTrue(selected.contains(21))
        XCTAssertTrue(selected.contains(22))
        XCTAssertTrue(selected.contains(41))
        XCTAssertTrue(selected.contains(42))
    }

    func testSmallInputRemainsUnboundedByBudget() {
        let categories = ["lifecycle", "readium", "epub"]
        XCTAssertEqual(ShareableLogBudget.selectedIndices(categories: categories, maxLines: 10, reservedPerCategory: 2), Set(categories.indices))
    }
}
