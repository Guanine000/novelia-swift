import Foundation
import OSLog

/// 仅导出经过检查的消息格式。未知的自由文本不会复制到分享文件中。
/// OSLog 隐私设置保护日志记录；此白名单也保护旧版或公开的日志条目。
public enum ShareableLogPolicy {
    public static let subsystem = "cc.novelia.ios.port"
    private static let patterns: [String: [String]] = [
        "lifecycle": [
            #"Application launched, version [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3} \([0-9]{1,8}\)"#,
            #"Scene phase changed; phase=(?:active|inactive|background|unknown)"#,
            #"Memory warning received; mono=[0-9]{1,12}"#,
        ],
        "txt": [
            #"TXT decode failed; bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}, attempted=UTF-8/BOM-Unicode/GB18030/GBK/Big5/Shift_JIS"#,
            #"TXT decode succeeded; bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
            #"TXT chapter detection fell back to full text; lines=[0-9]{1,12}, headings=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
            #"TXT chapters parsed; lines=[0-9]{1,12}, chapters=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
            // 来自 TXTBookCache 的结构化事件（0.12.1 及以后）。
            #"TXT decode succeeded; trace=\#(hex8), book=\#(hex8), source=\#(txtSource), reason=\#(txtReason), cacheHit=false, bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"TXT decode failed; trace=\#(hex8), book=\#(hex8), source=\#(txtSource), bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}, attempted=UTF-8/BOM-Unicode/GB18030/GBK/Big5/Shift_JIS\#(tail)"#,
            #"TXT chapters parsed; trace=\#(hex8), book=\#(hex8), source=\#(txtSource), reason=\#(txtReason), cacheHit=false, lines=[0-9]{1,12}, chapters=[0-9]{1,12}, elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"TXT chapter detection fell back to full text; trace=\#(hex8), book=\#(hex8), source=\#(txtSource), reason=\#(txtReason), cacheHit=false, lines=[0-9]{1,12}, headings=[0-9]{1,12}, elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"TXT chapter cache write failed; domain=\#(domainPattern), code=-?[0-9]{1,8}"#,
            #"TXT cache hit; trace=\#(hex8), book=\#(hex8), source=\#(txtSource), reason=\#(txtReason), level=(?:parsed|decoded|inflight|disk), cacheHit=true, (?:chapters|bytes)=[0-9]{1,12}, elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"TXT open requested; trace=\#(hex8), source=\#(txtSource), mode=(?:scroll|paged), mono=[0-9]{1,12}"#,
            #"TXT import started; trace=\#(hex8), mono=[0-9]{1,12}"#,
            #"TXT import completed; trace=\#(hex8), book=\#(hex8), elapsedMs=[0-9]{1,12}, mono=[0-9]{1,12}"#,
            #"TXT import skipped duplicate; trace=\#(hex8), book=\#(hex8), elapsedMs=[0-9]{1,12}, mono=[0-9]{1,12}"#,
        ],
        "novel-download": [
            #"Novel EPUB request failed before receiving an HTTP response; domain=(?:NSURLErrorDomain|NSCocoaErrorDomain|NSPOSIXErrorDomain), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            #"Novel EPUB request returned HTTP [0-9]{3}; elapsedMs=[0-9]{1,12}"#,
            "Novel file response was empty",
            #"Novel EPUB download completed; bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
        ],
        "epubcontainer": [
            #"TOC fallback generated entries=[0-9]{1,12}, embedded entries=[0-9]{1,12}"#,
            #"TOC nav mapped; entries=[0-9]{1,12}, mapped=[0-9]{1,12}"#,
        ],
        "epub": [
            "EPUB import started",
            #"EPUB import completed; bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
            #"EPUB import failed; stage=(?:copy|registration), domain=\#(domainPattern), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            "EPUB open started",
            #"EPUB open succeeded; spine=[0-9]{1,8}, toc=[0-9]{1,8}, pages=[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            #"EPUB open failed; stage=(?:hash|container|layout), error=\#(errorKindPattern), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            #"EPUB open cancelled; elapsedMs=[0-9]{1,12}"#,
            #"EPUB chapter laid out; spine=[0-9]{1,8}, pages=[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            #"EPUB chapter layout failed; spine=[0-9]{1,8}, error=\#(errorKindPattern), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            #"EPUB chapter layout cancelled; spine=[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            // 来自 EPUBReaderModel / EPUBLayoutCoordinator 的结构化事件（0.12.1 及以后）。
            #"(?:EPUB|TXT|Online) open started; kind=\#(bookKind), trace=\#(hex8), source=(?:open|restore), mono=[0-9]{1,12}"#,
            #"(?:EPUB|TXT|Online) open succeeded; kind=\#(bookKind), trace=\#(hex8), book=\#(hex8), totalSpine=[0-9]{1,8}, toc=[0-9]{1,8}, currentSpine=[0-9]{1,8}, currentChapterPages=[0-9]{1,8}, restored=(?:true|false), elapsedMs=[0-9]{1,12}, mono=[0-9]{1,12}"#,
            #"(?:EPUB|TXT|Online) open failed; kind=\#(bookKind), trace=\#(hex8), stage=(?:hash|container|layout), error=\#(errorKindPattern), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}, mono=[0-9]{1,12}"#,
            #"(?:EPUB|TXT|Online) open cancelled; kind=\#(bookKind), trace=\#(hex8), elapsedMs=[0-9]{1,12}, mono=[0-9]{1,12}"#,
            #"EPUB reader closed; trace=\#(hex8), gen=[0-9]{1,8}, cancelledTasks=[0-9]{1,6}, mono=[0-9]{1,12}"#,
            #"EPUB relayout scheduled; trace=\#(hex8), gen=[0-9]{1,8}, reason=\#(layoutReason), cancelledTasks=[0-9]{1,6}, mono=[0-9]{1,12}"#,
            // 跳页诊断（1.0.0 构建 92 及以后）：重排落点、重排以外的位置变化和阅读区尺寸变化。
            #"(?:EPUB|TXT|Online) relayout positioned; trace=\#(hex8), gen=[0-9]{1,8}, reason=\#(layoutReason), spine=[0-9]{1,8}, fromPage=[0-9]{1,8}, fromPages=[0-9]{1,8}, toPage=[0-9]{1,8}, toPages=[0-9]{1,8}, anchor=(?:offset|progression|fraction), resumed=(?:true|false), mono=[0-9]{1,12}"#,
            #"(?:EPUB|TXT|Online) position changed; trace=\#(hex8), gen=[0-9]{1,8}, cause=\#(positionCause), fromSpine=[0-9]{1,8}, fromPage=[0-9]{1,8}, fromPages=[0-9]{1,8}, toSpine=[0-9]{1,8}, toPage=[0-9]{1,8}, toPages=[0-9]{1,8}, mono=[0-9]{1,12}"#,
            #"EPUB viewport changed; trace=\#(hex8), from=[0-9]{1,5}x[0-9]{1,5}, to=[0-9]{1,5}x[0-9]{1,5}, mono=[0-9]{1,12}"#,
            #"User marked reading issue; engine=native, mono=[0-9]{1,12}"#,
            #"(?:EPUB|TXT|Online) chapter laid out; \#(layoutFields), pages=[0-9]{1,8}, cacheHit=false, elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"(?:EPUB|TXT|Online) chapter layout reused; \#(layoutFields), pages=[0-9]{1,8}, cacheHit=true, level=(?:memory|inflight|book), elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"(?:EPUB|TXT|Online) chapter layout cancelled; \#(layoutFields), elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"(?:EPUB|TXT|Online) chapter layout failed; \#(layoutFields), error=\#(errorKindPattern), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}\#(tail)"#,
        ],
        "readium": [
            #"Readium page snapshot; session=\#(hex8), nav=[0-9]{1,8}, op=[0-9]{1,8}, when=(?:tap|swipe|outerSwipe|locationCallback|issue|navigationComplete), model=-?[0-9]{1,8}, page=-?[0-9]{1,8}, view=[0-9]{1,8}, candidates=[0-9]{1,6}, offset=-?[0-9]{1,9}, width=[0-9]{1,6}, content=[0-9]{1,9}, loading=(?:true|false), moving=(?:true|false), mono=[0-9]{1,12}"#,
            #"Readium outer swipe decision; session=\#(hex8), nav=[0-9]{1,8}, op=[0-9]{1,8}, direction=(?:left|right|unknown), reason=(?:redirect|boundary|fixedLayout|noDirection|noPage|ambiguous|loading|moving|mismatch|invalidSize|busy|stale|completed|failed), mono=[0-9]{1,12}"#,
            #"Readium EPUB opened: [0-9]{1,8} resources, [0-9]{1,8} positions"#,
            #"User marked reading issue; engine=readium, mono=[0-9]{1,12}"#,
            // 1.0.0 构建 93 及以后：翻页时与停稳后的章节分页状态、WebView 重建与资源读取失败。
            #"Readium page state; when=(?:tap|swipe|outerSwipe|settled), resource=-?[0-9]{1,8}, offset=-?[0-9]{1,9}, width=[0-9]{1,6}, content=[0-9]{1,9}, mono=[0-9]{1,12}"#,
            #"Readium outer swipe redirected; direction=(?:left|right), resource=-?[0-9]{1,8}, mono=[0-9]{1,12}"#,
            #"Readium web view created; count=[0-9]{1,8}, mono=[0-9]{1,12}"#,
            #"Readium resource load failed; resource=-?[0-9]{1,8}, mono=[0-9]{1,12}"#,
            #"Readium position changed; kind=\#(bookKind), cause=\#(positionCause), fromResource=-?[0-9]{1,8}, fromProgress=-?[0-9]{1,4}, toResource=-?[0-9]{1,8}, toProgress=-?[0-9]{1,4}, total=-?[0-9]{1,4}, mono=[0-9]{1,12}"#,
        ],
        "enginediag": [
            #"EPUB layout trace summary; spine=[0-9]{1,8}, events=[0-9]{1,12}, html=[0-9]{1,12}, css=[0-9]{1,12}, selector=[0-9]{1,12}, style=[0-9]{1,12}, ingestion=[0-9]{1,12}, adapter=[0-9]{1,12}, allocation=[0-9]{1,12}"#,
        ],
    ]
    private static let hex8 = "[0-9a-f]{8}"
    private static let tail = ", thread=(?:main|background), mono=[0-9]{1,12}"
    public static let txtSources = ["import", "download", "open", "restore"]
    public static let txtReasons = ["first", "reopen", "concurrent", "duplicate", "evicted", "rulesChange", "launch"]
    /// 章节排版的原因，对应 EPUBLayoutReason 的原始值。
    public static let layoutReasons = ["first", "restore", "prefetch", "navigate", "seek", "retry", "resize", "rotate", "fontChange", "styleChange", "themeChange", "backgroundChange"]
    private static let txtSource = "(?:" + txtSources.joined(separator: "|") + ")"
    private static let txtReason = "(?:" + txtReasons.joined(separator: "|") + ")"
    private static let layoutReason = "(?:" + layoutReasons.joined(separator: "|") + ")"
    private static let bookKind = "(?:epub|txt|online)"
    /// 阅读位置变化的来源：两种阅读引擎共用。`other`／`unattributed` 表示没有对应的用户操作。
    public static let positionCauses = ["turnForward", "turnBackward", "tap", "swipe", "outerSwipe", "navigate", "seek", "restore", "open", "rebuild", "preferences", "other", "unattributed"]
    private static let positionCause = "(?:" + positionCauses.joined(separator: "|") + ")"
    private static let layoutFields = "book=\(hex8), trace=\(hex8), gen=[0-9]{1,8}, spine=[0-9]{1,8}, totalSpine=[0-9]{1,8}, currentSpine=[0-9]{1,8}, reason=\(layoutReason)"

    /// EPUB 阅读器记录的错误类型：使用固定名称，不包含错误描述。
    public static let errorKinds = ["unsupported", "resource", "layout", "cancelled", "archive", "container", "opf", "spine", "entrySize", "cocoa", "posix", "url", "other"]
    private static let errorKindPattern = "(?:" + errorKinds.joined(separator: "|") + ")"
    private static let reviewedDomains = ["NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSURLErrorDomain"]
    private static let domainPattern = "(?:" + (reviewedDomains + ["app"]).joined(separator: "|") + ")"

    /// 系统错误域直接保留；应用自定义的 Swift 错误域统一为 `app`。
    public static func domainLabel(_ domain: String) -> String {
        reviewedDomains.contains(domain) ? domain : "app"
    }
    private static let expressions = patterns.mapValues { $0.compactMap { try? NSRegularExpression(pattern: "\\A(?:" + $0 + ")\\z") } }

    public static func message(subsystem: String, category: String, text: String) -> String? {
        guard subsystem == self.subsystem, text.utf8.count <= 512 else { return nil }
        // 这些事件包含任意引擎或文件详情：仅导出事件名称。
        if category == "enginediag", text.hasPrefix("ENGINE_DIAG ") {
            return "EPUB layout trace event (Debug -EPUBEngineTrace only); details omitted for privacy"
        }
        if category == "epubcontainer", text.hasPrefix("TOC nav entries=") {
            return "EPUB navigation mapping diagnostic occurred; file details omitted for privacy"
        }
        if category == "novel-download", text.hasPrefix("Starting novel EPUB download;") {
            return "Starting novel EPUB download"
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard expressions[category]?.contains(where: { $0.firstMatch(in: text, range: range) != nil }) == true else { return nil }
        return text
    }
}

/// 合并重复事件前的一条导出日志。
public struct ShareableLogLine: Equatable {
    public let secondsAgo: Int
    public let level: String
    public let category: String
    public let message: String

    public init(secondsAgo: Int, level: String, category: String, message: String) {
        self.secondsAgo = secondsAgo
        self.level = level
        self.category = category
        self.message = message
    }
}

public enum ShareableLogAggregator {
    /// 将连续出现的相同级别、分类和消息合并为一行，并附上次数，
    /// 防止大量相同事件挤掉导出日志中的其他记录。
    /// 输入按从旧到新排序，因此同一连续区间的 `secondsAgo` 逐渐减小。
    public static func collapse(_ lines: [ShareableLogLine]) -> [String] {
        var output: [String] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let first = lines[index]
            var end = index + 1
            while end < lines.endIndex, lines[end].level == first.level,
                  lines[end].category == first.category, lines[end].message == first.message {
                end += 1
            }
            let count = end - index
            let last = lines[end - 1]
            let time = first.secondsAgo == last.secondsAgo ? "-\(first.secondsAgo)s" : "-\(first.secondsAgo)s…-\(last.secondsAgo)s"
            let repeats = count > 1 ? " (×\(count))" : ""
            output.append("\(time) [\(first.level)] [\(first.category)] \(first.message)\(repeats)")
            index = end
        }
        return output
    }
}

// MARK: - 跨启动诊断记录

/// 一条跨启动诊断记录。`launch` 标识写入它的那次启动。
public struct DiagnosticJournalEntry: Equatable {
    public let date: Date
    public let launch: String
    public let level: String
    public let category: String
    public let message: String
}

/// 把通过 `ShareableLogPolicy` 审查的诊断事件追加到 App 自己的文件，使 App 重启或被系统结束后
/// 仍能导出之前的记录（`OSLogStore` 在 iOS 上只能读当前进程）。
///
/// 只保存允许清单内的格式，写入与读取都再经过审查，因此文件中不会出现书名、正文、路径或账号。
/// 文件超过 `maxBytes` 时轮换为一个旧文件，最多占用约两倍空间；读取时只取最近 7 天。
/// 所有文件操作在私有串行队列上执行，调用方不阻塞主线程。
public final class DiagnosticJournal: @unchecked Sendable {
    /// App 使用的实例，位于 Application Support/Diagnostics，不随 iCloud 备份。
    public static let shared: DiagnosticJournal = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DiagnosticJournal(directory: base.appendingPathComponent("Diagnostics", isDirectory: true))
    }()

    /// 本次启动的标识，用于导出时区分「以前的启动」与当前进程（当前进程的记录改从系统日志读取）。
    public let launch: String
    private let directory: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "cc.novelia.ios.port.diagnostic-journal")
    private var currentURL: URL { directory.appendingPathComponent("journal.log") }
    private var rotatedURL: URL { directory.appendingPathComponent("journal.1.log") }

    public init(directory: URL, launch: String = DiagnosticContext.newTraceID(), maxBytes: Int = 1_500_000) {
        self.directory = directory
        self.launch = launch
        self.maxBytes = max(maxBytes, 1_024)
    }

    /// 追加一条记录；未通过审查的消息直接丢弃。
    public func append(level: String, category: String, message: String, date: Date = Date()) {
        queue.async { [self] in
            guard ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: message) != nil,
                  ["debug", "info", "notice", "error", "fault"].contains(level) else { return }
            let line = "\(Int((date.timeIntervalSince1970 * 1_000).rounded()))\t\(launch)\t\(level)\t\(category)\t\(message)\n"
            write(Data(line.utf8))
        }
    }

    /// 读取 `since` 之后的记录（旧到新），可排除指定启动；损坏或未通过审查的行被跳过。
    public func entries(since: Date, excludingLaunch: String? = nil) -> [DiagnosticJournalEntry] {
        queue.sync {
            [rotatedURL, currentURL].flatMap { url -> [DiagnosticJournalEntry] in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                return text.split(separator: "\n").compactMap { Self.parse($0) }
            }
            .filter { $0.date >= since && $0.launch != excludingLaunch }
            .sorted { $0.date < $1.date }
        }
    }

    /// 等待已排队的写入完成（测试与导出前使用）。
    public func flush() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = directory
            try? url.setResourceValues(values)
        }
        let size = (try? manager.attributesOfItem(atPath: currentURL.path)[.size] as? Int) ?? 0
        if size + data.count > maxBytes, size > 0 {
            try? manager.removeItem(at: rotatedURL)
            try? manager.moveItem(at: currentURL, to: rotatedURL)
        }
        if !manager.fileExists(atPath: currentURL.path) {
            manager.createFile(atPath: currentURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: currentURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func parse(_ line: Substring) -> DiagnosticJournalEntry? {
        let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, let millis = Int(fields[0]),
              fields[1].range(of: "\\A[0-9a-f]{8}\\z", options: .regularExpression) != nil,
              ["debug", "info", "notice", "error", "fault"].contains(fields[2]),
              let message = ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: fields[3], text: fields[4])
        else { return nil }
        return DiagnosticJournalEntry(date: Date(timeIntervalSince1970: Double(millis) / 1_000), launch: fields[1],
                                      level: fields[2], category: fields[3], message: message)
    }
}

/// 同时写入系统日志与跨启动诊断记录的日志器，用于需要出现在分享日志中的事件。
/// 只有通过 `ShareableLogPolicy` 审查的消息才以公开形式写入系统日志，其余按私有处理。
public struct ShareableLogger: Sendable {
    public let category: String
    private let logger: Logger
    private let journal: DiagnosticJournal

    public init(category: String, journal: DiagnosticJournal = .shared) {
        self.category = category
        self.logger = Logger(subsystem: ShareableLogPolicy.subsystem, category: category)
        self.journal = journal
    }

    public func notice(_ message: String) {
        record(.default, level: "notice", message)
    }

    public func error(_ message: String) {
        record(.error, level: "error", message)
    }

    private func record(_ type: OSLogType, level: String, _ message: String) {
        if ShareableLogPolicy.message(subsystem: ShareableLogPolicy.subsystem, category: category, text: message) != nil {
            logger.log(level: type, "\(message, privacy: .public)")
        } else {
            logger.log(level: type, "\(message, privacy: .private)")
        }
        journal.append(level: level, category: category, message: message)
    }
}

/// 阅读位置与运行环境诊断的消息格式。集中在 Core 中生成，回归测试逐一确认它们能通过
/// `ShareableLogPolicy`，避免调用处的拼写差异让事件在导出时被静默丢弃。只接受数字与固定标签。
public enum ReaderDiagnosticMessage {
    public static func relayoutScheduled(trace: String, generation: Int, reason: String, cancelledTasks: Int,
                                         mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "EPUB relayout scheduled; trace=\(trace), gen=\(generation), reason=\(reason), cancelledTasks=\(cancelledTasks), mono=\(mono)"
    }

    public static func readerClosed(trace: String, generation: Int, cancelledTasks: Int,
                                    mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "EPUB reader closed; trace=\(trace), gen=\(generation), cancelledTasks=\(cancelledTasks), mono=\(mono)"
    }

    /// `label` 为 EPUB、TXT 或 Online，`kind` 为对应的 epub、txt、online。
    public static func openSucceeded(label: String, kind: String, trace: String, book: String, totalSpine: Int, toc: Int,
                                     currentSpine: Int, currentChapterPages: Int, restored: Bool, elapsedMs: Int,
                                     mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "\(label) open succeeded; kind=\(kind), trace=\(trace), book=\(book), totalSpine=\(totalSpine), toc=\(toc), currentSpine=\(currentSpine), currentChapterPages=\(currentChapterPages), restored=\(restored), elapsedMs=\(elapsedMs), mono=\(mono)"
    }

    public static func relayoutPositioned(label: String, trace: String, generation: Int, reason: String, spine: Int,
                                          fromPage: Int, fromPages: Int, toPage: Int, toPages: Int, anchor: String, resumed: Bool,
                                          mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "\(label) relayout positioned; trace=\(trace), gen=\(generation), reason=\(reason), spine=\(spine), fromPage=\(fromPage), fromPages=\(fromPages), toPage=\(toPage), toPages=\(toPages), anchor=\(anchor), resumed=\(resumed), mono=\(mono)"
    }

    public static func positionChanged(label: String, trace: String, generation: Int, cause: String,
                                       fromSpine: Int, fromPage: Int, fromPages: Int, toSpine: Int, toPage: Int, toPages: Int,
                                       mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "\(label) position changed; trace=\(trace), gen=\(generation), cause=\(cause), fromSpine=\(fromSpine), fromPage=\(fromPage), fromPages=\(fromPages), toSpine=\(toSpine), toPage=\(toPage), toPages=\(toPages), mono=\(mono)"
    }

    public static func viewportChanged(trace: String, fromWidth: Int, fromHeight: Int, toWidth: Int, toHeight: Int,
                                       mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "EPUB viewport changed; trace=\(trace), from=\(fromWidth)x\(fromHeight), to=\(toWidth)x\(toHeight), mono=\(mono)"
    }

    /// 用户在阅读器中点了「标记问题」。`engine` 为 native 或 readium。
    public static func issueMarked(engine: String, mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "User marked reading issue; engine=\(engine), mono=\(mono)"
    }

    public static func readiumOpened(resources: Int, positions: Int) -> String {
        "Readium EPUB opened: \(resources) resources, \(positions) positions"
    }

    /// 进度为千分比；未知时为 -1。
    public static func readiumPositionChanged(kind: String, cause: String, fromResource: Int, fromProgress: Int,
                                              toResource: Int, toProgress: Int, total: Int,
                                              mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Readium position changed; kind=\(kind), cause=\(cause), fromResource=\(fromResource), fromProgress=\(fromProgress), toResource=\(toResource), toProgress=\(toProgress), total=\(total), mono=\(mono)"
    }

    /// 当前章节 WebView 的横向分页状态（单位 pt）：页码约为 offset/width，页数约为 content/width。
    /// Readium 翻页时若 offset + width 超出 content 就认为已到章末并进入下一章。
    public static func readiumPageState(when: String, resource: Int, offset: Int, width: Int, content: Int,
                                        mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Readium page state; when=\(when), resource=\(resource), offset=\(offset), width=\(width), content=\(content), mono=\(mono)"
    }

    /// 页面所属资源独立于模型位置；未知为 -1，没有可唯一选择的页面时 view 为 0。
    public static func readiumSnapshot(session: String, nav: Int, op: Int, when: String,
                                        model: Int, page: Int, view: Int, candidates: Int,
                                        offset: Int, width: Int, content: Int, loading: Bool, moving: Bool,
                                        mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Readium page snapshot; session=\(session), nav=\(nav), op=\(op), when=\(when), model=\(model), page=\(page), view=\(view), candidates=\(candidates), offset=\(offset), width=\(width), content=\(content), loading=\(loading), moving=\(moving), mono=\(mono)"
    }

    public static func readiumSwipeDecision(session: String, nav: Int, op: Int, direction: String, reason: String,
                                             mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Readium outer swipe decision; session=\(session), nav=\(nav), op=\(op), direction=\(direction), reason=\(reason), mono=\(mono)"
    }

    /// 外层章节切换视图开始的拖动被改为章内翻页（本章在该方向仍有页面）。
    public static func readiumSwipeRedirected(direction: String, resource: Int,
                                              mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Readium outer swipe redirected; direction=\(direction), resource=\(resource), mono=\(mono)"
    }

    /// Readium 新建章节 WebView；WebContent 进程终止后 Readium 会重建全部章节，表现为短时间内连续出现。
    public static func readiumWebViewCreated(count: Int, mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Readium web view created; count=\(count), mono=\(mono)"
    }

    public static func readiumResourceLoadFailed(resource: Int, mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Readium resource load failed; resource=\(resource), mono=\(mono)"
    }

    public static func scenePhase(_ phase: String) -> String {
        "Scene phase changed; phase=\(phase)"
    }

    public static func memoryWarning(mono: Int = DiagnosticContext.monotonicMilliseconds()) -> String {
        "Memory warning received; mono=\(mono)"
    }
}
