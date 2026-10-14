import Foundation
import UIKit
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

// MARK: - 章节来源
//
// EPUBPageBook 与 EPUBReaderModel 只依赖这一接口：EPUB 容器、TXT 与在线小说都把
// 章节交成 XHTML + CSS，由同一套 YueduCoreText 分页、位图缓存与翻页手势显示。

@MainActor
protocol EPUBChapterSource: AnyObject {
    var bookTitle: String { get }
    /// 分页单位（EPUB 的 spine 项；TXT 的长章会拆成多个单位）。
    var chapterCount: Int { get }
    var toc: [EPUBTOCEntry] { get }
    /// 主题正文颜色；排版前由阅读模型同步。
    var themeTextColor: UIColor { get set }
    func chapterHref(at index: Int) -> String
    func chapterHTML(at index: Int) async throws -> String
    func cssTexts(forChapterHTML html: String, chapterHref: String, aspectRatio: CGFloat) async -> [String]
    func images(forChapterHTML html: String, chapterHref: String) async -> [String: UIImage]
    func spineIndex(forLinkHref href: String, relativeTo chapterHref: String) -> Int?
}

extension EPUBContainer: EPUBChapterSource {
    var chapterCount: Int { spine.count }
    func chapterHref(at index: Int) -> String { spine[index].href }
}

// MARK: - 纯文本章节（TXT / 在线小说）

/// 生成章节文本中的一个段落。`secondary` 使用较淡的阅读器文字色
/// （用于双语译文）；`note` 是居中的状态提示，例如缺少译文。
struct TextChapterParagraph: Equatable {
    enum Role: Equatable { case body, secondary, note }
    var text: String
    var role: Role = .body
}

struct TextChapterContent: Equatable {
    var title: String?
    var subtitle: String?
    var paragraphs: [TextChapterParagraph]
    /// 在线正文：与滚动阅读器一样，将 http(s) URL 转为链接。
    var linksURLs = false
}

enum TextChapterXHTML {
    /// 将用户文本转义为 XHTML。丢弃 XML 禁止的字符（多数 C0 控制字符），
    /// 避免任意 TXT 字节破坏文档结构。
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(" ")
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func document(_ content: TextChapterContent) -> String {
        var body: [String] = []
        if let subtitle = content.subtitle, !subtitle.isEmpty {
            body.append("<p class=\"subtitle\">\(escape(subtitle))</p>")
        }
        if let title = content.title, !title.isEmpty {
            body.append("<h1>\(escape(title))</h1>")
        }
        for paragraph in content.paragraphs where !paragraph.text.isEmpty {
            let attribute: String
            switch paragraph.role {
            case .body: attribute = ""
            case .secondary: attribute = " class=\"secondary\""
            case .note: attribute = " class=\"note\""
            }
            let text = content.linksURLs ? linked(paragraph.text) : escape(paragraph.text)
            body.append("<p\(attribute)>\(text)</p>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head><body>
        \(body.joined(separator: "\n"))
        </body></html>
        """
    }

    /// 转义文本，并将 http(s) URL 包装为链接。仅检测到的 URL 用作 href。
    static func linked(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return escape(text)
        }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  match.range.location >= cursor else { continue }
            result += escape(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            result += "<a href=\"\(escape(url.absoluteString))\">\(escape(source.substring(with: match.range)))</a>"
            cursor = match.range.location + match.range.length
        }
        return result + escape(source.substring(from: cursor))
    }

    /// 生成章节使用的阅读器样式表，颜色跟随主题文字色。
    static func css(textColor: UIColor) -> String {
        let (r, g, b) = textColor.rgbComponents
        let isLightText = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) > 127.5
        let secondary = isLightText ? "#ADADB5" : "#6B6B70"
        return """
        body { color: \(String(format: "#%02X%02X%02X", r, g, b)); }
        h1 { font-size: 1.35em; font-weight: bold; line-height: 1.4; margin: 0.4em 0 1.2em 0; text-indent: 0; }
        p { text-indent: 2em; line-height: 1.75; margin: 0 0 0.55em 0; text-align: justify; }
        p.subtitle { font-size: 0.75em; color: #3C8F68; text-indent: 0; margin: 0; }
        p.secondary { color: \(secondary); }
        p.note { color: \(secondary); font-size: 0.85em; text-indent: 0; text-align: center; margin: 1em 0; }
        a { color: \(isLightText ? "#64A8F0" : "#1F6FC5"); text-decoration: underline; }
        """
    }

    /// 将文本拆分为段落：每个非空行一个段落，移除首尾空白
    /// （包括许多 TXT 文件使用的全角缩进）。
    static func paragraphs(fromLines text: String, role: TextChapterParagraph.Role = .body) -> [TextChapterParagraph] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{3000}")))
            return trimmed.isEmpty ? nil : TextChapterParagraph(text: trimmed, role: role)
        }
    }
}

/// 在内存中生成或按需加载的章节，由 EPUB 分页书籍对象排版。
/// 每个单元的 `load` 运行一次；加载失败时在下次请求中重试。
final class TextChapterSource: EPUBChapterSource {
    struct Unit {
        let tocTitle: String?
        let load: @MainActor () async throws -> TextChapterContent
    }

    let bookTitle: String
    let toc: [EPUBTOCEntry]
    var themeTextColor: UIColor = .black
    /// 生成内容的稳定身份（TXT 文件哈希 + 章节规则）。仅在相同身份
    /// 始终生成相同章节时设置，以便跨阅读器会话缓存排版结果。
    /// `nil`（在线章节）使排版结果仅在当前会话内使用。
    let layoutIdentity: String?
    private let units: [Unit]
    private var cache: [Int: String] = [:]

    init(bookTitle: String, units: [Unit], layoutIdentity: String? = nil) {
        self.bookTitle = bookTitle
        self.layoutIdentity = layoutIdentity
        self.units = units
        toc = units.enumerated().compactMap { index, unit in
            unit.tocTitle.map { EPUBTOCEntry(title: $0, spineIndex: index) }
        }
    }

    var chapterCount: Int { units.count }

    func chapterHref(at index: Int) -> String { "chapter-\(index).xhtml" }

    func chapterHTML(at index: Int) async throws -> String {
        if let cached = cache[index] { return cached }
        let html = TextChapterXHTML.document(try await units[index].load())
        cache[index] = html
        return html
    }

    func cssTexts(forChapterHTML html: String, chapterHref: String, aspectRatio: CGFloat) async -> [String] {
        [TextChapterXHTML.css(textColor: themeTextColor)]
    }

    func images(forChapterHTML html: String, chapterHref: String) async -> [String: UIImage] { [:] }

    func spineIndex(forLinkHref href: String, relativeTo chapterHref: String) -> Int? { nil }

    /// 目录项起始单元的序号，用于章节级阅读位置。
    func firstUnit(ofTOCEntry entry: Int) -> Int? {
        toc.indices.contains(entry) ? toc[entry].spineIndex : nil
    }

    /// 包含某个单元的目录项（起始单元不晚于它的最后一项）。目录项
    /// 按单元顺序构建，因此使用二分查找；每次翻页时都会调用。
    func tocEntry(containingUnit unit: Int) -> Int? {
        var low = 0, high = toc.count
        while low < high {
            let middle = (low + high) / 2
            if (toc[middle].spineIndex ?? .max) <= unit { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }
}

extension TextChapterSource {
    /// 在段落边界拆分长 TXT 章节（或没有标题的整本书），
    /// 避免一次排版持有数兆字节文本。仅章节的第一个单元
    /// 包含标题和目录项。
    nonisolated static func units(splitting chapters: [TextChapterContent], maximumUTF16: Int = 12_000) -> [Unit] {
        var units: [Unit] = []
        for chapter in chapters {
            var parts: [[TextChapterParagraph]] = [[]]
            var length = 0
            for paragraph in chapter.paragraphs {
                let count = paragraph.text.utf16.count
                if length > 0, length + count > maximumUTF16 {
                    parts.append([])
                    length = 0
                }
                parts[parts.count - 1].append(paragraph)
                length += count
            }
            for (index, paragraphs) in parts.enumerated() {
                let content = TextChapterContent(
                    title: index == 0 ? chapter.title : nil,
                    subtitle: index == 0 ? chapter.subtitle : nil,
                    paragraphs: paragraphs)
                units.append(Unit(tocTitle: index == 0 ? (chapter.title ?? "") : nil, load: { content }))
            }
        }
        return units
    }
}

/// 拆分段落之前的章节原始文本（TXT）。
struct TextChapterBody {
    var title: String?
    var subtitle: String?
    var body: String
}

extension TextChapterSource {
    /// 类似 `units(splitting:)`，但打开时仅扫描各正文的 UTF-8 字节，
    /// 根据换行确定单元边界；段落在单元排版时才构建。
    /// 因此打开 9 MB TXT 时无需创建数十万个段落字符串。
    /// 单元约包含 `maximumUTF8` 字节文本，始终在换行处结束。
    nonisolated static func units(lazilySplitting chapters: [TextChapterBody], maximumUTF8: Int = 36_000) -> [Unit] {
        var units: [Unit] = []
        for chapter in chapters {
            var contiguous = chapter.body
            contiguous.makeContiguousUTF8()
            let body = contiguous
            let offsets = Self.unitCuts(utf8: body.utf8, maximumUTF8: maximumUTF8)
            let cuts = offsets.map { body.utf8.index(body.utf8.startIndex, offsetBy: $0) }
            for part in 0..<(cuts.count - 1) {
                let range = cuts[part]..<cuts[part + 1]
                let first = part == 0
                units.append(Unit(tocTitle: first ? (chapter.title ?? "") : nil) {
                    TextChapterContent(title: first ? chapter.title : nil, subtitle: first ? chapter.subtitle : nil,
                                       paragraphs: TextChapterXHTML.paragraphs(fromLines: String(body[range])))
                })
            }
        }
        return units
    }
}

extension TextChapterSource {
    /// 单元起始字节偏移量（首项始终为 0，末项为正文长度）。行文本
    /// 即将超过 `maximumUTF8` 字节时，单元在换行处结束。
    nonisolated static func unitCuts(utf8: String.UTF8View, maximumUTF8: Int) -> [Int] {
        let scan: (UnsafeBufferPointer<UInt8>) -> [Int] = { bytes in
            var cuts = [0]
            var unitBytes = 0
            var lineStart = 0
            for index in 0...bytes.count {
                guard index == bytes.count || bytes[index] == 0x0A || bytes[index] == 0x0D else { continue }
                let lineBytes = index - lineStart
                if lineBytes > 0 {
                    if unitBytes > 0, unitBytes + lineBytes > maximumUTF8 {
                        cuts.append(lineStart)
                        unitBytes = 0
                    }
                    unitBytes += lineBytes
                }
                lineStart = index + 1
            }
            cuts.append(bytes.count)
            return cuts
        }
        return utf8.withContiguousStorageIfAvailable(scan) ?? Array(utf8).withUnsafeBufferPointer(scan)
    }
}

/// TXT 最近阅读的位置，由滚动和分页阅读器共享，以文件内容
/// （SHA-256）为键。`chapter` 是 TXT 章节序号；仅在分页单元及文本偏移量
/// 仍属于相同单元划分（单元总数相同）和章节时，用它们进一步定位。
extension TXTReadingPosition {
    /// 分页阅读器打开时使用的单元和偏移量：保存的页面仍有效时使用它，
    /// 否则使用保存章节的第一个单元。
    @MainActor
    func pagedStart(in source: TextChapterSource) -> (unit: Int, offset: Int?) {
        if let unit, unitCount == source.chapterCount, (0..<source.chapterCount).contains(unit),
           source.tocEntry(containingUnit: unit) == chapter {
            return (unit, offset)
        }
        return (source.firstUnit(ofTOCEntry: min(max(chapter, 0), max(source.toc.count - 1, 0))) ?? 0, nil)
    }
}
