import Foundation

/// 文库小说，与表示网络小说的 `Novel` 分开。
public struct WenkuNovelOutline: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let title: String
    public let titleZh: String
    public let cover: String?
    public let favored: String?

    public init(id: String, title: String, titleZh: String = "", cover: String? = nil, favored: String? = nil) {
        self.id = id
        self.title = title
        self.titleZh = titleZh
        self.cover = cover
        self.favored = favored
    }

    public var displayTitle: String {
        titleZh.isEmpty ? title : titleZh
    }
}

public struct WenkuNovelDetail: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let titleZh: String
    public let cover: String?
    public let authors: [String]
    public let artists: [String]
    public let keywords: [String]
    public let publisher: String?
    public let imprint: String?
    public let latestPublishAt: Int64?
    public let level: String
    public let introduction: String
    public let webIds: [String]
    public let volumes: [WenkuVolumeMetadata]
    public let glossary: [String: String]
    public let visited: Int64
    public let favored: String?
    public let volumeZh: [String]
    public let volumeJp: [WenkuVolumeAvailability]

    public init(
        id: String,
        title: String,
        titleZh: String,
        cover: String?,
        authors: [String],
        artists: [String],
        keywords: [String],
        publisher: String?,
        imprint: String?,
        latestPublishAt: Int64?,
        level: String,
        introduction: String,
        webIds: [String],
        volumes: [WenkuVolumeMetadata],
        glossary: [String: String],
        visited: Int64,
        favored: String?,
        volumeZh: [String],
        volumeJp: [WenkuVolumeAvailability]
    ) {
        self.id = id
        self.title = title
        self.titleZh = titleZh
        self.cover = cover
        self.authors = authors
        self.artists = artists
        self.keywords = keywords
        self.publisher = publisher
        self.imprint = imprint
        self.latestPublishAt = latestPublishAt
        self.level = level
        self.introduction = introduction
        self.webIds = webIds
        self.volumes = volumes
        self.glossary = glossary
        self.visited = visited
        self.favored = favored
        self.volumeZh = volumeZh
        self.volumeJp = volumeJp
    }

    public var displayTitle: String { titleZh.isEmpty ? title : titleZh }
}

public struct WenkuVolumeMetadata: Hashable, Sendable, Decodable {
    public let asin: String
    public let title: String
    public let titleZh: String?
    public let cover: String
    public let coverHires: String?
    public let publisher: String?
    public let imprint: String?
    public let publishAt: Int64?
}

public struct WenkuVolumeAvailability: Identifiable, Hashable, Sendable, Decodable {
    public let volumeId: String
    public let total: Int
    public let baidu: Int
    public let youdao: Int
    public let gpt: Int
    public let sakura: Int

    public var id: String { volumeId }

    public func count(for translator: WenkuTranslator) -> Int {
        switch translator {
        case .baidu: baidu
        case .youdao: youdao
        case .gpt: gpt
        case .sakura: sakura
        }
    }
}

public enum WenkuTranslator: String, CaseIterable, Identifiable, Sendable {
    case baidu
    case youdao
    case gpt
    case sakura

    public static let websiteDefaultPriority: [WenkuTranslator] = [.sakura, .gpt, .youdao]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .baidu: "百度"
        case .youdao: "有道"
        case .gpt: "GPT"
        case .sakura: "Sakura"
        }
    }
}

public enum WenkuEPUBMode: String, CaseIterable, Identifiable, Sendable {
    case original = "jp"
    case translated = "zh"
    case originalThenTranslation = "jp-zh"
    case translationThenOriginal = "zh-jp"

    public var id: String { rawValue }

    /// 与 Novelia 网站 EPUB 下载链接生成的文件名一致。
    public func websiteDownloadFilename(
        volumeId: String,
        translationsMode: WenkuTranslationsMode,
        translators: [WenkuTranslator],
        authors: [String] = []
    ) -> String {
        let translatorCodes = translators.map { String($0.rawValue.prefix(1)) }.joined()
        let sourceMode = translationsMode == .parallel ? "B" : "Y"
        let filename = URL(fileURLWithPath: volumeId).lastPathComponent
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        var volumeName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        for author in authors where !author.isEmpty {
            volumeName = volumeName.replacingOccurrences(of: author, with: "")
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_—–·,，、"))
        volumeName = volumeName.trimmingCharacters(in: separators)
        let cleanVolumeId = fileExtension.isEmpty ? volumeName : "\(volumeName).\(fileExtension)"
        return [rawValue, sourceMode + translatorCodes, cleanVolumeId].joined(separator: ".")
    }

    public var title: String {
        switch self {
        case .original: "原文（上游暂不支持）"
        case .translated: "译文"
        case .originalThenTranslation: "原文 + 译文"
        case .translationThenOriginal: "译文 + 原文"
        }
    }
}

public struct WenkuNovelPage: Sendable {
    public let novels: [WenkuNovelOutline]
    public let pageCount: Int

    public init(novels: [WenkuNovelOutline], pageCount: Int) {
        self.novels = novels
        self.pageCount = pageCount
    }
}
