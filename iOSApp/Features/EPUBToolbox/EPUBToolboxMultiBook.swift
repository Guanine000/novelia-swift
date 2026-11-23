// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ReadiumZIPFoundation
import SwiftSoup
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

// MARK: - 1. EPUB 内部文件浏览器 & 编辑器数据加载器

struct EPUBEditableSnapshot: Sendable {
    let title: String
    let author: String
    let language: String
    let description: String
    let coverImageData: Data?
    let tocNodes: [EPUBToolboxTOCNode]
}

enum EPUBArchivePreviewError: LocalizedError, Equatable {
    case missingEntry
    case entryTooLarge

    var errorDescription: String? {
        switch self {
        case .missingEntry: "压缩包中找不到该文件。"
        case .entryTooLarge: "文件太大，无法预览。"
        }
    }
}

enum EPUBArchiveBrowser {
    static func listEntries(url: URL) async throws -> EPUBArchiveListing {
        guard let archive = try? await Archive(url: url, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let entries = try await archive.entries()
        var entryByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file {
            let norm = EPUBToolboxPath.normalize(entry.path)
            if !norm.isEmpty { entryByPath[norm] = entry }
        }

        // 尝试解析 OPF 以计算资源是否被引用
        var reachable = Set<String>(["mimetype", "META-INF/container.xml"])
        if let opf = await loadOPF(from: archive, entryByPath: entryByPath) {
            reachable.insert(opf.opfPath)
            let used = await EPUBToolboxInspector.collectReachablePaths(
                opf: opf,
                archive: archive,
                entryByPath: entryByPath
            )
            reachable.formUnion(used)
        }

        let textExts: Set<String> = ["xhtml", "xht", "html", "htm", "css", "opf", "ncx", "xml", "svg", "js", "txt", "json", "smil"]
        let files: [EPUBArchiveEntryInfo] = entryByPath.keys.sorted().compactMap { path in
            guard let entry = entryByPath[path] else { return nil }
            let ext = EPUBToolboxPath.pathExtension(of: path)
            let mt = EPUBToolboxPath.inferredMediaType(for: path)
            let category: String
            if path == "mimetype" || path.hasPrefix("META-INF/") || ext == "opf" || ext == "ncx" {
                category = "容器与清单"
            } else {
                switch EPUBToolboxPath.sigilFolder(for: path, mediaType: mt) {
                case .text: category = "正文（Text）"
                case .styles: category = "样式（Styles）"
                case .images: category = "图片（Images）"
                case .fonts: category = "字体（Fonts）"
                case .misc: category = "其他（Misc）"
                }
            }
            let previewable = path == "mimetype" || textExts.contains(ext)
            return EPUBArchiveEntryInfo(
                path: path,
                archivePath: entry.path,
                category: category,
                uncompressedBytes: Int64(entry.uncompressedSize),
                isTextPreviewable: previewable,
                isReferenced: reachable.contains(path) || path.hasPrefix("META-INF/")
            )
        }
        let folders = entries.filter { $0.type == .directory }.map { EPUBToolboxPath.normalize($0.path) }
        return EPUBArchiveListing(entries: files, explicitFolders: folders)
    }

    static func readTextPreview(url: URL, entryPath: String) async throws -> String {
        let data = try await readPreviewData(url: url, entryPath: entryPath, maxBytes: 256 * 1024)
        return EPUBToolboxInspector.decodeText(data).text ?? "（无法以文本解码该文件）"
    }

    static func readPreviewData(url: URL, entryPath: String, maxBytes: Int = 32 * 1024 * 1024) async throws -> Data {
        guard let archive = try? await Archive(url: url, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        guard let entry = try? await archive.get(entryPath), entry.type == .file else {
            throw EPUBArchivePreviewError.missingEntry
        }
        guard entry.uncompressedSize <= Int64(maxBytes) else {
            throw EPUBArchivePreviewError.entryTooLarge
        }
        try Task.checkCancellation()
        return try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: maxBytes)
    }

    /// 读取书籍的当前元数据、封面图与目录树，供元数据编辑器与目录编辑器初始化使用。
    static func loadEditableSnapshot(url: URL) async throws -> EPUBEditableSnapshot {
        guard let archive = try? await Archive(url: url, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let entries = (try? await archive.entries()) ?? []
        var entryByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file {
            let norm = EPUBToolboxPath.normalize(entry.path)
            if !norm.isEmpty { entryByPath[norm] = entry }
        }
        guard let opf = await loadOPF(from: archive, entryByPath: entryByPath) else {
            throw EPUBToolboxError.missingOPF
        }

        let desc = opf.metadataEntries.first(where: {
            EPUBToolboxParsedOPF.localName($0.tagName) == "description" && !$0.text.isEmpty
        })?.text ?? ""

        var coverData: Data?
        if let coverItem = EPUBToolboxInspector.resolveCoverItem(in: opf, existingPaths: Set(entryByPath.keys)).item,
           let entry = entryByPath[coverItem.path] {
            coverData = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: 20 * 1024 * 1024)
        }

        var tocNodes: [EPUBToolboxTOCNode] = []
        if let navItem = opf.manifest.first(where: \.isNav),
           let entry = entryByPath[navItem.path],
           let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes),
           let html = EPUBToolboxInspector.decodeText(data).text {
            tocNodes = EPUBToolboxInspector.parseNavTOC(html: html, baseDirectory: EPUBToolboxPath.directory(of: navItem.path))
        }
        if tocNodes.isEmpty,
           let ncxItem = opf.manifest.first(where: { $0.id == opf.spineTocID || $0.isNCX }),
           let entry = entryByPath[ncxItem.path],
           let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes),
           let xml = EPUBToolboxInspector.decodeText(data).text {
            tocNodes = EPUBToolboxInspector.parseNCXTOC(xml: xml, baseDirectory: EPUBToolboxPath.directory(of: ncxItem.path))
        }

        return EPUBEditableSnapshot(
            title: opf.title.isEmpty ? url.deletingPathExtension().lastPathComponent : opf.title,
            author: opf.author,
            language: opf.language.isEmpty ? "zh" : opf.language,
            description: desc,
            coverImageData: coverData,
            tocNodes: tocNodes
        )
    }

    static func loadOPF(from archive: Archive, entryByPath: [String: Entry]) async -> EPUBToolboxParsedOPF? {
        var opfPath: String?
        if let containerEntry = entryByPath["META-INF/container.xml"],
           let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: containerEntry, limit: 1024 * 1024),
           let xml = EPUBToolboxInspector.decodeText(data).text,
           let parsed = EPUBToolboxInspector.parseContainerOPFPath(xml: xml),
           entryByPath[parsed] != nil {
            opfPath = parsed
        } else {
            opfPath = entryByPath.keys.sorted().first(where: { $0.lowercased().hasSuffix(".opf") })
        }
        guard let opfPath,
              let opfEntry = entryByPath[opfPath],
              let opfData = try? await EPUBToolboxInspector.extractData(from: archive, entry: opfEntry, limit: EPUBToolboxInspector.maxTextEntryBytes),
              let opfXML = EPUBToolboxInspector.decodeText(opfData).text else { return nil }
        return EPUBToolboxInspector.parseOPF(xml: opfXML, opfPath: opfPath)
    }
}

// MARK: - 2. EPUB 导出为纯文本 TXT

enum EPUBToolboxTXTExporter {
    struct ExportResult: Equatable, Sendable {
        let outputURL: URL
        let chapterCount: Int
        let characterCount: Int
    }

    static func exportToTXT(
        source: URL,
        destination: URL,
        rubyHandling: EPUBRubyHandling = .removeAnnotations,
        chineseConversion: EPUBChineseConversionOption = .none
    ) async throws -> ExportResult {
        let startedAt = MonotonicInstant.now
        do {
            let result = try await performExportToTXT(source: source, destination: destination, rubyHandling: rubyHandling, chineseConversion: chineseConversion)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            EPUBToolboxDiagnosticLog.logActionCompleted(action: "exportTXT", items: result.chapterCount, bytes: bytes, since: startedAt)
            return result
        } catch {
            EPUBToolboxDiagnosticLog.logActionFailed(action: "exportTXT", error: error, since: startedAt)
            throw error
        }
    }

    private static func performExportToTXT(
        source: URL,
        destination: URL,
        rubyHandling: EPUBRubyHandling = .removeAnnotations,
        chineseConversion: EPUBChineseConversionOption = .none
    ) async throws -> ExportResult {
        guard let archive = try? await Archive(url: source, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let entries = (try? await archive.entries()) ?? []
        var entryByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file {
            let norm = EPUBToolboxPath.normalize(entry.path)
            if !norm.isEmpty { entryByPath[norm] = entry }
        }
        if let encEntry = entryByPath["META-INF/encryption.xml"],
           let encData = try? await EPUBToolboxInspector.extractData(from: archive, entry: encEntry, limit: 2 * 1024 * 1024),
           let encXML = EPUBToolboxInspector.decodeText(encData).text,
           EPUBToolboxInspector.detectsDRM(inEncryptionXML: encXML) {
            throw EPUBToolboxError.drmProtected
        }
        guard let opf = await EPUBArchiveBrowser.loadOPF(from: archive, entryByPath: entryByPath) else {
            throw EPUBToolboxError.missingOPF
        }

        let manifestByID = Dictionary(opf.manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sections: [String] = []
        let bookTitle = opf.title.isEmpty ? source.deletingPathExtension().lastPathComponent : opf.title
        var header = bookTitle
        if !opf.author.isEmpty { header += "\n作者：\(opf.author)" }
        sections.append(EPUBToolboxTransforms.convertText(header, option: chineseConversion))

        var chapterCount = 0
        for sp in opf.spine {
            if Task.isCancelled { throw EPUBToolboxError.cancelled }
            guard let item = manifestByID[sp.idref],
                  item.isXHTML,
                  let entry = entryByPath[item.path],
                  let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes),
                  let html = EPUBToolboxInspector.decodeText(data).text,
                  let doc = try? SwiftSoup.parse(html) else { continue }

            _ = EPUBToolboxTransforms.processRuby(in: doc, mode: rubyHandling)
            // 移除 script/style/head
            if let removals = try? doc.select("script, style, head").array() {
                for el in removals { _ = try? el.remove() }
            }
            var lines: [String] = []
            if let blocks = try? doc.select("h1, h2, h3, h4, h5, h6, p, li, blockquote, pre").array(), !blocks.isEmpty {
                for block in blocks {
                    guard let text = try? block.text() else { continue }
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { lines.append(cleaned) }
                }
            } else if let bodyText = try? doc.body()?.text() {
                let cleaned = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { lines.append(cleaned) }
            }
            if !lines.isEmpty {
                chapterCount += 1
                let joined = lines.joined(separator: "\n\n")
                sections.append(EPUBToolboxTransforms.convertText(joined, option: chineseConversion))
            }
        }

        let fullText = sections.joined(separator: "\n\n\n") + "\n"
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fullText.utf8).write(to: destination, options: .atomic)
        return ExportResult(outputURL: destination, chapterCount: chapterCount, characterCount: fullText.count)
    }
}

// MARK: - 3. 多卷 EPUB 合并

enum EPUBToolboxMerger {
    struct VolumeInput: Sendable {
        let title: String
        let url: URL
    }

    struct MergeResult: Equatable, Sendable {
        let outputURL: URL
        let volumeCount: Int
        let totalSpineCount: Int
        let outputSizeBytes: Int64
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_767_225_600)

    /// 将多卷 EPUB 合并为一本标准 EPUB 3（每卷独立前缀防重名，以卷为一级目录合并原目录，保留首卷封面）。
    static func merge(
        volumes: [VolumeInput],
        title: String,
        author: String,
        destination: URL,
        onProgress: (@Sendable (EPUBToolboxProgress) -> Void)? = nil
    ) async throws -> MergeResult {
        let startedAt = MonotonicInstant.now
        do {
            let result = try await performMerge(volumes: volumes, title: title, author: author, destination: destination, onProgress: onProgress)
            EPUBToolboxDiagnosticLog.logActionCompleted(action: "merge", items: result.volumeCount, bytes: result.outputSizeBytes, since: startedAt)
            return result
        } catch {
            EPUBToolboxDiagnosticLog.logActionFailed(action: "merge", error: error, since: startedAt)
            throw error
        }
    }

    private static func performMerge(
        volumes: [VolumeInput],
        title: String,
        author: String,
        destination: URL,
        onProgress: (@Sendable (EPUBToolboxProgress) -> Void)? = nil
    ) async throws -> MergeResult {
        guard volumes.count >= 2 else {
            throw EPUBToolboxError.writeFailed("至少需要选择 2 本 EPUB 才能合并。")
        }

        let tempDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(".epub-merge-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let outArchive = try? await Archive(url: tempURL, accessMode: .create) else {
            throw EPUBToolboxError.writeFailed("无法创建合并输出文件")
        }

        var writtenPaths = Set<String>()
        func writeEntry(path: String, data: Data, compression: CompressionMethod) async throws {
            let norm = EPUBToolboxPath.normalize(path)
            guard !norm.isEmpty, writtenPaths.insert(norm).inserted else { return }
            try await outArchive.addEntry(
                with: norm,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: fixedDate,
                compressionMethod: compression
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }

        try await writeEntry(path: "mimetype", data: Data("application/epub+zip".utf8), compression: .none)
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>

        """
        try await writeEntry(path: "META-INF/container.xml", data: Data(containerXML.utf8), compression: .deflate)

        var mergedManifest: [EPUBToolboxManifestItem] = []
        var mergedSpine: [EPUBToolboxSpineItem] = []
        var mergedTOCNodes: [EPUBToolboxTOCNode] = []
        var usedPaths = Set<String>(["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/toc.ncx", "OEBPS/Text/nav.xhtml"])
        var firstCoverID: String?
        var detectedLang = "zh"

        for (volIndex, volume) in volumes.enumerated() {
            if Task.isCancelled { throw EPUBToolboxError.cancelled }
            let prefix = String(format: "v%02d_", volIndex + 1)
            onProgress?(EPUBToolboxProgress(
                fraction: 0.1 + 0.8 * (Double(volIndex) / Double(volumes.count)),
                stage: "正在合并第 \(volIndex + 1)/\(volumes.count) 卷：\(volume.title)…"
            ))

            guard let archive = try? await Archive(url: volume.url, accessMode: .read) else {
                throw EPUBToolboxError.invalidArchive
            }
            let entries = (try? await archive.entries()) ?? []
            var entryByPath: [String: Entry] = [:]
            for entry in entries where entry.type == .file {
                let norm = EPUBToolboxPath.normalize(entry.path)
                if !norm.isEmpty { entryByPath[norm] = entry }
            }
            if let encEntry = entryByPath["META-INF/encryption.xml"],
               let encData = try? await EPUBToolboxInspector.extractData(from: archive, entry: encEntry, limit: 2 * 1024 * 1024),
               let encXML = EPUBToolboxInspector.decodeText(encData).text,
               EPUBToolboxInspector.detectsDRM(inEncryptionXML: encXML) {
                throw EPUBToolboxError.drmProtected
            }
            guard let opf = await EPUBArchiveBrowser.loadOPF(from: archive, entryByPath: entryByPath) else {
                throw EPUBToolboxError.missingOPF
            }
            if volIndex == 0 && !opf.language.isEmpty { detectedLang = opf.language }

            // 计算本卷各资源在合并包中的路径映射
            var pathMap: [String: String] = [:]
            var idMap: [String: String] = [:]
            let coverItem = EPUBToolboxInspector.resolveCoverItem(in: opf, existingPaths: Set(entryByPath.keys)).item

            for item in opf.manifest where entryByPath[item.path] != nil {
                if item.isNCX || item.isNav { continue }
                let newID = prefix + EPUBToolboxPath.sanitizedFilename(item.id, fallback: "item")
                idMap[item.id] = newID
                let folder = EPUBToolboxPath.sigilFolder(for: item.path, mediaType: item.mediaType).rawValue
                let rawName = EPUBToolboxPath.filename(of: item.path)
                let baseName: String
                if item.isXHTML {
                    let stem = URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
                    baseName = prefix + EPUBToolboxPath.sanitizedFilename(stem, fallback: "section") + ".xhtml"
                } else {
                    baseName = prefix + EPUBToolboxPath.sanitizedFilename(rawName, fallback: "res")
                }
                let targetPath = uniquePath(folder: folder, filename: baseName, used: &usedPaths)
                pathMap[item.path] = targetPath

                var props = item.properties
                props.remove("nav")
                props.remove("cover-image")
                if volIndex == 0, let coverItem, coverItem.id == item.id {
                    props.insert("cover-image")
                    firstCoverID = newID
                }
                mergedManifest.append(EPUBToolboxManifestItem(
                    id: newID,
                    path: targetPath,
                    mediaType: item.isXHTML ? "application/xhtml+xml" : item.mediaType,
                    properties: props,
                    fallback: nil
                ))
            }

            var firstSpinePathOfVolume: String?
            for sp in opf.spine {
                guard let newID = idMap[sp.idref] else { continue }
                mergedSpine.append(EPUBToolboxSpineItem(idref: newID, linear: sp.linear, properties: sp.properties))
                if firstSpinePathOfVolume == nil, let m = mergedManifest.first(where: { $0.id == newID }) {
                    firstSpinePathOfVolume = m.path
                }
            }

            // 写入本卷资源（重写相对链接）
            for item in opf.manifest where pathMap[item.path] != nil {
                guard let newPath = pathMap[item.path], let entry = entryByPath[item.path] else { continue }
                let oldDir = EPUBToolboxPath.directory(of: item.path)
                let newDir = EPUBToolboxPath.directory(of: newPath)
                if item.isXHTML {
                    let data = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                    if let html = EPUBToolboxInspector.decodeText(data).text {
                        let rewritten = rewriteLinksInXHTML(html, oldDir: oldDir, newDir: newDir, pathMap: pathMap)
                        try await writeEntry(path: newPath, data: Data(rewritten.utf8), compression: .deflate)
                    } else {
                        try await writeEntry(path: newPath, data: data, compression: .deflate)
                    }
                } else if item.isCSS {
                    let data = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                    if let css = EPUBToolboxInspector.decodeText(data).text {
                        let rewritten = rewriteCSSURLs(css, oldDir: oldDir, newDir: newDir, pathMap: pathMap)
                        try await writeEntry(path: newPath, data: Data(rewritten.utf8), compression: .deflate)
                    } else {
                        try await writeEntry(path: newPath, data: data, compression: .deflate)
                    }
                } else {
                    let data = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: 128 * 1024 * 1024)
                    try await writeEntry(path: newPath, data: data, compression: .deflate)
                }
            }

            // 合并本卷目录为二级子节点
            let snapshot = try? await EPUBArchiveBrowser.loadEditableSnapshot(url: volume.url)
            let mappedChildren = remapNodes(snapshot?.tocNodes ?? [], pathMap: pathMap)
            let volTitle = volume.title.isEmpty ? (opf.title.isEmpty ? "第 \(volIndex + 1) 卷" : opf.title) : volume.title
            if let rootPath = mappedChildren.first?.path ?? firstSpinePathOfVolume {
                mergedTOCNodes.append(EPUBToolboxTOCNode(
                    title: volTitle,
                    path: rootPath,
                    fragment: "",
                    children: mappedChildren
                ))
            }
        }

        // 添加统一 nav.xhtml 与 toc.ncx
        let navItem = EPUBToolboxManifestItem(id: "nav", path: "OEBPS/Text/nav.xhtml", mediaType: "application/xhtml+xml", properties: ["nav"], fallback: nil)
        let ncxItem = EPUBToolboxManifestItem(id: "ncx", path: "OEBPS/toc.ncx", mediaType: "application/x-dtbncx+xml", properties: [], fallback: nil)
        mergedManifest.insert(navItem, at: 0)
        mergedManifest.insert(ncxItem, at: 0)

        let bookID = "urn:uuid:\(UUID().uuidString)"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var metadata: [EPUBToolboxMetadataEntry] = [
            EPUBToolboxMetadataEntry(tagName: "dc:title", attributes: [], text: title.isEmpty ? "合集" : title),
            EPUBToolboxMetadataEntry(tagName: "dc:language", attributes: [], text: detectedLang),
            EPUBToolboxMetadataEntry(tagName: "dc:identifier", attributes: [("id", "BookId")], text: bookID),
            EPUBToolboxMetadataEntry(tagName: "meta", attributes: [("property", "dcterms:modified")], text: formatter.string(from: Date())),
        ]
        if !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata.append(EPUBToolboxMetadataEntry(tagName: "dc:creator", attributes: [], text: author))
        }
        if let firstCoverID {
            metadata.append(EPUBToolboxMetadataEntry(tagName: "meta", attributes: [("content", firstCoverID), ("name", "cover")], text: ""))
        }

        let opfXML = renderMinimalOPF(
            version: "3.0",
            uniqueID: "BookId",
            tocID: "ncx",
            metadata: metadata,
            manifest: mergedManifest,
            spine: mergedSpine
        )
        let ncxXML = renderNCX(title: title, identifier: bookID, nodes: mergedTOCNodes, baseDir: "OEBPS")
        let navHTML = renderNav(title: title, language: detectedLang, nodes: mergedTOCNodes, baseDir: "OEBPS/Text")

        try await writeEntry(path: "OEBPS/content.opf", data: Data(opfXML.utf8), compression: .deflate)
        try await writeEntry(path: "OEBPS/toc.ncx", data: Data(ncxXML.utf8), compression: .deflate)
        try await writeEntry(path: "OEBPS/Text/nav.xhtml", data: Data(navHTML.utf8), compression: .deflate)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tempURL, to: destination)
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        onProgress?(EPUBToolboxProgress(fraction: 1.0, stage: "合并完成"))
        return MergeResult(outputURL: destination, volumeCount: volumes.count, totalSpineCount: mergedSpine.count, outputSizeBytes: size)
    }

    // MARK: - 内部共享序列化/重写工具

    fileprivate static func uniquePath(folder: String, filename: String, used: inout Set<String>) -> String {
        let base = EPUBToolboxPath.normalize("\(folder)/\(filename)")
        if used.insert(base).inserted { return base }
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            let candidate = EPUBToolboxPath.normalize("\(folder)/\(name)")
            if used.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    fileprivate static func remapNodes(_ nodes: [EPUBToolboxTOCNode], pathMap: [String: String]) -> [EPUBToolboxTOCNode] {
        nodes.compactMap { node in
            let children = remapNodes(node.children, pathMap: pathMap)
            if let mapped = pathMap[node.path] {
                return EPUBToolboxTOCNode(title: node.title, path: mapped, fragment: node.fragment, children: children)
            }
            if let firstChild = children.first {
                return EPUBToolboxTOCNode(title: node.title, path: firstChild.path, fragment: firstChild.fragment, children: children)
            }
            return nil
        }
    }

    fileprivate static func rewriteLinksInXHTML(_ html: String, oldDir: String, newDir: String, pathMap: [String: String]) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return html }
        doc.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).charset(.utf8).prettyPrint(pretty: false)
        if let root = try? doc.select("html").first() {
            if (try? root.attr("xmlns"))?.isEmpty != false { _ = try? root.attr("xmlns", "http://www.w3.org/1999/xhtml") }
            if (try? root.attr("xmlns:epub"))?.isEmpty != false { _ = try? root.attr("xmlns:epub", "http://www.idpf.org/2007/ops") }
        }
        for attr in ["href", "src", "poster", "xlink:href", "data"] {
            guard let els = try? doc.select("[\(attr)]").array() else { continue }
            for el in els {
                guard let raw = try? el.attr(attr),
                      let resolved = EPUBToolboxPath.resolveRelative(raw, baseDirectory: oldDir),
                      let target = pathMap[resolved.path] else { continue }
                let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: newDir, to: target)) + resolved.suffix
                _ = try? el.attr(attr, rel)
            }
        }
        let body = (try? doc.select("html").first()?.outerHtml()) ?? (try? doc.outerHtml()) ?? html
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>\n\(body)\n"
    }

    fileprivate static func rewriteCSSURLs(_ css: String, oldDir: String, newDir: String, pathMap: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"url\(\s*(["']?)([^)"'\s]+)\1\s*\)"#, options: [.caseInsensitive]) else {
            return css
        }
        let ns = css as NSString
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return css }
        let mutable = NSMutableString(string: css)
        for match in matches.reversed() {
            let raw = ns.substring(with: match.range(at: 2))
            guard let resolved = EPUBToolboxPath.resolveRelative(raw, baseDirectory: oldDir),
                  let target = pathMap[resolved.path] else { continue }
            let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: newDir, to: target)) + resolved.suffix
            mutable.replaceCharacters(in: match.range, with: "url(\"\(rel)\")")
        }
        return mutable as String
    }

    fileprivate static func renderMinimalOPF(
        version: String,
        uniqueID: String,
        tocID: String,
        metadata: [EPUBToolboxMetadataEntry],
        manifest: [EPUBToolboxManifestItem],
        spine: [EPUBToolboxSpineItem]
    ) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="utf-8"?>"#,
            #"<package xmlns="http://www.idpf.org/2007/opf" version="\#(version)" unique-identifier="\#(uniqueID)">"#,
            #"  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">"#,
        ]
        for entry in metadata {
            let attrs = entry.attributes.map { #" \#($0.0)="\#(EPUBToolboxPath.xmlEscaped($0.1))""# }.joined()
            if entry.text.isEmpty {
                lines.append("    <\(entry.tagName)\(attrs)/>")
            } else {
                lines.append("    <\(entry.tagName)\(attrs)>\(EPUBToolboxPath.xmlEscaped(entry.text))</\(entry.tagName)>")
            }
        }
        lines.append("  </metadata>")
        lines.append("  <manifest>")
        for item in manifest {
            let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: "OEBPS", to: item.path))
            var attrs = [#"id="\#(EPUBToolboxPath.xmlEscaped(item.id))""#, #"href="\#(EPUBToolboxPath.xmlEscaped(rel))""#, #"media-type="\#(EPUBToolboxPath.xmlEscaped(item.mediaType))""#]
            if !item.properties.isEmpty {
                attrs.append(#"properties="\#(EPUBToolboxPath.xmlEscaped(item.properties.sorted().joined(separator: " ")))""#)
            }
            lines.append("    <item \(attrs.joined(separator: " "))/>")
        }
        lines.append("  </manifest>")
        lines.append("  <spine toc=\"\(EPUBToolboxPath.xmlEscaped(tocID))\">")
        for sp in spine {
            lines.append("    <itemref idref=\"\(EPUBToolboxPath.xmlEscaped(sp.idref))\"/>")
        }
        lines.append("  </spine>")
        lines.append("</package>")
        return lines.joined(separator: "\n") + "\n"
    }

    fileprivate static func renderNCX(title: String, identifier: String, nodes: [EPUBToolboxTOCNode], baseDir: String) -> String {
        var order = 0
        func walk(_ list: [EPUBToolboxTOCNode], indent: String) -> String {
            var out = ""
            for node in list {
                order += 1
                let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: baseDir, to: node.path)) + node.fragment
                out += "\(indent)<navPoint id=\"navPoint-\(order)\" playOrder=\"\(order)\">\n"
                out += "\(indent)  <navLabel><text>\(EPUBToolboxPath.xmlEscaped(node.title))</text></navLabel>\n"
                out += "\(indent)  <content src=\"\(EPUBToolboxPath.xmlEscaped(rel))\"/>\n"
                if !node.children.isEmpty { out += walk(node.children, indent: indent + "  ") }
                out += "\(indent)</navPoint>\n"
            }
            return out
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(EPUBToolboxPath.xmlEscaped(identifier))"/>
            <meta name="dtb:depth" content="2"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle><text>\(EPUBToolboxPath.xmlEscaped(title))</text></docTitle>
          <navMap>
        \(walk(nodes, indent: "    "))  </navMap>
        </ncx>

        """
    }

    fileprivate static func renderNav(title: String, language: String, nodes: [EPUBToolboxTOCNode], baseDir: String) -> String {
        func walk(_ list: [EPUBToolboxTOCNode], indent: String) -> String {
            var out = "\(indent)<ol>\n"
            for node in list {
                let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: baseDir, to: node.path)) + node.fragment
                out += "\(indent)  <li><a href=\"\(EPUBToolboxPath.xmlEscaped(rel))\">\(EPUBToolboxPath.xmlEscaped(node.title))</a>"
                if !node.children.isEmpty { out += "\n" + walk(node.children, indent: indent + "    ") + "\(indent)  " }
                out += "</li>\n"
            }
            out += "\(indent)</ol>\n"
            return out
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(EPUBToolboxPath.xmlEscaped(language))" lang="\(EPUBToolboxPath.xmlEscaped(language))">
          <head><meta charset="utf-8"/><title>\(EPUBToolboxPath.xmlEscaped(title))</title></head>
          <body>
            <nav epub:type="toc" id="toc">
              <h1>目录</h1>
        \(walk(nodes, indent: "      "))    </nav>
          </body>
        </html>

        """
    }
}

// MARK: - 4. 合集 EPUB 拆分

enum EPUBToolboxSplitter {
    struct SplitGroup: Identifiable, Equatable, Sendable {
        let id = UUID()
        var title: String
        var spineRange: Range<Int>
        var tocNodes: [EPUBToolboxTOCNode]
    }

    struct SplitVolumeResult: Identifiable, Equatable, Sendable {
        let id = UUID()
        let title: String
        let outputURL: URL
        let spineCount: Int
        let sizeBytes: Int64
    }

    /// 按一级目录自动规划拆分分组；若目录不足 2 项，则按固定章数均分。
    static func proposeGroups(url: URL, fallbackChaptersPerPart: Int = 20) async throws -> [SplitGroup] {
        guard let archive = try? await Archive(url: url, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let entries = (try? await archive.entries()) ?? []
        var entryByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file {
            let norm = EPUBToolboxPath.normalize(entry.path)
            if !norm.isEmpty { entryByPath[norm] = entry }
        }
        guard let opf = await EPUBArchiveBrowser.loadOPF(from: archive, entryByPath: entryByPath),
              !opf.spine.isEmpty else {
            throw EPUBToolboxError.missingOPF
        }
        let manifestByID = Dictionary(opf.manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spinePaths = opf.spine.compactMap { manifestByID[$0.idref]?.path }
        let indexByPath = Dictionary(spinePaths.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

        let snapshot = try? await EPUBArchiveBrowser.loadEditableSnapshot(url: url)
        let topNodes = snapshot?.tocNodes ?? []
        var anchors: [(index: Int, node: EPUBToolboxTOCNode)] = []
        for node in topNodes {
            if let idx = indexByPath[node.path] {
                if anchors.last?.index != idx {
                    anchors.append((idx, node))
                }
            }
        }
        anchors.sort { $0.index < $1.index }

        if anchors.count >= 2 {
            var groups: [SplitGroup] = []
            for i in anchors.indices {
                let start = (i == 0) ? 0 : anchors[i].index
                let end = (i + 1 < anchors.count) ? anchors[i + 1].index : spinePaths.count
                guard start < end else { continue }
                let node = anchors[i].node
                let children = node.children.isEmpty ? [node] : node.children
                groups.append(SplitGroup(title: node.title, spineRange: start..<end, tocNodes: children))
            }
            if groups.count >= 2 { return groups }
        }

        // 回退：按章节数均匀切分
        let step = max(1, min(fallbackChaptersPerPart, max(1, spinePaths.count / 2)))
        var groups: [SplitGroup] = []
        var start = 0
        var part = 1
        while start < spinePaths.count {
            let end = min(start + step, spinePaths.count)
            groups.append(SplitGroup(title: "第 \(part) 部分", spineRange: start..<end, tocNodes: []))
            start = end
            part += 1
        }
        return groups
    }

    /// 按选定分组将单本合集 EPUB 拆分为多本独立标准 EPUB 3（每本只保留自身可达资源）。
    static func split(
        source: URL,
        groups: [SplitGroup],
        outputDirectory: URL,
        onProgress: (@Sendable (EPUBToolboxProgress) -> Void)? = nil
    ) async throws -> [SplitVolumeResult] {
        let startedAt = MonotonicInstant.now
        do {
            let results = try await performSplit(source: source, groups: groups, outputDirectory: outputDirectory, onProgress: onProgress)
            let totalBytes = results.reduce(Int64(0)) { $0 + $1.sizeBytes }
            EPUBToolboxDiagnosticLog.logActionCompleted(action: "split", items: results.count, bytes: totalBytes, since: startedAt)
            return results
        } catch {
            EPUBToolboxDiagnosticLog.logActionFailed(action: "split", error: error, since: startedAt)
            throw error
        }
    }

    private static func performSplit(
        source: URL,
        groups: [SplitGroup],
        outputDirectory: URL,
        onProgress: (@Sendable (EPUBToolboxProgress) -> Void)? = nil
    ) async throws -> [SplitVolumeResult] {
        guard !groups.isEmpty else {
            throw EPUBToolboxError.writeFailed("没有可拆分的分组。")
        }
        guard let archive = try? await Archive(url: source, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let entries = (try? await archive.entries()) ?? []
        var entryByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file {
            let norm = EPUBToolboxPath.normalize(entry.path)
            if !norm.isEmpty { entryByPath[norm] = entry }
        }
        if let encEntry = entryByPath["META-INF/encryption.xml"],
           let encData = try? await EPUBToolboxInspector.extractData(from: archive, entry: encEntry, limit: 2 * 1024 * 1024),
           let encXML = EPUBToolboxInspector.decodeText(encData).text,
           EPUBToolboxInspector.detectsDRM(inEncryptionXML: encXML) {
            throw EPUBToolboxError.drmProtected
        }
        guard let opf = await EPUBArchiveBrowser.loadOPF(from: archive, entryByPath: entryByPath) else {
            throw EPUBToolboxError.missingOPF
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var results: [SplitVolumeResult] = []
        let fixedDate = Date(timeIntervalSince1970: 1_767_225_600)

        for (idx, group) in groups.enumerated() {
            if Task.isCancelled { throw EPUBToolboxError.cancelled }
            onProgress?(EPUBToolboxProgress(
                fraction: Double(idx) / Double(groups.count),
                stage: "正在拆分第 \(idx + 1)/\(groups.count) 册：\(group.title)…"
            ))

            let safeRange = max(0, group.spineRange.lowerBound)..<min(opf.spine.count, group.spineRange.upperBound)
            guard !safeRange.isEmpty else { continue }
            let subSpine = Array(opf.spine[safeRange])

            // 构造子 OPF 计算本册可达资源，实现零冗余打包
            var subOPF = opf
            subOPF.spine = subSpine
            subOPF.guide = []
            let reachable = await EPUBToolboxInspector.collectReachablePaths(
                opf: subOPF,
                archive: archive,
                entryByPath: entryByPath
            )

            let fileName = String(format: "%02d_%@.epub", idx + 1, EPUBToolboxPath.sanitizedFilename(group.title, fallback: "part\(idx + 1)"))
            let destURL = outputDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destURL.path) { try FileManager.default.removeItem(at: destURL) }

            guard let outArchive = try? await Archive(url: destURL, accessMode: .create) else {
                throw EPUBToolboxError.writeFailed("无法创建拆分文件 \(fileName)")
            }

            var written = Set<String>()
            func writeEntry(path: String, data: Data, compression: CompressionMethod) async throws {
                let norm = EPUBToolboxPath.normalize(path)
                guard !norm.isEmpty, written.insert(norm).inserted else { return }
                try await outArchive.addEntry(
                    with: norm,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    modificationDate: fixedDate,
                    compressionMethod: compression
                ) { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                }
            }

            try await writeEntry(path: "mimetype", data: Data("application/epub+zip".utf8), compression: .none)
            let containerXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>

            """
            try await writeEntry(path: "META-INF/container.xml", data: Data(containerXML.utf8), compression: .deflate)

            var usedPaths = Set<String>(["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/toc.ncx", "OEBPS/Text/nav.xhtml"])
            var pathMap: [String: String] = [:]
            var subManifest: [EPUBToolboxManifestItem] = []

            for item in opf.manifest where reachable.contains(item.path) && entryByPath[item.path] != nil {
                if item.isNCX || item.isNav { continue }
                let folder = EPUBToolboxPath.sigilFolder(for: item.path, mediaType: item.mediaType).rawValue
                let rawName = EPUBToolboxPath.filename(of: item.path)
                let targetName = item.isXHTML
                    ? EPUBToolboxPath.sanitizedFilename(URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent, fallback: "section") + ".xhtml"
                    : EPUBToolboxPath.sanitizedFilename(rawName, fallback: "res")
                let targetPath = EPUBToolboxMerger.uniquePath(folder: folder, filename: targetName, used: &usedPaths)
                pathMap[item.path] = targetPath
                var props = item.properties
                props.remove("nav")
                subManifest.append(EPUBToolboxManifestItem(
                    id: item.id,
                    path: targetPath,
                    mediaType: item.isXHTML ? "application/xhtml+xml" : item.mediaType,
                    properties: props,
                    fallback: nil
                ))
            }

            for item in opf.manifest where pathMap[item.path] != nil {
                guard let newPath = pathMap[item.path], let entry = entryByPath[item.path] else { continue }
                let oldDir = EPUBToolboxPath.directory(of: item.path)
                let newDir = EPUBToolboxPath.directory(of: newPath)
                if item.isXHTML {
                    let data = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                    if let html = EPUBToolboxInspector.decodeText(data).text {
                        let rewritten = EPUBToolboxMerger.rewriteLinksInXHTML(html, oldDir: oldDir, newDir: newDir, pathMap: pathMap)
                        try await writeEntry(path: newPath, data: Data(rewritten.utf8), compression: .deflate)
                    } else {
                        try await writeEntry(path: newPath, data: data, compression: .deflate)
                    }
                } else if item.isCSS {
                    let data = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                    if let css = EPUBToolboxInspector.decodeText(data).text {
                        let rewritten = EPUBToolboxMerger.rewriteCSSURLs(css, oldDir: oldDir, newDir: newDir, pathMap: pathMap)
                        try await writeEntry(path: newPath, data: Data(rewritten.utf8), compression: .deflate)
                    } else {
                        try await writeEntry(path: newPath, data: data, compression: .deflate)
                    }
                } else {
                    let data = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: 128 * 1024 * 1024)
                    try await writeEntry(path: newPath, data: data, compression: .deflate)
                }
            }

            let manifestByID = Dictionary(subManifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var toc = EPUBToolboxMerger.remapNodes(group.tocNodes, pathMap: pathMap)
            if toc.isEmpty {
                toc = subSpine.enumerated().compactMap { i, sp in
                    guard let m = manifestByID[sp.idref] else { return nil }
                    return EPUBToolboxTOCNode(title: "第 \(i + 1) 章", path: m.path, fragment: "", children: [])
                }
            }

            subManifest.insert(EPUBToolboxManifestItem(id: "nav", path: "OEBPS/Text/nav.xhtml", mediaType: "application/xhtml+xml", properties: ["nav"], fallback: nil), at: 0)
            subManifest.insert(EPUBToolboxManifestItem(id: "ncx", path: "OEBPS/toc.ncx", mediaType: "application/x-dtbncx+xml", properties: [], fallback: nil), at: 0)

            let bookID = "urn:uuid:\(UUID().uuidString)"
            let lang = opf.language.isEmpty ? "zh" : opf.language
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            var metadata: [EPUBToolboxMetadataEntry] = [
                EPUBToolboxMetadataEntry(tagName: "dc:title", attributes: [], text: group.title),
                EPUBToolboxMetadataEntry(tagName: "dc:language", attributes: [], text: lang),
                EPUBToolboxMetadataEntry(tagName: "dc:identifier", attributes: [("id", "BookId")], text: bookID),
                EPUBToolboxMetadataEntry(tagName: "meta", attributes: [("property", "dcterms:modified")], text: formatter.string(from: Date())),
            ]
            if !opf.author.isEmpty {
                metadata.append(EPUBToolboxMetadataEntry(tagName: "dc:creator", attributes: [], text: opf.author))
            }

            let opfXML = EPUBToolboxMerger.renderMinimalOPF(version: "3.0", uniqueID: "BookId", tocID: "ncx", metadata: metadata, manifest: subManifest, spine: subSpine)
            let ncxXML = EPUBToolboxMerger.renderNCX(title: group.title, identifier: bookID, nodes: toc, baseDir: "OEBPS")
            let navHTML = EPUBToolboxMerger.renderNav(title: group.title, language: lang, nodes: toc, baseDir: "OEBPS/Text")

            try await writeEntry(path: "OEBPS/content.opf", data: Data(opfXML.utf8), compression: .deflate)
            try await writeEntry(path: "OEBPS/toc.ncx", data: Data(ncxXML.utf8), compression: .deflate)
            try await writeEntry(path: "OEBPS/Text/nav.xhtml", data: Data(navHTML.utf8), compression: .deflate)

            let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            results.append(SplitVolumeResult(title: group.title, outputURL: destURL, spineCount: subSpine.count, sizeBytes: size))
        }

        onProgress?(EPUBToolboxProgress(fraction: 1.0, stage: "拆分完成"))
        return results
    }
}
