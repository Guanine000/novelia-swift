import Foundation
import OSLog
import ReadiumZIPFoundation
import UIKit

// MARK: - 最小 EPUB 容器解析（原型专用）
//
// 职责划分参考 Yuedu-reader：YueduCoreText 只负责 HTML/CSS 排版与绘制；
// EPUB ZIP / container.xml / OPF / spine / 资源装载由宿主完成。
// 本文件是原型的最小自给实现，不依赖 Readium 解析器，仅复用其 ZIPFoundation fork。
// 已知原型限制（迁移前需替换为正式解析器）：
// - nav 目录锚点、章节 CSS/图片引用使用正则提取，未做完整 HTML 解析；
// - 不处理加密内容、固定布局属性与 media overlay；
// - 文本编码仅尝试 UTF-8 与 Latin-1 回退。

struct PrototypeTOCEntry: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let spineIndex: Int?
}

struct PrototypeSpineItem: Equatable {
    let href: String       // 归一化后的 ZIP 内路径
    let mediaType: String
    let properties: [String]
}

enum PrototypeEPUBError: LocalizedError {
    case cannotOpenArchive
    case missingContainer
    case missingOPF
    case emptySpine

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: "无法打开 EPUB 压缩包。"
        case .missingContainer: "缺少 META-INF/container.xml。"
        case .missingOPF: "EPUB 缺少有效的 OPF 包描述文件。"
        case .emptySpine: "EPUB 的 spine 为空，没有可阅读章节。"
        }
    }
}

final class PrototypeEPUBContainer {
    static let tocLog = Logger(subsystem: "cc.novelia.ios.port", category: "epubcontainer")
    let fileURL: URL
    let bookTitle: String
    let author: String?
    let spine: [PrototypeSpineItem]
    private(set) var toc: [PrototypeTOCEntry] = []

    private let archive: Archive
    private let opfDirectory: String      // ZIP 内 OPF 目录（含结尾 /，根为 ""）
    private let manifestByID: [String: PrototypeSpineItem]
    /// 目录为空时的可诊断原因。
    private(set) var tocDiagnostic: String?

    private init(fileURL: URL, archive: Archive, opfDirectory: String,
                 bookTitle: String, author: String?, spine: [PrototypeSpineItem],
                 manifestByID: [String: PrototypeSpineItem]) {
        self.fileURL = fileURL
        self.archive = archive
        self.opfDirectory = opfDirectory
        self.bookTitle = bookTitle
        self.author = author
        self.spine = spine
        self.manifestByID = manifestByID
    }

    static func open(fileURL: URL) async throws -> PrototypeEPUBContainer {
        guard let archive = try? await Archive(url: fileURL, accessMode: .read) else {
            throw PrototypeEPUBError.cannotOpenArchive
        }

        // 1. container.xml → rootfile
        guard let containerEntry = try? await archive.get("META-INF/container.xml"),
              let containerXML = try? await entryText(containerEntry, from: archive) else {
            throw PrototypeEPUBError.missingContainer
        }
        guard let rootPath = XMLValueParser.elementValue("rootfile", attribute: "full-path", xml: containerXML),
              !rootPath.isEmpty else {
            throw PrototypeEPUBError.missingOPF
        }

        // 2. OPF → metadata / manifest / spine
        guard let opfEntry = try? await archive.get(rootPath),
              let opfXML = try? await entryText(opfEntry, from: archive) else {
            throw PrototypeEPUBError.missingOPF
        }
        let opfDirectory = rootPath.contains("/")
            ? String(rootPath[...(rootPath.lastIndex(of: "/")!)])
            : ""

        let bookTitle = (XMLValueParser.elementValue("dc:title", xml: opfXML)
            ?? XMLValueParser.elementValue("title", xml: opfXML))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (XMLValueParser.elementValue("dc:creator", xml: opfXML)
            ?? XMLValueParser.elementValue("creator", xml: opfXML))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var manifest: [String: PrototypeSpineItem] = [:]
        for attributes in XMLValueParser.openTagAttributes("item", in: opfXML) {
            guard let id = attributes["id"], let href = attributes["href"] else { continue }
            let properties = (attributes["properties"] ?? "")
                .split(separator: " ").map(String.init)
            manifest[id] = PrototypeSpineItem(
                href: normalizePath(opfDirectory + href),
                mediaType: attributes["media-type"] ?? "",
                properties: properties
            )
        }

        var spineItems: [PrototypeSpineItem] = []
        for attributes in XMLValueParser.openTagAttributes("itemref", in: opfXML) {
            guard let idref = attributes["idref"], let item = manifest[idref] else { continue }
            spineItems.append(item)
        }
        let readable = spineItems.filter {
            $0.mediaType.contains("xhtml") || $0.mediaType.contains("html")
        }
        guard !readable.isEmpty else { throw PrototypeEPUBError.emptySpine }

        let container = PrototypeEPUBContainer(
            fileURL: fileURL, archive: archive, opfDirectory: opfDirectory,
            bookTitle: bookTitle ?? fileURL.deletingPathExtension().lastPathComponent,
            author: author, spine: readable,
            manifestByID: manifest
        )
        await container.buildTOC()
        return container
    }

    // MARK: 资源访问

    private static func entryData(_ entry: Entry, from archive: Archive) async throws -> Data {
        var data = Data()
        let consumer: Consumer = { chunk in
            data.append(chunk)
        }
        _ = try await archive.extract(entry, consumer: consumer)
        return data
    }

    private static func entryText(_ entry: Entry, from archive: Archive) async throws -> String {
        let data = try await entryData(entry, from: archive)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    func entryData(atPath path: String) async -> Data? {
        guard let entry = await resolveEntry(path) else { return nil }
        return try? await Self.entryData(entry, from: archive)
    }

    /// 稳健的条目解析：精确路径 → 百分号解码 → 大小写不敏感匹配。
    /// 真实 EPUB（尤其日文书）常用 URL 编码的图片路径，ZIP 内条目名是解码后的。
    private func resolveEntry(_ path: String) async -> Entry? {
        let normalized = Self.normalizePath(path)
        if let entry = try? await archive.get(normalized) { return entry }
        // 百分号解码回退（逐层尝试，防止双重编码）。
        var decoded = normalized
        for _ in 0..<2 {
            guard let step = decoded.removingPercentEncoding, step != decoded else { break }
            decoded = step
            if let entry = try? await archive.get(decoded) { return entry }
        }
        // 大小写不敏感回退：扫描全部条目（缓存）。
        let entries = await allEntries()
        let lowered = normalized.lowercased()
        if let match = entries.first(where: { $0.path.lowercased() == lowered }) {
            return match
        }
        let loweredDecoded = decoded.lowercased()
        if let match = entries.first(where: { $0.path.lowercased() == loweredDecoded }) {
            return match
        }
        return nil
    }

    private var entryPathCache: [Entry]?
    private func allEntries() async -> [Entry] {
        if let entryPathCache { return entryPathCache }
        let list = (try? await archive.entries()) ?? []
        entryPathCache = list
        return list
    }

    /// 主题正文色：opacity 改写按其 RGB 换算（浅色黑、深色近白，由模型在换主题时同步）。
    var themeTextColor: UIColor = .black

    /// 已从章节中剥离的 `<script>` 数量（脚本无法渲染，剥离是回退策略而非丢正文；
    /// 数量在目录页的诊断区可见）。
    private(set) var strippedScriptCount = 0
    /// 已把 `opacity:X` 改写为等价文字 alpha 颜色的数量（引擎不支持 opacity 属性、
    /// 但支持 color 的 rgba alpha；当前主题为米色底黑字，故等价映射为黑色 alpha）。
    private(set) var opacityRewriteCount = 0
    /// 已按设备条件求值的 @media 规则块数量（引擎不支持 media queries；
    /// print/amzn-mobi 丢弃，not amzn-mobi 保留内容，aspect-ratio 按视口求值）。
    private(set) var mediaQueryRewriteCount = 0

    func chapterHTML(at index: Int) async throws -> String {
        guard spine.indices.contains(index) else { throw PrototypeEPUBError.emptySpine }
        guard let data = await entryData(atPath: spine[index].href) else {
            throw PrototypeEPUBError.missingOPF
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        var stripped = Self.stripScripts(from: text, counter: &strippedScriptCount)
        stripped = Self.rewriteOpacity(in: stripped, counter: &opacityRewriteCount,
                                       rgb: themeTextColor.rgbComponents)
        return stripped
    }

    /// `opacity:X` → `color:rgba(r,g,b,X)`（颜色取当前主题正文色）。
    /// 引擎 parseColor 支持 rgba 第 4 分量，但不支持 opacity 属性与 8 位 hex。
    static func rewriteOpacity(in html: String, counter: inout Int,
                               rgb: (Int, Int, Int)) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "opacity\\s*:\\s*([0-9.]+)", options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        counter += matches.count
        var result = html
        for match in matches.reversed() {
            let alpha = ns.substring(with: match.range(at: 1))
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: "color:rgba(\(rgb.0),\(rgb.1),\(rgb.2),\(alpha))")
            }
        }
        return result
    }

    /// 剥离 `<script>`（含自闭合写法）。脚本不产生可见正文，剥离后引擎的
    /// scripted-interactive 检查可通过；数量被记录，不静默。
    static func stripScripts(from html: String, counter: inout Int) -> String {
        var result = html
        let blockRegex = try? NSRegularExpression(pattern: "<script\\b[^>]*>[\\s\\S]*?</script\\s*>", options: [.caseInsensitive])
        let selfClosingRegex = try? NSRegularExpression(pattern: "<script\\b[^>]*/>", options: [.caseInsensitive])
        if let blockRegex {
            let ns = result as NSString
            let matches = blockRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                counter += matches.count
                result = blockRegex.stringByReplacingMatches(
                    in: result, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            }
        }
        if let selfClosingRegex {
            let ns = result as NSString
            let matches = selfClosingRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                counter += matches.count
                result = selfClosingRegex.stringByReplacingMatches(
                    in: result, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            }
        }
        return result
    }

    /// 章节需要的外部 CSS 文本：按 <link rel=stylesheet> 顺序 + 内联 <style>，@import 递归展开（深度 3）。
    /// 相对 href 一律相对**章节文件所在目录**解析（章节常在 OPF 子目录里，如 OEBPS/Text/）。
    /// aspectRatio（宽/高）用于对 @media 的 device-aspect-ratio 条件求值。
    func cssTexts(forChapterHTML html: String, chapterHref: String,
                  aspectRatio: CGFloat) async -> [String] {
        let chapterDirectory = Self.directory(of: chapterHref)
        var texts: [String] = []
        for attributes in XMLValueParser.openTagAttributes("link", in: html) {
            let rel = (attributes["rel"] ?? "").lowercased()
            guard rel.contains("stylesheet"), let href = attributes["href"] else { continue }
            let path = Self.isAbsoluteInPackage(href)
                ? Self.normalizePath(String(href.dropFirst()))
                : Self.normalizePath(chapterDirectory + href)
            if let css = await cssText(atPath: path, depth: 0, aspectRatio: aspectRatio) {
                texts.append(css)
            }
        }
        for block in XMLValueParser.elementBlocks("style", in: html) {
            var cleaned = block
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
            cleaned = Self.filterMediaQueries(in: cleaned, aspectRatio: aspectRatio,
                                              counter: &mediaQueryRewriteCount)
            texts.append(Self.rewriteOpacity(in: cleaned, counter: &opacityRewriteCount,
                                             rgb: themeTextColor.rgbComponents))
        }
        return texts
    }

    private func cssText(atPath path: String, depth: Int, aspectRatio: CGFloat) async -> String? {
        guard depth < 3 else { return nil }
        guard let data = await entryData(atPath: path),
              var css = String(data: data, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "@import\\s+(?:url\\(\\s*)?[\"']?([^\"')\\s;]+)") else {
            return finish(css: css, aspectRatio: aspectRatio, mediaCounter: &mediaQueryRewriteCount)
        }
        let ns = css as NSString
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            let importedHref = ns.substring(with: match.range(at: 1))
            let importedPath = Self.isAbsoluteInPackage(importedHref)
                ? Self.normalizePath(String(importedHref.dropFirst()))
                : Self.normalizePath(Self.directory(of: path) + importedHref)
            let imported = await cssText(atPath: importedPath, depth: depth + 1, aspectRatio: aspectRatio) ?? ""
            css = (css as NSString).replacingCharacters(in: match.range, with: imported)
        }
        return finish(css: css, aspectRatio: aspectRatio, mediaCounter: &mediaQueryRewriteCount)
    }

    private func finish(css: String, aspectRatio: CGFloat, mediaCounter: inout Int) -> String {
        var result = Self.filterMediaQueries(in: css, aspectRatio: aspectRatio, counter: &mediaCounter)
        result = Self.rewriteOpacity(in: result, counter: &opacityRewriteCount,
                                     rgb: themeTextColor.rgbComponents)
        return result
    }

    /// @media 按设备条件求值：匹配的规则块替换为其内容，不匹配的整块移除。
    /// 支持 print（丢弃）、amzn-mobi（Kindle 专用，丢弃）、not amzn-mobi（保留）、
    /// (min|max)-device-aspect-ratio:A/B（按视口宽高比求值）；未知查询保守丢弃（基础样式保留）。
    static func filterMediaQueries(in css: String, aspectRatio: CGFloat,
                                   counter: inout Int) -> String {
        var result = css
        while let mediaStart = result.range(of: "@media", options: .caseInsensitive) {
            // prelude 到 {，再用括号深度找配对的 }。
            guard let braceStart = result[mediaStart.lowerBound...].firstIndex(of: "{") else { break }
            let query = String(result[mediaStart.upperBound..<braceStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            var depth = 0
            var closeIndex: String.Index?
            var cursor = braceStart
            while cursor < result.endIndex {
                let ch = result[cursor]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { closeIndex = cursor; break }
                }
                cursor = result.index(after: cursor)
            }
            guard let close = closeIndex else { break }
            let inner = String(result[result.index(after: braceStart)..<close])
            counter += 1
            let replacement = Self.evaluateMediaQuery(query, aspectRatio: aspectRatio) ? inner : ""
            result.replaceSubrange(mediaStart.lowerBound...close, with: replacement)
        }
        return result
    }

    private static func evaluateMediaQuery(_ raw: String, aspectRatio: CGFloat) -> Bool {
        let query = raw.lowercased()
        if query.contains("amzn-mobi") {
            return query.contains("not amzn-mobi")
        }
        if query.contains("print") && !query.contains("screen") {
            return false
        }
        if let range = query.range(of: "device-aspect-ratio\\s*:\\s*([0-9]+)\\s*/\\s*([0-9]+)",
                                   options: .regularExpression),
           let a = Double(query[range][query[range].range(of: ":\\s*([0-9]+)", options: .regularExpression)!.upperBound...]
                          .components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? ""),
           let b = Double(query[range].components(separatedBy: "/").last?.filter { $0.isNumber || $0 == "." } ?? ""),
           b > 0 {
            let target = a / b
            if query.contains("min-device-aspect-ratio") { return aspectRatio >= target }
            if query.contains("max-device-aspect-ratio") { return aspectRatio <= target }
        }
        // 未知媒体查询：保守丢弃（基础样式仍在，设备变体样式丢失，数量已记录）。
        return false
    }

    /// 章节引用的位图图片：以 HTML 中的原始 src 为键（引擎按字面 src 查表）。
    /// 相对 src 一律相对**章节文件所在目录**解析；另支持包内绝对路径、百分号编码、data: URI。
    func images(forChapterHTML html: String, chapterHref: String) async -> [String: UIImage] {
        let chapterDirectory = Self.directory(of: chapterHref)
        var images: [String: UIImage] = [:]
        guard let tagRegex = try? NSRegularExpression(
                  pattern: "<(?:img|image)\\b[^>]*>", options: [.caseInsensitive]),
              let srcRegex = try? NSRegularExpression(
                  pattern: "(?:\\bsrc|xlink:href|\\bhref)\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]) else {
            return images
        }
        let nsHTML = html as NSString
        for tagMatch in tagRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let tag = nsHTML.substring(with: tagMatch.range)
            let nsTag = tag as NSString
            for srcMatch in srcRegex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
                let src = XMLValueParser.decodeEntities(nsTag.substring(with: srcMatch.range(at: 1)))
                guard images[src] == nil else { continue }

                // data: URI（引擎把非空 src 一律视为待装载资源）。
                if src.lowercased().hasPrefix("data:") {
                    if let image = Self.image(fromDataURI: src) {
                        images[src] = image
                    }
                    continue
                }

                guard Self.isRelative(src) || Self.isAbsoluteInPackage(src) else { continue }
                // 相对路径拼章节文件目录；包内绝对路径去掉开头 / 后从包根解析。
                let joined = Self.isAbsoluteInPackage(src)
                    ? String(src.dropFirst())
                    : Self.normalizePath(chapterDirectory + src)
                if let data = await entryData(atPath: joined), let image = UIImage(data: data) {
                    images[src] = image
                }
            }
        }
        return images
    }

    /// 解析 data:image/...;base64,xxx 形式的内嵌图片。
    private static func image(fromDataURI uri: String) -> UIImage? {
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let metadata = uri[uri.startIndex..<commaIndex].lowercased()
        let payload = String(uri[uri.index(after: commaIndex)])
        guard metadata.contains(";base64") else { return nil }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: data)
    }

    static func isAbsoluteInPackage(_ href: String) -> Bool {
        href.hasPrefix("/")
    }

    // MARK: 目录
    //
    // nav/NCX 通常只出现在 manifest、不在 spine，因此一律从 manifest 定位。

    private func buildTOC() async {
        // 1) EPUB3 nav：manifest 中 properties 含 "nav" 的条目。
        //    注意：nav 里的 href 相对 nav 文档所在目录解析（通常在 OPF 子目录）。
        let navItems = manifestByID.values.filter { $0.properties.contains("nav") }
        for navItem in navItems {
            guard let html = try? await chapterHTML(path: navItem.href) else { continue }
            let entries = Self.parseNavTOC(html: html)
            if !entries.isEmpty {
                let mapped = mapToSpine(entries, baseDirectory: Self.directory(of: navItem.href))
                Self.tocLog.fault("TOC nav entries=\(entries.count) mapped=\(mapped.filter { $0.spineIndex != nil }.count) navHref=\(navItem.href, privacy: .public)")
                if !mapped.isEmpty {
                    toc = mapped
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
                    toc = mapped
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

    /// 目录 href 相对其文档所在目录解析后映射到 spine。
    private func mapToSpine(_ entries: [(title: String, href: String)],
                            baseDirectory: String) -> [PrototypeTOCEntry] {
        entries.map { entry in
            let target = Self.isAbsoluteInPackage(entry.href)
                ? Self.normalizePath(String(entry.href.dropFirst()))
                : Self.normalizePath(baseDirectory + entry.href)
            let index = spine.firstIndex {
                Self.stripFragment($0.href) == Self.stripFragment(target)
            }
            return PrototypeTOCEntry(title: entry.title, spineIndex: index)
        }
    }

    private func chapterHTML(path: String) async throws -> String {
        guard let data = await entryData(atPath: path) else {
            throw PrototypeEPUBError.missingOPF
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        var discarded = 0
        return Self.stripScripts(from: text, counter: &discarded)
    }

    // MARK: nav 目录解析（正则提取 <a href>，原型限制见文件头）

    private static func parseNavTOC(html: String) -> [(title: String, href: String)] {
        var block = html
        if let navStart = html.range(of: "<nav\\b[^>]*>", options: .regularExpression),
           let navEnd = html.range(of: "</nav>", range: navStart.upperBound..<html.endIndex) {
            block = String(html[navStart.lowerBound..<navEnd.upperBound])
        }
        guard let anchorRegex = try? NSRegularExpression(
            pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>") else {
            return []
        }
        var result: [(String, String)] = []
        let ns = block as NSString
        for match in anchorRegex.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            let title = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !href.isEmpty, !title.isEmpty {
                result.append((XMLValueParser.decodeEntities(title), href))
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

// MARK: - 轻量 XML / HTML 值提取（原型专用）

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

// MARK: - NCX 目录解析（XMLParser）

enum NCXParser {
    static func parse(xml: String) -> [(title: String, href: String)] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var points: [(title: String, href: String)] = []
        private var currentTitle: String?
        private var currentHref: String?
        private var isCollectingText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "navPoint" {
                currentTitle = nil
                currentHref = nil
            }
            if name == "content" {
                currentHref = attributes["src"]
            }
            if name == "text" {
                isCollectingText = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingText {
                currentTitle = (currentTitle ?? "") + string
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if isCollectingText, let text = String(data: CDATABlock, encoding: .utf8) {
                currentTitle = (currentTitle ?? "") + text
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "text" {
                isCollectingText = false
            }
            if name == "navPoint" {
                let title = (currentTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let href = currentHref, !title.isEmpty {
                    points.append((XMLValueParser.decodeEntities(title), href))
                }
                currentTitle = nil
                currentHref = nil
            }
        }
    }
}

// MARK: - UIColor 工具

extension UIColor {
    /// RGB 整数分量（0-255），用于宿主级 CSS 颜色改写。
    var rgbComponents: (Int, Int, Int) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return (0, 0, 0)
        }
        return (Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }
}
