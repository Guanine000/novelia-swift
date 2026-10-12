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
    private let units: [Unit]
    private var cache: [Int: String] = [:]

    init(bookTitle: String, units: [Unit]) {
        self.bookTitle = bookTitle
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

    /// TOC entry containing a unit (the last entry starting at or before it).
    func tocEntry(containingUnit unit: Int) -> Int? {
        toc.lastIndex { ($0.spineIndex ?? .max) <= unit }
    }
}

extension TextChapterSource {
    /// Long TXT chapters (or a whole book without headings) are split at paragraph
    /// boundaries so one layout never holds megabytes of text. Only the first unit of a
    /// chapter carries its heading and TOC entry.
    static func units(splitting chapters: [TextChapterContent], maximumUTF16: Int = 12_000) -> [Unit] {
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

/// Local paged position for a TXT file. A different unit count (changed chapter rules)
/// invalidates the offset, which is only meaningful for the same units.
struct TXTPagedPosition: Codable, Equatable {
    var unit: Int
    var offset: Int?
    var unitCount: Int

    static func key(hash: String) -> String { "txtPagedPosition.v1.\(hash)" }

    static func load(key: String, unitCount: Int, defaults: UserDefaults = .standard) -> TXTPagedPosition? {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(TXTPagedPosition.self, from: data),
              saved.unitCount == unitCount, (0..<unitCount).contains(saved.unit) else { return nil }
        return saved
    }

    static func save(_ position: TXTPagedPosition, key: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(position) { defaults.set(data, forKey: key) }
    }
}
