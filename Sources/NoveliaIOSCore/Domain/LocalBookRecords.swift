import Foundation

// 本机书库保存的书籍记录。书库索引（library.json）与 WebDAV 清单都直接编码这些类型，
// 新增字段须为可选，使旧版索引和清单仍可解码。

enum WebNovelFileFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case epub
    case txt

    var id: String { rawValue }
    var title: String { self == .epub ? "EPUB" : "TXT" }
    var fileExtension: String { rawValue }
}

/// 网站更新的明确配置；旧记录缺字段时不推断模式，必须由用户确认。
struct WebNovelEPUBUpdateConfiguration: Equatable, Sendable {
    let mode: WebNovelDownloadMode
    let translationSource: NovelTranslationSource?
    var isValid: Bool { mode == .original || translationSource != nil }
    var effectiveSource: NovelTranslationSource? { mode == .original ? nil : translationSource }
}

struct DownloadedWebNovel: Codable, Identifiable, Hashable, Sendable {
    let novel: Novel
    let fileFilename: String
    let downloadedAt: Date
    let translationSource: NovelTranslationSource?
    /// 使用可选字段，使选择语言模式之前创建的索引仍可读取。
    let downloadMode: WebNovelDownloadMode?
    /// 使用可选字段，使旧版应用创建的书库索引仍可读取。
    let fileFormat: WebNovelFileFormat?

    var id: String { novel.id }
    var resolvedFileFormat: WebNovelFileFormat {
        fileFormat ?? (fileFilename.lowercased().hasSuffix(".txt") ? .txt : .epub)
    }
    var epubUpdateConfiguration: WebNovelEPUBUpdateConfiguration? {
        guard let downloadMode else { return nil }
        let value = WebNovelEPUBUpdateConfiguration(mode: downloadMode, translationSource: translationSource)
        return value.isValid ? value : nil
    }
    var resolvedDownloadMode: WebNovelDownloadMode {
        downloadMode ?? (translationSource == nil ? .original : .translated)
    }
}

struct LocalWenkuEPUB: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    let filename: String
    let addedAt: Date
    var lastLocatorJSON: String? = nil
    var bookDescription: String? = nil
    var author: String? = nil
    var coverFilename: String? = nil
    var metadataLoaded: Bool? = nil
    var fileFormat: WebNovelFileFormat? = nil
    var sourceWebNovel: DownloadedWebNovel? = nil
    /// 用户在书库中修改书名、作者、简介或封面的时间；为 nil 表示仍是导入时读出的信息。
    /// 同一文件版本在设备间按此时间合并这些信息，不改动书籍文件。
    var metadataUpdatedAt: Date? = nil
    var resolvedFileFormat: WebNovelFileFormat {
        fileFormat ?? (filename.lowercased().hasSuffix(".txt") ? .txt : .epub)
    }
}
