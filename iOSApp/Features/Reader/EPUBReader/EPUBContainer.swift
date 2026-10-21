import Foundation
import OSLog
import ReadiumZIPFoundation
import UIKit

// MARK: - 最小 EPUB 容器解析
//
// 职责划分参考 Yuedu-reader：YueduCoreText 只负责 HTML/CSS 排版与绘制；
// EPUB ZIP / container.xml / OPF / spine / 资源装载由宿主完成。
// 本文件是最小自给实现，不依赖 Readium 解析器，仅复用其 ZIPFoundation fork。
// 已知限制：
// - nav 目录锚点、章节 CSS/图片引用使用正则提取，未做完整 HTML 解析；
// - 不处理加密内容、固定布局属性与 media overlay；
// - 文本编码仅尝试 UTF-8 与 Latin-1 回退。

struct EPUBTOCEntry: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let spineIndex: Int?
    /// 目录层级，0 为顶层；nav 的嵌套 <ol> 与 NCX 的嵌套 navPoint 逐层加一。
    var level: Int = 0
}

/// 按层级展平的目录的折叠计算（YueduCoreText 与 Readium 阅读器的目录面板共用）。
/// 目录以先序展平：父项在前，紧随其后、层级更深的连续条目都是它的后代。
enum TOCOutline {
    /// 每一项的父项序号；顶层为 nil。
    static func parents(levels: [Int]) -> [Int?] {
        var stack: [Int] = []
        return levels.indices.map { index in
            while let last = stack.last, levels[last] >= levels[index] { stack.removeLast() }
            let parent = stack.last
            stack.append(index)
            return parent
        }
    }

    /// 每一项是否有子项（下一项层级更深）。
    static func hasChildren(levels: [Int]) -> [Bool] {
        levels.indices.map { $0 + 1 < levels.count && levels[$0 + 1] > levels[$0] }
    }

    /// 当前展开状态下应显示的条目：所有祖先都已展开的项。
    static func visibleIndices(levels: [Int], expanded: Set<Int>) -> [Int] {
        let parents = parents(levels: levels)
        var visible = [Bool](repeating: false, count: levels.count)
        for index in levels.indices {
            if let parent = parents[index] {
                visible[index] = visible[parent] && expanded.contains(parent)
            } else {
                visible[index] = true
            }
        }
        return levels.indices.filter { visible[$0] }
    }

    /// 某项的所有祖先（用于默认展开当前章节所在的分组）。
    static func ancestors(of index: Int, levels: [Int]) -> [Int] {
        guard levels.indices.contains(index) else { return [] }
        let parents = parents(levels: levels)
        var result: [Int] = []
        var current = parents[index]
        while let parent = current {
            result.append(parent)
            current = parents[parent]
        }
        return result
    }
}

struct EPUBSpineItem: Equatable {
    let href: String       // 归一化后的 ZIP 内路径
    let mediaType: String
    let properties: [String]
}

enum EPUBError: LocalizedError {
    case cannotOpenArchive
    case missingContainer
    case missingOPF
    case emptySpine
    case entryTooLarge
    case missingChapter(path: String)
    case unreadableEntry(path: String)
    case invalidChapter(index: Int)

    var errorDescription: String? {
        switch self {
        case .entryTooLarge: "EPUB 中有超过 \(EPUBContainer.maxEntryBytes / 1_048_576) MB 的单个文件，无法读取。"
        case .cannotOpenArchive: "无法打开 EPUB 压缩包。"
        case .missingContainer: "缺少 META-INF/container.xml。"
        case .missingOPF: "EPUB 缺少有效的 OPF 包描述文件。"
        case .emptySpine: "EPUB 的 spine 为空，没有可阅读章节。"
        case .missingChapter(let path): "章节文件缺失：\(path)。已尝试路径解码和大小写回退查找；请重新获取 EPUB，或在有目录时选择其他章节。"
        case .unreadableEntry(let path): "书内文件无法读取：\(path)。文件可能已损坏，请重新获取 EPUB 后重试。"
        case .invalidChapter(let index): "章节位置无效（第 \(index + 1) 章），请重新打开书籍或通过目录选择章节。"
        }
    }
}

final class EPUBContainer {
    static let tocLog = Logger(subsystem: "cc.novelia.ios.port", category: "epubcontainer")
    let fileURL: URL
    let bookTitle: String
    let author: String?
    let spine: [EPUBSpineItem]
    private(set) var toc: [EPUBTOCEntry] = []

    private let archive: Archive
    private let opfDirectory: String      // ZIP 内 OPF 目录（含结尾 /，根为 ""）
    private let manifestByID: [String: EPUBSpineItem]
    /// 目录为空时的可诊断原因。
    private(set) var tocDiagnostic: String?
    /// 内嵌目录过于稀疏，已用从 spine 恢复的标题替换时记录。
    private(set) var tocFallbackDiagnostic: String?

    private init(fileURL: URL, archive: Archive, opfDirectory: String,
                 bookTitle: String, author: String?, spine: [EPUBSpineItem],
                 manifestByID: [String: EPUBSpineItem]) {
        self.fileURL = fileURL
        self.archive = archive
        self.opfDirectory = opfDirectory
        self.bookTitle = bookTitle
        self.author = author
        self.spine = spine
        self.manifestByID = manifestByID
    }

    static func open(fileURL: URL) async throws -> EPUBContainer {
        guard let archive = try? await Archive(url: fileURL, accessMode: .read) else {
            throw EPUBError.cannotOpenArchive
        }

        // 1–2. container.xml → rootfile → OPF（metadata / manifest / spine）
        let (opfXML, opfDirectory) = try await packageDocument(in: archive)

        let bookTitle = mainTitle(inMetadata: metadataSection(of: opfXML))
        let author = (XMLValueParser.elementValue("dc:creator", xml: opfXML)
            ?? XMLValueParser.elementValue("creator", xml: opfXML))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var manifest: [String: EPUBSpineItem] = [:]
        for attributes in XMLValueParser.openTagAttributes("item", in: opfXML) {
            guard let id = attributes["id"], let href = attributes["href"] else { continue }
            let properties = (attributes["properties"] ?? "")
                .split(separator: " ").map(String.init)
            manifest[id] = EPUBSpineItem(
                href: normalizePath(opfDirectory + href),
                mediaType: attributes["media-type"] ?? "",
                properties: properties
            )
        }

        var spineItems: [EPUBSpineItem] = []
        for attributes in XMLValueParser.openTagAttributes("itemref", in: opfXML) {
            guard let idref = attributes["idref"], let item = manifest[idref] else { continue }
            spineItems.append(item)
        }
        let readable = spineItems.filter {
            $0.mediaType.contains("xhtml") || $0.mediaType.contains("html")
        }
        guard !readable.isEmpty else { throw EPUBError.emptySpine }

        let container = EPUBContainer(
            fileURL: fileURL, archive: archive, opfDirectory: opfDirectory,
            bookTitle: bookTitle ?? fileURL.deletingPathExtension().lastPathComponent,
            author: author, spine: readable,
            manifestByID: manifest
        )
        await container.buildTOC()
        return container
    }

    // MARK: 资源访问

    /// 读取 container.xml 指向的 OPF 文本及其 ZIP 内目录（含结尾 /，根为 ""）。
    private static func packageDocument(in archive: Archive) async throws -> (xml: String, directory: String) {
        guard let containerEntry = try? await archive.get("META-INF/container.xml") else {
            throw EPUBError.missingContainer
        }
        let containerXML = try await entryText(containerEntry, from: archive)
        guard let rootPath = XMLValueParser.elementValue("rootfile", attribute: "full-path", xml: containerXML),
              !rootPath.isEmpty else {
            throw EPUBError.missingOPF
        }
        guard let opfEntry = try? await archive.get(rootPath) else {
            throw EPUBError.missingOPF
        }
        let opfXML = try await entryText(opfEntry, from: archive)
        let directory = rootPath.contains("/")
            ? String(rootPath[...(rootPath.lastIndex(of: "/")!)])
            : ""
        return (opfXML, directory)
    }

    /// 单个条目解压后的上限。条目整块读入内存，异常或恶意 EPUB 的超大条目会耗尽内存导致闪退；
    /// 正常书籍的章节、图片和字体远小于此值。
    static let maxEntryBytes: UInt64 = 200 * 1_048_576

    private static func entryData(_ entry: Entry, from archive: Archive) async throws -> Data {
        try Task.checkCancellation()
        // 目录中的大小可能不实，解压时也累计检查。
        guard entry.uncompressedSize <= maxEntryBytes else { throw EPUBError.entryTooLarge }
        var data = Data()
        let consumer: Consumer = { chunk in
            try Task.checkCancellation()
            guard UInt64(data.count + chunk.count) <= maxEntryBytes else { throw EPUBError.entryTooLarge }
            data.append(chunk)
        }
        do {
            // ZIPFoundation 返回实际 CRC，调用方负责与目录记录比较。
            let checksum = try await archive.extract(entry, consumer: consumer)
            guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else {
                throw EPUBError.unreadableEntry(path: entry.path)
            }
            try Task.checkCancellation()
        } catch let error as EPUBError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 用户界面保留包内路径；日志只记录固定错误分类，避免写出书名或正文。
            throw EPUBError.unreadableEntry(path: entry.path)
        }
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
    /// 已剥离的 `display: table/table-cell`、`vertical-align: middle` 声明数量。
    /// 多看风格插图页用它们垂直居中；在当前引擎中会让图片整页丢失（实测定位），
    /// 去掉后图片按内容高度正常布局，仅失去"垂直居中"这一装饰效果。
    private(set) var tableDisplayStripCount = 0
    /// 已将 Flex/Grid 布局降级为普通块布局的声明数量。
    /// 内容仍会显示，但 Flex/Grid 专属的对齐与间距效果不保留。
    private(set) var flexGridRewriteCount = 0

    func chapterHTML(at index: Int) async throws -> String {
        guard spine.indices.contains(index) else { throw EPUBError.invalidChapter(index: index) }
        guard let entry = await resolveEntry(spine[index].href) else {
            throw EPUBError.missingChapter(path: spine[index].href)
        }
        let data = try await Self.entryData(entry, from: archive)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        var stripped = Self.stripScripts(from: text, counter: &strippedScriptCount)
        stripped = Self.rewriteOpacity(in: stripped, counter: &opacityRewriteCount,
                                       rgb: themeTextColor.rgbComponents)
        stripped = Self.rewriteUnsupportedFlexGrid(in: stripped, counter: &flexGridRewriteCount)
        return Self.rewriteEightDigitColors(in: stripped)
    }

    /// Readium 实验引擎打开前的容器预检：确认容器结构、spine 各章节都存在，
    /// 且解压数据与中央目录的 CRC／长度一致。只读 spine 文档，不解压图片等资源；
    /// Readium 的 streamer 对空 spine 会崩溃、对缺失或损坏的章节会一直停在加载态，
    /// 先用原生容器把这些情况变成可读的错误说明。
    func validateForReadium() async throws {
        for index in spine.indices {
            guard let entry = await resolveEntry(spine[index].href) else {
                throw EPUBError.missingChapter(path: spine[index].href)
            }
            _ = try await Self.entryData(entry, from: archive)
        }
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
            cleaned = Self.rewriteOpacity(in: cleaned, counter: &opacityRewriteCount,
                                          rgb: themeTextColor.rgbComponents)
            cleaned = Self.rewriteUnsupportedFlexGrid(in: cleaned, counter: &flexGridRewriteCount)
            texts.append(Self.rewriteEightDigitColors(in: cleaned))
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
        result = Self.stripTableDisplayRules(in: result, counter: &tableDisplayStripCount)
        result = Self.rewriteUnsupportedFlexGrid(in: result, counter: &flexGridRewriteCount)
        result = Self.rewriteTextShadow(in: result, counter: &textShadowRewriteCount)
        return Self.rewriteEightDigitColors(in: result)
    }

    /// 将 Flex/Grid 容器降级为普通块布局，并移除引擎不支持的布局属性。
    /// 子元素和内容保持不变，封面等内容可继续排版，只失去 Flex/Grid 对齐效果。
    static func rewriteUnsupportedFlexGrid(in text: String, counter: inout Int) -> String {
        guard let displayRegex = try? NSRegularExpression(
            pattern: #"display\s*:\s*(?:-webkit-)?(?:inline-)?(?:flex|grid)\s*(?:!important\s*)?;?"#,
            options: [.caseInsensitive]),
              let layoutRegex = try? NSRegularExpression(
                pattern: #"(?:flex(?:-(?:direction|wrap|basis|grow|shrink))?|justify-content|align-items|grid-[a-z-]+|gap)\s*:\s*[^;}]*;?"#,
                options: [.caseInsensitive]) else { return text }

        let ns = text as NSString
        let displayMatches = displayRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in displayMatches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "display: block;")
        }
        counter += displayMatches.count

        let layoutNS = result as NSString
        let layoutMatches = layoutRegex.matches(
            in: result, range: NSRange(location: 0, length: layoutNS.length))
        for match in layoutMatches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "")
        }
        counter += layoutMatches.count
        return result
    }

    /// CSS4 #RGBA / #RRGGBBAA 转为引擎可解析的 rgba()。只匹配完整的颜色词，
    /// 避免把更长的十六进制串截断成颜色。
    static func rewriteEightDigitColors(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "#[0-9a-fA-F]{8}(?![0-9a-fA-F])|#[0-9a-fA-F]{4}(?![0-9a-fA-F])") else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let hex = String(ns.substring(with: match.range).dropFirst())
            let expanded = hex.count == 4
                ? hex.map { "\($0)\($0)" }.joined()
                : hex
            guard let value = UInt32(expanded, radix: 16),
                  let range = Range(match.range, in: result) else { continue }
            let red = (value >> 24) & 0xff
            let green = (value >> 16) & 0xff
            let blue = (value >> 8) & 0xff
            let alpha = Double(value & 0xff) / 255.0
            result.replaceSubrange(range, with: "rgba(\(red),\(green),\(blue),\(alpha))")
        }
        return result
    }

    /// 已把含颜色的 `text-shadow` 改写为文字颜色的数量。
    /// 多看风格台词是"白字+彩色阴影描边"；引擎不支持文字阴影，白字裸奔不可读。
    /// 改写后 profile 类（在 char-quote 之后声明，同优先级后者胜）以阴影色作文字色。
    private(set) var textShadowRewriteCount = 0

    /// `text-shadow: <颜色> ...` → `color: <颜色>;`（同规则内、原声明位置）。
    /// 无颜色分量的 text-shadow 直接删除（引擎不支持，删了也不丢正文）。
    static func rewriteTextShadow(in css: String, counter: inout Int) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "text-shadow\\s*:\\s*(#[0-9a-fA-F]{3,8}|rgba?\\([^)]*\\)|[a-zA-Z]+)[^;}]*;?") else {
            return css
        }
        let ns = css as NSString
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return css }
        counter += matches.count
        var result = css
        for match in matches.reversed() {
            let colorToken = ns.substring(with: match.range(at: 1))
            // 阴影色是"currentColor/black"之类时无法近似，直接删除该声明。
            let replacement: String
            if colorToken.lowercased() == "currentcolor" {
                replacement = ""
            } else {
                replacement = "color:\(colorToken);"
            }
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    /// 剥离 `display: table`/`table-cell` 与 `vertical-align: middle` 声明。
    /// 多看风格插图页用它们垂直居中图片；在当前排版引擎中该组合会让图片
    /// 在布局阶段被整体丢弃（整页空白，真实书籍实测定位）。
    static func stripTableDisplayRules(in css: String, counter: inout Int) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(display\\s*:\\s*(table|table-cell)\\s*;?)|(vertical-align\\s*:\\s*middle\\s*;?)",
            options: [.caseInsensitive]) else { return css }
        let ns = css as NSString
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return css }
        counter += matches.count
        return regex.stringByReplacingMatches(
            in: css, range: NSRange(location: 0, length: ns.length), withTemplate: "")
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
        // 逗号为 OR；单项里的 and 条件全部满足才保留。
        for alternative in raw.lowercased().split(separator: ",") {
            var query = String(alternative).trimmingCharacters(in: .whitespacesAndNewlines)
            if query.hasPrefix("not amzn-mobi") {
                query.removeFirst("not amzn-mobi".count)
            }
            if query.contains("amzn-mobi") { continue }
            if query.hasPrefix("not ") { continue }
            if query.hasPrefix("only ") { query.removeFirst(5) }
            if query == "print" || query.hasPrefix("print and ") ||
               query == "speech" || query.hasPrefix("speech and ") { continue }
            if query == "screen" || query == "all" { return true }
            if query.hasPrefix("screen and ") { query.removeFirst("screen and ".count) }
            if query.hasPrefix("all and ") { query.removeFirst("all and ".count) }
            if query.hasPrefix(" and ") { query.removeFirst(" and ".count) }
            let conditions = query.components(separatedBy: " and ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if conditions.allSatisfy({ evaluateMediaCondition($0, aspectRatio: aspectRatio) }) {
                return true
            }
        }
        return false
    }

    private static func evaluateMediaCondition(_ condition: String, aspectRatio: CGFloat) -> Bool {
        guard condition.hasPrefix("("), condition.hasSuffix(")") else { return false }
        let body = condition.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let feature = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if feature == "orientation" {
            return value == (aspectRatio >= 1 ? "landscape" : "portrait")
        }
        guard ["aspect-ratio", "device-aspect-ratio", "min-aspect-ratio", "max-aspect-ratio",
               "min-device-aspect-ratio", "max-device-aspect-ratio"].contains(feature) else { return false }
        let ratioParts = value.split(separator: "/").map(String.init)
        let target: Double?
        if ratioParts.count == 2, let numerator = Double(ratioParts[0].trimmingCharacters(in: .whitespaces)),
           let denominator = Double(ratioParts[1].trimmingCharacters(in: .whitespaces)), denominator > 0 {
            target = numerator / denominator
        } else {
            target = Double(value)
        }
        guard let target else { return false }
        let actual = Double(aspectRatio)
        if feature.hasPrefix("min-") { return actual >= target }
        if feature.hasPrefix("max-") { return actual <= target }
        return abs(actual - target) < 0.001
    }

    /// 缺图占位：1×1 透明图。YueduCoreText 遇到非空 src 却没有对应资源时会让
    /// 整章排版失败；机翻书缺图很常见，因此用透明占位保证章节仍可阅读。
    static let missingImagePlaceholder: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in }
    }()

    /// 章节引用的位图图片：以 HTML 中的原始 src 为键（引擎按字面 src 查表）。
    /// 相对 src 一律相对**章节文件所在目录**解析；另支持包内绝对路径、百分号编码、data: URI。
    /// 解析不到或无法解码的图片返回透明占位图，避免整章排版失败。
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
                    images[src] = Self.image(fromDataURI: src) ?? Self.missingImagePlaceholder
                    continue
                }

                guard Self.isRelative(src) || Self.isAbsoluteInPackage(src) else {
                    // 包外资源（http/file 等）本应用不加载，但引擎仍需要资源占位。
                    images[src] = Self.missingImagePlaceholder
                    continue
                }
                // 相对路径拼章节文件目录；包内绝对路径去掉开头 / 后从包根解析。
                let joined = Self.isAbsoluteInPackage(src)
                    ? String(src.dropFirst())
                    : Self.normalizePath(chapterDirectory + src)
                if let data = await entryData(atPath: joined), let image = UIImage(data: data) {
                    images[src] = image
                } else {
                    images[src] = Self.missingImagePlaceholder
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

    // MARK: nav 目录解析（正则提取 <a href>，限制见文件头）

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
    fileprivate static func metadataSection(of opfXML: String) -> String {
        XMLValueParser.elementBlocks("metadata", in: opfXML).first
            ?? XMLValueParser.elementBlocks("opf:metadata", in: opfXML).first
            ?? opfXML
    }

    /// 书名：`title-type=main` 的 dc:title，否则第一个 dc:title。阅读器与书库共用同一规则。
    fileprivate static func mainTitle(inMetadata metadataXML: String) -> String? {
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

// MARK: - 注释正文识别（Readium 未标 noteref 的注释链接）

/// Readium 只对 `<a epub:type="noteref">` 弹出注释；多看及 Sigil 注释插件生成的
/// `<a class="duokan-footnote" href="#note_1">` 没有该属性，会被当成普通链接跳到章末。
/// 这里按链接目标判断是否为注释正文，规则与 YueduCoreText 的 `collectFootnotes` 一致：
/// 带 id、class 含 "footnote" 的 `<li>`，或 `epub:type` 含 footnote／endnote／note／rearnote 的元素。
/// 只看目标，不猜测普通锚点，未命中的链接仍照常跳转。
enum EPUBFootnoteTarget {
    /// 文档中 id 为 `id` 的注释正文的内部 HTML；不是注释或为空时返回 nil。
    static func noteHTML(id: String, inDocument html: String) -> String? {
        guard !id.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: id)
        guard let openRegex = try? NSRegularExpression(
            pattern: "<([A-Za-z][\\w:-]*)\\b([^>]*?\\sid\\s*=\\s*[\"']\(escaped)[\"'][^>]*?)(/?)>",
            options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let open = openRegex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              open.range(at: 3).length == 0 else { return nil }
        let tag = ns.substring(with: open.range(at: 1)).lowercased()
        let attributes = ns.substring(with: open.range(at: 2))
        guard isNoteBody(tag: tag, attributes: attributes) else { return nil }

        // 找到同名标签的配对结束标签（计入嵌套）。
        guard let tagRegex = try? NSRegularExpression(
            pattern: "<(/?)\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*?(/?)>",
            options: [.caseInsensitive]) else { return nil }
        let start = open.range.location + open.range.length
        var depth = 1
        var end = ns.length
        for match in tagRegex.matches(in: html, range: NSRange(location: start, length: ns.length - start)) {
            if match.range(at: 2).length > 0 { continue }
            depth += match.range(at: 1).length > 0 ? -1 : 1
            if depth == 0 { end = match.range.location; break }
        }
        let inner = ns.substring(with: NSRange(location: start, length: end - start))
        let text = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : inner
    }

    private static func isNoteBody(tag: String, attributes: String) -> Bool {
        if tag == "li", let classes = attributeValue("class", in: attributes),
           classes.lowercased().contains("footnote") {
            return true
        }
        guard let epubType = attributeValue("epub:type", in: attributes) else { return false }
        let tokens = epubType.lowercased().split(whereSeparator: \.isWhitespace)
        return tokens.contains { ["footnote", "endnote", "note", "rearnote"].contains($0) }
    }

    private static func attributeValue(_ name: String, in attributes: String) -> String? {
        let pattern = "(?:^|\\s)\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = attributes as NSString
        guard let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 2))
    }
}

// MARK: - NCX 目录解析（XMLParser）

enum NCXParser {
    /// 按先序返回目录点；嵌套 navPoint 的层级逐层加一，父项排在子项之前。
    static func parse(xml: String) -> [(title: String, href: String, level: Int)] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private final class Point {
            var title = ""
            var href: String?
            var emitted = false
        }

        var points: [(title: String, href: String, level: Int)] = []
        /// 尚未结束的 navPoint；子项开始前先输出父项，保证先序。
        private var stack: [Point] = []
        private var isCollectingText = false

        private func emit(_ point: Point, level: Int) {
            guard !point.emitted else { return }
            point.emitted = true
            let title = point.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = point.href, !title.isEmpty {
                points.append((XMLValueParser.decodeEntities(title), href, level))
            }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "navPoint" {
                if let parent = stack.last { emit(parent, level: stack.count - 1) }
                stack.append(Point())
            }
            if name == "content", let point = stack.last, point.href == nil {
                point.href = attributes["src"]
            }
            if name == "text", !stack.isEmpty {
                isCollectingText = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingText { stack.last?.title += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if isCollectingText, let text = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.title += text
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "text" {
                isCollectingText = false
            }
            if name == "navPoint", let point = stack.last {
                emit(point, level: stack.count - 1)
                stack.removeLast()
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
