import Foundation

public struct Novel: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let summary: String
    public let genres: [String]
    public let chapters: [NovelChapter]
    public let accent: NovelAccent
    public let providerId: String?
    public let novelId: String?

    public init(
        id: String,
        title: String,
        author: String,
        summary: String,
        genres: [String],
        chapters: [NovelChapter],
        accent: NovelAccent,
        providerId: String? = nil,
        novelId: String? = nil
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
    }

    public var isRemote: Bool { providerId != nil && novelId != nil }
}

public struct NovelChapter: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let originalText: String
    public let translatedText: String

    public init(id: String, title: String, originalText: String, translatedText: String) {
        self.id = id
        self.title = title
        self.originalText = originalText
        self.translatedText = translatedText
    }
}

public enum NovelAccent: String, Hashable, Sendable {
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
