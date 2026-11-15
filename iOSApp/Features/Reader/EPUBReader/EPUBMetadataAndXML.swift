import Foundation
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif
import OSLog
import ReadiumZIPFoundation
import UIKit

// MARK: - EPUB 目录解析、路径工具、轻量 XML 与书库元数据

extension EPUBContainer {
    // nav/NCX 通常只出现在 manifest、不在 spine，因此一律从 manifest 定位。
    func buildTOC() async {
        // 1) EPUB3 nav：manifest 中 properties 含 "nav" 的条目。
        //    注意：nav 里的 href 相对 nav 文档所在目录解析（通常在 OPF 子目录）。
        let navItems = manifestByID.values.filter { $0.properties.contains("nav") }
        for navItem in navItems {
            guard let html = try? await chapterHTML(path: navItem.href) else { continue }
            let entries = Self.parseNavTOC(html: html)
            if !entries.isEmpty {
                let mapped = mapToSpine(entries, baseDirectory: Self.directory(of: navItem.href))
                Self.tocLog.info("TOC nav mapped; entries=\(entries.count, privacy: .public), mapped=\(mapped.filter { $0.spineIndex != nil }.count, privacy: .public)")
                if !mapped.isEmpty {
                    toc = await preferGeneratedTOCIfSparse(mapped)
                    return
                }
                tocDiagnostic = "nav 文档解析出 \(entries.count) 个条目，但没有一个能映射到 spine 章节"
                return
            }
        }
        if !navItems.isEmpty {
            tocDiagnostic = "manifest 含 nav 文档，但未解析出目录锚点（可能缺少 <nav epub:type=\"toc\">）"
        }

        // 2) EPUB2 NCX：manifest 中 media-type 为 application/x-dtbncx+xml 的条目。
        let ncxItems = manifestByID.values.filter {
            $0.mediaType.lowercased() == "application/x-dtbncx+xml"
        }
        for ncxItem in ncxItems {
            guard let data = await entryData(atPath: ncxItem.href),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let parsed = NCXParser.parse(xml: xml)
            if !parsed.isEmpty {
                let mapped = mapToSpine(parsed, baseDirectory: Self.directory(of: ncxItem.href))
                if !mapped.isEmpty {
                    toc = await preferGeneratedTOCIfSparse(mapped)
                    return
                }
                tocDiagnostic = "NCX 解析出 \(parsed.count) 个条目，但没有一个能映射到 spine 章节"
                return
            }
        }

        if toc.isEmpty {
            if navItems.isEmpty && ncxItems.isEmpty {
                tocDiagnostic = "manifest 中没有 nav（EPUB3）或 NCX（EPUB2）目录条目，本书可能没有内嵌目录"
            } else if tocDiagnostic == nil {
                tocDiagnostic = "目录文档存在但未能解析出条目"
            }
        }
    }

    /// 部分 EPUB 的 nav/NCX 在格式上有效，却只包含版权页或封面。
    /// 当该目录明显不完整时，从 spine 中恢复章节标题。
    private func preferGeneratedTOCIfSparse(_ embedded: [EPUBTOCEntry]) async -> [EPUBTOCEntry] {
        guard embedded.count <= 1 else { return embedded }
        let generated = await generateTOCFromSpineHeadings()
        guard generated.count > embedded.count else { return embedded }
        let embeddedTitle = embedded.map(\.title).joined(separator: "、")
        tocFallbackDiagnostic = "原书内嵌目录只有 \(embedded.count) 项（\(embeddedTitle)），已根据正文标题生成备用目录，共 \(generated.count) 项。"
        Self.tocLog.info("TOC fallback generated entries=\(generated.count), embedded entries=\(embedded.count)")
        return generated
    }

    private func generateTOCFromSpineHeadings() async -> [EPUBTOCEntry] {
        var entries: [EPUBTOCEntry] = []
        var seenTitles = Set<String>()
        for (spineIndex, item) in spine.enumerated() {
            guard item.mediaType.contains("xhtml") || item.mediaType.contains("html"),
                  let html = try? await chapterHTML(path: item.href),
                  let title = Self.fallbackTOCHeadings(inChapterHTML: html)
                      .first(where: { seenTitles.insert($0).inserted }) else { continue }
            entries.append(EPUBTOCEntry(title: title, spineIndex: spineIndex))
        }
        return entries
    }

    /// 备用目录候选：章节 XHTML 中形如「序章／第N章／终章／Epilogue」的段落标题，按出现顺序。
    /// 章节内可能出现类似后续标题的例子或链接，调用方每个章节只取第一个未用过的标题。
    /// YueduCoreText 与 Readium 阅读器共用此规则。
    static func fallbackTOCHeadings(inChapterHTML html: String) -> [String] {
        guard let headingPattern = try? NSRegularExpression(
            pattern: "^(?:序章|序幕|プロローグ|Prologue|第\\s*[0-9０-９一二三四五六七八九十百]+\\s*(?:章|话|話|节|節|回|幕)|终章|終章|尾声|後日譚|后日谈|终幕|終幕|エピローグ|Epilogue)",
            options: [.caseInsensitive]) else { return [] }
        return paragraphTexts(in: html).compactMap { paragraph in
            let range = NSRange(paragraph.startIndex..., in: paragraph)
            guard headingPattern.firstMatch(in: paragraph, range: range) != nil else { return nil }
            let title = paragraph
                .replacingOccurrences(of: "[\\s　]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
    }

    private static func paragraphTexts(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<p\\b[^>]*>([\\s\\S]*?)</p>", options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var text = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            text = XMLValueParser.decodeEntities(text)
                .replacingOccurrences(of: "[\\s　]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// 目录 href 相对其文档所在目录解析后映射到 spine。
    private func mapToSpine(_ entries: [(title: String, href: String, level: Int)],
                            baseDirectory: String) -> [EPUBTOCEntry] {
        entries.map { entry in
            let target = Self.isAbsoluteInPackage(entry.href)
                ? Self.normalizePath(String(entry.href.dropFirst()))
                : Self.normalizePath(baseDirectory + entry.href)
            let index = spine.firstIndex {
                Self.stripFragment($0.href) == Self.stripFragment(target)
            }
            return EPUBTOCEntry(title: entry.title, spineIndex: index, level: entry.level)
        }
    }

    private func chapterHTML(path: String) async throws -> String {
        guard let entry = await resolveEntry(path) else {
            throw EPUBError.missingChapter(path: path)
        }
        let data = try await Self.entryData(entry, from: archive)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        var discarded = 0
        return Self.stripScripts(from: text, counter: &discarded)
    }

    // MARK: nav 目录解析（正则提取 <a href>，限制见 EPUBContainer 文件头）

    static func parseNavTOC(html: String) -> [(title: String, href: String, level: Int)] {
        var block = html
        if let navStart = html.range(of: "<nav\\b[^>]*>", options: .regularExpression),
           let navEnd = html.range(of: "</nav>", range: navStart.upperBound..<html.endIndex) {
            block = String(html[navStart.lowerBound..<navEnd.upperBound])
        }
        guard let anchorRegex = try? NSRegularExpression(
            pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>") else {
            return []
        }
        // 层级 = 包含该锚点的外层 <li> 中本身带链接的个数。只有标题文字、没有链接的
        // 分组（<li><span>第一卷</span><ol>…）不计层级，避免把其子项挂到前一个兄弟条目下。
        let structureTags = (try? NSRegularExpression(pattern: "<(/?)(ol|ul|li)\\b[^>]*>", options: [.caseInsensitive]))?
            .matches(in: block, range: NSRange(location: 0, length: (block as NSString).length)) ?? []
        var result: [(String, String, Int)] = []
        let ns = block as NSString
        var tagCursor = 0
        var itemHasLink: [Bool] = []
        var listItemCounts: [Int] = []
        for match in anchorRegex.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
            while tagCursor < structureTags.count, structureTags[tagCursor].range.location < match.range.location {
                let tag = structureTags[tagCursor]
                let closing = tag.range(at: 1).length > 0
                let isItem = ns.substring(with: tag.range(at: 2)).lowercased() == "li"
                switch (isItem, closing) {
                case (true, false): itemHasLink.append(false)
                case (true, true): if !itemHasLink.isEmpty { itemHasLink.removeLast() }
                case (false, false): listItemCounts.append(itemHasLink.count)
                case (false, true):
                    // 列表结束时一并关闭其中漏写 </li> 的条目。
                    if let count = listItemCounts.popLast(), count < itemHasLink.count {
                        itemHasLink.removeLast(itemHasLink.count - count)
                    }
                }
                tagCursor += 1
            }
            let href = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            let title = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !href.isEmpty, !title.isEmpty {
                let level = itemHasLink.dropLast().filter { $0 }.count
                if !itemHasLink.isEmpty { itemHasLink[itemHasLink.count - 1] = true }
                result.append((XMLValueParser.decodeEntities(title), href, level))
            }
        }
        return result
    }

    /// 把书内链接 href（相对当前章节目录）解析为 spine 序号；解析不到返回 nil。
    /// 锚点（#fragment）不影响章定位；章内精确定位留待后续。
    func spineIndex(forLinkHref href: String, relativeTo chapterHref: String) -> Int? {
        let target: String
        if href.hasPrefix("#") {
            target = chapterHref
        } else if Self.isAbsoluteInPackage(href) {
            target = Self.normalizePath(String(href.dropFirst()))
        } else {
            target = Self.normalizePath(Self.directory(of: chapterHref) + href)
        }
        return spine.firstIndex { Self.stripFragment($0.href) == Self.stripFragment(target) }
    }

    // MARK: 路径工具

    static func isRelative(_ href: String) -> Bool {
        !(href.hasPrefix("http://") || href.hasPrefix("https://")
            || href.hasPrefix("data:") || href.hasPrefix("/") || href.hasPrefix("file:"))
    }

    static func normalizePath(_ path: String) -> String {
        var output: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." {
                if !output.isEmpty { output.removeLast() }
                continue
            }
            output.append(component)
        }
        return output.joined(separator: "/")
    }

    static func stripFragment(_ href: String) -> String {
        guard let hash = href.firstIndex(of: "#") else { return href }
        return String(href[..<hash])
    }

    static func directory(of href: String) -> String {
        guard let slash = href.lastIndex(of: "/") else { return "" }
        return String(href[...slash])
    }
}

// MARK: - 轻量 XML / HTML 值提取

enum XMLValueParser {
    /// 提取 `<name attr="...">` 开标签的属性表序列（自闭合与普通开标签均可）。
    static func openTagAttributes(_ name: String, in text: String) -> [[String: String]] {
        let pattern = "<" + NSRegularExpression.escapedPattern(for: name) + "\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var results: [[String: String]] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            results.append(attributes(of: tag))
        }
        return results
    }

    /// `<name attr="...">value</name>` 的属性值（如 rootfile full-path）。
    static func elementValue(_ name: String, attribute: String, xml: String) -> String? {
        let pattern = "<" + NSRegularExpression.escapedPattern(for: name)
            + "\\b[^>]*\\b" + NSRegularExpression.escapedPattern(for: attribute)
            + "\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return decodeEntities(ns.substring(with: match.range(at: 1)))
    }

    /// `<name ...>content</name>` 的内文。
    static func elementValue(_ name: String, xml: String) -> String? {
        let pattern = "<" + NSRegularExpression.escapedPattern(for: name) + "\\b[^>]*>([\\s\\S]*?)</"
            + NSRegularExpression.escapedPattern(for: name) + ">"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return decodeEntities(ns.substring(with: match.range(at: 1)))
    }

    /// `<name ...>content</name>` 块的内文序列。
    static func elementBlocks(_ name: String, in text: String) -> [String] {
        let pattern = "<" + NSRegularExpression.escapedPattern(for: name) + "\\b[^>]*>([\\s\\S]*?)</"
            + NSRegularExpression.escapedPattern(for: name) + ">"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// `<name attrs>text</name>` 元素序列：属性表 + 去除内嵌标签、解码实体并去空白后的文本（空文本跳过）。
    static func elements(_ name: String, in text: String) -> [(attributes: [String: String], text: String)] {
        let pattern = "(<" + NSRegularExpression.escapedPattern(for: name) + "\\b[^>]*(?<!/)>)([\\s\\S]*?)</"
            + NSRegularExpression.escapedPattern(for: name) + ">"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var inner = ns.substring(with: match.range(at: 2))
            if inner.hasPrefix("<![CDATA["), inner.hasSuffix("]]>") {
                inner = String(inner.dropFirst(9).dropLast(3))
            } else {
                inner = decodeEntities(inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            }
            let value = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : (attributes(of: ns.substring(with: match.range(at: 1))), value)
        }
    }

    /// EPUB3 `<meta refines="#id" property="p">value</meta>`：id → (property → 第一个 value)。
    static func metaRefines(in text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for element in elements("meta", in: text) {
            guard let target = element.attributes["refines"], target.hasPrefix("#"),
                  let property = element.attributes["property"] else { continue }
            let id = String(target.dropFirst())
            if result[id]?[property] == nil { result[id, default: [:]][property] = element.text }
        }
        return result
    }

    private static func attributes(of tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: "([\\w:-]+)\\s*=\\s*[\"']([^\"']*)[\"']") else { return [:] }
        let ns = tag as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            result[key] = decodeEntities(ns.substring(with: match.range(at: 2)))
        }
        return result
    }

    static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - 书库元数据（导入时读取，不排版）

/// 书库列表所需的 EPUB 元数据。选择规则与此前使用的 Readium OPF 解析一致：
/// 标题取 title-type=main 的 dc:title，否则第一个 dc:title；作者为角色是 aut 或未知/缺省的
/// dc:creator；封面为 EPUB2 `<meta name="cover">` 或 EPUB3 `cover-image` 指向的 manifest 条目。
struct EPUBMetadata {
    var title: String?
    var description: String?
    var authors: [String]
    var cover: UIImage?
}

extension EPUBContainer {
    /// 只读 OPF 与封面图，不构建目录、不排版；失败返回 nil。
    static func metadata(fileURL: URL, coverMaxSize: CGSize) async -> EPUBMetadata? {
        guard let archive = try? await Archive(url: fileURL, accessMode: .read),
              let (opfXML, opfDirectory) = try? await packageDocument(in: archive) else { return nil }
        let metadataXML = metadataSection(of: opfXML)
        let refines = XMLValueParser.metaRefines(in: metadataXML)

        let knownRoles: Set = ["aut", "trl", "edt", "pbl", "art", "ill", "clr", "nrt"]
        let creators = XMLValueParser.elements("dc:creator", in: metadataXML).nonEmpty
            ?? XMLValueParser.elements("creator", in: metadataXML)
        let authors = creators.compactMap { element -> String? in
            let role = element.attributes["id"].flatMap { refines[$0]?["role"] }
                ?? element.attributes["opf:role"] ?? element.attributes["role"]
            if let role, knownRoles.contains(role), role != "aut" { return nil }
            return element.text
        }

        var cover: UIImage?
        let coverID = XMLValueParser.openTagAttributes("meta", in: metadataXML)
            .first { $0["name"] == "cover" }?["content"]
        let coverItem = XMLValueParser.openTagAttributes("item", in: opfXML).first { item in
            (coverID != nil && item["id"] == coverID)
                || (item["properties"] ?? "").split(separator: " ").contains("cover-image")
        }
        if let href = coverItem?["href"] {
            let path = normalizePath(opfDirectory + href)
            var entry = try? await archive.get(path)
            if entry == nil, let decoded = path.removingPercentEncoding { entry = try? await archive.get(decoded) }
            if let entry, let data = try? await entryData(entry, from: archive), let image = UIImage(data: data) {
                cover = scaledCover(image, maxSize: coverMaxSize)
            }
        }

        return EPUBMetadata(
            title: mainTitle(inMetadata: metadataXML),
            description: (XMLValueParser.elements("dc:description", in: metadataXML).first
                ?? XMLValueParser.elements("description", in: metadataXML).first)?.text,
            authors: authors,
            cover: cover
        )
    }

    /// OPF 的 `<metadata>` 段；缺失时退回整个 OPF。
    static func metadataSection(of opfXML: String) -> String {
        XMLValueParser.elementBlocks("metadata", in: opfXML).first
            ?? XMLValueParser.elementBlocks("opf:metadata", in: opfXML).first
            ?? opfXML
    }

    /// 书名：`title-type=main` 的 dc:title，否则第一个 dc:title。阅读器与书库共用同一规则。
    static func mainTitle(inMetadata metadataXML: String) -> String? {
        let refines = XMLValueParser.metaRefines(in: metadataXML)
        let titles = XMLValueParser.elements("dc:title", in: metadataXML).nonEmpty
            ?? XMLValueParser.elements("title", in: metadataXML)
        return (titles.first { element in
            element.attributes["id"].flatMap { refines[$0]?["title-type"] } == "main"
        } ?? titles.first)?.text
    }

    /// 按像素等比缩小到 maxSize 以内，不放大（输出 scale 为 1）。
    private static func scaledCover(_ image: UIImage, maxSize: CGSize) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image }
        let ratio = min(maxSize.width / pixelSize.width, maxSize.height / pixelSize.height, 1)
        if ratio == 1, image.scale == 1 { return image }
        let renderSize = CGSize(width: pixelSize.width * ratio, height: pixelSize.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: renderSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
