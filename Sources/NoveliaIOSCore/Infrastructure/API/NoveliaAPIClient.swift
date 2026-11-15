import Foundation
import OSLog

public struct NoveliaAPIClient: Sendable {
    public static let defaultBaseURL = APIConfiguration.production.novelAPI
    public static let forumBaseURL = APIConfiguration.production.bookCommentsOrigin
    private static let downloadLogger = Logger(subsystem: "cc.novelia.ios.port", category: "novel-download")

    private let bookCommentsBaseURL: URL
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    public init(
        baseURL: URL = NoveliaAPIClient.defaultBaseURL,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String? = { NoveliaSessionTokenVault.read() },
        bookCommentsBaseURL: URL = NoveliaAPIClient.forumBaseURL
    ) {
        self.bookCommentsBaseURL = bookCommentsBaseURL
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func searchNovels(query: String, page: Int = 1, exactTag: Bool = false,
                             filter: NovelCatalogFilter = .standard) async throws -> NoveliaRankPage {
        let searchQuery = exactTag ? "\(query)$" : query
        // 应用页码从 1 开始，小说搜索 API 的页码从 0 开始。
        let apiPage = max(page - 1, 0)
        let response: APIPage<APIWebOutline> = try await get(
            path: ["novel"],
            query: [
                URLQueryItem(name: "page", value: String(apiPage)),
                URLQueryItem(name: "pageSize", value: "20"),
                URLQueryItem(name: "query", value: searchQuery),
                URLQueryItem(name: "provider", value: Self.providers.joined(separator: ",")),
                URLQueryItem(name: "type", value: String(filter.kind.rawValue)),
                URLQueryItem(name: "level", value: String(filter.rating.rawValue)),
                URLQueryItem(name: "translate", value: "0"),
                URLQueryItem(name: "sort", value: String(filter.sort.rawValue))
            ]
        )

        return NoveliaRankPage(
            novels: response.items.compactMap { $0.asNovel },
            pageCount: max(1, response.pageNumber ?? 1)
        )
    }

    public func searchWenku(query: String, page: Int = 0, pageSize: Int = 24, level: Int = 0) async throws -> WenkuNovelPage {
        let response: APIPage<APIWenkuOutline> = try await get(
            path: ["wenku"],
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "level", value: String(level))
            ]
        )
        return WenkuNovelPage(novels: response.items.map(\.asOutline), pageCount: max(0, response.pageNumber ?? 0))
    }

    public func wenkuNovel(id: String) async throws -> WenkuNovelDetail {
        let detail: APIWenkuDetail = try await get(path: ["wenku", id])
        return detail.asDetail(id: id)
    }

    public func siteRankedNovels(page: Int = 1) async throws -> NoveliaRankPage {
        // 应用页码从 1 开始，API 从 0 开始；之前直接传入导致排行榜第 1 页跳过了前 20 名。
        let response: APIPage<APIWebOutline> = try await get(
            path: ["novel"],
            query: [
                URLQueryItem(name: "page", value: String(max(page - 1, 0))),
                URLQueryItem(name: "pageSize", value: "20"),
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "provider", value: Self.providers.joined(separator: ",")),
                URLQueryItem(name: "type", value: "0"),
                URLQueryItem(name: "level", value: "1"),
                URLQueryItem(name: "translate", value: "0"),
                URLQueryItem(name: "sort", value: "1")
            ]
        )
        return NoveliaRankPage(
            novels: response.items.compactMap { $0.asNovel },
            pageCount: max(1, response.pageNumber ?? 1)
        )
    }

    public func novel(providerId: String, novelId: String) async throws -> Novel {
        let detail: APIWebDetail = try await get(path: ["novel", providerId, novelId])
        return detail.asNovel(providerId: providerId, novelId: novelId)
    }

    public func chapter(providerId: String, novelId: String, chapterId: String) async throws -> NovelChapter {
        let response: APIChapter = try await get(
            path: ["novel", providerId, novelId, "chapter", chapterId]
        )
        return response.asNovelChapter(id: chapterId)
    }

    /// 使用与 Novelia 网站相同的文件生成接口下载完整网络小说。
    public func downloadWebNovelEPUB(
        to destinationURL: URL,
        providerId: String,
        novelId: String,
        title: String,
        translationSource: NovelTranslationSource?,
        mode: WebNovelDownloadMode = .translated
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NoveliaAPIError.invalidURL
        }
        var basePath = components.percentEncodedPath
        if !basePath.hasSuffix("/") { basePath += "/" }
        let encodedPath = ["novel", providerId, novelId, "file"].map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? $0
        }.joined(separator: "/")
        components.percentEncodedPath = basePath + encodedPath

        let apiMode = mode.apiValue
        let translationsMode = mode == .bilingual ? "parallel" : "priority"
        let effectiveTranslationSource = mode == .original ? nil : translationSource
        let translatorCode = effectiveTranslationSource.map { String($0.rawValue.prefix(1)) } ?? ""
        let safeTitle = title.replacingOccurrences(of: "[\\/|\\\\:*?\"<>]", with: "", options: .regularExpression)
        let translationFilenamePrefix = mode == .bilingual ? "B" : "Y"
        let filenameParts = [apiMode, translatorCode.isEmpty ? nil : "\(translationFilenamePrefix)\(translatorCode)", safeTitle, "epub"].compactMap { $0 }
        var queryItems = [
            URLQueryItem(name: "mode", value: apiMode),
            URLQueryItem(name: "translationsMode", value: translationsMode),
            URLQueryItem(name: "type", value: "epub"),
            URLQueryItem(name: "filename", value: filenameParts.joined(separator: "."))
        ]
        if let effectiveTranslationSource {
            queryItems.append(URLQueryItem(name: "translations", value: effectiveTranslationSource.rawValue))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw NoveliaAPIError.invalidURL }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/epub+zip, application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = NoveliaRequestTimeout.generatedNovelFile
        let downloadStartedAt = ProcessInfo.processInfo.systemUptime
        Self.downloadLogger.info("Starting novel EPUB download; mode=\(apiMode, privacy: .public), translationsMode=\(translationsMode, privacy: .public)")
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await NoveliaSessionRenewal.download(
                session: session, request: request, app: "n", tokenProvider: tokenProvider)
        } catch {
            let nsError = error as NSError
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - downloadStartedAt) * 1_000)
            Self.downloadLogger.error("Novel EPUB request failed before receiving an HTTP response; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public), elapsedMs=\(elapsedMS, privacy: .public)")
            throw error
        }
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - downloadStartedAt) * 1_000)
        do {
            let size = try acceptEPUBDownload(at: temporaryURL, response: response, to: destinationURL)
            Self.downloadLogger.info("Novel EPUB download completed; bytes=\(size, privacy: .public), elapsedMs=\(elapsedMS, privacy: .public)")
        } catch {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Self.downloadLogger.error("Novel EPUB download rejected; status=\(status, privacy: .public), elapsedMs=\(elapsedMS, privacy: .public)")
            throw error
        }
    }

    /// 检查下载响应并把文件移到目标位置，返回字节数。非 2xx、空文件或不是 ZIP（EPUB）时删除临时文件并抛错，
    /// 避免代理或服务器返回的网页、错误信息被当作书籍保存，在书库留下打不开的记录。
    @discardableResult
    func acceptEPUBDownload(at temporaryURL: URL, response: URLResponse, to destinationURL: URL) throws -> Int {
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw NoveliaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NoveliaAPIError.httpStatus(http.statusCode, serverMessage(in: Self.responseData(from: temporaryURL)))
        }
        let head = Self.responseData(from: temporaryURL)
        guard !head.isEmpty else { throw NoveliaAPIError.invalidResponse }
        guard head.starts(with: [0x50, 0x4b]) else { throw NoveliaAPIError.notEPUB }
        let size = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? head.count
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return size
    }

    public func cloudFavoriteFolders() async throws -> [NoveliaCloudFolder] {
        let response: APICloudFolders = try await get(path: ["user", "favored"])
        return response.favoredWeb
    }

    public func cloudWenkuFavoriteFolders() async throws -> [NoveliaCloudFolder] {
        let response: APICloudFolders = try await get(path: ["user", "favored"])
        return response.favoredWenku
    }

    public func cloudWenkuFavorites(folderId: String, page: Int = 0, pageSize: Int = 24) async throws -> WenkuNovelPage {
        let response: APIPage<APIWenkuOutline> = try await get(
            path: ["user", "favored-wenku", folderId],
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
                URLQueryItem(name: "sort", value: "create")
            ]
        )
        return WenkuNovelPage(novels: response.items.map(\.asOutline), pageCount: max(0, response.pageNumber ?? 0))
    }

    public func addCloudWenkuFavorite(novelId: String, folderId: String) async throws {
        try await mutate(path: ["user", "favored-wenku", folderId, novelId], method: "PUT")
    }

    public func removeCloudWenkuFavorite(novelId: String, folderId: String) async throws {
        try await mutate(path: ["user", "favored-wenku", folderId, novelId], method: "DELETE")
    }

    public func downloadWenkuEPUB(
        to destinationURL: URL,
        novelId: String,
        volumeId: String,
        mode: WenkuEPUBMode,
        translator: WenkuTranslator,
        filenameTranslators: [WenkuTranslator]? = nil,
        filenameAuthors: [String] = [],
        translationsMode: WenkuTranslationsMode = .priority
    ) async throws {
        guard mode != .original else { throw NoveliaAPIError.unsupportedWenkuOriginalDownload }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NoveliaAPIError.invalidURL
        }
        var basePath = components.percentEncodedPath
        if !basePath.hasSuffix("/") { basePath += "/" }
        let encodedPath = ["wenku", novelId, "file", volumeId].map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? $0
        }.joined(separator: "/")
        components.percentEncodedPath = basePath + encodedPath
        components.queryItems = [
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "translationsMode", value: translationsMode.rawValue),
            URLQueryItem(name: "type", value: "epub"),
            URLQueryItem(
                name: "filename",
                value: mode.websiteDownloadFilename(
                    volumeId: volumeId,
                    translationsMode: translationsMode,
                    translators: filenameTranslators ?? [translator],
                    authors: filenameAuthors
                )
            ),
            URLQueryItem(name: "translations", value: translator.rawValue)
        ]
        guard let url = components.url else { throw NoveliaAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/epub+zip, application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = NoveliaRequestTimeout.wenkuVolume
        let (temporaryURL, response) = try await NoveliaSessionRenewal.download(
            session: session, request: request, app: "n", tokenProvider: tokenProvider)
        try acceptEPUBDownload(at: temporaryURL, response: response, to: destinationURL)
    }

    public func cloudFavorites(folderId: String, page: Int = 0) async throws -> [Novel] {
        let response: APIPage<APIWebOutline> = try await get(
            path: ["user", "favored-web", folderId],
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: "20"),
                URLQueryItem(name: "sort", value: "update"),
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "provider", value: Self.providers.joined(separator: ",")),
                URLQueryItem(name: "type", value: "0"),
                URLQueryItem(name: "level", value: "0"),
                URLQueryItem(name: "translate", value: "0")
            ]
        )
        return response.items.compactMap { $0.asNovel }
    }

    public func cloudReadingHistory(page: Int = 0) async throws -> [NoveliaCloudReadingHistoryItem] {
        let response: APIPage<APIWebOutline> = try await get(
            path: ["user", "read-history"],
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: "20")
            ]
        )
        return response.items.compactMap { $0.asReadingHistoryItem }
    }

    /// 在已登录用户的网络小说阅读历史中记录最近打开的章节。
    public func updateWebReadingHistory(providerId: String, novelId: String, chapterId: String) async throws {
        guard !providerId.isEmpty, !novelId.isEmpty, !chapterId.isEmpty else {
            throw NoveliaAPIError.invalidInput("阅读记录参数无效。")
        }
        _ = try await request(
            path: ["user", "read-history", providerId, novelId],
            method: "PUT",
            body: Data(chapterId.utf8),
            contentType: "text/plain; charset=utf-8"
        )
    }

    public func novelForContinuation(providerId: String, novelId: String) async throws -> NoveliaCloudNovelDetail {
        let detail: APIWebDetail = try await get(path: ["novel", providerId, novelId])
        return NoveliaCloudNovelDetail(
            novel: detail.asNovel(providerId: providerId, novelId: novelId),
            lastReadChapterID: detail.lastReadChapterId
        )
    }

    public func addCloudFavorite(providerId: String, novelId: String, folderId: String) async throws {
        try await mutate(path: ["user", "favored-web", folderId, providerId, novelId], method: "PUT")
    }

    public func removeCloudFavorite(providerId: String, novelId: String, folderId: String) async throws {
        try await mutate(path: ["user", "favored-web", folderId, providerId, novelId], method: "DELETE")
    }

    public func novelComments(providerId: String, novelId: String, page: Int = 1, pageSize: Int = 10) async throws -> NoveliaCommentPage {
        try await novelComments(subjectKey: "web-\(providerId)-\(novelId)", page: page, pageSize: pageSize)
    }

    public func novelComments(subjectKey: String, page: Int = 1, pageSize: Int = 10) async throws -> NoveliaCommentPage {
        return try await get(
            path: ["api", "v1", "external", "comment", "novel", subjectKey],
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize))
            ],
            baseURL: bookCommentsBaseURL
        )
    }

    public func novelCommentReplies(providerId: String, novelId: String, rootID: Int, page: Int = 1, pageSize: Int = 20) async throws -> NoveliaCommentPage {
        try await novelCommentReplies(subjectKey: "web-\(providerId)-\(novelId)", rootID: rootID, page: page, pageSize: pageSize)
    }

    public func novelCommentReplies(subjectKey: String, rootID: Int, page: Int = 1, pageSize: Int = 20) async throws -> NoveliaCommentPage {
        return try await get(
            path: ["api", "v1", "external", "comment", "novel", subjectKey, String(rootID), "reply"],
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize))
            ],
            baseURL: bookCommentsBaseURL
        )
    }

    @discardableResult
    public func postNovelComment(providerId: String, novelId: String, content: String, rootID: Int? = nil) async throws -> NoveliaComment {
        try await postNovelComment(subjectKey: "web-\(providerId)-\(novelId)", content: content, rootID: rootID)
    }

    @discardableResult
    public func postNovelComment(subjectKey: String, content: String, rootID: Int? = nil) async throws -> NoveliaComment {
        var body: [String: Any] = ["content": content]
        if let rootID { body["rootId"] = rootID }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await get(
            path: ["api", "v1", "external", "comment", "novel", subjectKey],
            method: "POST",
            body: bodyData,
            baseURL: bookCommentsBaseURL
        )
    }

    private func mutate(path: [String], method: String) async throws {
        _ = try await request(path: path, method: method)
    }

    private func get<T: Decodable>(path: [String], method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, baseURL: URL? = nil) async throws -> T {
        let data = try await request(path: path, method: method, query: query, body: body, baseURL: baseURL)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NoveliaAPIError.decoding(error.localizedDescription)
        }
    }

    private func request(path: [String], method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, baseURL requestBaseURL: URL? = nil, contentType: String = "application/json") async throws -> Data {
        guard var components = URLComponents(url: requestBaseURL ?? baseURL, resolvingAgainstBaseURL: false) else {
            throw NoveliaAPIError.invalidURL
        }
        var basePath = components.percentEncodedPath
        if !basePath.hasSuffix("/") { basePath += "/" }
        let encodedPath = path.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? segment
        }.joined(separator: "/")
        components.percentEncodedPath = basePath + encodedPath
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw NoveliaAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        } else if method != "GET" && method != "HEAD" {
            request.httpBody = Data()
        }
        request.timeoutInterval = NoveliaRequestTimeout.api

        let (data, response) = try await NoveliaSessionRenewal.data(session: session, request: request, app: "n", tokenProvider: tokenProvider)
        guard let http = response as? HTTPURLResponse else { throw NoveliaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NoveliaAPIError.httpStatus(http.statusCode, serverMessage(in: data))
        }
        return data
    }

    private func serverMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["message"] as? String ?? object["msg"] as? String ?? object["error"] as? String
    }

    private static func responseData(from url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 64 * 1024)) ?? Data()
    }

    // 与 Android 客户端公开小说列表请求使用的翻译来源顺序一致。
    private static let providers = ["kakuyomu", "syosetu", "novelup", "hameln", "pixiv", "alphapolis"]

    public static func providerName(_ id: String) -> String { NovelProviderMetadata.name(id) }
}

public struct NoveliaCloudFolder: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
}

public enum WenkuTranslationsMode: String, CaseIterable, Identifiable, Sendable {
    case priority
    case parallel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .priority: "优先显示一种译源"
        case .parallel: "并列显示所选译源"
        }
    }
}

public struct NoveliaRankPage: Sendable {
    public let novels: [Novel]
    public let pageCount: Int

    public init(novels: [Novel], pageCount: Int) {
        self.novels = novels
        self.pageCount = pageCount
    }
}

public struct NoveliaCommentPage: Codable, Hashable, Sendable {
    public let total: Int
    public let items: [NoveliaComment]

    public init(total: Int, items: [NoveliaComment]) {
        self.total = total
        self.items = items
    }
}

public struct NoveliaComment: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let subjectKey: String
    public let rootId: Int?
    public let content: String
    public let authorId: Int
    public let authorUsername: String
    public let status: Int
    public let createdAt: String
    public let updatedAt: String
    public let replyCount: Int
    public let replies: NoveliaCommentPage?

    public init(id: Int, subjectKey: String, rootId: Int?, content: String, authorId: Int, authorUsername: String, status: Int, createdAt: String, updatedAt: String, replyCount: Int, replies: NoveliaCommentPage? = nil) {
        self.id = id
        self.subjectKey = subjectKey
        self.rootId = rootId
        self.content = content
        self.authorId = authorId
        self.authorUsername = authorUsername
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.replyCount = replyCount
        self.replies = replies
    }
}

public struct NoveliaCloudReadingHistoryItem: Codable, Identifiable, Hashable, Sendable {
    public let novel: Novel
    public let lastReadAt: Int64?
    public var id: String { novel.id }

    public init(novel: Novel, lastReadAt: Int64?) {
        self.novel = novel
        self.lastReadAt = lastReadAt
    }
}

public struct NoveliaCloudNovelDetail: Sendable {
    public let novel: Novel
    public let lastReadChapterID: String?

    public init(novel: Novel, lastReadChapterID: String?) {
        self.novel = novel
        self.lastReadChapterID = lastReadChapterID
    }
}
