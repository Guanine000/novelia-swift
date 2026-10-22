import Foundation
import SwiftSoup

/// 把 libmobi 从旧版 MOBI（KF7／Mobipocket）重建的单个 HTML 整理成 EPUB 可用的 XHTML 章节。
///
/// 旧版 MOBI 的正文是 Mobipocket 方言的 HTML：标签不闭合、带 `mbp:` 前缀标签、`<head>` 里放 `<guide>`，
/// 整本书只有一个文件。Readium 按 XHTML 严格解析，原样放入会报错；整本放在一个章节里，
/// 原生分页每次也要排版全书。这里用 SwiftSoup 宽松解析，在 body 顶层的 `<mbp:pagebreak>` 处切分章节，
/// 去掉其余带前缀的标签（保留内容）与带前缀的属性，再按 XHTML 语法输出，并把书内链接改写到目标所在的章节文件。
///
/// 输出确定：相同输入得到相同文件名与内容。
enum KindleMOBI6Normalizer {
    struct Chapter: Equatable {
        let filename: String
        let xhtml: String
    }

    struct Result {
        let chapters: [Chapter]
        /// 锚点 id → 所在章节文件名，供 NCX／OPF 改写引用。
        let anchorFiles: [String: String]
    }

    /// `sourceFilename` 为 libmobi 输出的文件名（如 `part00000.html`）；首章沿用该名，后续章节追加序号。
    static func normalize(html: String, sourceFilename: String) throws -> Result {
        let source = try SwiftSoup.parse(html)
        try source.select("guide").remove()
        let title = try source.title()
        let headStyles = try source.head()?.select("style, link[rel]").array().filter { element in
            if element.tagName() == "style" { return true }
            return try element.attr("rel").lowercased().contains("stylesheet")
        } ?? []
        let bodyAttributes: [(String, String)] = source.body()?.getAttributes().map { attributes in
            attributes.map { ($0.getKey(), $0.getValue()) }.filter { !$0.0.contains(":") }
        } ?? []

        // 只在 body 顶层切分；嵌套在其他元素中的分页标记无法安全拆开，随其他前缀标签一起去掉。
        var segments: [[Node]] = [[]]
        for node in source.body()?.getChildNodes() ?? [] {
            if let element = node as? Element, element.tagName().lowercased() == "mbp:pagebreak" {
                segments.append([])
            } else {
                segments[segments.count - 1].append(node)
            }
        }
        // 只有空白或空锚点（如书尾的 `<a></a>`）的片段会成为空白章节，整段丢弃；其中的空锚点没有内容可跳，
        // 指向它们的链接保持原样。
        segments = segments.filter { nodes in
            nodes.contains { node in
                if let text = node as? TextNode { return !text.isBlank() }
                guard let element = node as? Element else { return false }
                return ((try? element.text()) ?? "").isEmpty == false
                    || ((try? element.select("img, image, svg, hr, table, object, video, audio").isEmpty()) == false)
                    || ["img", "image", "svg", "hr", "table", "object", "video", "audio"].contains(element.tagName().lowercased())
            }
        }
        if segments.isEmpty { segments = [[]] }

        let base = (sourceFilename as NSString).deletingPathExtension
        let ext = (sourceFilename as NSString).pathExtension
        let filenames = segments.indices.map { $0 == 0 ? sourceFilename : "\(base)-\(String(format: "%03d", $0)).\(ext)" }

        // 每章一份独立文档：节点移入后清理、收集锚点，输出时使用该文档的 XHTML 设置。
        var documents: [Document] = []
        var anchorFiles: [String: String] = [:]
        for (index, nodes) in segments.enumerated() {
            let document = try SwiftSoup.parse("<html><head></head><body></body></html>")
            document.outputSettings(OutputSettings().syntax(syntax: .xml).escapeMode(.xhtml)
                .prettyPrint(pretty: false).charset(.utf8))
            guard let body = document.body() else { continue }
            for node in nodes { try body.appendChild(node) }
            for (key, value) in bodyAttributes { try body.attr(key, value) }
            for style in headStyles { try document.head()?.appendChild(style.copy() as! Node) }
            try cleanPrefixedMarkup(in: body)
            try convertMobipocketFormatting(in: body)
            for element in try body.select("[id], a[name]").array() {
                for key in ["id", "name"] {
                    let value = try element.attr(key)
                    if !value.isEmpty, anchorFiles[value] == nil { anchorFiles[value] = filenames[index] }
                }
            }
            documents.append(document)
        }

        var chapters: [Chapter] = []
        for (index, document) in documents.enumerated() {
            guard let body = document.body() else { continue }
            for link in try body.select("a[href]").array() {
                let href = try link.attr("href")
                guard let target = rewrittenHref(href, sourceFilename: sourceFilename,
                                                 currentFile: filenames[index], anchorFiles: anchorFiles) else { continue }
                try link.attr("href", target)
            }
            let headInner = try document.head()?.html() ?? ""
            chapters.append(Chapter(
                filename: filenames[index],
                xhtml: "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                    + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head>"
                    + "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/>"
                    + "<title>\(escapeXML(title))</title>"
                    // Mobipocket 段落没有默认上下外边距，间距只由 height 属性给出（已转为 margin-top）；
                    // 放在书内样式之前，书内样式仍可覆盖。
                    + "<style type=\"text/css\">p { margin-top: 0; margin-bottom: 0; }</style>\(headInner)</head>"
                    + (try body.outerHtml()) + "</html>\n"))
        }
        return Result(chapters: chapters, anchorFiles: anchorFiles)
    }

    /// KF8 章节通常已是 XHTML；个别书不是合法 XML 时 Readium 会显示解析错误，
    /// 此时用 SwiftSoup 宽松解析后按 XHTML 重新输出（保留命名空间声明与属性，不分章）。合法时返回 nil、原样使用。
    static func repairedXHTML(_ html: String) throws -> String? {
        guard !XMLParser(data: Data(html.utf8)).parse() else { return nil }
        let document = try SwiftSoup.parse(html)
        document.outputSettings(OutputSettings().syntax(syntax: .xml).escapeMode(.xhtml)
            .prettyPrint(pretty: false).charset(.utf8))
        if let root = try document.select("html").first(), !root.hasAttr("xmlns") {
            try root.attr("xmlns", "http://www.w3.org/1999/xhtml")
        }
        try document.select("guide").remove()
        let markup = try document.getChildNodes()
            .filter { !($0 is XmlDeclaration) }
            .map { try $0.outerHtml() }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + markup + "\n"
    }

    /// 带命名空间前缀的标签（`mbp:`、Word 的 `o:` 等）在 XHTML 中没有声明，去掉标签保留内容；
    /// 带前缀的属性同理删除，`xml:lang` 除外。
    private static func cleanPrefixedMarkup(in root: Element) throws {
        for element in try root.select("*").array().reversed() {
            if element !== root, element.tagName().contains(":") {
                try element.unwrap()
                continue
            }
            let prefixed = element.getAttributes()?.map { $0.getKey() }
                .filter { $0.contains(":") && $0.lowercased() != "xml:lang" } ?? []
            for key in prefixed { try element.removeAttr(key) }
        }
    }

    /// Mobipocket 用属性表达排版：块元素的 `width` 是首行缩进（负值为悬挂缩进）、`height` 是段前间距、
    /// `align` 是对齐，`<font size/color/face>` 是字号颜色字体。两个阅读引擎都不把这些属性当排版，
    /// 首行缩进等会丢失，因此转成等价的内联样式（追加在已有 style 之后）。图片、表格的宽高不在此列。
    private static let blockTags: Set<String> = ["p", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "li", "dd", "dt"]
    private static let lengthPattern = try! NSRegularExpression(pattern: "^-?\\d+(\\.\\d+)?(em|ex|pt|px|%|in|cm|mm)?$")
    private static let fontSizes = ["x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"]

    private static func convertMobipocketFormatting(in root: Element) throws {
        for element in try root.select("*").array() {
            let tag = element.tagName().lowercased()
            var declarations: [String] = []
            if blockTags.contains(tag) {
                for (attribute, property) in [("width", "text-indent"), ("height", "margin-top")] {
                    guard element.hasAttr(attribute) else { continue }
                    if let length = cssLength(try element.attr(attribute)) { declarations.append("\(property): \(length)") }
                    try element.removeAttr(attribute)
                }
                if element.hasAttr("align") {
                    let align = try element.attr("align").lowercased()
                    if ["left", "right", "center", "justify"].contains(align) { declarations.append("text-align: \(align)") }
                    try element.removeAttr("align")
                }
            } else if tag == "font" {
                if element.hasAttr("size"), let size = fontSize(try element.attr("size")) { declarations.append("font-size: \(size)") }
                let color = try element.attr("color")
                if !color.isEmpty { declarations.append("color: \(color)") }
                let face = try element.attr("face")
                if !face.isEmpty { declarations.append("font-family: \(face)") }
                for attribute in ["size", "color", "face"] { try element.removeAttr(attribute) }
                try element.tagName("span")
            }
            guard !declarations.isEmpty else { continue }
            let existing = try element.attr("style").trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
            try element.attr("style", ([existing].filter { !$0.isEmpty } + declarations).joined(separator: "; "))
        }
    }

    /// 无单位的数值按像素处理。
    private static func cssLength(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard lengthPattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
        else { return nil }
        return trimmed.last?.isNumber == true ? trimmed + "px" : trimmed
    }

    /// HTML `<font size>`：1–7 或相对 3 的 +n／-n。
    private static func fontSize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let number = Int(trimmed.replacingOccurrences(of: "+", with: "")) else { return nil }
        let size = trimmed.hasPrefix("+") || trimmed.hasPrefix("-") ? 3 + number : number
        return fontSizes[min(max(size, 1), 7) - 1]
    }

    /// 书内锚点链接改为目标章节；同章节保持 `#id`。返回 nil 表示不需要改写。
    static func rewrittenHref(_ href: String, sourceFilename: String, currentFile: String,
                              anchorFiles: [String: String]) -> String? {
        let fragment: String
        if href.hasPrefix("#") {
            fragment = String(href.dropFirst())
        } else if href.hasPrefix(sourceFilename + "#") {
            fragment = String(href.dropFirst(sourceFilename.count + 1))
        } else {
            return nil
        }
        guard let file = anchorFiles[fragment] else { return nil }
        return file == currentFile ? "#\(fragment)" : "\(file)#\(fragment)"
    }

    /// 改写 NCX／OPF 中指向源文件锚点的 `src`／`href`。
    static func rewriteReferences(in text: String, sourceFilename: String, anchorFiles: [String: String]) -> String {
        guard !anchorFiles.isEmpty else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: sourceFilename)
        let regex = try! NSRegularExpression(pattern: "(src|href)=\"\(escaped)#([^\"]*)\"")
        let ns = text as NSString
        var output = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let attribute = ns.substring(with: match.range(at: 1))
            let fragment = ns.substring(with: match.range(at: 2))
            output += "\(attribute)=\"\(anchorFiles[fragment] ?? sourceFilename)#\(fragment)\""
            last = match.range.location + match.range.length
        }
        output += ns.substring(from: last)
        return output
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
