import Foundation
import UIKit

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

/// One paragraph of generated chapter text. `secondary` uses the muted reader colour
/// (bilingual translations); `note` is a centred status line such as a missing translation.
struct TextChapterParagraph: Equatable {
    enum Role: Equatable { case body, secondary, note }
    var text: String
    var role: Role = .body
}

struct TextChapterContent: Equatable {
    var title: String?
    var subtitle: String?
    var paragraphs: [TextChapterParagraph]
}

enum TextChapterXHTML {
    /// Escapes user text for XHTML. Characters XML forbids (most C0 controls) are dropped,
    /// so arbitrary TXT bytes cannot break the document.
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
            body.append("<p\(attribute)>\(escape(paragraph.text))</p>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head><body>
        \(body.joined(separator: "\n"))
        </body></html>
        """
    }

    /// Reader stylesheet for generated chapters. Colours follow the theme text colour.
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
        """
    }

    /// Splits text into paragraphs: one per non-blank line, leading and trailing
    /// whitespace (including the full-width indent many TXT files use) removed.
    static func paragraphs(fromLines text: String, role: TextChapterParagraph.Role = .body) -> [TextChapterParagraph] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{3000}")))
            return trimmed.isEmpty ? nil : TextChapterParagraph(text: trimmed, role: role)
        }
    }
}

/// Chapters produced in memory or loaded on demand, laid out by the EPUB page book.
/// `load` runs once per unit; a failed load is retried on the next request.
final class TextChapterSource: EPUBChapterSource {
    struct Unit {
        let tocTitle: String?
        let load: @MainActor () async throws -> TextChapterContent
    }

    let bookTitle: String
    let toc: [EPUBTOCEntry]
    var themeTextColor: UIColor = .black
    /// Stable identity of the generated content (a TXT file hash + chapter rules). Set only
    /// when the same identity always yields the same chapters; it lets layouts be cached
    /// across reader sessions. `nil` (online chapters) keeps layouts private to one session.
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

    /// Index of the unit a TOC entry starts at, for chapter-level positions.
    func firstUnit(ofTOCEntry entry: Int) -> Int? {
        toc.indices.contains(entry) ? toc[entry].spineIndex : nil
    }

    /// TOC entry containing a unit (the last entry starting at or before it). Entries are
    /// built in unit order, so this is a binary search; it runs on every page turn.
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
    /// Long TXT chapters (or a whole book without headings) are split at paragraph
    /// boundaries so one layout never holds megabytes of text. Only the first unit of a
    /// chapter carries its heading and TOC entry.
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

/// A chapter's raw text before paragraph splitting (TXT).
struct TextChapterBody {
    var title: String?
    var subtitle: String?
    var body: String
}

extension TextChapterSource {
    /// Like `units(splitting:)`, but opening only scans each body's UTF-8 bytes for line
    /// breaks to place unit boundaries; paragraphs are built when a unit is laid out. A
    /// 9 MB TXT then opens without creating hundreds of thousands of paragraph strings.
    /// Units hold about `maximumUTF8` bytes of text and always end at a line break.
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
    /// Byte offsets where units start (always 0 first, the body length last). Units end at a
    /// line break once they would exceed `maximumUTF8` bytes of line text.
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

/// Where a TXT file was last read, shared by the scroll and paged readers and keyed by
/// file content (SHA-256). `chapter` is the TXT chapter index; the paged unit and text
/// offset refine it only while they belong to the same units (same unit count) and chapter.
struct TXTReadingPosition: Codable, Equatable {
    var chapter: Int
    var unit: Int?
    var offset: Int?
    var unitCount: Int?

    static func key(hash: String) -> String { "txtReadingPosition.v1.\(hash)" }

    static func load(hash: String, defaults: UserDefaults = .standard) -> TXTReadingPosition? {
        defaults.data(forKey: key(hash: hash)).flatMap { try? JSONDecoder().decode(TXTReadingPosition.self, from: $0) }
    }

    func save(hash: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(hash: hash)) }
    }

    /// The scroll reader moved to `chapter`; a paged location inside it is kept.
    func movingToChapter(_ chapter: Int) -> TXTReadingPosition {
        chapter == self.chapter ? self : TXTReadingPosition(chapter: chapter)
    }

    /// Unit and offset the paged reader opens at: the saved page when it is still valid,
    /// otherwise the first unit of the saved chapter.
    @MainActor
    func pagedStart(in source: TextChapterSource) -> (unit: Int, offset: Int?) {
        if let unit, unitCount == source.chapterCount, (0..<source.chapterCount).contains(unit),
           source.tocEntry(containingUnit: unit) == chapter {
            return (unit, offset)
        }
        return (source.firstUnit(ofTOCEntry: min(max(chapter, 0), max(source.toc.count - 1, 0))) ?? 0, nil)
    }
}
