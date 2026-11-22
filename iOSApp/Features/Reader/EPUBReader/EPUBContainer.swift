import Foundation
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif
import ImageIO
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
    /// 章内锚点，不含 `#`。nil 表示该 spine 文件的开头。
    /// 目录只活在打开后的内存里，不进入进度、书签或同步，因此没有旧记录要迁移。
    var fragment: String? = nil
    /// 目录层级，0 为顶层；nav 的嵌套 <ol> 与 NCX 的嵌套 navPoint 逐层加一。
    var level: Int = 0
}

/// 同一资源里有多个目录锚点时，按章内位置取「不晚于当前位置」的最后一项。
/// 位置未知时当前资源回退到第一项。Yuedu 的源文本偏移和 Readium 的 progression 共用这套比较。
enum InFileTOCSelection {
    static func currentIndex<Position: Comparable>(
        resources: [Int?],
        positions: [Position?],
        resource: Int,
        position: Position?,
        positionsReady: Bool
    ) -> Int? {
        let canCompare = positionsReady && position != nil
        var firstInResource: Int?
        var resolvedInResource = false
        var bestEarlier: (resource: Int, index: Int)?
        var bestHere: (position: Position, index: Int)?
        for index in resources.indices {
            guard let entryResource = resources[index] else { continue }
            if entryResource == resource {
                if firstInResource == nil { firstInResource = index }
                guard canCompare, let current = position, let entryPosition = positions[index] else { continue }
                resolvedInResource = true
                if entryPosition <= current {
                    if let best = bestHere {
                        if entryPosition > best.position || (entryPosition == best.position && index > best.index) {
                            bestHere = (entryPosition, index)
                        }
                    } else {
                        bestHere = (entryPosition, index)
                    }
                }
            } else if entryResource < resource {
                // 更早资源已完整经过，不参与当前文件的章内位置比较，按资源与目录顺序取最后一项。
                if let best = bestEarlier {
                    if entryResource > best.resource || (entryResource == best.resource && index > best.index) {
                        bestEarlier = (entryResource, index)
                    }
                } else {
                    bestEarlier = (entryResource, index)
                }
            }
        }
        if let bestHere { return bestHere.index }
        // 章内位置未知，或本章一个锚点偏移都没有：落在该文件的第一项，而不是最后一项。
        if let firstInResource, !canCompare || !resolvedInResource { return firstInResource }
        return bestEarlier?.index
    }
}

/// 原生目录高亮。`anchorOffsets` 为 nil 表示该章还没有排版结果。
enum EPUBTOCHighlight {
    static func index(entries: [EPUBTOCEntry], spineIndex: Int,
                      pageSourceOffset: Int?, anchorOffsets: [String: Int]?) -> Int? {
        let ready = anchorOffsets != nil && pageSourceOffset != nil
        let positions: [Int?] = entries.map { entry in
            guard entry.spineIndex == spineIndex, let anchorOffsets else { return nil }
            return offset(fragment: entry.fragment, anchors: anchorOffsets)
        }
        return InFileTOCSelection.currentIndex(
            resources: entries.map(\.spineIndex),
            positions: positions,
            resource: spineIndex,
            position: pageSourceOffset,
            positionsReady: ready
        )
    }

    /// 无 fragment 时为文件开头（偏移 0）。锚点不在表里时返回 nil，调用方跳过该项。
    static func offset(fragment: String?, anchors: [String: Int]) -> Int? {
        guard let key = normalizedFragment(fragment) else { return 0 }
        return anchors[key]
    }

    static func normalizedFragment(_ fragment: String?) -> String? {
        guard let fragment else { return nil }
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { return EPUBContainer.tocFragment(in: trimmed) }
        return EPUBContainer.tocFragment(in: "#\(trimmed)")
    }
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
    var displayProjection = ReadingTextProjection()
    static let tocLog = Logger(subsystem: "cc.novelia.ios.port", category: "epubcontainer")
    let fileURL: URL
    let bookTitle: String
    let author: String?
    let spine: [EPUBSpineItem]
    /// OPF `<spine page-progression-direction="rtl">` 是否声明从右向左翻页（竖排日文/中文书常见）。
    let isSpineRTL: Bool
    var toc: [EPUBTOCEntry] = []

    let archive: Archive
    private let opfDirectory: String      // ZIP 内 OPF 目录（含结尾 /，根为 ""）
    let manifestByID: [String: EPUBSpineItem]
    /// 目录为空时的可诊断原因。
    var tocDiagnostic: String?
    /// 内嵌目录过于稀疏，已用从 spine 恢复的标题替换时记录。
    var tocFallbackDiagnostic: String?

    private init(fileURL: URL, archive: Archive, opfDirectory: String,
                 bookTitle: String, author: String?, spine: [EPUBSpineItem],
                 isSpineRTL: Bool,
                 manifestByID: [String: EPUBSpineItem]) {
        self.fileURL = fileURL
        self.archive = archive
        self.opfDirectory = opfDirectory
        self.bookTitle = bookTitle
        self.author = author
        self.spine = spine
        self.isSpineRTL = isSpineRTL
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

        let isSpineRTL = XMLValueParser.openTagAttributes("spine", in: opfXML)
            .first?["page-progression-direction"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "rtl"

        let container = EPUBContainer(
            fileURL: fileURL, archive: archive, opfDirectory: opfDirectory,
            bookTitle: bookTitle ?? fileURL.deletingPathExtension().lastPathComponent,
            author: author, spine: readable,
            isSpineRTL: isSpineRTL,
            manifestByID: manifest
        )
        await container.buildTOC()
        return container
    }

    // MARK: 资源访问

    /// 读取 container.xml 指向的 OPF 文本及其 ZIP 内目录（含结尾 /，根为 ""）。
    static func packageDocument(in archive: Archive) async throws -> (xml: String, directory: String) {
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

    static func entryData(_ entry: Entry, from archive: Archive) async throws -> Data {
        try Task.checkCancellation()
        // 目录中的大小可能不实，解压时也累计检查。
        guard entry.uncompressedSize <= maxEntryBytes else { throw EPUBError.entryTooLarge }
        let buffer = EntryDataBuffer()
        let consumer: Consumer = { chunk in
            try Task.checkCancellation()
            try buffer.append(chunk, limit: maxEntryBytes)
        }
        do {
            // ZIPFoundation 返回实际 CRC，调用方负责与目录记录比较。
            let checksum = try await archive.extract(entry, consumer: consumer)
            guard checksum == entry.checksum, UInt64(buffer.snapshot().count) == entry.uncompressedSize else {
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
        return buffer.snapshot()
    }

    /// ZIP 消费回调可跨执行器运行；锁同时保护累计大小检查和写入，不共享可变局部变量。
    private final class EntryDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data, limit: UInt64) throws {
            lock.lock()
            defer { lock.unlock() }
            guard UInt64(data.count) + UInt64(chunk.count) <= limit else { throw EPUBError.entryTooLarge }
            data.append(chunk)
        }
        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
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
    func resolveEntry(_ path: String) async -> Entry? {
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
    /// 已将 Flex/Grid 布局降级为普通块布局的声明数量。
    /// 内容仍会显示，但 Flex/Grid 专属的对齐与间距效果不保留。
    private(set) var flexGridRewriteCount = 0
    /// 已将 `position: absolute/fixed/sticky` 降级为普通流的声明数量。
    /// 引擎遇到这类定位会整章拒绝排版；降级后内容按文档顺序显示，只失去定位效果
    /// （如固定在页面底部的标题页导语改为接在前文之后）。
    private(set) var positionRewriteCount = 0

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
        stripped = Self.rewriteUnsupportedPositioning(in: stripped, counter: &positionRewriteCount)
        return displayProjection.applyHTML(Self.rewriteEightDigitColors(in: stripped))
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
            cleaned = Self.rewriteUnsupportedPositioning(in: cleaned, counter: &positionRewriteCount)
            texts.append(Self.rewriteEightDigitColors(in: cleaned))
        }
        if !texts.contains(where: EPUBHorizontalLayoutCompatibility.containsVerticalWritingMode) {
            texts = texts.map(EPUBHorizontalLayoutCompatibility.normalizingHangingIndentsForHorizontal(in:))
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
        result = Self.rewriteUnsupportedFlexGrid(in: result, counter: &flexGridRewriteCount)
        result = Self.rewriteUnsupportedPositioning(in: result, counter: &positionRewriteCount)
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

    /// 将 `position: absolute/fixed/sticky` 改为 `position: static`，元素回到普通流。
    /// 偏移量（top/bottom 等）对 static 元素不生效，保留原样；`relative` 引擎可接受，不改动。
    static func rewriteUnsupportedPositioning(in text: String, counter: inout Int) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\w-])position\s*:\s*(?:absolute|fixed|sticky|-webkit-sticky)\b"#,
            options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        counter += matches.count
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "position: static")
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
        var images: [String: UIImage] = [:]
        for src in Self.imageSources(inChapterHTML: html) {
            // data: URI（引擎把非空 src 一律视为待装载资源）。
            if src.lowercased().hasPrefix("data:") {
                images[src] = Self.image(fromDataURI: src) ?? Self.missingImagePlaceholder
                continue
            }
            // 包外资源（http/file 等）本应用不加载，但引擎仍需要资源占位。
            guard let path = Self.resolveImagePath(src: src, chapterHref: chapterHref),
                  let data = await entryData(atPath: path), let image = UIImage(data: data) else {
                images[src] = Self.missingImagePlaceholder
                continue
            }
            images[src] = image
        }
        return images
    }

    /// 章节 HTML 中 `<img>`／SVG `<image>` 的原始 src（解码实体、按出现顺序去重）。
    static func imageSources(inChapterHTML html: String) -> [String] {
        guard let tagRegex = try? NSRegularExpression(
                  pattern: "<(?:img|image)\\b[^>]*>", options: [.caseInsensitive]),
              let srcRegex = try? NSRegularExpression(
                  pattern: "(?:\\bsrc|xlink:href|\\bhref)\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]) else {
            return []
        }
        var seen = Set<String>()
        var sources: [String] = []
        let nsHTML = html as NSString
        for tagMatch in tagRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let tag = nsHTML.substring(with: tagMatch.range)
            let nsTag = tag as NSString
            for srcMatch in srcRegex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
                let src = XMLValueParser.decodeEntities(nsTag.substring(with: srcMatch.range(at: 1)))
                if seen.insert(src).inserted { sources.append(src) }
            }
        }
        return sources
    }

    /// 把章节中的图片 src 解析为 ZIP 内路径：相对路径拼章节文件目录，包内绝对路径去掉开头 /。
    /// data: URI 与包外地址返回 nil。
    static func resolveImagePath(src: String, chapterHref: String) -> String? {
        guard !src.lowercased().hasPrefix("data:"), isRelative(src) || isAbsoluteInPackage(src) else { return nil }
        let path = stripFragment(src)
        return isAbsoluteInPackage(path)
            ? normalizePath(String(path.dropFirst()))
            : normalizePath(directory(of: chapterHref) + path)
    }

    // MARK: 书内图片（目录页“图片”与图片查看器）

    /// 全书插图：按 spine 顺序收集各章引用的图片，再补上 manifest 中未被章节引用的图片。
    /// 长边小于 `minimumPixelLength` 的小图（注释标记、外字、装饰线等）不列入。
    func allImages(minimumPixelLength: CGFloat = 120) async -> [EPUBImageEntry] {
        var seen = Set<String>()
        var entries: [EPUBImageEntry] = []
        func consider(_ path: String, spineIndex: Int?) async {
            let key = path.lowercased()
            guard seen.insert(key).inserted, let data = await entryData(atPath: path),
                  let size = EPUBImageDecoding.pixelSize(of: data),
                  max(size.width, size.height) >= minimumPixelLength else { return }
            entries.append(EPUBImageEntry(path: path, spineIndex: spineIndex))
        }
        for (index, item) in spine.enumerated() {
            if Task.isCancelled { return entries }
            guard let html = try? await chapterHTML(at: index) else { continue }
            for src in Self.imageSources(inChapterHTML: html) {
                guard let path = Self.resolveImagePath(src: src, chapterHref: item.href) else { continue }
                await consider(path, spineIndex: index)
            }
        }
        let leftovers = manifestByID.values
            .filter { $0.mediaType.lowercased().hasPrefix("image/") }
            .map(\.href)
            .sorted()
        for path in leftovers {
            if Task.isCancelled { break }
            await consider(path, spineIndex: nil)
        }
        return entries
    }

    /// 由阅读器中的图片地址（例如 Readium 页面里的绝对 URL）找到 ZIP 内路径：
    /// 逐个去掉 URL 路径开头的部分，直到包内存在该条目。
    func packagePath(forImageURL url: URL) async -> String? {
        let decoded = url.path.removingPercentEncoding ?? url.path
        let components = decoded.split(separator: "/").map(String.init)
        for start in components.indices {
            let candidate = components[start...].joined(separator: "/")
            if await entryData(atPath: candidate) != nil { return candidate }
        }
        return nil
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
}
