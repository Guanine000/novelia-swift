import Foundation

public struct Novel: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let summary: String
    public let genres: [String]
    public let chapters: [NovelChapter]
    public let accent: NovelAccent
    public let providerId: String?
    public let novelId: String?
    public let cloudFavoriteFolderID: String?
    public let translationChapterCounts: [NovelTranslationSource: Int]?
    public let totalCharacters: Int?

    public init(
        id: String,
        title: String,
        author: String,
        summary: String,
        genres: [String],
        chapters: [NovelChapter],
        accent: NovelAccent,
        providerId: String? = nil,
        novelId: String? = nil,
        cloudFavoriteFolderID: String? = nil,
        translationChapterCounts: [NovelTranslationSource: Int]? = nil,
        totalCharacters: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.summary = summary
        self.genres = genres
        self.chapters = chapters
        self.accent = accent
        self.providerId = providerId
        self.novelId = novelId
        self.cloudFavoriteFolderID = cloudFavoriteFolderID
        self.translationChapterCounts = translationChapterCounts
        self.totalCharacters = totalCharacters
    }

    public var isRemote: Bool { providerId != nil && novelId != nil }

    public func settingCloudFavoriteFolder(_ folderID: String?) -> Novel {
        Novel(
            id: id,
            title: title,
            author: author,
            summary: summary,
            genres: genres,
            chapters: chapters,
            accent: accent,
            providerId: providerId,
            novelId: novelId,
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

/// Language content included in a generated web-novel download.
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

    /// Mode values understood by the Novelia generated-file endpoint.
    public var apiValue: String {
        switch self {
        case .original: "jp"
        case .translated: "zh"
        // The generated-file API spells the bilingual direction explicitly.
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
