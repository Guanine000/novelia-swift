// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ReadiumZIPFoundation
import SwiftSoup
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

/// EPUB 工具箱脱敏诊断日志辅助：只记录模式、操作类型、计数、字节数、固定错误分类与耗时，
/// 绝不记录书名、文件路径、元数据或正文内容。
enum EPUBToolboxDiagnosticLog {
    private static let logger = ShareableLogger(category: "epubtoolbox")

    static func failureReason(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let toolboxError = error as? EPUBToolboxError else { return "other" }
        switch toolboxError {
        case .cancelled: return "cancelled"
        case .drmProtected: return "drm"
        case .invalidArchive: return "invalidArchive"
        case .missingOPF: return "missingOPF"
        case .nothingSelected: return "nothingSelected"
        case .writeFailed: return "writeFailed"
        }
    }

    static func logInspectCompleted(mode: EPUBInspectionMode, report: EPUBInspectionReport, since start: MonotonicInstant) {
        let modeLabel = mode == .deep ? "deep" : "lightweight"
        logger.notice(AppDiagnosticMessage.epubToolboxInspectCompleted(
            mode: modeLabel,
            issues: report.issues.count,
            drm: report.isDRMProtected,
            elapsedMs: DiagnosticContext.milliseconds(since: start)
        ))
    }

    static func logInspectFailed(mode: EPUBInspectionMode, error: Error, since start: MonotonicInstant) {
        let modeLabel = mode == .deep ? "deep" : "lightweight"
        let nsError = error as NSError
        logger.error(AppDiagnosticMessage.epubToolboxInspectFailed(
            mode: modeLabel,
            reason: failureReason(for: error),
            domain: nsError.domain,
            code: nsError.code,
            elapsedMs: DiagnosticContext.milliseconds(since: start)
        ))
    }

    static func logActionCompleted(action: String, items: Int, bytes: Int64, since start: MonotonicInstant) {
        logger.notice(AppDiagnosticMessage.epubToolboxActionCompleted(
            action: action,
            items: items,
            bytes: Int(clamping: max(0, bytes)),
            elapsedMs: DiagnosticContext.milliseconds(since: start)
        ))
    }

    static func logActionFailed(action: String, error: Error, since start: MonotonicInstant) {
        let nsError = error as NSError
        logger.error(AppDiagnosticMessage.epubToolboxActionFailed(
            action: action,
            reason: failureReason(for: error),
            domain: nsError.domain,
            code: nsError.code,
            elapsedMs: DiagnosticContext.milliseconds(since: start)
        ))
    }
}

// MARK: - 共享 OPF / 目录解析结构（体检与处理共用）

struct EPUBToolboxManifestItem: Equatable, Sendable {
    var id: String
    /// 规范化后的 ZIP 根路径（如 `OEBPS/Text/ch01.xhtml`）。
    var path: String
    var mediaType: String
    var properties: Set<String>
    var fallback: String?

    var isXHTML: Bool {
        let mt = mediaType.lowercased()
        let ext = EPUBToolboxPath.pathExtension(of: path)
        return mt.contains("xhtml") || mt == "text/html" || ["xhtml", "xht", "html", "htm"].contains(ext)
    }

    var isCSS: Bool {
        mediaType.lowercased() == "text/css" || EPUBToolboxPath.pathExtension(of: path) == "css"
    }

    var isNCX: Bool {
        mediaType.lowercased() == "application/x-dtbncx+xml" || EPUBToolboxPath.pathExtension(of: path) == "ncx"
    }

    var isNav: Bool {
        properties.contains("nav")
    }

    var isImage: Bool {
        mediaType.lowercased().hasPrefix("image/")
    }
}

struct EPUBToolboxSpineItem: Equatable, Sendable {
    var idref: String
    var linear: String?
    var properties: String?
}

struct EPUBToolboxGuideReference: Equatable, Sendable {
    var type: String
    var title: String?
    /// 规范化后的 ZIP 根路径（不含 fragment）。
    var path: String
    var fragment: String
}

struct EPUBToolboxMetadataEntry: Equatable, Sendable {
    /// 元素名，如 `dc:title`、`dc:creator`、`meta`。
    var tagName: String
    var attributes: [(String, String)]
    var text: String

    static func == (lhs: EPUBToolboxMetadataEntry, rhs: EPUBToolboxMetadataEntry) -> Bool {
        lhs.tagName == rhs.tagName
            && lhs.text == rhs.text
            && lhs.attributes.count == rhs.attributes.count
            && zip(lhs.attributes, rhs.attributes).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

struct EPUBToolboxTOCNode: Equatable, Sendable {
    var title: String
    /// 规范化后的 ZIP 根路径（不含 fragment）。
    var path: String
    var fragment: String
    var children: [EPUBToolboxTOCNode]
}

struct EPUBToolboxParsedOPF: Sendable {
    var opfPath: String
    var version: String
    var uniqueIdentifier: String
    var packagePrefix: String?
    var packageLang: String?
    var spineTocID: String?
    var pageProgressionDirection: String?
    var metadataEntries: [EPUBToolboxMetadataEntry]
    var manifest: [EPUBToolboxManifestItem]
    var spine: [EPUBToolboxSpineItem]
    var guide: [EPUBToolboxGuideReference]

    var isEPUB3: Bool {
        version.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("3")
    }

    var title: String {
        metadataEntries.first(where: { Self.localName($0.tagName) == "title" && !$0.text.isEmpty })?.text ?? ""
    }

    var author: String {
        metadataEntries.first(where: { Self.localName($0.tagName) == "creator" && !$0.text.isEmpty })?.text ?? ""
    }

    var language: String {
        metadataEntries.first(where: { Self.localName($0.tagName) == "language" && !$0.text.isEmpty })?.text ?? ""
    }

    var identifierValue: String {
        if !uniqueIdentifier.isEmpty,
           let matched = metadataEntries.first(where: {
               Self.localName($0.tagName) == "identifier"
                   && $0.attributes.contains(where: { $0.0 == "id" && $0.1 == uniqueIdentifier })
                   && !$0.text.isEmpty
           }) {
            return matched.text
        }
        return metadataEntries.first(where: { Self.localName($0.tagName) == "identifier" && !$0.text.isEmpty })?.text ?? ""
    }

    var isFixedLayout: Bool {
        metadataEntries.contains { entry in
            Self.localName(entry.tagName) == "meta"
                && entry.attributes.contains(where: { $0.0 == "property" && $0.1 == "rendition:layout" })
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pre-paginated"
        }
    }

    /// EPUB 2 `<meta name="cover" content="..."/>` 指向的 manifest ID 或路径。
    var epub2CoverMetaContent: String? {
        for entry in metadataEntries where Self.localName(entry.tagName) == "meta" {
            let name = entry.attributes.first(where: { $0.0 == "name" })?.1.lowercased()
            if name == "cover" {
                let content = entry.attributes.first(where: { $0.0 == "content" })?.1.trimmingCharacters(in: .whitespacesAndNewlines)
                if let content, !content.isEmpty { return content }
            }
        }
        return nil
    }

    static func localName(_ tag: String) -> String {
        if let colon = tag.lastIndex(of: ":") {
            return String(tag[tag.index(after: colon)...]).lowercased()
        }
        return tag.lowercased()
    }
}

// MARK: - 体检引擎

/// EPUB 结构体检器：支持导入链路的轻量体检（不解压章节正文与图片）与工具箱页面的深度体检。
enum EPUBToolboxInspector {
    /// 单个 XML/文本条目的安全读取上限（32 MiB），避免异常压缩包撑爆内存。
    static let maxTextEntryBytes = 32 * 1024 * 1024

    static func inspect(url: URL, mode: EPUBInspectionMode) async throws -> EPUBInspectionReport {
        let startedAt = MonotonicInstant.now
        do {
            let report = try await performInspect(url: url, mode: mode)
            EPUBToolboxDiagnosticLog.logInspectCompleted(mode: mode, report: report, since: startedAt)
            return report
        } catch {
            EPUBToolboxDiagnosticLog.logInspectFailed(mode: mode, error: error, since: startedAt)
            throw error
        }
    }

    private static func performInspect(url: URL, mode: EPUBInspectionMode) async throws -> EPUBInspectionReport {
        guard let archive = try? await Archive(url: url, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        let entries = (try? await archive.entries()) ?? []
        var entryByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file {
            let normalized = EPUBToolboxPath.normalize(entry.path)
            if !normalized.isEmpty {
                entryByPath[normalized] = entry
            }
        }

        let fileEntries = entries.filter { $0.type == .file }
        var issues: [EPUBInspectionIssue] = []

        // 1) DRM 加密检查（区分字体混淆和真正的正文/资源 DRM）
        var isDRM = false
        if let encEntry = entryByPath["META-INF/encryption.xml"],
           let encData = try? await extractData(from: archive, entry: encEntry, limit: 2 * 1024 * 1024),
           let encXML = decodeText(encData).text {
            isDRM = detectsDRM(inEncryptionXML: encXML)
            if isDRM {
                issues.append(EPUBInspectionIssue(
                    category: .protection,
                    severity: .error,
                    title: "受 DRM 加密保护",
                    detail: "META-INF/encryption.xml 包含非字体混淆加密项，工具箱不能修改受保护的书籍。"
                ))
            }
        }

        // 2) mimetype 检查
        if let mimeEntry = entryByPath["mimetype"] {
            let firstFile = fileEntries.first
            let isFirst = firstFile.map { EPUBToolboxPath.normalize($0.path) == "mimetype" } ?? false
            let isUncompressed = !mimeEntry.isCompressed
            let mimeData = try? await extractData(from: archive, entry: mimeEntry, limit: 256)
            let mimeText = mimeData.flatMap { String(data: $0, encoding: .ascii) }
            if !isFirst || !isUncompressed || mimeText != "application/epub+zip" {
                var reasons: [String] = []
                if !isFirst { reasons.append("不在压缩包首位") }
                if !isUncompressed { reasons.append("使用了压缩而非原样存储") }
                if mimeText != "application/epub+zip" { reasons.append("内容不是精确的 application/epub+zip") }
                issues.append(EPUBInspectionIssue(
                    category: .structure,
                    severity: .warning,
                    title: "mimetype 不符合规范",
                    detail: reasons.joined(separator: "，") + "。",
                    affectedPaths: ["mimetype"]
                ))
            }
        } else {
            issues.append(EPUBInspectionIssue(
                category: .structure,
                severity: .error,
                title: "缺少 mimetype 文件",
                detail: "EPUB 规范要求压缩包首个条目为未压缩的 mimetype 文件。"
            ))
        }

        // 3) container.xml 与 OPF 定位
        var containerOPFPath: String?
        if let containerEntry = entryByPath["META-INF/container.xml"],
           let data = try? await extractData(from: archive, entry: containerEntry, limit: 1024 * 1024),
           let xml = decodeText(data).text {
            containerOPFPath = parseContainerOPFPath(xml: xml)
        } else {
            issues.append(EPUBInspectionIssue(
                category: .structure,
                severity: .error,
                title: "缺少 META-INF/container.xml",
                detail: "标准阅读器需要通过 container.xml 定位 OPF 入口文件。"
            ))
        }

        let resolvedOPFPath: String?
        if let path = containerOPFPath, entryByPath[path] != nil {
            resolvedOPFPath = path
        } else {
            if let path = containerOPFPath {
                issues.append(EPUBInspectionIssue(
                    category: .structure,
                    severity: .error,
                    title: "container.xml 指向的 OPF 不存在",
                    detail: "声明的路径 \(path) 在压缩包中找不到。",
                    affectedPaths: [path]
                ))
            }
            resolvedOPFPath = entryByPath.keys.sorted().first(where: { $0.lowercased().hasSuffix(".opf") })
        }

        guard let opfPath = resolvedOPFPath,
              let opfEntry = entryByPath[opfPath],
              let opfData = try? await extractData(from: archive, entry: opfEntry, limit: maxTextEntryBytes),
              let opfXML = decodeText(opfData).text,
              let opf = parseOPF(xml: opfXML, opfPath: opfPath) else {
            issues.append(EPUBInspectionIssue(
                category: .opf,
                severity: .error,
                title: "OPF 文件缺失或无法解析",
                detail: "未找到有效的 .opf 配置文件。"
            ))
            return EPUBInspectionReport(
                mode: mode,
                fileSizeBytes: fileSize,
                epubVersion: "未知",
                title: url.deletingPathExtension().lastPathComponent,
                author: "",
                opfPath: resolvedOPFPath,
                spineCount: 0,
                entryCount: fileEntries.count,
                isDRMProtected: isDRM,
                isFixedLayout: false,
                hasScripts: false,
                unusedResourceCount: 0,
                unusedResourceBytes: 0,
                issues: issues
            )
        }

        if opf.isFixedLayout {
            issues.append(EPUBInspectionIssue(
                category: .protection,
                severity: .info,
                title: "固定版式 EPUB（Fixed-Layout）",
                detail: "此类书籍依赖精确版面定位，目录重排或 XHTML 改写可能影响版式，建议处理后预览核对。"
            ))
        }

        // 4) Sigil 目录结构检查
        var nonStandardPaths: [String] = []
        if opfPath != "OEBPS/content.opf" {
            nonStandardPaths.append(opfPath)
        }
        for item in opf.manifest where entryByPath[item.path] != nil {
            if item.isNCX {
                if item.path != "OEBPS/toc.ncx" { nonStandardPaths.append(item.path) }
            } else {
                let expectedFolder = EPUBToolboxPath.sigilFolder(for: item.path, mediaType: item.mediaType).rawValue
                if EPUBToolboxPath.directory(of: item.path) != expectedFolder {
                    nonStandardPaths.append(item.path)
                }
            }
        }
        if !nonStandardPaths.isEmpty {
            issues.append(EPUBInspectionIssue(
                category: .structure,
                severity: .info,
                title: "目录结构未按 Sigil 规范组织",
                detail: "有 \(nonStandardPaths.count) 个文件未位于标准的 OEBPS/{Text,Styles,Images,Fonts,Misc} 结构下。",
                affectedPaths: Array(nonStandardPaths.prefix(10))
            ))
        }

        // 5) OPF Manifest 死链 & 未注册孤立文件 & 系统垃圾文件
        let manifestPaths = Set(opf.manifest.map(\.path))
        let deadManifestPaths = opf.manifest.map(\.path).filter { entryByPath[$0] == nil }
        if !deadManifestPaths.isEmpty {
            issues.append(EPUBInspectionIssue(
                category: .opf,
                severity: .warning,
                title: "OPF 存在 \(deadManifestPaths.count) 处失效引用",
                detail: "manifest 中列出的部分文件在压缩包中不存在。",
                affectedPaths: Array(deadManifestPaths.prefix(10))
            ))
        }

        let manifestByID = Dictionary(opf.manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let deadSpineIDs = opf.spine.map(\.idref).filter { idref in
            guard let item = manifestByID[idref] else { return true }
            return entryByPath[item.path] == nil
        }
        if !deadSpineIDs.isEmpty {
            issues.append(EPUBInspectionIssue(
                category: .opf,
                severity: .error,
                title: "阅读顺序（spine）存在 \(deadSpineIDs.count) 个无效章节",
                detail: "部分 spine 指向缺失的 manifest 项或不存在的章节文件。"
            ))
        }

        var junkPaths: [String] = []
        var unregisteredPaths: [String] = []
        for path in entryByPath.keys.sorted() {
            if path == "mimetype" || path == opfPath || path.hasPrefix("META-INF/") { continue }
            if EPUBToolboxPath.isJunkArchiveEntry(path) {
                junkPaths.append(path)
            } else if !manifestPaths.contains(path) {
                unregisteredPaths.append(path)
            }
        }
        if !junkPaths.isEmpty {
            issues.append(EPUBInspectionIssue(
                category: .unusedResources,
                severity: .info,
                title: "包含 \(junkPaths.count) 个系统残留文件",
                detail: "例如 __MACOSX 或 .DS_Store 等无关条目。",
                affectedPaths: Array(junkPaths.prefix(10))
            ))
        }
        if !unregisteredPaths.isEmpty {
            issues.append(EPUBInspectionIssue(
                category: .opf,
                severity: .warning,
                title: "压缩包中存在 \(unregisteredPaths.count) 个未注册文件",
                detail: "这些文件存在于压缩包内但未在 OPF manifest 中登记。",
                affectedPaths: Array(unregisteredPaths.prefix(10))
            ))
        }

        // 6) 目录检查（EPUB 3 Nav / EPUB 2 NCX）
        let tocAnalysis = await inspectTOC(opf: opf, archive: archive, entryByPath: entryByPath)
        issues.append(contentsOf: tocAnalysis.issues)

        // 7) 封面检查
        let coverIssues = inspectCover(opf: opf, entryByPath: entryByPath)
        issues.append(contentsOf: coverIssues)

        // 8) 深度模式：逐章检查 XHTML 良构性 / 编码 / 脚本，以及精确计算未引用冗余资源
        var hasScripts = false
        var unusedCount = junkPaths.count
        var unusedBytes: Int64 = junkPaths.reduce(0) { $0 + Int64(entryByPath[$1]?.uncompressedSize ?? 0) }

        if mode == .deep && !isDRM {
            let deep = await inspectDeepContent(
                opf: opf,
                archive: archive,
                entryByPath: entryByPath,
                junkPaths: Set(junkPaths)
            )
            hasScripts = deep.hasScripts
            unusedCount += deep.unusedPaths.count
            unusedBytes += deep.unusedBytes
            issues.append(contentsOf: deep.issues)
        }

        issues.sort { $0.severity < $1.severity }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        return EPUBInspectionReport(
            mode: mode,
            fileSizeBytes: fileSize,
            epubVersion: opf.version.isEmpty ? "2.0" : opf.version,
            title: opf.title.isEmpty ? fallbackTitle : opf.title,
            author: opf.author,
            opfPath: opfPath,
            spineCount: opf.spine.count,
            entryCount: fileEntries.count,
            isDRMProtected: isDRM,
            isFixedLayout: opf.isFixedLayout,
            hasScripts: hasScripts,
            unusedResourceCount: unusedCount,
            unusedResourceBytes: unusedBytes,
            issues: issues
        )
    }

    // MARK: - 目录检查

    private static func inspectTOC(opf: EPUBToolboxParsedOPF, archive: Archive, entryByPath: [String: Entry]) async -> (nodes: [EPUBToolboxTOCNode], issues: [EPUBInspectionIssue]) {
        var issues: [EPUBInspectionIssue] = []
        let navItem = opf.manifest.first(where: \.isNav)
        let ncxItem = opf.manifest.first(where: { item in
            if let tocID = opf.spineTocID, item.id == tocID { return true }
            return item.isNCX
        })

        var validNodes: [EPUBToolboxTOCNode] = []
        var brokenLinkCount = 0

        if let navItem, let entry = entryByPath[navItem.path],
           let data = try? await extractData(from: archive, entry: entry, limit: maxTextEntryBytes),
           let html = decodeText(data).text {
            let parsed = parseNavTOC(html: html, baseDirectory: EPUBToolboxPath.directory(of: navItem.path))
            let checked = countValidAndBroken(nodes: parsed, existingPaths: Set(entryByPath.keys))
            validNodes = parsed
            brokenLinkCount += checked.broken
            if checked.valid == 0 && opf.spine.count > 0 {
                issues.append(EPUBInspectionIssue(
                    category: .toc,
                    severity: .warning,
                    title: "EPUB 3 导航目录无效或为空",
                    detail: "未能从 \(navItem.path) 解析出指向有效章节的目录项。",
                    affectedPaths: [navItem.path]
                ))
            }
        } else if opf.isEPUB3 {
            issues.append(EPUBInspectionIssue(
                category: .toc,
                severity: .warning,
                title: "EPUB 3 缺少导航目录（nav）",
                detail: "EPUB 3 规范要求包含带 properties=\"nav\" 的目录文档。"
            ))
        }

        if let ncxItem, let entry = entryByPath[ncxItem.path],
           let data = try? await extractData(from: archive, entry: entry, limit: maxTextEntryBytes),
           let xml = decodeText(data).text {
            let parsed = parseNCXTOC(xml: xml, baseDirectory: EPUBToolboxPath.directory(of: ncxItem.path))
            let checked = countValidAndBroken(nodes: parsed, existingPaths: Set(entryByPath.keys))
            if validNodes.isEmpty { validNodes = parsed }
            if navItem == nil { brokenLinkCount += checked.broken }
            if checked.valid == 0 && opf.spine.count > 0 {
                issues.append(EPUBInspectionIssue(
                    category: .toc,
                    severity: .warning,
                    title: "NCX 目录无效或为空",
                    detail: "未能从 \(ncxItem.path) 解析出有效目录项。",
                    affectedPaths: [ncxItem.path]
                ))
            }
        } else if navItem == nil {
            issues.append(EPUBInspectionIssue(
                category: .toc,
                severity: .error,
                title: "缺少目录文件（NCX / Nav）",
                detail: "OPF 中未找到可用的目录文档，阅读器目录可能为空。"
            ))
        }

        if brokenLinkCount > 0 {
            issues.append(EPUBInspectionIssue(
                category: .toc,
                severity: .warning,
                title: "目录存在 \(brokenLinkCount) 处断链",
                detail: "部分目录条目指向不存在的章节文件。"
            ))
        }

        let validCount = countValidAndBroken(nodes: validNodes, existingPaths: Set(entryByPath.keys)).valid
        if validCount > 0 && validCount <= 1 && opf.spine.count >= 3 {
            let onlyTitle = validNodes.first?.title ?? ""
            issues.append(EPUBInspectionIssue(
                category: .toc,
                severity: .warning,
                title: "目录不完整（仅 \(validCount) 项）",
                detail: "内嵌目录仅包含「\(onlyTitle)」，但全书有 \(opf.spine.count) 个正文文档，可按章节标题自动补全目录。"
            ))
        }

        return (validNodes, issues)
    }

    private static func countValidAndBroken(nodes: [EPUBToolboxTOCNode], existingPaths: Set<String>) -> (valid: Int, broken: Int) {
        var valid = 0
        var broken = 0
        for node in nodes {
            if !node.path.isEmpty {
                if existingPaths.contains(node.path) { valid += 1 } else { broken += 1 }
            }
            let sub = countValidAndBroken(nodes: node.children, existingPaths: existingPaths)
            valid += sub.valid
            broken += sub.broken
        }
        return (valid, broken)
    }

    // MARK: - 封面检查

    static func resolveCoverItem(in opf: EPUBToolboxParsedOPF, existingPaths: Set<String>) -> (item: EPUBToolboxManifestItem?, needsRepair: Bool, reason: String?) {
        let epub3Cover = opf.manifest.first(where: { $0.properties.contains("cover-image") && existingPaths.contains($0.path) })
        var epub2Cover: EPUBToolboxManifestItem?
        if let content = opf.epub2CoverMetaContent {
            epub2Cover = opf.manifest.first(where: {
                ($0.id == content || $0.path == EPUBToolboxPath.normalize(content) || EPUBToolboxPath.filename(of: $0.path) == content)
                    && existingPaths.contains($0.path)
            })
        }

        if let c3 = epub3Cover, let c2 = epub2Cover {
            if c3.id == c2.id {
                return (c3, false, nil)
            }
            return (c3, true, "EPUB 2 与 EPUB 3 的封面声明指向不同图片，可统一规范化。")
        }
        if let c3 = epub3Cover {
            return (c3, opf.epub2CoverMetaContent == nil, opf.epub2CoverMetaContent == nil ? "缺少 EPUB 2 兼容的 <meta name=\"cover\"> 声明。" : nil)
        }
        if let c2 = epub2Cover {
            if !c2.isImage {
                return (nil, true, "EPUB 2 封面声明指向非图片项（\(c2.path)）。")
            }
            if opf.isEPUB3 && !c2.properties.contains("cover-image") {
                return (c2, true, "缺少 EPUB 3 的 properties=\"cover-image\" 封面属性。")
            }
            return (c2, false, nil)
        }

        // 未声明或声明失效：检查是否存在候选封面图片
        let existingImages = opf.manifest.filter { $0.isImage && existingPaths.contains($0.path) }
        if opf.epub2CoverMetaContent != nil {
            return (candidateCoverImage(from: existingImages), true, "原有封面声明指向不存在的文件。")
        }
        if let candidate = candidateCoverImage(from: existingImages) {
            return (candidate, true, "未在 OPF 中声明封面，检测到候选封面图 \(EPUBToolboxPath.filename(of: candidate.path))。")
        }
        return (nil, false, nil)
    }

    static func candidateCoverImage(from images: [EPUBToolboxManifestItem]) -> EPUBToolboxManifestItem? {
        if let named = images.first(where: {
            let lower = EPUBToolboxPath.filename(of: $0.path).lowercased()
            return lower.contains("cover") || $0.id.lowercased().contains("cover")
        }) {
            return named
        }
        return nil
    }

    private static func inspectCover(opf: EPUBToolboxParsedOPF, entryByPath: [String: Entry]) -> [EPUBInspectionIssue] {
        let resolved = resolveCoverItem(in: opf, existingPaths: Set(entryByPath.keys))
        guard resolved.needsRepair, let reason = resolved.reason else { return [] }
        return [EPUBInspectionIssue(
            category: .cover,
            severity: .warning,
            title: "封面声明不规范或缺失",
            detail: reason,
            affectedPaths: resolved.item.map { [$0.path] } ?? []
        )]
    }

    // MARK: - 深度内容检查（XHTML 良构性 + 精确冗余资源）

    private struct DeepInspectionResult {
        var hasScripts = false
        var unusedPaths: [String] = []
        var unusedBytes: Int64 = 0
        var issues: [EPUBInspectionIssue] = []
    }

    private static func inspectDeepContent(
        opf: EPUBToolboxParsedOPF,
        archive: Archive,
        entryByPath: [String: Entry],
        junkPaths: Set<String>
    ) async -> DeepInspectionResult {
        var result = DeepInspectionResult()
        var malformedXHTML: [String] = []
        var nonUTF8Files: [String] = []
        var missingNamespace: [String] = []

        // 1) 扫描所有 XHTML 文档的编码、XML 良构性与脚本
        let xhtmlItems = opf.manifest.filter { $0.isXHTML && entryByPath[$0.path] != nil }
        var xhtmlTexts: [String: String] = [:]
        for item in xhtmlItems {
            guard let entry = entryByPath[item.path],
                  let data = try? await extractData(from: archive, entry: entry, limit: maxTextEntryBytes) else { continue }
            let decoded = decodeText(data)
            if !decoded.wasUTF8 {
                nonUTF8Files.append(item.path)
            }
            guard let html = decoded.text else {
                malformedXHTML.append(item.path)
                continue
            }
            xhtmlTexts[item.path] = html
            if html.range(of: "<script\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                result.hasScripts = true
            }
            if !isWellFormedXML(data: Data(html.utf8)) {
                malformedXHTML.append(item.path)
            } else if !html.contains("http://www.w3.org/1999/xhtml") {
                missingNamespace.append(item.path)
            }
        }

        if !nonUTF8Files.isEmpty {
            result.issues.append(EPUBInspectionIssue(
                category: .xhtml,
                severity: .warning,
                title: "有 \(nonUTF8Files.count) 个章节不是 UTF-8 编码",
                detail: "非 UTF-8 文本在部分阅读器中可能出现乱码，工具箱会自动转码为 UTF-8。",
                affectedPaths: Array(nonUTF8Files.prefix(10))
            ))
        }
        if !malformedXHTML.isEmpty {
            result.issues.append(EPUBInspectionIssue(
                category: .xhtml,
                severity: .error,
                title: "有 \(malformedXHTML.count) 个章节存在 XHTML 语法错误",
                detail: "存在未闭合标签、非法实体或非良构 XML，可通过 XHTML 良构修复整理。",
                affectedPaths: Array(malformedXHTML.prefix(10))
            ))
        }
        if !missingNamespace.isEmpty {
            result.issues.append(EPUBInspectionIssue(
                category: .xhtml,
                severity: .info,
                title: "有 \(missingNamespace.count) 个章节缺少标准 XHTML 命名空间",
                detail: "补充 xmlns=\"http://www.w3.org/1999/xhtml\" 可提升跨阅读器兼容性。",
                affectedPaths: Array(missingNamespace.prefix(10))
            ))
        }
        if result.hasScripts {
            result.issues.append(EPUBInspectionIssue(
                category: .protection,
                severity: .info,
                title: "书籍包含内嵌脚本（JavaScript）",
                detail: "冗余资源清理会保留脚本文件，但若脚本动态拼接了资源路径，重排目录后可能受影响。"
            ))
        }

        // 2) 可达性分析统计冗余资源
        let reachable = await collectReachablePaths(
            opf: opf,
            archive: archive,
            entryByPath: entryByPath,
            cachedXHTML: xhtmlTexts
        )
        for (path, entry) in entryByPath {
            if path == "mimetype" || path == opf.opfPath || path.hasPrefix("META-INF/") || junkPaths.contains(path) {
                continue
            }
            if !reachable.contains(path) {
                result.unusedPaths.append(path)
                result.unusedBytes += Int64(entry.uncompressedSize)
            }
        }
        result.unusedPaths.sort()

        if !result.unusedPaths.isEmpty {
            let sizeText = ByteCountFormatter.string(fromByteCount: result.unusedBytes, countStyle: .file)
            result.issues.append(EPUBInspectionIssue(
                category: .unusedResources,
                severity: .info,
                title: "发现 \(result.unusedPaths.count) 个未被引用的冗余资源",
                detail: "共占用约 \(sizeText)，可在处理时安全清理以减小文件体积。",
                affectedPaths: Array(result.unusedPaths.prefix(10))
            ))
        }
        return result
    }

    /// 从 spine 文档、目录、封面、guide、JS/SMIL 出发做可达性遍历（供体检和冗余清理共用）。
    static func collectReachablePaths(
        opf: EPUBToolboxParsedOPF,
        archive: Archive,
        entryByPath: [String: Entry],
        cachedXHTML: [String: String] = [:]
    ) async -> Set<String> {
        let existingPaths = Set(entryByPath.keys)
        let manifestByID = Dictionary(opf.manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let manifestByPath = Dictionary(opf.manifest.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var reachable = Set<String>()
        var queue: [String] = []
        func enqueue(_ path: String) {
            let norm = EPUBToolboxPath.normalize(path)
            guard existingPaths.contains(norm), reachable.insert(norm).inserted else { return }
            queue.append(norm)
        }

        // 种子：spine 文档、Nav、NCX、封面、guide、fallback、SMIL/JS（保守保留脚本避免误删）
        for sp in opf.spine {
            if let item = manifestByID[sp.idref] { enqueue(item.path) }
        }
        for item in opf.manifest {
            if item.isNav || item.isNCX || item.properties.contains("cover-image")
                || item.mediaType.lowercased().contains("javascript")
                || item.mediaType.lowercased().contains("smil") {
                enqueue(item.path)
            }
            if let fb = item.fallback, let fbItem = manifestByID[fb] {
                enqueue(fbItem.path)
            }
        }
        if let cover = resolveCoverItem(in: opf, existingPaths: existingPaths).item {
            enqueue(cover.path)
        }
        for ref in opf.guide {
            enqueue(ref.path)
        }

        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let baseDir = EPUBToolboxPath.directory(of: current)
            let item = manifestByPath[current]
            let isHTML = item?.isXHTML ?? ["xhtml", "xht", "html", "htm"].contains(EPUBToolboxPath.pathExtension(of: current))
            let isCSS = item?.isCSS ?? (EPUBToolboxPath.pathExtension(of: current) == "css")
            let isSVG = (item?.mediaType.lowercased() == "image/svg+xml") || EPUBToolboxPath.pathExtension(of: current) == "svg"

            if isHTML {
                let html: String?
                if let cached = cachedXHTML[current] {
                    html = cached
                } else if let entry = entryByPath[current],
                          let data = try? await extractData(from: archive, entry: entry, limit: maxTextEntryBytes) {
                    html = decodeText(data).text
                } else {
                    html = nil
                }
                if let html {
                    for ref in extractHTMLReferences(from: html) {
                        if let resolved = EPUBToolboxPath.resolveRelative(ref, baseDirectory: baseDir) {
                            enqueue(resolved.path)
                        }
                    }
                    for ref in extractCSSReferences(from: html) {
                        if let resolved = EPUBToolboxPath.resolveRelative(ref, baseDirectory: baseDir) {
                            enqueue(resolved.path)
                        }
                    }
                }
            } else if isCSS || isSVG {
                if let entry = entryByPath[current],
                   let data = try? await extractData(from: archive, entry: entry, limit: maxTextEntryBytes),
                   let text = decodeText(data).text {
                    for ref in extractCSSReferences(from: text) {
                        if let resolved = EPUBToolboxPath.resolveRelative(ref, baseDirectory: baseDir) {
                            enqueue(resolved.path)
                        }
                    }
                    if isSVG {
                        for ref in extractHTMLReferences(from: text) {
                            if let resolved = EPUBToolboxPath.resolveRelative(ref, baseDirectory: baseDir) {
                                enqueue(resolved.path)
                            }
                        }
                    }
                }
            }
        }
        return reachable
    }

    // MARK: - 通用解析与工具方法

    static func extractData(from archive: Archive, entry: Entry, limit: Int) async throws -> Data {
        final class LockedBuffer: @unchecked Sendable {
            private let lock = NSLock()
            var data = Data()
            var exceeded = false
            func append(_ chunk: Data, limit: Int) {
                lock.lock()
                defer { lock.unlock() }
                if data.count + chunk.count > limit {
                    exceeded = true
                    return
                }
                data.append(chunk)
            }
        }
        let buffer = LockedBuffer()
        _ = try await archive.extract(entry) { chunk in
            buffer.append(chunk, limit: limit)
        }
        if buffer.exceeded { throw EPUBToolboxError.writeFailed("条目体积超过安全上限：\(entry.path)") }
        return buffer.data
    }

    static func decodeText(_ data: Data) -> (text: String?, wasUTF8: Bool) {
        if let utf8 = String(data: data, encoding: .utf8) {
            return (utf8, true)
        }
        let encodings: [String.Encoding] = [
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            .shiftJIS,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            .isoLatin1,
        ]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return (text, false)
            }
        }
        return (nil, false)
    }

    static func isWellFormedXML(data: Data) -> Bool {
        final class ValidatorDelegate: NSObject, XMLParserDelegate {
            var hasError = false
            func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
                hasError = true
            }
        }
        let parser = XMLParser(data: data)
        let delegate = ValidatorDelegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        return ok && !delegate.hasError
    }

    /// 识别 META-INF/encryption.xml 中的非字体混淆 DRM 加密。
    static func detectsDRM(inEncryptionXML xml: String) -> Bool {
        guard xml.range(of: "EncryptedData", options: .caseInsensitive) != nil else { return false }
        // 提取所有 EncryptionMethod Algorithm 属性；若存在非 IDPF / Adobe 字体混淆的算法，则视为 DRM。
        guard let regex = try? NSRegularExpression(
            pattern: #"Algorithm\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else { return true }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return true }
        let fontObfuscationAlgorithms: Set<String> = [
            "http://www.idpf.org/2008/embedding",
            "http://ns.adobe.com/pdf/enc#rc",
        ]
        for match in matches {
            let algo = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !fontObfuscationAlgorithms.contains(algo) {
                return true
            }
        }
        return false
    }

    static func parseContainerOPFPath(xml: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<rootfile\b[^>]*\bfull-path\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        let decoded = raw.removingPercentEncoding ?? raw
        let normalized = EPUBToolboxPath.normalize(decoded)
        return normalized.isEmpty ? nil : normalized
    }

    static func parseOPF(xml: String, opfPath: String) -> EPUBToolboxParsedOPF? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let opfDir = EPUBToolboxPath.directory(of: opfPath)
        let delegate = OPFSAXParser(opfPath: opfPath, opfDirectory: opfDir)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.result
    }

    static func parseNCXTOC(xml: String, baseDirectory: String) -> [EPUBToolboxTOCNode] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let delegate = NCXSAXParser(baseDirectory: baseDirectory)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.roots
    }

    static func parseNavTOC(html: String, baseDirectory: String) -> [EPUBToolboxTOCNode] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        let navs = (try? doc.select("nav").array()) ?? []
        let tocNav = navs.first(where: { nav in
            let epubType = (try? nav.attr("epub:type"))?.lowercased() ?? ""
            let typeAttr = (try? nav.attr("type"))?.lowercased() ?? ""
            let role = (try? nav.attr("role"))?.lowercased() ?? ""
            return epubType.split(separator: " ").contains("toc")
                || typeAttr.split(separator: " ").contains("toc")
                || role == "doc-toc"
        }) ?? navs.first
        guard let tocNav, let ol = try? tocNav.select("ol").first() else { return [] }
        return parseNavList(ol, baseDirectory: baseDirectory)
    }

    private static func parseNavList(_ listElement: Element, baseDirectory: String) -> [EPUBToolboxTOCNode] {
        var nodes: [EPUBToolboxTOCNode] = []
        for child in listElement.children().array() where child.tagName().lowercased() == "li" {
            let anchor = child.children().array().first(where: { $0.tagName().lowercased() == "a" })
                ?? (try? child.select("a").first())
            let span = child.children().array().first(where: { $0.tagName().lowercased() == "span" })
            let rawTitle = (try? anchor?.text()) ?? (try? span?.text()) ?? ""
            let title = rawTitle.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let href = (try? anchor?.attr("href")) ?? ""
            let resolved = EPUBToolboxPath.resolveRelative(href, baseDirectory: baseDirectory)
            let nestedOL = child.children().array().first(where: { $0.tagName().lowercased() == "ol" })
            let children = nestedOL.map { parseNavList($0, baseDirectory: baseDirectory) } ?? []
            if !title.isEmpty || !children.isEmpty {
                nodes.append(EPUBToolboxTOCNode(
                    title: title.isEmpty ? "章节" : title,
                    path: resolved?.path ?? "",
                    fragment: resolved?.suffix ?? "",
                    children: children
                ))
            }
        }
        return nodes
    }

    /// 抽取 HTML / SVG 中的所有资源路径属性（href / src / poster / xlink:href / data）。
    static func extractHTMLReferences(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:href|src|poster|xlink:href|data)\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard range.location != NSNotFound else { return nil }
            return ns.substring(with: range)
        }
    }

    /// 抽取 CSS 中的 `url(...)` 与 `@import "..."` 引用路径。
    static func extractCSSReferences(from css: String) -> [String] {
        var refs: [String] = []
        let ns = css as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        if let urlRegex = try? NSRegularExpression(
            pattern: #"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s"']+))\s*\)"#,
            options: [.caseInsensitive]
        ) {
            for match in urlRegex.matches(in: css, range: fullRange) {
                for idx in 1...3 {
                    let r = match.range(at: idx)
                    if r.location != NSNotFound {
                        refs.append(ns.substring(with: r))
                        break
                    }
                }
            }
        }
        if let importRegex = try? NSRegularExpression(
            pattern: #"@import\s+(?:"([^"]*)"|'([^']*)')"#,
            options: [.caseInsensitive]
        ) {
            for match in importRegex.matches(in: css, range: fullRange) {
                let r = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                if r.location != NSNotFound {
                    refs.append(ns.substring(with: r))
                }
            }
        }
        return refs
    }
}

// MARK: - OPF / NCX SAX 解析器

private final class OPFSAXParser: NSObject, XMLParserDelegate {
    private let opfPath: String
    private let opfDirectory: String
    private var version = "2.0"
    private var uniqueIdentifier = "BookId"
    private var packagePrefix: String?
    private var packageLang: String?
    private var spineTocID: String?
    private var pageProgressionDirection: String?
    private var metadataEntries: [EPUBToolboxMetadataEntry] = []
    private var manifest: [EPUBToolboxManifestItem] = []
    private var spine: [EPUBToolboxSpineItem] = []
    private var guide: [EPUBToolboxGuideReference] = []
    private var sawPackage = false

    private var inMetadata = false
    private var currentMetadataTag: String?
    private var currentMetadataAttrs: [(String, String)] = []
    private var currentMetadataText = ""

    init(opfPath: String, opfDirectory: String) {
        self.opfPath = opfPath
        self.opfDirectory = opfDirectory
    }

    var result: EPUBToolboxParsedOPF? {
        guard sawPackage || !manifest.isEmpty || !spine.isEmpty else { return nil }
        return EPUBToolboxParsedOPF(
            opfPath: opfPath,
            version: version,
            uniqueIdentifier: uniqueIdentifier,
            packagePrefix: packagePrefix,
            packageLang: packageLang,
            spineTocID: spineTocID,
            pageProgressionDirection: pageProgressionDirection,
            metadataEntries: metadataEntries,
            manifest: manifest,
            spine: spine,
            guide: guide
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = EPUBToolboxParsedOPF.localName(elementName)
        switch local {
        case "package":
            sawPackage = true
            if let v = attributeDict["version"], !v.isEmpty { version = v }
            if let uid = attributeDict["unique-identifier"], !uid.isEmpty { uniqueIdentifier = uid }
            packagePrefix = attributeDict["prefix"]
            packageLang = attributeDict["xml:lang"] ?? attributeDict["lang"]
        case "metadata":
            inMetadata = true
        case "item":
            guard !inMetadata,
                  let id = attributeDict["id"], !id.isEmpty,
                  let rawHref = attributeDict["href"], !rawHref.isEmpty,
                  let resolved = EPUBToolboxPath.resolveRelative(rawHref, baseDirectory: opfDirectory) else { return }
            let mediaType = attributeDict["media-type"] ?? EPUBToolboxPath.inferredMediaType(for: resolved.path)
            let props = Set((attributeDict["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            manifest.append(EPUBToolboxManifestItem(
                id: id,
                path: resolved.path,
                mediaType: mediaType,
                properties: props,
                fallback: attributeDict["fallback"]
            ))
        case "spine":
            spineTocID = attributeDict["toc"]
            pageProgressionDirection = attributeDict["page-progression-direction"]
        case "itemref":
            if let idref = attributeDict["idref"], !idref.isEmpty {
                spine.append(EPUBToolboxSpineItem(
                    idref: idref,
                    linear: attributeDict["linear"],
                    properties: attributeDict["properties"]
                ))
            }
        case "reference":
            guard let type = attributeDict["type"], !type.isEmpty,
                  let rawHref = attributeDict["href"], !rawHref.isEmpty,
                  let resolved = EPUBToolboxPath.resolveRelative(rawHref, baseDirectory: opfDirectory) else { return }
            guide.append(EPUBToolboxGuideReference(
                type: type,
                title: attributeDict["title"],
                path: resolved.path,
                fragment: resolved.suffix
            ))
        default:
            if inMetadata && currentMetadataTag == nil {
                currentMetadataTag = elementName
                currentMetadataAttrs = attributeDict.sorted { $0.key < $1.key }
                currentMetadataText = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentMetadataTag != nil {
            currentMetadataText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = EPUBToolboxParsedOPF.localName(elementName)
        if local == "metadata" {
            inMetadata = false
            return
        }
        if let tag = currentMetadataTag, tag == elementName {
            metadataEntries.append(EPUBToolboxMetadataEntry(
                tagName: tag,
                attributes: currentMetadataAttrs,
                text: currentMetadataText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            currentMetadataTag = nil
            currentMetadataAttrs = []
            currentMetadataText = ""
        }
    }
}

private final class NCXSAXParser: NSObject, XMLParserDelegate {
    private let baseDirectory: String
    private var stack: [EPUBToolboxTOCNode] = []
    private(set) var roots: [EPUBToolboxTOCNode] = []
    private var inNavLabel = false
    private var inText = false
    private var textBuffer = ""

    init(baseDirectory: String) {
        self.baseDirectory = baseDirectory
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = EPUBToolboxParsedOPF.localName(elementName)
        switch local {
        case "navpoint":
            stack.append(EPUBToolboxTOCNode(title: "", path: "", fragment: "", children: []))
        case "navlabel":
            inNavLabel = true
        case "text":
            if inNavLabel {
                inText = true
                textBuffer = ""
            }
        case "content":
            guard !stack.isEmpty,
                  let src = attributeDict["src"],
                  let resolved = EPUBToolboxPath.resolveRelative(src, baseDirectory: baseDirectory) else { return }
            stack[stack.count - 1].path = resolved.path
            stack[stack.count - 1].fragment = resolved.suffix
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = EPUBToolboxParsedOPF.localName(elementName)
        switch local {
        case "text":
            if inText {
                if !stack.isEmpty {
                    let cleaned = textBuffer.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        stack[stack.count - 1].title = cleaned
                    }
                }
                inText = false
                textBuffer = ""
            }
        case "navlabel":
            inNavLabel = false
        case "navpoint":
            guard let finished = stack.popLast() else { return }
            if stack.isEmpty {
                roots.append(finished)
            } else {
                stack[stack.count - 1].children.append(finished)
            }
        default:
            break
        }
    }
}
