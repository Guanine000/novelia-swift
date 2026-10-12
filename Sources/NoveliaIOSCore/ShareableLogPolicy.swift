import Foundation

/// Export only reviewed message formats. Unknown free text is never copied into a share file.
/// OSLog privacy protects recording; this allowlist also protects older/public log entries.
public enum ShareableLogPolicy {
    public static let subsystem = "cc.novelia.ios.port"
    private static let patterns: [String: [String]] = [
        "lifecycle": [#"Application launched, version [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3} \([0-9]{1,8}\)"#],
        "txt": [
            #"TXT decode failed; bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}, attempted=UTF-8/BOM-Unicode/GB18030/GBK/Big5/Shift_JIS"#,
            #"TXT decode succeeded; bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
            #"TXT chapter detection fell back to full text; lines=[0-9]{1,12}, headings=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
            #"TXT chapters parsed; lines=[0-9]{1,12}, chapters=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
        ],
        "novel-download": [
            #"Novel EPUB request failed before receiving an HTTP response; domain=(?:NSURLErrorDomain|NSCocoaErrorDomain|NSPOSIXErrorDomain), code=-?[0-9]{1,8}, elapsedMs=[0-9]{1,12}"#,
            #"Novel EPUB request returned HTTP [0-9]{3}; elapsedMs=[0-9]{1,12}"#,
            "Novel file response was empty",
            #"Novel EPUB download completed; bytes=[0-9]{1,12}, elapsedMs=[0-9]{1,12}"#,
        ],
        "epubcontainer": [#"TOC fallback generated entries=[0-9]{1,12}, embedded entries=[0-9]{1,12}"#],
    ]
    private static let expressions = patterns.mapValues { $0.compactMap { try? NSRegularExpression(pattern: "\\A(?:" + $0 + ")\\z") } }

    public static func message(subsystem: String, category: String, text: String) -> String? {
        guard subsystem == self.subsystem, text.utf8.count <= 512 else { return nil }
        // These events contain arbitrary engine/file details: export the event alone.
        if category == "enginediag", text.hasPrefix("ENGINE_DIAG ") {
            return "EPUB layout diagnostic occurred; details omitted for privacy"
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
