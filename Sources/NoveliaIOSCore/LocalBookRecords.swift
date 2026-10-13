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
    var resolvedFileFormat: WebNovelFileFormat {
        fileFormat ?? (filename.lowercased().hasSuffix(".txt") ? .txt : .epub)
    }
}
