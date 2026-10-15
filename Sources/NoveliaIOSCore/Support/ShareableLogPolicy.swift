import Foundation

/// 仅导出经过检查的消息格式。未知的自由文本不会复制到分享文件中。
/// OSLog 隐私设置保护日志记录；此白名单也保护旧版或公开的日志条目。
public enum ShareableLogPolicy {
    public static let subsystem = "cc.novelia.ios.port"
    private static let patterns: [String: [String]] = [
        "lifecycle": [#"Application launched, version [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3} \([0-9]{1,8}\)"#],
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
            #"(?:EPUB|TXT|Online) chapter laid out; \#(layoutFields), pages=[0-9]{1,8}, cacheHit=false, elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"(?:EPUB|TXT|Online) chapter layout reused; \#(layoutFields), pages=[0-9]{1,8}, cacheHit=true, level=(?:memory|inflight|book), elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"(?:EPUB|TXT|Online) chapter layout cancelled; \#(layoutFields), elapsedMs=[0-9]{1,12}\#(tail)"#,
            #"(?:EPUB|TXT|Online) chapter layout failed; \#(layoutFields), error=\#(errorKindPattern), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}\#(tail)"#,
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
