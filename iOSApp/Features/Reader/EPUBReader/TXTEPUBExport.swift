// SPDX-License-Identifier: GPL-3.0-only
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif
import Foundation
import ReadiumZIPFoundation

/// 导出用章节：已按阅读器使用的手工目录切好，`body` 不含标题行。
struct TXTEPUBChapter: Sendable {
    let title: String
    let volumeTitle: String?
    let body: String
}

enum TXTEPUBExportError: LocalizedError {
    case notTXT, missingFile, emptyBook, writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notTXT: "只有 TXT 书籍可以导出为 EPUB。"
        case .missingFile: "找不到这本书的 TXT 文件。"
        case .emptyBook: "这本书没有可导出的正文。"
        case .writeFailed(let reason): "EPUB 写入失败：\(reason)"
        }
    }
}

/// 生成最小 EPUB 3。输入章节来自 TXT 的手工目录快照，导出过程不再识别章节，
/// 因此用户修改过的标题、分章边界和卷名原样进入目录与正文。
/// 章节正文逐章投影、生成 XHTML 并写入压缩包，不在内存中保留全书页面。
enum TXTEPUBExporter {
    struct Entry: Sendable {
        let path: String
        let text: String
    }

    private enum NavGroup {
        case chapter(Int)
        case volume(String, [Int])
    }

    private struct Headings {
        let titles: [String]
        let volumes: [String?]
        let groups: [NavGroup]
        let volumeStarts: Set<Int>
    }

    static func export(title: String, author: String, chapters: [TXTEPUBChapter],
                       projection: ReadingTextProjection, destination: URL) async throws {
        guard !chapters.isEmpty else { throw TXTEPUBExportError.emptyBook }
        let identifier = "urn:uuid:" + UUID().uuidString
        let modified = Date()
        let headings = makeHeadings(chapters: chapters, projection: projection)
        let fixed = fixedEntries(title: title, author: author, identifier: identifier, modified: modified,
                                 chapterCount: chapters.count, headings: headings)
        try await write(chapters: chapters, headings: headings, projection: projection,
                        fixed: fixed, to: destination)
    }

    /// 测试与检查用：一次性返回全部条目；正式导出走逐章写入，避免整书 XHTML 常驻内存。
    static func makeEntries(title: String, author: String, chapters: [TXTEPUBChapter],
                            projection: ReadingTextProjection,
                            identifier: String = "urn:uuid:" + UUID().uuidString,
                            modified: Date = Date()) throws -> [Entry] {
        guard !chapters.isEmpty else { throw TXTEPUBExportError.emptyBook }
        let headings = makeHeadings(chapters: chapters, projection: projection)
        var entries = fixedEntries(title: title, author: author, identifier: identifier, modified: modified,
                                   chapterCount: chapters.count, headings: headings)
        for index in chapters.indices {
            entries.append(chapterEntry(index: index, chapter: chapters[index], headings: headings,
                                        projection: projection))
        }
        return entries
    }

    // MARK: - 目录与章节

    /// 只投影标题和卷名；正文在写入时逐章处理。连续且卷名相同的章节归入同一个卷。
    private static func makeHeadings(chapters: [TXTEPUBChapter], projection: ReadingTextProjection) -> Headings {
        let titles = chapters.map { projection.apply($0.title) }
        let volumes = chapters.map { $0.volumeTitle.map(projection.apply) }
        let display = chapters.indices.map { TXTEPUBChapter(title: titles[$0], volumeTitle: volumes[$0], body: "") }
        let groups = navGroups(chapters: display)
        let starts = Set(groups.compactMap { group -> Int? in
            if case .volume(_, let indices) = group { return indices.first }
            return nil
        })
        return Headings(titles: titles, volumes: volumes, groups: groups, volumeStarts: starts)
    }

    private static func navGroups(chapters: [TXTEPUBChapter]) -> [NavGroup] {
        var groups: [NavGroup] = []
        var volume: String?
        var indices: [Int] = []
        func flush() {
            if let volume, !indices.isEmpty { groups.append(.volume(volume, indices)) }
            volume = nil; indices = []
        }
        for (index, chapter) in chapters.enumerated() {
            let name = chapter.volumeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty {
                flush(); groups.append(.chapter(index))
            } else if volume == name {
                indices.append(index)
            } else {
                flush(); volume = name; indices = [index]
            }
        }
        flush()
        return groups
    }

    private static func chapterEntry(index: Int, chapter: TXTEPUBChapter, headings: Headings,
                                     projection: ReadingTextProjection) -> Entry {
        Entry(path: "OEBPS/text/\(fileName(index)).xhtml",
              text: chapterDocument(title: headings.titles[index], volume: headings.volumes[index],
                                    body: projection.apply(chapter.body),
                                    startsVolume: headings.volumeStarts.contains(index)))
    }

    private static func chapterDocument(title: String, volume: String?, body: String, startsVolume: Bool) -> String {
        var lines: [String] = []
        if startsVolume, let volume, !volume.isEmpty {
            lines.append("<p class=\"volume\">\(TextChapterXHTML.escape(volume))</p>")
        }
        lines.append("<h1>\(TextChapterXHTML.escape(title))</h1>")
        for paragraph in TextChapterXHTML.paragraphs(fromLines: body) where !paragraph.text.isEmpty {
            lines.append("<p>\(TextChapterXHTML.escape(paragraph.text))</p>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">
        <head><title>\(TextChapterXHTML.escape(title))</title><link rel="stylesheet" type="text/css" href="../style.css"/></head>
        <body>
        \(lines.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func fixedEntries(title: String, author: String, identifier: String, modified: Date,
                                     chapterCount: Int, headings: Headings) -> [Entry] {
        [
            Entry(path: "mimetype", text: "application/epub+zip"),
            Entry(path: "META-INF/container.xml", text: containerXML),
            Entry(path: "OEBPS/content.opf", text: contentOPF(title: title, author: author, identifier: identifier,
                                                              modified: modified, chapterCount: chapterCount)),
            Entry(path: "OEBPS/nav.xhtml", text: navigationDocument(title: title, headings: headings)),
            Entry(path: "OEBPS/toc.ncx", text: ncxDocument(title: title, identifier: identifier, headings: headings)),
            Entry(path: "OEBPS/style.css", text: stylesheet)
        ]
    }

    private static func navigationDocument(title: String, headings: Headings) -> String {
        func item(_ index: Int) -> String {
            "<li><a href=\"text/\(fileName(index)).xhtml\">\(TextChapterXHTML.escape(headings.titles[index]))</a></li>"
        }
        let items: [String] = headings.groups.map { group in
            switch group {
            case .chapter(let index): return item(index)
            case .volume(let title, let indices):
                let children = indices.map(item).joined(separator: "\n")
                return "<li><span>\(TextChapterXHTML.escape(title))</span><ol>\n\(children)\n</ol></li>"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh">
        <head><title>\(TextChapterXHTML.escape(title))</title></head>
        <body>
        <nav epub:type="toc" id="toc"><h1>目录</h1><ol>
        \(items.joined(separator: "\n"))
        </ol></nav>
        </body>
        </html>
        """
    }

    private static func ncxDocument(title: String, identifier: String, headings: Headings) -> String {
        var points: [String] = []
        var order = 1
        var volumeNumber = 0, chapterNumber = 0
        func chapterPoint(_ index: Int, indent: String = "") -> String {
            chapterNumber += 1
            let point = """
            \(indent)<navPoint id="c\(chapterNumber)" playOrder="\(order)">
            \(indent)  <navLabel><text>\(TextChapterXHTML.escape(headings.titles[index]))</text></navLabel>
            \(indent)  <content src="text/\(fileName(index)).xhtml"/>
            \(indent)</navPoint>
            """
            order += 1
            return point
        }
        for group in headings.groups {
            switch group {
            case .chapter(let index):
                points.append(chapterPoint(index))
            case .volume(let volume, let indices):
                guard let first = indices.first else { continue }
                volumeNumber += 1
                let volumeOrder = order
                order += 1
                let inner = indices.map { chapterPoint($0, indent: "    ") }.joined(separator: "\n")
                points.append("""
                <navPoint id="v\(volumeNumber)" playOrder="\(volumeOrder)">
                  <navLabel><text>\(TextChapterXHTML.escape(volume))</text></navLabel>
                  <content src="text/\(fileName(first)).xhtml"/>
                \(inner)
                </navPoint>
                """)
            }
        }
        let depth = headings.groups.contains { group in
            if case .volume(_, _) = group { return true }
            return false
        } ? 2 : 1
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="zh">
        <head>
        <meta name="dtb:uid" content="\(TextChapterXHTML.escape(identifier))"/>
        <meta name="dtb:depth" content="\(depth)"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
        </head>
        <docTitle><text>\(TextChapterXHTML.escape(title))</text></docTitle>
        <navMap>
        \(points.joined(separator: "\n"))
        </navMap>
        </ncx>
        """
    }

    // MARK: - 包文档与写入

    private static func contentOPF(title: String, author: String, identifier: String,
                                   modified: Date, chapterCount: Int) -> String {
        let manifest = (0..<chapterCount).map {
            "<item id=\"c\($0 + 1)\" href=\"text/\(fileName($0)).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = (0..<chapterCount).map { "<itemref idref=\"c\($0 + 1)\"/>" }.joined(separator: "\n")
        let creator = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "\n    <dc:creator>\(TextChapterXHTML.escape(author))</dc:creator>"
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="zh">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(TextChapterXHTML.escape(identifier))</dc:identifier>
            <dc:title>\(TextChapterXHTML.escape(title))</dc:title>
            <dc:language>zh</dc:language>\(creator)
            <meta property="dcterms:modified">\(formatter.string(from: modified))</meta>
        </metadata>
        <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
        \(manifest)
        </manifest>
        <spine toc="ncx">
        \(spine)
        </spine>
        </package>
        """
    }

    private static func fileName(_ index: Int) -> String { String(format: "%04d", index + 1) }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    private static let stylesheet = """
    body { margin: 1em; line-height: 1.75; }
    h1 { font-size: 1.35em; font-weight: bold; line-height: 1.4; margin: 0.4em 0 1.2em 0; text-indent: 0; }
    p { text-indent: 2em; margin: 0 0 0.55em 0; text-align: justify; }
    p.volume { font-size: 0.8em; color: #3C8F68; text-indent: 0; margin: 0 0 1em 0; }
    """

    /// 逐章生成并写入；单章 XHTML 在追加后即可释放，峰值内存不再随章节数线性增长。
    private static func write(chapters: [TXTEPUBChapter], headings: Headings,
                              projection: ReadingTextProjection, fixed: [Entry],
                              to destination: URL) async throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".txt-epub-\(UUID().uuidString).epub")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            let archive = try await Archive(url: temporary, accessMode: .create)
            for entry in fixed {
                try await append(entry, to: archive)
            }
            for index in chapters.indices {
                let entry = chapterEntry(index: index, chapter: chapters[index],
                                         headings: headings, projection: projection)
                try await append(entry, to: archive)
            }
        } catch {
            throw TXTEPUBExportError.writeFailed(error.localizedDescription)
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private static func append(_ entry: Entry, to archive: Archive) async throws {
        let data = Data(entry.text.utf8)
        // EPUB 要求 mimetype 为首个且不压缩的条目。
        try await archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(data.count),
                                   modificationDate: Date(),
                                   compressionMethod: entry.path == "mimetype" ? .none : .deflate) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }
}
