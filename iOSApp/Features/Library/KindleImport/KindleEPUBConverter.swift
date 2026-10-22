import CLibMobi
import Foundation
import ReadiumZIPFoundation

/// AZW3／MOBI 导入失败的原因，导入汇总按此向用户说明。
enum KindleImportError: LocalizedError, Equatable {
    case drmProtected
    case unsupportedKindleFormat
    case printReplica
    case invalidFile
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .drmProtected: "受 DRM 保护，无法导入。"
        case .unsupportedKindleFormat: "KFX 等新版 Kindle 格式暂不支持。"
        case .printReplica: "Print Replica（PDF 版式）暂不支持。"
        case .invalidFile: "文件损坏或不是 AZW3／MOBI。"
        case .conversionFailed: "转换为 EPUB 失败。"
        }
    }
}

/// 导入时把 AZW3（KF8）与旧版 MOBI 转换为 EPUB；书库只保存转换结果，原文件不保留。
///
/// libmobi（`Vendor/CLibMobi`，不含 DRM 代码）解析 PalmDB、解压正文并重建 KF8 骨架与片段，生成 OPF／NCX；
/// 这里负责：识别 KFX／DRM 等不支持的情况、旧版 MOBI 的 XHTML 整理与分章（`KindleMOBI6Normalizer`）、
/// `amzn-*` 媒体查询展开（`KindleCSSMediaFlattener`）、固定版式元数据补充，以及确定性的 EPUB 打包。
///
/// 输出确定：条目顺序固定、修改时间固定（按 UTC 写入 ZIP），同一文件重复导入得到相同内容哈希，
/// 书库按内容哈希去重的规则因此照常生效。文件名沿用 libmobi 的 `partNNNNN`／`flowNNNNN`／`resourceNNNNN`，
/// 因为 libmobi 重建的书内链接与 OPF 都引用这些名称。
enum KindleEPUBConverter {
    /// 书库接受的 Kindle 文件扩展名。
    static let supportedExtensions: Set<String> = ["azw3", "mobi", "azw", "prc"]

    /// ZIP 条目的固定修改时间（2026-01-01 00:00:00 UTC）。
    private static let entryDate = Date(timeIntervalSince1970: 1_767_225_600)

    private static let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>\
        </container>

        """

    struct Entry: Equatable {
        let path: String
        let data: Data
    }

    /// 转换 `source` 并写入 `destination`（已存在时替换）。C 解析为同步计算，调用方应在主线程之外执行。
    static func convert(source: URL, destination: URL) async throws {
        let entries = try makeEntries(source: source)
        try await writeArchive(entries, to: destination)
    }

    // MARK: 解析

    static func makeEntries(source: URL) throws -> [Entry] {
        try checkContainer(source)
        guard let mobi = mobi_init() else { throw KindleImportError.conversionFailed }
        defer { mobi_free(mobi) }
        guard mobi_load_filename(mobi, source.path) == MOBI_SUCCESS else { throw KindleImportError.invalidFile }
        if mobi_is_encrypted(mobi) { throw KindleImportError.drmProtected }
        if mobi_is_replica(mobi) { throw KindleImportError.printReplica }
        guard let rawml = mobi_init_rawml(mobi) else { throw KindleImportError.conversionFailed }
        defer { mobi_free_rawml(rawml) }
        guard mobi_parse_rawml(rawml, mobi) == MOBI_SUCCESS else { throw KindleImportError.conversionFailed }
        return try assemble(rawml: rawml.pointee)
    }

    /// 只接受 PalmDB 格式的 Mobipocket 文件；KFX、Topaz 等给出专门提示。
    private static func checkContainer(_ source: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: source) else { throw KindleImportError.invalidFile }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 68)) ?? Data()
        let bytes = [UInt8](header)
        let prefix = bytes.prefix(8)
        if prefix.starts(with: Array("CONT".utf8)) || prefix.starts(with: [0xEA] + Array("DRMION".utf8))
            || prefix.starts(with: Array("TPZ".utf8)) || prefix.starts(with: [0x50, 0x4B]) {
            throw KindleImportError.unsupportedKindleFormat
        }
        guard bytes.count >= 68 else { throw KindleImportError.invalidFile }
        let type = String(decoding: bytes[60..<68], as: UTF8.self)
        guard type == "BOOKMOBI" || type == "TEXtREAd" else { throw KindleImportError.invalidFile }
    }

    private struct Part {
        let filename: String
        let type: MOBIFiletype
        let data: Data
    }

    private static func parts(_ head: UnsafeMutablePointer<MOBIPart>?, prefix: String, skipFirst: Bool = false) -> [Part] {
        var result: [Part] = []
        var current = skipFirst ? head?.pointee.next : head
        while let part = current {
            let meta = mobi_get_filemeta_by_type(part.pointee.type)
            let ext = withUnsafeBytes(of: meta.extension) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let name = meta.type == T_OPF ? "content.opf" : prefix + String(format: "%05ld", part.pointee.uid) + "." + ext
            let data = part.pointee.data.map { Data(bytes: $0, count: part.pointee.size) } ?? Data()
            result.append(Part(filename: name, type: part.pointee.type, data: data))
            current = part.pointee.next
        }
        return result
    }

    private static func assemble(rawml: MOBIRawml) throws -> [Entry] {
        let markup = parts(rawml.markup, prefix: "part")
        // flow 链表的第一项是整本原始 HTML，其余才是 CSS／SVG 等辅助文件（与 mobitool 一致）。
        let flows = parts(rawml.flow, prefix: "flow", skipFirst: true)
        let resources = parts(rawml.resources, prefix: "resource").filter { !$0.data.isEmpty }
        guard !markup.isEmpty, var opf = resources.first(where: { $0.type == T_OPF }).map({ text($0.data) }) else {
            throw KindleImportError.conversionFailed
        }

        var textEntries: [(String, String)] = []
        var anchorRewrites: [(source: String, anchors: [String: String])] = []
        // libmobi 以 UINT32_MAX 表示版本未知，按旧版处理。
        let isLegacyMOBI = rawml.version < 8 || rawml.version == Int(UInt32.max)
        for part in markup {
            let html = text(part.data)
            if isLegacyMOBI && part.type == T_HTML {
                let result = try KindleMOBI6Normalizer.normalize(html: html, sourceFilename: part.filename)
                for chapter in result.chapters {
                    textEntries.append((chapter.filename, KindleCSSMediaFlattener.flattenMarkup(chapter.xhtml)))
                }
                anchorRewrites.append((part.filename, result.anchorFiles))
                opf = insertSplitChapters(result.chapters.map(\.filename), replacing: part.filename, in: opf)
            } else if part.type == T_HTML {
                let xhtml = sameDocumentLinks(restoringEPUBTypes(try KindleMOBI6Normalizer.repairedXHTML(html) ?? html),
                                              filename: part.filename)
                textEntries.append((part.filename, KindleCSSMediaFlattener.flattenMarkup(xhtml)))
            } else {
                textEntries.append((part.filename, KindleCSSMediaFlattener.flattenMarkup(html)))
            }
        }

        var entries = [Entry(path: "mimetype", data: Data("application/epub+zip".utf8)),
                       Entry(path: "META-INF/container.xml", data: Data(containerXML.utf8))]
        entries += textEntries.map { Entry(path: "OEBPS/\($0.0)", data: Data($0.1.utf8)) }
        for flow in flows {
            let data = flow.type == T_CSS ? Data(KindleCSSMediaFlattener.flatten(text(flow.data)).utf8) : flow.data
            entries.append(Entry(path: "OEBPS/\(flow.filename)", data: data))
        }
        for rewrite in anchorRewrites {
            opf = KindleMOBI6Normalizer.rewriteReferences(in: opf, sourceFilename: rewrite.source, anchorFiles: rewrite.anchors)
        }
        for resource in resources {
            switch resource.type {
            case T_OPF:
                entries.append(Entry(path: "OEBPS/content.opf", data: Data(addingFixedLayoutRendition(to: opf).utf8)))
            case T_NCX:
                var ncx = text(resource.data)
                for rewrite in anchorRewrites {
                    ncx = KindleMOBI6Normalizer.rewriteReferences(in: ncx, sourceFilename: rewrite.source, anchorFiles: rewrite.anchors)
                }
                entries.append(Entry(path: "OEBPS/\(resource.filename)", data: Data(ncx.utf8)))
            default:
                entries.append(Entry(path: "OEBPS/\(resource.filename)", data: resource.data))
            }
        }
        return entries
    }

    /// KF8 中的语义类型写成不带前缀的 `type="noteref"`、`<aside type="footnote">`（calibre 等工具的输出如此），
    /// 两个阅读引擎只按 `epub:type` 识别注释，原样放入会把注脚当普通链接跳转、注释正文直接显示。
    /// 这里把值全部属于注释类词汇的 `type` 改回 `epub:type` 并补上命名空间声明；
    /// `<style type>`、`<ol type>`、`<input type>` 等取值不在词汇表内，不受影响。
    private static let noteTypeVocabulary: Set<String> = [
        "noteref", "footnote", "footnotes", "endnote", "endnotes", "rearnote", "rearnotes",
        "note", "annoref", "annotation", "biblioref", "glossref",
    ]
    private static let startTag = try! NSRegularExpression(pattern: "<([A-Za-z][\\w-]*)(\\s[^<>]*?)?(/?)>")
    private static let typeAttribute = try! NSRegularExpression(
        pattern: "(\\s)type\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])

    static func restoringEPUBTypes(_ html: String) -> String {
        guard html.range(of: "type=", options: .caseInsensitive) != nil else { return html }
        let ns = html as NSString
        var output = ""
        var last = 0
        var changed = false
        for match in startTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attributesRange = match.range(at: 2)
            guard attributesRange.location != NSNotFound else { continue }
            let attributes = ns.substring(with: attributesRange)
            guard attributes.range(of: "epub:type", options: .caseInsensitive) == nil,
                  let type = typeAttribute.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))
            else { continue }
            let attrNS = attributes as NSString
            let valueRange = type.range(at: 3).location != NSNotFound ? type.range(at: 3) : type.range(at: 4)
            let tokens = attrNS.substring(with: valueRange).lowercased().split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty, tokens.allSatisfy({ noteTypeVocabulary.contains(String($0)) }) else { continue }
            let rewritten = attrNS.replacingCharacters(
                in: type.range, with: "\(attrNS.substring(with: type.range(at: 1)))epub:type=\"\(attrNS.substring(with: valueRange))\"")
            output += ns.substring(with: NSRange(location: last, length: attributesRange.location - last)) + rewritten
            last = attributesRange.location + attributesRange.length
            changed = true
        }
        guard changed else { return html }
        output += ns.substring(from: last)
        guard !output.contains("xmlns:epub="),
              let htmlTag = output.range(of: "<html", options: .caseInsensitive) else { return output }
        output.replaceSubrange(htmlTag, with: "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"")
        return output
    }

    /// libmobi 重建 KF8 链接时总写完整文件名，同章注脚也成了 `href="part00001.html#fn1"`；
    /// 原生引擎只把同文档 `#id` 识别为章内注脚，带文件名会报“链接目标不在章节列表内”。改回 `#id`。
    static func sameDocumentLinks(_ html: String, filename: String) -> String {
        html.replacingOccurrences(of: "href=\"\(filename)#", with: "href=\"#")
            .replacingOccurrences(of: "href='\(filename)#", with: "href='#")
    }

    /// libmobi 已把 cp1252 正文转为 UTF-8；个别资源不是合法 UTF-8 时按 cp1252 读取，避免整本失败。
    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// 旧版 MOBI 分章后，在 OPF 的 manifest 与 spine 中紧接原条目加入后续章节。
    static func insertSplitChapters(_ filenames: [String], replacing source: String, in opf: String) -> String {
        guard filenames.count > 1 else { return opf }
        let sourceID = (source as NSString).deletingPathExtension
        let extra = filenames.dropFirst()
        var result = opf
        let item = "<item id=\"\(sourceID)\" href=\"\(source)\" media-type=\"application/xhtml+xml\"/>"
        if let range = result.range(of: item) {
            let items = extra.map { "<item id=\"\(($0 as NSString).deletingPathExtension)\" href=\"\($0)\" media-type=\"application/xhtml+xml\"/>" }
            result.replaceSubrange(range, with: ([item] + items).joined(separator: "\n  "))
        }
        let itemref = "<itemref idref=\"\(sourceID)\"/>"
        if let range = result.range(of: itemref) {
            let refs = extra.map { "<itemref idref=\"\(($0 as NSString).deletingPathExtension)\"/>" }
            result.replaceSubrange(range, with: ([itemref] + refs).joined(separator: "\n  "))
        }
        return result
    }

    /// libmobi 把 Kindle 的固定版式标记写成 `<meta name="fixed-layout" content="true"/>`；
    /// 补上 EPUB 的 `rendition:layout`，让支持固定版式的阅读器识别。
    static func addingFixedLayoutRendition(to opf: String) -> String {
        guard opf.range(of: "name=\"fixed-layout\" content=\"true\"", options: .caseInsensitive) != nil,
              !opf.contains("rendition:layout"),
              let close = opf.range(of: "</metadata>") else { return opf }
        var result = opf
        result.replaceSubrange(close, with: "<meta property=\"rendition:layout\">pre-paginated</meta>\n </metadata>")
        return result
    }

    // MARK: 打包

    static func writeArchive(_ entries: [Entry], to destination: URL) async throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".kindle-\(UUID().uuidString).epub")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            let archive = try await Archive(url: temporary, accessMode: .create)
            for entry in entries {
                let data = entry.data
                // EPUB 要求 mimetype 为首个且不压缩的条目。
                try await archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(data.count),
                                           modificationDate: entryDate,
                                           compressionMethod: entry.path == "mimetype" ? .none : .deflate) { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
        } catch {
            throw KindleImportError.conversionFailed
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
    }
}
