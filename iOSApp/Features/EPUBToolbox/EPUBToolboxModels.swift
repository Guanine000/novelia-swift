// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 图片压缩档位（使用系统 ImageIO，仅在压缩后体积确有减小时替换）。
enum EPUBImageCompressionOption: String, CaseIterable, Identifiable, Equatable, Sendable {
    case off
    case high
    case balanced
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "不压缩"
        case .high: "高清瘦身（2048px · 85%）"
        case .balanced: "均衡瘦身（1600px · 78%）"
        case .compact: "极限瘦身（1200px · 70%）"
        }
    }

    var maxPixelSize: Int {
        switch self {
        case .off: 0
        case .high: 2048
        case .balanced: 1600
        case .compact: 1200
        }
    }

    var jpegQuality: Double {
        switch self {
        case .off: 1.0
        case .high: 0.85
        case .balanced: 0.78
        case .compact: 0.70
        }
    }
}

/// 全书简繁转换选项（复用项目内置简繁词表与语言标记修正）。
enum EPUBChineseConversionOption: String, CaseIterable, Identifiable, Equatable, Sendable {
    case none
    case toSimplified
    case toTraditional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "保持原文"
        case .toSimplified: "转为简体中文"
        case .toTraditional: "轉為繁體中文（台灣常用詞）"
        }
    }
}

/// 横排 / 竖排一键转换选项。
enum EPUBWritingDirectionTransform: String, CaseIterable, Identifiable, Equatable, Sendable {
    case keep
    case horizontal
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: "保持原样"
        case .horizontal: "转为横排（从左到右）"
        case .vertical: "转为竖排（从右到左）"
        }
    }
}

/// Ruby 注音处理模式。
enum EPUBRubyHandling: String, CaseIterable, Identifiable, Equatable, Sendable {
    case keep
    case removeAnnotations
    case inlineParentheses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: "保留原样"
        case .removeAnnotations: "移除所有注音"
        case .inlineParentheses: "转为「底文（读音）」"
        }
    }
}

/// 写入 EPUB 文件的元数据与封面覆盖项（nil 表示保留原书字段）。
struct EPUBMetadataOverride: Equatable, Sendable {
    var title: String?
    var author: String?
    var language: String?
    var description: String?
    var coverImageData: Data?
    var coverMediaType: String = "image/jpeg"

    var hasAnyOverride: Bool {
        title != nil || author != nil || language != nil || description != nil || coverImageData != nil
    }
}

/// EPUB 工具箱单书处理选项（全部支持独立开关与自由组合）。
struct EPUBToolboxOptions: Equatable, Sendable {
    /// EPUB 目录结构标准化（Sigil Norm：`OEBPS/{Text,Styles,Images,Fonts,Misc}` + 相对路径重写）。
    var standardizeStructure = true
    /// XHTML 良构修复（非 UTF-8 转码、未闭合标签与非法实体修复、补齐 XML/XHTML 声明）。
    var mendXHTML = true
    /// OPF / 目录 / 封面修复（清理死链、补录未注册资源、修复或重建 NCX/Nav、规范化封面声明）。
    var repairOPFTOCCover = true
    /// 冗余资源清理（移除未被正文、目录、封面或样式表引用的图片、样式表、字体与杂项）。
    var removeUnusedResources = true

    /// 图片瘦身压缩。
    var imageCompression: EPUBImageCompressionOption = .off
    /// 元数据与封面覆写。
    var metadataOverride: EPUBMetadataOverride?
    /// 移除内嵌字体文件并清理 CSS 中的 `@font-face`。
    var removeEmbeddedFonts = false
    /// 清理 CSS 与内联样式中写死的字色、底色、字号、行高与字体族。
    var cleanForcedStyles = false
    /// 全书简繁转换。
    var chineseConversion: EPUBChineseConversionOption = .none
    /// 横排 / 竖排转换。
    var writingDirection: EPUBWritingDirectionTransform = .keep
    /// EPUB 2 → EPUB 3 升级。
    var upgradeToEPUB3 = false
    /// Ruby 注音处理。
    var rubyHandling: EPUBRubyHandling = .keep
    /// 注释标准化（将多看等常见非标准脚注转为标准 EPUB 3 noteref / footnote）。
    var standardizeFootnotes = false
    /// 目录可视化编辑器手工修订后的目录（非 nil 时写入 NCX 与 Nav）。
    var customTOC: [EPUBToolboxTOCNode]?

    var hasAnyEnabled: Bool {
        standardizeStructure
            || mendXHTML
            || repairOPFTOCCover
            || removeUnusedResources
            || imageCompression != .off
            || (metadataOverride?.hasAnyOverride == true)
            || removeEmbeddedFonts
            || cleanForcedStyles
            || chineseConversion != .none
            || writingDirection != .keep
            || upgradeToEPUB3
            || rubyHandling != .keep
            || standardizeFootnotes
            || customTOC != nil
    }

    static let all = EPUBToolboxOptions()
}

/// 体检模式：导入链路使用 `lightweight`（仅读 ZIP 目录与 OPF/目录元数据），工具箱页使用 `deep`。
enum EPUBInspectionMode: Equatable, Sendable {
    case lightweight
    case deep
}

enum EPUBIssueSeverity: Int, Comparable, Sendable {
    case error = 0
    case warning = 1
    case info = 2

    static func < (lhs: EPUBIssueSeverity, rhs: EPUBIssueSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .error: "错误"
        case .warning: "警告"
        case .info: "建议"
        }
    }
}

enum EPUBIssueCategory: String, Equatable, Sendable {
    case structure
    case xhtml
    case opf
    case toc
    case cover
    case unusedResources
    case protection

    var title: String {
        switch self {
        case .structure: "目录结构"
        case .xhtml: "XHTML 语法"
        case .opf: "OPF 清单"
        case .toc: "目录"
        case .cover: "封面"
        case .unusedResources: "冗余资源"
        case .protection: "保护与兼容"
        }
    }
}

struct EPUBInspectionIssue: Identifiable, Equatable, Sendable {
    let id = UUID()
    let category: EPUBIssueCategory
    let severity: EPUBIssueSeverity
    let title: String
    let detail: String
    let affectedPaths: [String]

    init(category: EPUBIssueCategory, severity: EPUBIssueSeverity, title: String, detail: String, affectedPaths: [String] = []) {
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
        self.affectedPaths = affectedPaths
    }

    static func == (lhs: EPUBInspectionIssue, rhs: EPUBInspectionIssue) -> Bool {
        lhs.category == rhs.category
            && lhs.severity == rhs.severity
            && lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.affectedPaths == rhs.affectedPaths
    }
}

/// 单本 EPUB 的结构体检报告。
struct EPUBInspectionReport: Equatable, Sendable {
    let mode: EPUBInspectionMode
    let fileSizeBytes: Int64
    let epubVersion: String
    let title: String
    let author: String
    let opfPath: String?
    let spineCount: Int
    let entryCount: Int
    let isDRMProtected: Bool
    let isFixedLayout: Bool
    let hasScripts: Bool
    let unusedResourceCount: Int
    let unusedResourceBytes: Int64
    let issues: [EPUBInspectionIssue]

    /// 是否存在值得提示用户进行修复或标准化的问题。
    var hasActionableIssues: Bool {
        guard !isDRMProtected else { return false }
        return issues.contains { $0.category != .protection }
    }

    /// 供导入弹窗展示的简短摘要。
    var shortSummary: String {
        let actionable = issues.filter { $0.category != .protection }
        guard !actionable.isEmpty else { return "结构正常" }
        let titles = actionable.prefix(3).map(\.title)
        let suffix = actionable.count > 3 ? " 等 \(actionable.count) 项" : ""
        return titles.joined(separator: "、") + suffix
    }
}

/// EPUB 处理完成后的产物与统计摘要。
struct EPUBToolboxResult: Equatable, Sendable {
    let outputURL: URL
    let suggestedTitle: String
    let suggestedFilename: String
    let originalSizeBytes: Int64
    let outputSizeBytes: Int64
    let relocatedPathsCount: Int
    let mendedXHTMLCount: Int
    let removedDeadManifestCount: Int
    let registeredOrphanCount: Int
    let repairedTOC: Bool
    let repairedCover: Bool
    let removedUnusedCount: Int
    let removedUnusedBytes: Int64
    var compressedImagesCount: Int = 0
    var compressedImagesSavedBytes: Int64 = 0
    var removedFontsCount: Int = 0
    var removedFontsBytes: Int64 = 0
    var cleanedStyleCount: Int = 0
    var convertedChinese: Bool = false
    var convertedWritingDirection: Bool = false
    var upgradedToEPUB3: Bool = false
    var processedRubyCount: Int = 0
    var standardizedFootnotesCount: Int = 0
    var updatedMetadata: Bool = false
    let notes: [String]

    var totalChangesCount: Int {
        relocatedPathsCount
            + mendedXHTMLCount
            + removedDeadManifestCount
            + registeredOrphanCount
            + (repairedTOC ? 1 : 0)
            + (repairedCover ? 1 : 0)
            + removedUnusedCount
            + compressedImagesCount
            + removedFontsCount
            + cleanedStyleCount
            + (convertedChinese ? 1 : 0)
            + (convertedWritingDirection ? 1 : 0)
            + (upgradedToEPUB3 ? 1 : 0)
            + processedRubyCount
            + standardizedFootnotesCount
            + (updatedMetadata ? 1 : 0)
    }
}

/// 内部文件浏览器展示的单条压缩包资源信息。
struct EPUBArchiveEntryInfo: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let category: String
    let uncompressedBytes: Int64
    let compressedBytes: Int64
    let isCompressed: Bool
    let isTextPreviewable: Bool
    let isReferenced: Bool
}

/// 处理阶段进度回调数据。
struct EPUBToolboxProgress: Equatable, Sendable {
    let fraction: Double
    let stage: String
}

enum EPUBToolboxError: LocalizedError, Equatable {
    case invalidArchive
    case drmProtected
    case missingOPF
    case nothingSelected
    case cancelled
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "文件损坏或不是有效的 EPUB 压缩包。"
        case .drmProtected: "此 EPUB 受 DRM 加密保护，工具箱无法修改。"
        case .missingOPF: "找不到 OPF 配置文件，无法解析书籍结构。"
        case .nothingSelected: "请至少启用一项处理功能。"
        case .cancelled: "已取消处理。"
        case .writeFailed(let detail): "写入处理结果失败：\(detail)"
        }
    }
}

// MARK: - 内部共享路径与 XML 工具

enum EPUBToolboxPath {
    /// 规范化 ZIP 内路径：统一使用 `/`，去掉开头 `./`、`/` 并折叠 `..`。
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var components: [String] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    static func directory(of path: String) -> String {
        let normalized = normalize(path)
        guard let slash = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<slash])
    }

    static func filename(of path: String) -> String {
        let normalized = normalize(path)
        guard let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    static func pathExtension(of path: String) -> String {
        let name = filename(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// 把相对引用（含可选 `#fragment` 或 `?query`）解析为 ZIP 根路径与后缀。
    static func resolveRelative(_ reference: String, baseDirectory: String) -> (path: String, suffix: String)? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:")
            || lower.hasPrefix("data:") || lower.hasPrefix("javascript:")
            || lower.hasPrefix("file:") {
            return nil
        }

        let suffixStart = trimmed.firstIndex(where: { $0 == "#" || $0 == "?" })
        let rawPath = suffixStart.map { String(trimmed[..<$0]) } ?? trimmed
        let suffix = suffixStart.map { String(trimmed[$0...]) } ?? ""
        guard !rawPath.isEmpty else { return nil }

        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let combined: String
        if decoded.hasPrefix("/") {
            combined = String(decoded.dropFirst())
        } else if baseDirectory.isEmpty {
            combined = decoded
        } else {
            combined = baseDirectory + "/" + decoded
        }
        let normalized = normalize(combined)
        return normalized.isEmpty ? nil : (normalized, suffix)
    }

    /// 计算从 `fromDirectory` 指向 `targetPath` 的相对路径（用于重写 XHTML/CSS/OPF/NCX 链接）。
    static func relativePath(fromDirectory: String, to targetPath: String) -> String {
        let fromParts = normalize(fromDirectory).split(separator: "/").map(String.init)
        let toParts = normalize(targetPath).split(separator: "/").map(String.init)
        var common = 0
        while common < fromParts.count && common < toParts.count && fromParts[common] == toParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        let downs = Array(toParts[common...])
        return (ups + downs).joined(separator: "/")
    }

    /// 对路径的每一段做 URI 百分号编码，保留 `/`。
    static func percentEncodePath(_ path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    /// 判断是否为系统生成的无用垃圾条目（如 macOS `__MACOSX/`、`.DS_Store`）。
    static func isJunkArchiveEntry(_ path: String) -> Bool {
        let normalized = normalize(path)
        let lower = normalized.lowercased()
        let name = filename(of: lower)
        return normalized.isEmpty
            || lower.hasPrefix("__macosx/")
            || name == ".ds_store"
            || name == "thumbs.db"
            || name == "desktop.ini"
            || name.hasPrefix("._")
    }

    /// 根据文件扩展名推断常见 EPUB MIME 类型。
    static func inferredMediaType(for path: String) -> String {
        switch pathExtension(of: path) {
        case "xhtml", "xht", "html", "htm": "application/xhtml+xml"
        case "css": "text/css"
        case "ncx": "application/x-dtbncx+xml"
        case "opf": "application/oebps-package+xml"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "bmp": "image/bmp"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "js": "application/javascript"
        case "smil": "application/smil+xml"
        case "mp3": "audio/mpeg"
        case "m4a", "mp4": "audio/mp4"
        case "pls": "application/pls+xml"
        case "xml": "application/xml"
        default: "application/octet-stream"
        }
    }

    /// 清理用于文件名或 ZIP 条目名的非法字符，避免路径穿越或控制字符。
    static func sanitizedFilename(_ raw: String, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "[/\\\\:*?\"<>|\\x00-\\x1F]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(120))
    }

    /// 归类资源到 Sigil 标准子目录。
    enum SigilFolder: String {
        case text = "OEBPS/Text"
        case styles = "OEBPS/Styles"
        case images = "OEBPS/Images"
        case fonts = "OEBPS/Fonts"
        case misc = "OEBPS/Misc"
    }

    static func sigilFolder(for path: String, mediaType: String) -> SigilFolder {
        let mt = mediaType.lowercased()
        let ext = pathExtension(of: path)
        if mt.contains("xhtml") || mt == "text/html" || ["xhtml", "xht", "html", "htm"].contains(ext) {
            return .text
        }
        if mt == "text/css" || ext == "css" {
            return .styles
        }
        if mt.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "avif"].contains(ext) {
            return .images
        }
        if mt.hasPrefix("font/") || mt.contains("font") || ["ttf", "otf", "woff", "woff2", "ttc"].contains(ext) {
            return .fonts
        }
        return .misc
    }

    static func isAlreadyCompressedFormat(_ path: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "woff", "woff2", "mp3", "m4a", "mp4", "zip", "gz"].contains(pathExtension(of: path))
    }

    static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
