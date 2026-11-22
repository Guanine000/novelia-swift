// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ReadiumZIPFoundation
import SwiftSoup

/// EPUB 工具箱核心处理引擎：执行目录结构标准化、XHTML 良构修复、OPF/目录/封面修复与冗余资源清理。
/// 所有处理只读取源文件并在临时文件写入完成后原子替换到目标路径，绝不修改原 EPUB。
enum EPUBToolboxProcessor {
    private static let fixedEntryDate = Date(timeIntervalSince1970: 1_767_225_600)

    static func process(
        source: URL,
        destination: URL,
        options: EPUBToolboxOptions,
        onProgress: (@Sendable (EPUBToolboxProgress) -> Void)? = nil
    ) async throws -> EPUBToolboxResult {
        guard options.hasAnyEnabled else { throw EPUBToolboxError.nothingSelected }
        try checkCancelled()

        onProgress?(EPUBToolboxProgress(fraction: 0.05, stage: "正在读取 EPUB 容器…"))
        guard let archive = try? await Archive(url: source, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0

        let archiveEntries = (try? await archive.entries()) ?? []
        var entryByPath: [String: Entry] = [:]
        for entry in archiveEntries where entry.type == .file {
            let norm = EPUBToolboxPath.normalize(entry.path)
            if !norm.isEmpty {
                entryByPath[norm] = entry
            }
        }

        // 1) DRM 保护检查
        if let encEntry = entryByPath["META-INF/encryption.xml"],
           let encData = try? await EPUBToolboxInspector.extractData(from: archive, entry: encEntry, limit: 2 * 1024 * 1024),
           let encXML = EPUBToolboxInspector.decodeText(encData).text,
           EPUBToolboxInspector.detectsDRM(inEncryptionXML: encXML) {
            throw EPUBToolboxError.drmProtected
        }

        // 2) 定位并解析 OPF
        var containerOPFPath: String?
        if let containerEntry = entryByPath["META-INF/container.xml"],
           let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: containerEntry, limit: 1024 * 1024),
           let xml = EPUBToolboxInspector.decodeText(data).text {
            containerOPFPath = EPUBToolboxInspector.parseContainerOPFPath(xml: xml)
        }
        let originalOPFPath: String
        if let path = containerOPFPath, entryByPath[path] != nil {
            originalOPFPath = path
        } else if let found = entryByPath.keys.sorted().first(where: { $0.lowercased().hasSuffix(".opf") }) {
            originalOPFPath = found
        } else {
            throw EPUBToolboxError.missingOPF
        }

        guard let opfEntry = entryByPath[originalOPFPath],
              let opfData = try? await EPUBToolboxInspector.extractData(from: archive, entry: opfEntry, limit: EPUBToolboxInspector.maxTextEntryBytes),
              let opfXML = EPUBToolboxInspector.decodeText(opfData).text,
              var opf = EPUBToolboxInspector.parseOPF(xml: opfXML, opfPath: originalOPFPath) else {
            throw EPUBToolboxError.missingOPF
        }

        var notes: [String] = []
        if opf.isFixedLayout {
            notes.append("本书为固定版式（Fixed-Layout），建议处理后预览排版。")
        }

        var removedDeadManifestCount = 0
        var registeredOrphanCount = 0
        var repairedTOC = false
        var repairedCover = false
        var removedUnusedCount = 0
        var removedUnusedBytes: Int64 = 0
        var mendedXHTMLCount = 0
        var relocatedPathsCount = 0
        var compressedImagesCount = 0
        var compressedImagesSavedBytes: Int64 = 0
        var removedFontsCount = 0
        var removedFontsBytes: Int64 = 0
        var cleanedStyleCount = 0
        var convertedChinese = false
        var convertedWritingDirection = false
        var upgradedToEPUB3 = false
        var processedRubyCount = 0
        var standardizedFootnotesCount = 0
        var updatedMetadata = false

        let existingPaths = Set(entryByPath.keys)
        var usedIDs = Set(opf.manifest.map(\.id))
        var injectedBinaryEntries: [String: Data] = [:]

        func makeUniqueID(prefix: String) -> String {
            var idx = 1
            while true {
                let candidate = "\(prefix)\(idx)"
                if usedIDs.insert(candidate).inserted { return candidate }
                idx += 1
            }
        }

        // 2b) EPUB 2 → EPUB 3 升级
        if options.upgradeToEPUB3 && !opf.isEPUB3 {
            opf.version = "3.0"
            upgradedToEPUB3 = true
            ensureCoreMetadata(in: &opf, fallbackTitle: source.deletingPathExtension().lastPathComponent)
        }

        // 2c) 元数据与封面覆盖
        if let meta = options.metadataOverride, meta.hasAnyOverride {
            applyMetadataOverride(
                meta,
                in: &opf,
                makeUniqueID: makeUniqueID,
                injectedBinaryEntries: &injectedBinaryEntries
            )
            updatedMetadata = true
            if meta.coverImageData != nil {
                repairedCover = true
            }
        }

        // 2d) 横竖排方向切换（OPF 元数据与 spine 翻页方向）
        if options.writingDirection != .keep {
            opf.pageProgressionDirection = options.writingDirection == .vertical ? "rtl" : "ltr"
            opf.metadataEntries.removeAll { entry in
                EPUBToolboxParsedOPF.localName(entry.tagName) == "meta"
                    && entry.attributes.contains(where: { $0.0 == "name" && $0.1.lowercased() == "primary-writing-mode" })
            }
            opf.metadataEntries.append(EPUBToolboxMetadataEntry(
                tagName: "meta",
                attributes: [
                    ("content", options.writingDirection == .vertical ? "vertical-rl" : "horizontal-lr"),
                    ("name", "primary-writing-mode"),
                ],
                text: ""
            ))
            convertedWritingDirection = true
        }

        // 2e) 全书简繁转换同步更新 OPF 元数据
        if options.chineseConversion != .none {
            for idx in opf.metadataEntries.indices {
                let local = EPUBToolboxParsedOPF.localName(opf.metadataEntries[idx].tagName)
                if local == "title" || local == "creator" || local == "description" || local == "subject" {
                    opf.metadataEntries[idx].text = EPUBToolboxTransforms.convertText(
                        opf.metadataEntries[idx].text,
                        option: options.chineseConversion
                    )
                } else if local == "language" {
                    opf.metadataEntries[idx].text = options.chineseConversion == .toSimplified ? "zh-Hans" : "zh-Hant"
                }
            }
            convertedChinese = true
        }

        // 3) OPF 基础清理：死链、未注册文件、必要元数据、封面声明
        onProgress?(EPUBToolboxProgress(fraction: 0.18, stage: "正在检查与修复 OPF 清单…"))
        try checkCancelled()

        let allAvailablePaths = existingPaths.union(injectedBinaryEntries.keys)
        if options.repairOPFTOCCover {
            // 3a) 移除不存在的 manifest 项与无效 spine 项
            let beforeManifestCount = opf.manifest.count
            opf.manifest = opf.manifest.filter { allAvailablePaths.contains($0.path) }
            removedDeadManifestCount = beforeManifestCount - opf.manifest.count
            let validManifestIDs = Set(opf.manifest.map(\.id))
            opf.spine = opf.spine.filter { validManifestIDs.contains($0.idref) }
            opf.guide = opf.guide.filter { allAvailablePaths.contains($0.path) }

            // 3b) 补录压缩包中未注册的有效内容文件（忽略 mimetype / META-INF / 系统垃圾）
            let registeredPaths = Set(opf.manifest.map(\.path))
            for path in entryByPath.keys.sorted() {
                if path == "mimetype" || path == originalOPFPath || path.hasPrefix("META-INF/") { continue }
                if EPUBToolboxPath.isJunkArchiveEntry(path) { continue }
                if !registeredPaths.contains(path) {
                    let mediaType = EPUBToolboxPath.inferredMediaType(for: path)
                    let id = makeUniqueID(prefix: "added_item_")
                    opf.manifest.append(EPUBToolboxManifestItem(
                        id: id,
                        path: path,
                        mediaType: mediaType,
                        properties: [],
                        fallback: nil
                    ))
                    registeredOrphanCount += 1
                }
            }

            // 3c) 补齐基础元数据（书名、标识符、语言、EPUB 3 modified）
            ensureCoreMetadata(in: &opf, fallbackTitle: source.deletingPathExtension().lastPathComponent)

            // 3d) 封面修复
            let coverResolution = EPUBToolboxInspector.resolveCoverItem(in: opf, existingPaths: allAvailablePaths)
            if coverResolution.needsRepair, let coverItem = coverResolution.item {
                repairedCover = applyCoverDeclaration(coverID: coverItem.id, in: &opf)
            }
        }

        // 4) 冗余资源清理与内嵌字体移除
        onProgress?(EPUBToolboxProgress(fraction: 0.30, stage: "正在分析资源引用…"))
        try checkCancelled()

        var droppedPaths = Set<String>()
        for path in entryByPath.keys where EPUBToolboxPath.isJunkArchiveEntry(path) {
            droppedPaths.insert(path)
            removedUnusedCount += 1
            removedUnusedBytes += Int64(entryByPath[path]?.uncompressedSize ?? 0)
        }

        if options.removeEmbeddedFonts {
            for item in opf.manifest where isFontItem(item) {
                if droppedPaths.insert(item.path).inserted {
                    removedFontsCount += 1
                    removedFontsBytes += Int64(entryByPath[item.path]?.uncompressedSize ?? 0)
                }
            }
            for (path, entry) in entryByPath where isFontPath(path) {
                if droppedPaths.insert(path).inserted {
                    removedFontsCount += 1
                    removedFontsBytes += Int64(entry.uncompressedSize)
                }
            }
        }

        if options.removeUnusedResources {
            let reachable = await EPUBToolboxInspector.collectReachablePaths(
                opf: opf,
                archive: archive,
                entryByPath: entryByPath
            )
            for path in entryByPath.keys.sorted() {
                if path == "mimetype" || path == originalOPFPath || path.hasPrefix("META-INF/") || droppedPaths.contains(path) {
                    continue
                }
                if !reachable.contains(path) {
                    droppedPaths.insert(path)
                    removedUnusedCount += 1
                    removedUnusedBytes += Int64(entryByPath[path]?.uncompressedSize ?? 0)
                }
            }
        }

        if !droppedPaths.isEmpty {
            opf.manifest.removeAll { droppedPaths.contains($0.path) }
            let remainingIDs = Set(opf.manifest.map(\.id))
            opf.spine.removeAll { !remainingIDs.contains($0.idref) }
            opf.guide.removeAll { droppedPaths.contains($0.path) }
        }

        let keptPaths = allAvailablePaths.subtracting(droppedPaths)

        // 5) 解析/修复目录（NCX / Nav）
        onProgress?(EPUBToolboxProgress(fraction: 0.42, stage: "正在检查与修复目录…"))
        try checkCancelled()

        var generatedNavPath: String?
        var generatedNCXPath: String?
        var tocNodes: [EPUBToolboxTOCNode] = []

        let existingNavItem = opf.manifest.first(where: \.isNav)
        let existingNCXItem = opf.manifest.first(where: { item in
            if let tocID = opf.spineTocID, item.id == tocID { return true }
            return item.isNCX
        })

        if let customTOC = options.customTOC {
            tocNodes = filterValidTOCNodes(customTOC, validPaths: keptPaths)
            repairedTOC = true
        } else {
            if let existingNavItem,
               let entry = entryByPath[existingNavItem.path],
               let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes),
               let html = EPUBToolboxInspector.decodeText(data).text {
                let parsed = EPUBToolboxInspector.parseNavTOC(html: html, baseDirectory: EPUBToolboxPath.directory(of: existingNavItem.path))
                tocNodes = filterValidTOCNodes(parsed, validPaths: keptPaths)
            }
            if tocNodes.isEmpty,
               let existingNCXItem,
               let entry = entryByPath[existingNCXItem.path],
               let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes),
               let xml = EPUBToolboxInspector.decodeText(data).text {
                let parsed = EPUBToolboxInspector.parseNCXTOC(xml: xml, baseDirectory: EPUBToolboxPath.directory(of: existingNCXItem.path))
                tocNodes = filterValidTOCNodes(parsed, validPaths: keptPaths)
            }
        }

        let needsTOCWrite = options.repairOPFTOCCover || options.customTOC != nil || options.upgradeToEPUB3 || options.chineseConversion != .none
        if needsTOCWrite {
            let needsRebuildTOC = options.customTOC == nil
                && ((tocNodes.isEmpty && !opf.spine.isEmpty)
                    || (options.repairOPFTOCCover && tocNodes.count <= 1 && opf.spine.count >= 3))
            if needsRebuildTOC {
                let rebuilt = await buildTOCFromSpine(opf: opf, archive: archive, entryByPath: entryByPath)
                if rebuilt.count > tocNodes.count {
                    tocNodes = rebuilt
                    repairedTOC = true
                }
            } else if options.repairOPFTOCCover {
                if (opf.isEPUB3 && existingNavItem == nil) || existingNCXItem == nil {
                    repairedTOC = true
                }
            }

            if options.chineseConversion != .none {
                tocNodes = convertTOCNodes(tocNodes, option: options.chineseConversion)
            }

            if !tocNodes.isEmpty {
                if let existingNCXItem {
                    generatedNCXPath = existingNCXItem.path
                    opf.spineTocID = existingNCXItem.id
                } else {
                    let ncxID = makeUniqueID(prefix: "ncx_")
                    let ncxPath = options.standardizeStructure ? "OEBPS/toc.ncx" : joinDirectory(EPUBToolboxPath.directory(of: originalOPFPath), "toc.ncx")
                    opf.manifest.append(EPUBToolboxManifestItem(
                        id: ncxID,
                        path: ncxPath,
                        mediaType: "application/x-dtbncx+xml",
                        properties: [],
                        fallback: nil
                    ))
                    opf.spineTocID = ncxID
                    generatedNCXPath = ncxPath
                    repairedTOC = true
                }

                if opf.isEPUB3 || existingNavItem != nil {
                    if let existingNavItem {
                        generatedNavPath = existingNavItem.path
                    } else {
                        let navID = makeUniqueID(prefix: "nav_")
                        let navPath = options.standardizeStructure ? "OEBPS/Text/nav.xhtml" : joinDirectory(EPUBToolboxPath.directory(of: originalOPFPath), "nav.xhtml")
                        opf.manifest.append(EPUBToolboxManifestItem(
                            id: navID,
                            path: navPath,
                            mediaType: "application/xhtml+xml",
                            properties: ["nav"],
                            fallback: nil
                        ))
                        generatedNavPath = navPath
                        repairedTOC = true
                    }
                }
            }
        }

        // 6) 计算目标路径映射（Sigil Norm 目录结构标准化）
        onProgress?(EPUBToolboxProgress(fraction: 0.50, stage: "正在规划标准目录结构…"))
        try checkCancelled()

        let targetOPFPath = options.standardizeStructure ? "OEBPS/content.opf" : originalOPFPath
        var pathMap: [String: String] = [:]
        var usedTargetPaths = Set<String>(["mimetype", "META-INF/container.xml", targetOPFPath])

        if options.standardizeStructure {
            for index in opf.manifest.indices {
                let item = opf.manifest[index]
                let oldPath = item.path
                let newPath: String
                if item.isNCX {
                    newPath = uniqueTargetPath(folder: "OEBPS", filename: "toc.ncx", used: &usedTargetPaths)
                } else {
                    let folder = EPUBToolboxPath.sigilFolder(for: oldPath, mediaType: item.mediaType).rawValue
                    let rawName = EPUBToolboxPath.filename(of: oldPath)
                    let targetName: String
                    if item.isXHTML {
                        let stem = URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
                        targetName = EPUBToolboxPath.sanitizedFilename(stem, fallback: "section") + ".xhtml"
                        opf.manifest[index].mediaType = "application/xhtml+xml"
                    } else {
                        targetName = EPUBToolboxPath.sanitizedFilename(rawName, fallback: "resource")
                    }
                    newPath = uniqueTargetPath(folder: folder, filename: targetName, used: &usedTargetPaths)
                }
                pathMap[oldPath] = newPath
                opf.manifest[index].path = newPath
                if oldPath != newPath {
                    relocatedPathsCount += 1
                }
            }
            if originalOPFPath != targetOPFPath {
                relocatedPathsCount += 1
            }
        } else {
            for item in opf.manifest {
                pathMap[item.path] = item.path
                usedTargetPaths.insert(item.path)
            }
        }

        // 同步更新 guide 与 tocNodes 的路径
        for idx in opf.guide.indices {
            if let mapped = pathMap[opf.guide[idx].path] {
                opf.guide[idx].path = mapped
            }
        }
        tocNodes = remapTOCNodes(tocNodes, pathMap: pathMap)
        opf.opfPath = targetOPFPath

        // 7) 逐条目处理并写入临时 ZIP
        let tempDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(".epub-toolbox-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let outArchive = try? await Archive(url: tempURL, accessMode: .create) else {
            throw EPUBToolboxError.writeFailed("无法创建输出压缩包")
        }

        var writtenPaths = Set<String>()
        func writeEntry(path: String, data: Data, compression: CompressionMethod) async throws {
            let norm = EPUBToolboxPath.normalize(path)
            guard !norm.isEmpty, writtenPaths.insert(norm).inserted else { return }
            try await outArchive.addEntry(
                with: norm,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: fixedEntryDate,
                compressionMethod: compression
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }

        // 7a) mimetype（严格首位、无压缩）
        try await writeEntry(path: "mimetype", data: Data("application/epub+zip".utf8), compression: .none)

        // 7b) META-INF/container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(EPUBToolboxPath.xmlEscaped(targetOPFPath))" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>

        """
        try await writeEntry(path: "META-INF/container.xml", data: Data(containerXML.utf8), compression: .deflate)

        // 保留其他 META-INF 文件（例如字体混淆 encryption.xml 或 iBooks display-options）
        for path in entryByPath.keys.sorted() where path.hasPrefix("META-INF/") && path != "META-INF/container.xml" {
            if path == "META-INF/encryption.xml" && options.removeEmbeddedFonts {
                // 已移除全部内嵌字体，不再保留字体混淆声明
                continue
            }
            guard !EPUBToolboxPath.isJunkArchiveEntry(path),
                  let entry = entryByPath[path],
                  let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes) else { continue }
            if path == "META-INF/encryption.xml",
               options.standardizeStructure,
               let xml = EPUBToolboxInspector.decodeText(data).text {
                let rewritten = rewriteEncryptionXML(xml: xml, pathMap: pathMap)
                try await writeEntry(path: path, data: Data(rewritten.utf8), compression: .deflate)
            } else {
                try await writeEntry(path: path, data: data, compression: .deflate)
            }
        }

        // 7d) 写入重建/同步的 NCX 与 Nav
        let mappedNCXPath = generatedNCXPath.flatMap { pathMap[$0] ?? $0 }
        let mappedNavPath = generatedNavPath.flatMap { pathMap[$0] ?? $0 }

        if needsTOCWrite && !tocNodes.isEmpty {
            if let mappedNCXPath {
                let ncxXML = serializeNCX(
                    title: opf.title.isEmpty ? source.deletingPathExtension().lastPathComponent : opf.title,
                    identifier: opf.identifierValue,
                    nodes: tocNodes,
                    ncxDirectory: EPUBToolboxPath.directory(of: mappedNCXPath)
                )
                try await writeEntry(path: mappedNCXPath, data: Data(ncxXML.utf8), compression: .deflate)
            }
            if let mappedNavPath {
                let shouldWriteGeneratedNav = existingNavItem == nil || repairedTOC || options.customTOC != nil || options.chineseConversion != .none
                if shouldWriteGeneratedNav {
                    let navHTML = serializeNavXHTML(
                        title: opf.title.isEmpty ? source.deletingPathExtension().lastPathComponent : opf.title,
                        language: opf.language.isEmpty ? "zh" : opf.language,
                        nodes: tocNodes,
                        navDirectory: EPUBToolboxPath.directory(of: mappedNavPath)
                    )
                    try await writeEntry(path: mappedNavPath, data: Data(navHTML.utf8), compression: .deflate)
                }
            }
        }

        // 7e) 逐个处理并写入 manifest 资源（图片压缩可能更新 mediaType，因此 OPF 在资源循环后再写入）
        let reverseMap = Dictionary(pathMap.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let sortedIndices = opf.manifest.indices.sorted { opf.manifest[$0].path < opf.manifest[$1].path }
        let totalItems = max(sortedIndices.count, 1)
        let needsDOMTransform = options.mendXHTML
            || options.rubyHandling != .keep
            || options.standardizeFootnotes
            || options.cleanForcedStyles
            || options.writingDirection != .keep
            || options.upgradeToEPUB3

        for (stepIdx, manifestIdx) in sortedIndices.enumerated() {
            try checkCancelled()
            if stepIdx % 10 == 0 || stepIdx == sortedIndices.count - 1 {
                let ratio = 0.55 + 0.40 * (Double(stepIdx + 1) / Double(totalItems))
                onProgress?(EPUBToolboxProgress(fraction: ratio, stage: "正在处理资源（\(stepIdx + 1)/\(totalItems)）…"))
            }
            let item = opf.manifest[manifestIdx]
            if writtenPaths.contains(item.path) { continue }

            let oldPath = reverseMap[item.path] ?? item.path
            if let injected = injectedBinaryEntries[oldPath] {
                try await writeEntry(path: item.path, data: injected, compression: .deflate)
                continue
            }
            guard let entry = entryByPath[oldPath] else { continue }

            let compression: CompressionMethod = .deflate
            let oldDir = EPUBToolboxPath.directory(of: oldPath)
            let newDir = EPUBToolboxPath.directory(of: item.path)

            if item.isXHTML {
                let rawData = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                let decoded = EPUBToolboxInspector.decodeText(rawData)
                guard var html = decoded.text else {
                    try await writeEntry(path: item.path, data: rawData, compression: .deflate)
                    continue
                }
                let wasMalformed = !decoded.wasUTF8
                    || !EPUBToolboxInspector.isWellFormedXML(data: Data(html.utf8))
                    || !html.contains("http://www.w3.org/1999/xhtml")

                if needsDOMTransform {
                    let transformed = transformXHTMLDocument(
                        html,
                        isEPUB3: opf.isEPUB3,
                        oldDirectory: oldDir,
                        newDirectory: newDir,
                        pathMap: options.standardizeStructure ? pathMap : nil,
                        options: options
                    )
                    if options.mendXHTML && wasMalformed { mendedXHTMLCount += 1 }
                    processedRubyCount += transformed.rubyCount
                    standardizedFootnotesCount += transformed.footnoteCount
                    if transformed.cleanedInlineStyles > 0 { cleanedStyleCount += 1 }
                    html = transformed.html
                } else if options.standardizeStructure {
                    html = rewriteHTMLPathsRegex(html, oldDirectory: oldDir, newDirectory: newDir, pathMap: pathMap)
                    html = rewriteCSSPaths(html, oldDirectory: oldDir, newDirectory: newDir, pathMap: pathMap)
                }

                if options.chineseConversion != .none {
                    html = EPUBToolboxTransforms.convertHTML(html, option: options.chineseConversion)
                }
                try await writeEntry(path: item.path, data: Data(html.utf8), compression: .deflate)
            } else if item.isCSS {
                let rawData = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                let needsCSSRewrite = options.standardizeStructure
                    || options.removeEmbeddedFonts
                    || options.cleanForcedStyles
                    || options.writingDirection != .keep
                if needsCSSRewrite, let css = EPUBToolboxInspector.decodeText(rawData).text {
                    var updated = css
                    if options.standardizeStructure {
                        updated = rewriteCSSPaths(updated, oldDirectory: oldDir, newDirectory: newDir, pathMap: pathMap)
                    }
                    if options.removeEmbeddedFonts {
                        updated = EPUBToolboxTransforms.removeFontFaceRules(in: updated)
                    }
                    if options.cleanForcedStyles {
                        let cleaned = EPUBToolboxTransforms.cleanForcedStyles(in: updated)
                        if cleaned != updated { cleanedStyleCount += 1 }
                        updated = cleaned
                    }
                    if options.writingDirection != .keep {
                        updated = EPUBToolboxTransforms.applyWritingDirection(options.writingDirection, toCSS: updated)
                    }
                    try await writeEntry(path: item.path, data: Data(updated.utf8), compression: .deflate)
                } else {
                    try await writeEntry(path: item.path, data: rawData, compression: .deflate)
                }
            } else if item.isNCX {
                let rawData = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                if options.standardizeStructure, let xml = EPUBToolboxInspector.decodeText(rawData).text {
                    let rewritten = rewriteHTMLPathsRegex(xml, oldDirectory: oldDir, newDirectory: newDir, pathMap: pathMap)
                    try await writeEntry(path: item.path, data: Data(rewritten.utf8), compression: .deflate)
                } else {
                    try await writeEntry(path: item.path, data: rawData, compression: .deflate)
                }
            } else if item.mediaType.lowercased() == "image/svg+xml" {
                let rawData = try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes)
                if options.standardizeStructure, let svg = EPUBToolboxInspector.decodeText(rawData).text {
                    var rewritten = rewriteHTMLPathsRegex(svg, oldDirectory: oldDir, newDirectory: newDir, pathMap: pathMap)
                    rewritten = rewriteCSSPaths(rewritten, oldDirectory: oldDir, newDirectory: newDir, pathMap: pathMap)
                    try await writeEntry(path: item.path, data: Data(rewritten.utf8), compression: .deflate)
                } else {
                    try await writeEntry(path: item.path, data: rawData, compression: .deflate)
                }
            } else if item.isImage && options.imageCompression != .off {
                let data = try await extractBinaryData(from: archive, entry: entry)
                if let compressed = EPUBToolboxTransforms.compressImage(
                    data: data,
                    mediaType: item.mediaType,
                    option: options.imageCompression
                ) {
                    opf.manifest[manifestIdx].mediaType = compressed.mediaType
                    compressedImagesCount += 1
                    compressedImagesSavedBytes += compressed.savedBytes
                    try await writeEntry(path: item.path, data: compressed.data, compression: .deflate)
                } else {
                    try await writeEntry(path: item.path, data: data, compression: compression)
                }
            } else {
                // 二进制资源（图片、字体、音频等）直接拷贝字节，不进文本解码
                let data = try await extractBinaryData(from: archive, entry: entry)
                try await writeEntry(path: item.path, data: data, compression: compression)
            }
        }

        // 7f) 写入最终规范化的 OPF（含图片压缩后可能更新的 media-type）
        let opfContent = serializeOPF(opf)
        try await writeEntry(path: targetOPFPath, data: Data(opfContent.utf8), compression: .deflate)

        // 若未启用 OPF 修复且未启用冗余清理，保留原包中未注册但未丢弃的非垃圾文件
        if !options.repairOPFTOCCover && !options.removeUnusedResources {
            for path in keptPaths.sorted() {
                if path == "mimetype" || path == originalOPFPath || path.hasPrefix("META-INF/") || writtenPaths.contains(path) {
                    continue
                }
                if let mapped = pathMap[path], writtenPaths.contains(mapped) { continue }
                guard let entry = entryByPath[path] else { continue }
                let data = try await extractBinaryData(from: archive, entry: entry)
                try await writeEntry(path: path, data: data, compression: .deflate)
            }
        }

        onProgress?(EPUBToolboxProgress(fraction: 0.98, stage: "正在完成打包…"))
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)

        let outputSize = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let baseTitle = opf.title.isEmpty ? source.deletingPathExtension().lastPathComponent : opf.title
        let filename = EPUBToolboxPath.sanitizedFilename(baseTitle, fallback: "book") + ".epub"

        onProgress?(EPUBToolboxProgress(fraction: 1.0, stage: "处理完成"))
        return EPUBToolboxResult(
            outputURL: destination,
            suggestedTitle: baseTitle,
            suggestedFilename: filename,
            originalSizeBytes: originalSize,
            outputSizeBytes: outputSize,
            relocatedPathsCount: relocatedPathsCount,
            mendedXHTMLCount: mendedXHTMLCount,
            removedDeadManifestCount: removedDeadManifestCount,
            registeredOrphanCount: registeredOrphanCount,
            repairedTOC: repairedTOC,
            repairedCover: repairedCover,
            removedUnusedCount: removedUnusedCount,
            removedUnusedBytes: removedUnusedBytes,
            compressedImagesCount: compressedImagesCount,
            compressedImagesSavedBytes: compressedImagesSavedBytes,
            removedFontsCount: removedFontsCount,
            removedFontsBytes: removedFontsBytes,
            cleanedStyleCount: cleanedStyleCount,
            convertedChinese: convertedChinese,
            convertedWritingDirection: convertedWritingDirection,
            upgradedToEPUB3: upgradedToEPUB3,
            processedRubyCount: processedRubyCount,
            standardizedFootnotesCount: standardizedFootnotesCount,
            updatedMetadata: updatedMetadata,
            notes: notes
        )
    }

    // MARK: - 取消与二进制提取

    private static func checkCancelled() throws {
        if Task.isCancelled { throw EPUBToolboxError.cancelled }
    }

    private static func extractBinaryData(from archive: Archive, entry: Entry) async throws -> Data {
        // 单个二进制资源安全上限 128 MiB
        try await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: 128 * 1024 * 1024)
    }

    // MARK: - XHTML 良构修复与专项 DOM 变换

    private struct XHTMLTransformOutput {
        let html: String
        let rubyCount: Int
        let footnoteCount: Int
        let cleanedInlineStyles: Int
    }

    private static func transformXHTMLDocument(
        _ html: String,
        isEPUB3: Bool,
        oldDirectory: String,
        newDirectory: String,
        pathMap: [String: String]?,
        options: EPUBToolboxOptions
    ) -> XHTMLTransformOutput {
        do {
            let doc = try SwiftSoup.parse(html)
            doc.outputSettings()
                .syntax(syntax: .xml)
                .escapeMode(.xhtml)
                .charset(.utf8)
                .prettyPrint(pretty: false)

            if let htmlEl = try doc.select("html").first() {
                if (try? htmlEl.attr("xmlns"))?.isEmpty != false {
                    try htmlEl.attr("xmlns", "http://www.w3.org/1999/xhtml")
                }
                if (try? htmlEl.attr("xmlns:epub"))?.isEmpty != false {
                    try htmlEl.attr("xmlns:epub", "http://www.idpf.org/2007/ops")
                }
            }

            if let pathMap {
                let linkAttrs = ["href", "src", "poster", "xlink:href", "data"]
                for attr in linkAttrs {
                    let elements = try doc.select("[\(attr)]").array()
                    for element in elements {
                        let raw = try element.attr(attr)
                        if let rewritten = rewriteSingleReference(raw, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap) {
                            try element.attr(attr, rewritten)
                        }
                    }
                }
                for element in try doc.select("[style]").array() {
                    let style = try element.attr("style")
                    if style.range(of: "url(", options: .caseInsensitive) != nil {
                        let rewritten = rewriteCSSPaths(style, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap)
                        try element.attr("style", rewritten)
                    }
                }
                for styleEl in try doc.select("style").array() {
                    let css = styleEl.data()
                    if !css.isEmpty {
                        let rewritten = rewriteCSSPaths(css, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap)
                        if rewritten != css {
                            try styleEl.text("")
                            try styleEl.appendChild(DataNode(Array(rewritten.utf8), []))
                        }
                    }
                }
            }

            let rubyCount = EPUBToolboxTransforms.processRuby(in: doc, mode: options.rubyHandling)
            let footnoteCount = options.standardizeFootnotes ? EPUBToolboxTransforms.standardizeFootnotes(in: doc) : 0
            let cleanedInline = options.cleanForcedStyles ? EPUBToolboxTransforms.cleanInlineForcedStyles(in: doc) : 0

            if options.removeEmbeddedFonts || options.cleanForcedStyles {
                for styleEl in try doc.select("style").array() {
                    var css = styleEl.data()
                    let original = css
                    if options.removeEmbeddedFonts { css = EPUBToolboxTransforms.removeFontFaceRules(in: css) }
                    if options.cleanForcedStyles { css = EPUBToolboxTransforms.cleanForcedStyles(in: css) }
                    if css != original {
                        try styleEl.text("")
                        try styleEl.appendChild(DataNode(Array(css.utf8), []))
                    }
                }
            }

            if options.writingDirection != .keep {
                EPUBToolboxTransforms.applyWritingDirection(options.writingDirection, toDoc: doc)
            }

            let serializedHTML: String
            if let htmlRoot = try doc.select("html").first() {
                serializedHTML = try htmlRoot.outerHtml()
            } else {
                serializedHTML = try doc.outerHtml()
            }
            let doctype = isEPUB3
                ? "<!DOCTYPE html>"
                : "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
            return XHTMLTransformOutput(
                html: "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\(doctype)\n\(serializedHTML)\n",
                rubyCount: rubyCount,
                footnoteCount: footnoteCount,
                cleanedInlineStyles: cleanedInline
            )
        } catch {
            if let pathMap {
                var fallback = rewriteHTMLPathsRegex(html, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap)
                fallback = rewriteCSSPaths(fallback, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap)
                return XHTMLTransformOutput(html: fallback, rubyCount: 0, footnoteCount: 0, cleanedInlineStyles: 0)
            }
            return XHTMLTransformOutput(html: html, rubyCount: 0, footnoteCount: 0, cleanedInlineStyles: 0)
        }
    }

    private static func isFontItem(_ item: EPUBToolboxManifestItem) -> Bool {
        let mt = item.mediaType.lowercased()
        return mt.hasPrefix("font/") || mt.contains("font") || isFontPath(item.path)
    }

    private static func isFontPath(_ path: String) -> Bool {
        ["ttf", "otf", "woff", "woff2", "ttc"].contains(EPUBToolboxPath.pathExtension(of: path))
    }

    private static func convertTOCNodes(_ nodes: [EPUBToolboxTOCNode], option: EPUBChineseConversionOption) -> [EPUBToolboxTOCNode] {
        nodes.map { node in
            EPUBToolboxTOCNode(
                title: EPUBToolboxTransforms.convertText(node.title, option: option),
                path: node.path,
                fragment: node.fragment,
                children: convertTOCNodes(node.children, option: option)
            )
        }
    }

    private static func applyMetadataOverride(
        _ meta: EPUBMetadataOverride,
        in opf: inout EPUBToolboxParsedOPF,
        makeUniqueID: (String) -> String,
        injectedBinaryEntries: inout [String: Data]
    ) {
        func replaceDC(localName: String, tagName: String, value: String?) {
            guard let raw = value else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            opf.metadataEntries.removeAll { EPUBToolboxParsedOPF.localName($0.tagName) == localName }
            if !trimmed.isEmpty {
                opf.metadataEntries.append(EPUBToolboxMetadataEntry(tagName: tagName, attributes: [], text: trimmed))
            }
        }
        replaceDC(localName: "title", tagName: "dc:title", value: meta.title)
        replaceDC(localName: "creator", tagName: "dc:creator", value: meta.author)
        replaceDC(localName: "language", tagName: "dc:language", value: meta.language)
        replaceDC(localName: "description", tagName: "dc:description", value: meta.description)

        if let coverData = meta.coverImageData, !coverData.isEmpty {
            let ext = meta.coverMediaType.lowercased().contains("png") ? "png" : "jpg"
            let path = "OEBPS/Images/cover_custom.\(ext)"
            let id = makeUniqueID("cover_custom_")
            injectedBinaryEntries[path] = coverData
            opf.manifest.append(EPUBToolboxManifestItem(
                id: id,
                path: path,
                mediaType: meta.coverMediaType,
                properties: opf.isEPUB3 ? ["cover-image"] : [],
                fallback: nil
            ))
            _ = applyCoverDeclaration(coverID: id, in: &opf)
        }
    }

    private static func rewriteSingleReference(
        _ raw: String,
        oldDirectory: String,
        newDirectory: String,
        pathMap: [String: String]
    ) -> String? {
        guard let resolved = EPUBToolboxPath.resolveRelative(raw, baseDirectory: oldDirectory) else { return nil }
        let targetPath = pathMap[resolved.path] ?? resolved.path
        let relative = EPUBToolboxPath.relativePath(fromDirectory: newDirectory, to: targetPath)
        let encoded = EPUBToolboxPath.percentEncodePath(relative) + resolved.suffix
        return encoded == raw ? nil : encoded
    }

    private static func rewriteHTMLPathsRegex(
        _ html: String,
        oldDirectory: String,
        newDirectory: String,
        pathMap: [String: String]
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\b(?:href|src|poster|xlink:href|data)\s*=\s*)(["'])([^"']*)(\2)"#,
            options: [.caseInsensitive]
        ) else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            let valueRange = match.range(at: 3)
            let raw = ns.substring(with: valueRange)
            if let rewritten = rewriteSingleReference(raw, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap) {
                mutable.replaceCharacters(in: valueRange, with: rewritten)
            }
        }
        return mutable as String
    }

    private static func rewriteCSSPaths(
        _ css: String,
        oldDirectory: String,
        newDirectory: String,
        pathMap: [String: String]
    ) -> String {
        var result = css
        if let urlRegex = try? NSRegularExpression(
            pattern: #"url\(\s*(["']?)([^)"'\s]+)\1\s*\)"#,
            options: [.caseInsensitive]
        ) {
            let ns = result as NSString
            let matches = urlRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                let mutable = NSMutableString(string: result)
                for match in matches.reversed() {
                    let quote = ns.substring(with: match.range(at: 1))
                    let raw = ns.substring(with: match.range(at: 2))
                    if let rewritten = rewriteSingleReference(raw, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap) {
                        let q = quote.isEmpty ? "\"" : quote
                        mutable.replaceCharacters(in: match.range, with: "url(\(q)\(rewritten)\(q))")
                    }
                }
                result = mutable as String
            }
        }
        if let importRegex = try? NSRegularExpression(
            pattern: #"(@import\s+)(["'])([^"']+)\2"#,
            options: [.caseInsensitive]
        ) {
            let ns = result as NSString
            let matches = importRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                let mutable = NSMutableString(string: result)
                for match in matches.reversed() {
                    let prefix = ns.substring(with: match.range(at: 1))
                    let quote = ns.substring(with: match.range(at: 2))
                    let raw = ns.substring(with: match.range(at: 3))
                    if let rewritten = rewriteSingleReference(raw, oldDirectory: oldDirectory, newDirectory: newDirectory, pathMap: pathMap) {
                        mutable.replaceCharacters(in: match.range, with: "\(prefix)\(quote)\(rewritten)\(quote)")
                    }
                }
                result = mutable as String
            }
        }
        return result
    }

    private static func rewriteEncryptionXML(xml: String, pathMap: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(<(?:[A-Za-z0-9_-]+:)?CipherReference\b[^>]*\bURI\s*=\s*)(["'])([^"']+)\2"#,
            options: [.caseInsensitive]
        ) else { return xml }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return xml }
        let mutable = NSMutableString(string: xml)
        for match in matches.reversed() {
            let raw = ns.substring(with: match.range(at: 3))
            let decoded = raw.removingPercentEncoding ?? raw
            let norm = EPUBToolboxPath.normalize(decoded)
            if let mapped = pathMap[norm], mapped != norm {
                let encoded = EPUBToolboxPath.percentEncodePath(mapped)
                mutable.replaceCharacters(in: match.range(at: 3), with: encoded)
            }
        }
        return mutable as String
    }

    // MARK: - 元数据、封面与目录修复

    private static func ensureCoreMetadata(in opf: inout EPUBToolboxParsedOPF, fallbackTitle: String) {
        if opf.uniqueIdentifier.isEmpty {
            opf.uniqueIdentifier = "BookId"
        }
        if opf.title.isEmpty {
            opf.metadataEntries.append(EPUBToolboxMetadataEntry(tagName: "dc:title", attributes: [], text: fallbackTitle))
        }
        if opf.language.isEmpty {
            opf.metadataEntries.append(EPUBToolboxMetadataEntry(tagName: "dc:language", attributes: [], text: "zh"))
        }
        if opf.identifierValue.isEmpty {
            opf.metadataEntries.append(EPUBToolboxMetadataEntry(
                tagName: "dc:identifier",
                attributes: [("id", opf.uniqueIdentifier)],
                text: "urn:uuid:\(UUID().uuidString)"
            ))
        }
        if opf.isEPUB3 {
            let hasModified = opf.metadataEntries.contains { entry in
                EPUBToolboxParsedOPF.localName(entry.tagName) == "meta"
                    && entry.attributes.contains(where: { $0.0 == "property" && $0.1 == "dcterms:modified" })
                    && !entry.text.isEmpty
            }
            if !hasModified {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                opf.metadataEntries.append(EPUBToolboxMetadataEntry(
                    tagName: "meta",
                    attributes: [("property", "dcterms:modified")],
                    text: formatter.string(from: Date())
                ))
            }
        }
    }

    private static func applyCoverDeclaration(coverID: String, in opf: inout EPUBToolboxParsedOPF) -> Bool {
        var changed = false
        // 清理旧的 <meta name="cover">
        let oldCount = opf.metadataEntries.count
        opf.metadataEntries.removeAll { entry in
            EPUBToolboxParsedOPF.localName(entry.tagName) == "meta"
                && entry.attributes.contains(where: { $0.0 == "name" && $0.1.lowercased() == "cover" })
        }
        if opf.metadataEntries.count != oldCount { changed = true }
        opf.metadataEntries.append(EPUBToolboxMetadataEntry(
            tagName: "meta",
            attributes: [("content", coverID), ("name", "cover")],
            text: ""
        ))
        changed = true

        // 同步 EPUB 3 properties="cover-image"
        for idx in opf.manifest.indices {
            if opf.manifest[idx].id == coverID {
                if opf.isEPUB3 && !opf.manifest[idx].properties.contains("cover-image") {
                    opf.manifest[idx].properties.insert("cover-image")
                    changed = true
                }
            } else if opf.manifest[idx].properties.contains("cover-image") {
                opf.manifest[idx].properties.remove("cover-image")
                changed = true
            }
        }
        return changed
    }

    private static func filterValidTOCNodes(_ nodes: [EPUBToolboxTOCNode], validPaths: Set<String>) -> [EPUBToolboxTOCNode] {
        nodes.compactMap { node in
            let validChildren = filterValidTOCNodes(node.children, validPaths: validPaths)
            let pathValid = !node.path.isEmpty && validPaths.contains(node.path)
            if pathValid {
                return EPUBToolboxTOCNode(title: node.title, path: node.path, fragment: node.fragment, children: validChildren)
            }
            if !validChildren.isEmpty {
                return EPUBToolboxTOCNode(title: node.title, path: validChildren[0].path, fragment: validChildren[0].fragment, children: validChildren)
            }
            return nil
        }
    }

    private static func remapTOCNodes(_ nodes: [EPUBToolboxTOCNode], pathMap: [String: String]) -> [EPUBToolboxTOCNode] {
        nodes.map { node in
            EPUBToolboxTOCNode(
                title: node.title,
                path: pathMap[node.path] ?? node.path,
                fragment: node.fragment,
                children: remapTOCNodes(node.children, pathMap: pathMap)
            )
        }
    }

    private static func buildTOCFromSpine(
        opf: EPUBToolboxParsedOPF,
        archive: Archive,
        entryByPath: [String: Entry]
    ) async -> [EPUBToolboxTOCNode] {
        let manifestByID = Dictionary(opf.manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var headingNodes: [EPUBToolboxTOCNode] = []
        var fallbackNodes: [EPUBToolboxTOCNode] = []
        var seenHeadingTitles = Set<String>()

        for (idx, sp) in opf.spine.enumerated() {
            guard let item = manifestByID[sp.idref],
                  item.isXHTML,
                  let entry = entryByPath[item.path],
                  let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes),
                  let html = EPUBToolboxInspector.decodeText(data).text else { continue }
            if let heading = extractChapterHeading(from: html),
               seenHeadingTitles.insert(heading).inserted {
                headingNodes.append(EPUBToolboxTOCNode(title: heading, path: item.path, fragment: "", children: []))
            }
            let title = extractChapterTitle(from: html) ?? "第 \(idx + 1) 章"
            fallbackNodes.append(EPUBToolboxTOCNode(title: title, path: item.path, fragment: "", children: []))
        }
        // 优先使用识别出的真实章节标题（过滤封面页、插图页、空白页）；若未识别到多于 1 项则退回全部 spine
        return headingNodes.count > 1 ? headingNodes : fallbackNodes
    }

    private static func extractChapterHeading(from html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        for selector in ["h1", "h2", "h3"] {
            if let el = try? doc.select(selector).first(),
               let text = try? el.text() {
                let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && cleaned.count <= 120 {
                    return cleaned
                }
            }
        }
        guard let headingPattern = try? NSRegularExpression(
            pattern: "^(?:序章|序幕|プロローグ|Prologue|第\\s*[0-9０-９一二三四五六七八九十百]+\\s*(?:章|话|話|节|節|回|幕)|终章|終章|尾声|後日譚|后日谈|终幕|終幕|エピローグ|Epilogue)",
            options: [.caseInsensitive]
        ) else { return nil }
        if let paragraphs = try? doc.select("p").array() {
            for p in paragraphs.prefix(12) {
                guard let raw = try? p.text() else { continue }
                let cleaned = raw.replacingOccurrences(of: "[\\s　]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty && cleaned.count <= 120 else { continue }
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                if headingPattern.firstMatch(in: cleaned, range: range) != nil {
                    return cleaned
                }
            }
        }
        return nil
    }

    private static func extractChapterTitle(from html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        for selector in ["h1", "h2", "h3", "title"] {
            if let el = try? doc.select(selector).first(),
               let text = try? el.text() {
                let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && cleaned.count <= 120 {
                    return cleaned
                }
            }
        }
        return nil
    }

    // MARK: - 序列化 OPF / NCX / Nav

    private static func serializeOPF(_ opf: EPUBToolboxParsedOPF) -> String {
        let opfDir = EPUBToolboxPath.directory(of: opf.opfPath)
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="utf-8"?>"#)

        var pkgAttrs = [
            #"xmlns="http://www.idpf.org/2007/opf""#,
            #"version="\#(EPUBToolboxPath.xmlEscaped(opf.version.isEmpty ? "2.0" : opf.version))""#,
            #"unique-identifier="\#(EPUBToolboxPath.xmlEscaped(opf.uniqueIdentifier.isEmpty ? "BookId" : opf.uniqueIdentifier))""#,
        ]
        if let prefix = opf.packagePrefix, !prefix.isEmpty {
            pkgAttrs.append(#"prefix="\#(EPUBToolboxPath.xmlEscaped(prefix))""#)
        }
        if let lang = opf.packageLang, !lang.isEmpty {
            pkgAttrs.append(#"xml:lang="\#(EPUBToolboxPath.xmlEscaped(lang))""#)
        }
        lines.append("<package \(pkgAttrs.joined(separator: " "))>")

        // Metadata
        lines.append(#"  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">"#)
        for entry in opf.metadataEntries {
            let attrStr = entry.attributes.map { #" \#($0.0)="\#(EPUBToolboxPath.xmlEscaped($0.1))""# }.joined()
            if entry.text.isEmpty {
                lines.append("    <\(entry.tagName)\(attrStr)/>")
            } else {
                lines.append("    <\(entry.tagName)\(attrStr)>\(EPUBToolboxPath.xmlEscaped(entry.text))</\(entry.tagName)>")
            }
        }
        lines.append("  </metadata>")

        // Manifest
        lines.append("  <manifest>")
        for item in opf.manifest {
            let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: opfDir, to: item.path))
            var attrs = [
                #"id="\#(EPUBToolboxPath.xmlEscaped(item.id))""#,
                #"href="\#(EPUBToolboxPath.xmlEscaped(rel))""#,
                #"media-type="\#(EPUBToolboxPath.xmlEscaped(item.mediaType))""#,
            ]
            if !item.properties.isEmpty {
                let props = item.properties.sorted().joined(separator: " ")
                attrs.append(#"properties="\#(EPUBToolboxPath.xmlEscaped(props))""#)
            }
            if let fallback = item.fallback, !fallback.isEmpty {
                attrs.append(#"fallback="\#(EPUBToolboxPath.xmlEscaped(fallback))""#)
            }
            lines.append("    <item \(attrs.joined(separator: " "))/>")
        }
        lines.append("  </manifest>")

        // Spine
        var spineAttrs: [String] = []
        if let tocID = opf.spineTocID, opf.manifest.contains(where: { $0.id == tocID }) {
            spineAttrs.append(#"toc="\#(EPUBToolboxPath.xmlEscaped(tocID))""#)
        }
        if let ppd = opf.pageProgressionDirection, !ppd.isEmpty {
            spineAttrs.append(#"page-progression-direction="\#(EPUBToolboxPath.xmlEscaped(ppd))""#)
        }
        lines.append(spineAttrs.isEmpty ? "  <spine>" : "  <spine \(spineAttrs.joined(separator: " "))>")
        for itemref in opf.spine {
            var attrs = [#"idref="\#(EPUBToolboxPath.xmlEscaped(itemref.idref))""#]
            if let linear = itemref.linear, !linear.isEmpty {
                attrs.append(#"linear="\#(EPUBToolboxPath.xmlEscaped(linear))""#)
            }
            if let properties = itemref.properties, !properties.isEmpty {
                attrs.append(#"properties="\#(EPUBToolboxPath.xmlEscaped(properties))""#)
            }
            lines.append("    <itemref \(attrs.joined(separator: " "))/>")
        }
        lines.append("  </spine>")

        // Guide（若存在）
        if !opf.guide.isEmpty {
            lines.append("  <guide>")
            for ref in opf.guide {
                let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: opfDir, to: ref.path)) + ref.fragment
                var attrs = [#"type="\#(EPUBToolboxPath.xmlEscaped(ref.type))""#]
                if let title = ref.title, !title.isEmpty {
                    attrs.append(#"title="\#(EPUBToolboxPath.xmlEscaped(title))""#)
                }
                attrs.append(#"href="\#(EPUBToolboxPath.xmlEscaped(rel))""#)
                lines.append("    <reference \(attrs.joined(separator: " "))/>")
            }
            lines.append("  </guide>")
        }

        lines.append("</package>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func serializeNCX(
        title: String,
        identifier: String,
        nodes: [EPUBToolboxTOCNode],
        ncxDirectory: String
    ) -> String {
        var playOrder = 0
        func renderNodes(_ list: [EPUBToolboxTOCNode], indent: String) -> String {
            var out = ""
            for node in list {
                playOrder += 1
                let id = "navPoint-\(playOrder)"
                let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: ncxDirectory, to: node.path)) + node.fragment
                out += "\(indent)<navPoint id=\"\(id)\" playOrder=\"\(playOrder)\">\n"
                out += "\(indent)  <navLabel><text>\(EPUBToolboxPath.xmlEscaped(node.title))</text></navLabel>\n"
                out += "\(indent)  <content src=\"\(EPUBToolboxPath.xmlEscaped(rel))\"/>\n"
                if !node.children.isEmpty {
                    out += renderNodes(node.children, indent: indent + "  ")
                }
                out += "\(indent)</navPoint>\n"
            }
            return out
        }

        let depth = maxDepth(of: nodes)
        let uid = identifier.isEmpty ? "urn:uuid:\(UUID().uuidString)" : identifier
        let navMapBody = renderNodes(nodes, indent: "    ")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(EPUBToolboxPath.xmlEscaped(uid))"/>
            <meta name="dtb:depth" content="\(depth)"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle><text>\(EPUBToolboxPath.xmlEscaped(title))</text></docTitle>
          <navMap>
        \(navMapBody)  </navMap>
        </ncx>

        """
    }

    private static func serializeNavXHTML(
        title: String,
        language: String,
        nodes: [EPUBToolboxTOCNode],
        navDirectory: String
    ) -> String {
        func renderList(_ list: [EPUBToolboxTOCNode], indent: String) -> String {
            var out = "\(indent)<ol>\n"
            for node in list {
                let rel = EPUBToolboxPath.percentEncodePath(EPUBToolboxPath.relativePath(fromDirectory: navDirectory, to: node.path)) + node.fragment
                out += "\(indent)  <li><a href=\"\(EPUBToolboxPath.xmlEscaped(rel))\">\(EPUBToolboxPath.xmlEscaped(node.title))</a>"
                if !node.children.isEmpty {
                    out += "\n" + renderList(node.children, indent: indent + "    ") + "\(indent)  "
                }
                out += "</li>\n"
            }
            out += "\(indent)</ol>\n"
            return out
        }

        let listMarkup = renderList(nodes, indent: "      ")
        let escapedLang = EPUBToolboxPath.xmlEscaped(language)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(escapedLang)" lang="\(escapedLang)">
          <head>
            <meta charset="utf-8"/>
            <title>\(EPUBToolboxPath.xmlEscaped(title))</title>
          </head>
          <body>
            <nav epub:type="toc" id="toc">
              <h1>目录</h1>
        \(listMarkup)    </nav>
          </body>
        </html>

        """
    }

    private static func maxDepth(of nodes: [EPUBToolboxTOCNode]) -> Int {
        guard !nodes.isEmpty else { return 1 }
        return nodes.map { 1 + ($0.children.isEmpty ? 0 : maxDepth(of: $0.children)) }.max() ?? 1
    }

    private static func joinDirectory(_ dir: String, _ name: String) -> String {
        dir.isEmpty ? name : "\(dir)/\(name)"
    }

    private static func uniqueTargetPath(folder: String, filename: String, used: inout Set<String>) -> String {
        let base = EPUBToolboxPath.normalize("\(folder)/\(filename)")
        if used.insert(base).inserted { return base }
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
            let candidate = EPUBToolboxPath.normalize("\(folder)/\(candidateName)")
            if used.insert(candidate).inserted { return candidate }
            suffix += 1
        }
    }
}
