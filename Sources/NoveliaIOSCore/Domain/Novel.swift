import Foundation

public struct Novel: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    /// 原书名（网络小说的原文标题）。服务端未提供或与 `title` 相同时为 nil。
    public let originalTitle: String?
    public let summary: String
    public let genres: [String]
    public let chapters: [NovelChapter]
    public let accent: NovelAccent
    public let providerId: String?
    public let novelId: String?
    /// 同一作品在文库（中文译本）里的 id；服务端未关联文库时为 nil。
    public let wenkuId: String?
    public let cloudFavoriteFolderID: String?
    public let translationChapterCounts: [NovelTranslationSource: Int]?
    public let totalCharacters: Int?

    public init(
        id: String,
        title: String,
        author: String,
        originalTitle: String? = nil,
        summary: String,
        genres: [String],
        chapters: [NovelChapter],
        accent: NovelAccent,
        providerId: String? = nil,
        novelId: String? = nil,
        wenkuId: String? = nil,
        cloudFavoriteFolderID: String? = nil,
        translationChapterCounts: [NovelTranslationSource: Int]? = nil,
        totalCharacters: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.originalTitle = originalTitle
        self.summary = summary
        self.genres = genres
        self.chapters = chapters
        self.accent = accent
        self.providerId = providerId
        self.novelId = novelId
        self.wenkuId = wenkuId
        self.cloudFavoriteFolderID = cloudFavoriteFolderID
        self.translationChapterCounts = translationChapterCounts
        self.totalCharacters = totalCharacters
    }

    public var isRemote: Bool { providerId != nil && novelId != nil }

    /// 仅当原书名存在且与展示标题不同时返回，供详情页决定是否显示「原名」一行。
    public var distinctOriginalTitle: String? {
        guard let originalTitle = originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !originalTitle.isEmpty,
              originalTitle != title else { return nil }
        return originalTitle
    }

    public func settingCloudFavoriteFolder(_ folderID: String?) -> Novel {
        Novel(
            id: id,
            title: title,
            author: author,
            originalTitle: originalTitle,
            summary: summary,
            genres: genres,
            chapters: chapters,
            accent: accent,
            providerId: providerId,
            novelId: novelId,
            wenkuId: wenkuId,
            cloudFavoriteFolderID: folderID,
            translationChapterCounts: translationChapterCounts,
            totalCharacters: totalCharacters
        )
    }
}

public struct NovelChapter: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let originalText: String
    public let translatedText: String
    public let bilingualParagraphs: [NovelBilingualParagraph]?
    public let translationsBySource: [NovelTranslationSource: [String]]?

    public init(
        id: String,
        title: String,
        originalText: String,
        translatedText: String,
        bilingualParagraphs: [NovelBilingualParagraph]? = nil,
        translationsBySource: [NovelTranslationSource: [String]]? = nil
    ) {
        self.id = id
        self.title = title
        self.originalText = originalText
        self.translatedText = translatedText
        self.bilingualParagraphs = bilingualParagraphs
        self.translationsBySource = translationsBySource
    }

    public func translation(for source: NovelTranslationSource) -> [String]? {
        translationsBySource?[source]
    }
}

public enum NovelTranslationSource: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case youdao
    case gpt
    case sakura

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .youdao: "有道"
        case .gpt: "GPT"
        case .sakura: "Sakura"
        }
    }
}

/// 生成的网络小说下载文件包含的语言内容。
public enum WebNovelDownloadMode: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case original
    case translated
    case bilingual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "原文"
        case .translated: "译文"
        case .bilingual: "双语"
        }
    }

    /// Novelia 文件生成接口接受的模式值。
    public var apiValue: String {
        switch self {
        case .original: "jp"
        case .translated: "zh"
        // 文件生成 API 显式区分双语排列顺序。
        case .bilingual: "jp-zh"
        }
    }
}

public struct NovelBilingualParagraph: Hashable, Codable, Sendable {
    public let original: String
    public let translation: String

    public init(original: String, translation: String) {
        self.original = original
        self.translation = translation
    }
}

public enum NovelAccent: String, Hashable, Codable, Sendable {
    case plum
    case ocean
    case moss
}

public enum ReaderMode: String, CaseIterable, Identifiable, Sendable {
    case original
    case translated
    case bilingual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "原文"
        case .translated: "译文"
        case .bilingual: "双语"
        }
    }
}

/// API 适配与界面共用的来源显示信息；展示名称不依赖具体客户端。
public enum NovelProviderMetadata {
    public static func name(_ id: String) -> String {
        switch id {
        case "kakuyomu": "Kakuyomu"
        case "syosetu": "成为小说家吧"
        case "novelup": "Novelup"
        case "hameln": "Hameln"
        case "pixiv": "Pixiv"
        case "alphapolis": "Alphapolis"
        default: id
        }
    }
}
