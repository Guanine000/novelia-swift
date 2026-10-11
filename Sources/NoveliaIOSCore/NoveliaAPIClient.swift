import Foundation
import Security
import OSLog

public struct NoveliaAPIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://n.novelia.cc/api/")!
    public static let forumBaseURL = URL(string: "https://forum.novelia.cc/")!
    private static let downloadLogger = Logger(subsystem: "cc.novelia.ios.port", category: "novel-download")

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    public init(
        baseURL: URL = NoveliaAPIClient.defaultBaseURL,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String? = { NoveliaSessionTokenVault.read() }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func searchNovels(query: String, page: Int = 1, exactTag: Bool = false) async throws -> [Novel] {
        let searchQuery = exactTag ? "\(query)$" : query
        // The app uses 1-based pages, while the novel search API is 0-based.
        let apiPage = max(page - 1, 0)
        let response: APIPage<APIWebOutline> = try await get(
            path: ["novel"],
            query: [
                URLQueryItem(name: "page", value: String(apiPage)),
                URLQueryItem(name: "pageSize", value: "20"),
                URLQueryItem(name: "query", value: searchQuery),
                URLQueryItem(name: "provider", value: Self.providers.joined(separator: ",")),
                URLQueryItem(name: "type", value: "0"),
                URLQueryItem(name: "level", value: "1"),
                URLQueryItem(name: "translate", value: "0"),
                URLQueryItem(name: "sort", value: "0")
            ]
        )

        return response.items.compactMap { $0.asNovel }
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
        let response: APIPage<APIWebOutline> = try await get(
            path: ["novel"],
            query: [
                URLQueryItem(name: "page", value: String(page)),
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

    /// Downloads a complete web novel using the same generated-file endpoint as the Novelia website.
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

        var request = URLRequest(url: url)
        request.setValue("application/epub+zip, application/octet-stream", forHTTPHeaderField: "Accept")
        if let token = await NoveliaSessionRenewal.shared.token(app: "n", current: tokenProvider()), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 180
        let downloadStartedAt = ProcessInfo.processInfo.systemUptime
        Self.downloadLogger.info("Starting novel EPUB download; mode=\(apiMode, privacy: .public), translationsMode=\(translationsMode, privacy: .public)")
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            let nsError = error as NSError
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - downloadStartedAt) * 1_000)
            Self.downloadLogger.error("Novel EPUB request failed before receiving an HTTP response; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public), elapsedMs=\(elapsedMS, privacy: .public)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw NoveliaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - downloadStartedAt) * 1_000)
            Self.downloadLogger.error("Novel EPUB request returned HTTP \(http.statusCode, privacy: .public); elapsedMs=\(elapsedMS, privacy: .public)")
            throw NoveliaAPIError.httpStatus(http.statusCode, serverMessage(in: Self.responseData(from: temporaryURL)))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            Self.downloadLogger.error("Novel file response was empty")
            try? FileManager.default.removeItem(at: temporaryURL)
            throw NoveliaAPIError.invalidResponse
        }
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - downloadStartedAt) * 1_000)
        Self.downloadLogger.info("Novel EPUB download completed; bytes=\(size, privacy: .public), elapsedMs=\(elapsedMS, privacy: .public)")
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
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
        if let token = await NoveliaSessionRenewal.shared.token(app: "n", current: tokenProvider()), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw NoveliaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let responseData = Self.responseData(from: temporaryURL)
            throw NoveliaAPIError.httpStatus(http.statusCode, serverMessage(in: responseData))
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
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

    /// Records the chapter most recently opened in the signed-in user's web novel history.
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
            baseURL: Self.forumBaseURL
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
            baseURL: Self.forumBaseURL
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
            baseURL: Self.forumBaseURL
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
        if let token = await NoveliaSessionRenewal.shared.token(app: "n", current: tokenProvider()), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

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

    // Mirrors the provider order used by the Android client's public novel-list request.
    private static let providers = ["kakuyomu", "syosetu", "novelup", "hameln", "pixiv", "alphapolis"]

    public static func providerName(_ id: String) -> String {
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

private struct APICloudFolders: Decodable {
    let favoredWeb: [NoveliaCloudFolder]
    let favoredWenku: [NoveliaCloudFolder]

    private enum CodingKeys: String, CodingKey { case favoredWeb, favoredWenku }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favoredWeb = try container.decodeIfPresent([NoveliaCloudFolder].self, forKey: .favoredWeb) ?? []
        favoredWenku = try container.decodeIfPresent([NoveliaCloudFolder].self, forKey: .favoredWenku) ?? []
    }
}

/// Stores only the Novelia app access token. Authentication cookies stay in WKWebView's
/// website data store, which is the browser-owned store used by the official login flow.
public enum NoveliaSessionTokenVault {
    private static let service = "cc.novelia.ios.session"
    private static let account = "novel-access-token"
#if targetEnvironment(simulator)
    private static let simulatorFallbackKey = "novelia.session-token.simulator"
#endif

    public static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let token = String(data: data, encoding: .utf8) {
            return token
        }
#if targetEnvironment(simulator)
        // Simulator builds may be ad-hoc signed without a Keychain access-group entitlement.
        return UserDefaults.standard.string(forKey: simulatorFallbackKey)
#else
        return nil
#endif
    }

    public static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
#if targetEnvironment(simulator)
                if addStatus == errSecMissingEntitlement || addStatus == errSecNotAvailable {
                    UserDefaults.standard.set(token, forKey: simulatorFallbackKey)
                    return
                }
#endif
                throw NoveliaSessionError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
#if targetEnvironment(simulator)
            if status == errSecMissingEntitlement || status == errSecNotAvailable {
                UserDefaults.standard.set(token, forKey: simulatorFallbackKey)
                return
            }
#endif
            throw NoveliaSessionError.keychain(status)
        }
    }

    public static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
#if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: simulatorFallbackKey)
#endif
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

public enum NoveliaSessionError: LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status): "无法安全保存 Novelia 登录会话（Keychain 错误 \(status)）。"
        }
    }
}

public enum NoveliaAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidInput(String)
    case httpStatus(Int, String?)
    case decoding(String)
    case unsupportedWenkuOriginalDownload

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "API 地址无效。"
        case .invalidResponse: return "服务器返回了无法识别的响应。"
        case let .invalidInput(message): return message
        case .unsupportedWenkuOriginalDownload: return "Novelia 上游暂不支持单独下载文库原文 EPUB。"
        case let .httpStatus(status, message):
            if let message, !message.isEmpty { return "Novelia API 错误（HTTP \(status)）：\(message)" }
            return "Novelia API 错误（HTTP \(status)）。"
        case let .decoding(message): return "无法解析 Novelia API 响应：\(message)"
        }
    }
}

private struct APIPage<Item: Decodable>: Decodable {
    let pageNumber: Int?
    let items: [Item]
}

private struct APIWenkuOutline: Decodable {
    let id: String
    let title: String
    let titleZh: String
    let cover: String?
    let favored: String?

    var asOutline: WenkuNovelOutline {
        WenkuNovelOutline(id: id, title: title, titleZh: titleZh, cover: cover, favored: favored)
    }
}

private struct APIWenkuDetail: Decodable {
    let title: String
    let titleZh: String
    let cover: String?
    let authors: [String]
    let artists: [String]
    let keywords: [String]
    let publisher: String?
    let imprint: String?
    let latestPublishAt: Int64?
    let level: String
    let introduction: String
    let webIds: [String]
    let volumes: [WenkuVolumeMetadata]
    let glossary: [String: String]
    let visited: Int64
    let favored: String?
    let volumeZh: [String]
    let volumeJp: [WenkuVolumeAvailability]

    func asDetail(id: String) -> WenkuNovelDetail {
        WenkuNovelDetail(
            id: id,
            title: title,
            titleZh: titleZh,
            cover: cover,
            authors: authors,
            artists: artists,
            keywords: keywords,
            publisher: publisher,
            imprint: imprint,
            latestPublishAt: latestPublishAt,
            level: level,
            introduction: introduction,
            webIds: webIds,
            volumes: volumes,
            glossary: glossary,
            visited: visited,
            favored: favored,
            volumeZh: volumeZh,
            volumeJp: volumeJp
        )
    }
}

private struct APIWebOutline: Decodable {
    let providerId: String?
    let novelId: String?
    let titleJp: String?
    let titleZh: String?
    let type: String?
    let keywords: [String]?
    let total: Int?
    let totalCharacters: Int?
    let youdao: Int?
    let gpt: Int?
    let sakura: Int?
    let favored: String?
    let wenkuId: String?
    let lastReadAt: Int64?

    var asNovel: Novel? {
        guard let providerId, let novelId else { return nil }
        return Novel(
            id: "remote/\(providerId)/\(novelId)",
            title: titleZh?.nonEmpty ?? titleJp?.nonEmpty ?? novelId,
            author: NoveliaAPIClient.providerName(providerId),
            originalTitle: titleJp?.nonEmpty,
            summary: "\(type?.nonEmpty ?? "网络小说") · \(total ?? 0) 章",
            genres: keywords ?? [],
            chapters: [],
            accent: NovelAccent.forProvider(providerId),
            providerId: providerId,
            novelId: novelId,
            wenkuId: wenkuId?.nonEmpty,
            cloudFavoriteFolderID: favored,
            translationChapterCounts: translationCounts(youdao: youdao, gpt: gpt, sakura: sakura),
            totalCharacters: totalCharacters
        )
    }

    var asReadingHistoryItem: NoveliaCloudReadingHistoryItem? {
        guard let novel = asNovel else { return nil }
        return NoveliaCloudReadingHistoryItem(novel: novel, lastReadAt: lastReadAt)
    }
}

private struct APIWebDetail: Decodable {
    let titleJp: String?
    let titleZh: String?
    let authors: [APIAuthor]?
    let type: String?
    let keywords: [String]?
    let introductionJp: String?
    let introductionZh: String?
    let toc: [APITocItem]?
    let favored: String?
    let lastReadChapterId: String?
    let totalCharacters: Int?
    let youdao: Int?
    let gpt: Int?
    let sakura: Int?
    let wenkuId: String?
}

private struct APIAuthor: Decodable {
    let name: String?
}

private struct APITocItem: Decodable {
    let titleJp: String?
    let titleZh: String?
    let chapterId: String?
}

private struct APIChapter: Decodable {
    let titleJp: String?
    let titleZh: String?
    let paragraphs: [String]?
    let youdaoParagraphs: [String]?
    let gptParagraphs: [String]?
    let sakuraParagraphs: [String]?

    func asNovelChapter(id: String) -> NovelChapter {
        let originals = paragraphs ?? []
        let translationsBySource: [NovelTranslationSource: [String]] = [
            .youdao: youdaoParagraphs,
            .gpt: gptParagraphs,
            .sakura: sakuraParagraphs
        ].compactMapValues { $0 }
        let translationSources = [gptParagraphs, sakuraParagraphs, youdaoParagraphs].compactMap { $0 }
        let paragraphCount = max(originals.count, translationSources.map(\.count).max() ?? 0)
        let bilingualParagraphs = (0..<paragraphCount).compactMap { index -> NovelBilingualParagraph? in
            let original = originals.indices.contains(index) ? originals[index] : ""
            let translation = translationSources
                .compactMap { $0.indices.contains(index) ? $0[index].nonEmpty : nil }
                .first ?? ""
            guard !original.isEmpty || !translation.isEmpty else { return nil }
            return NovelBilingualParagraph(original: original, translation: translation)
        }
        let original = originals.joined(separator: "\n\n")
        let translated = bilingualParagraphs
            .map(\.translation)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return NovelChapter(
            id: id,
            title: titleZh?.nonEmpty ?? titleJp?.nonEmpty ?? id,
            originalText: original,
            translatedText: translated,
            bilingualParagraphs: bilingualParagraphs,
            translationsBySource: translationsBySource
        )
    }
}

private extension APIWebDetail {
    func asNovel(providerId: String, novelId: String) -> Novel {
        let chapters = (toc ?? []).compactMap { item -> NovelChapter? in
            guard let chapterId = item.chapterId?.nonEmpty else { return nil }
            return NovelChapter(
                id: chapterId,
                title: item.titleZh?.nonEmpty ?? item.titleJp?.nonEmpty ?? chapterId,
                originalText: "",
                translatedText: ""
            )
        }
        let author = (authors ?? []).compactMap { $0.name?.nonEmpty }.joined(separator: "、")
        return Novel(
            id: "remote/\(providerId)/\(novelId)",
            title: titleZh?.nonEmpty ?? titleJp?.nonEmpty ?? novelId,
            author: author.isEmpty ? providerId : author,
            originalTitle: titleJp?.nonEmpty,
            summary: introductionZh?.nonEmpty ?? introductionJp?.nonEmpty ?? "暂无简介",
            genres: [type?.nonEmpty].compactMap { $0 } + (keywords ?? []),
            chapters: chapters,
            accent: NovelAccent.forProvider(providerId),
            providerId: providerId,
            novelId: novelId,
            wenkuId: wenkuId?.nonEmpty,
            cloudFavoriteFolderID: favored,
            translationChapterCounts: translationCounts(youdao: youdao, gpt: gpt, sakura: sakura),
            totalCharacters: totalCharacters
        )
    }
}

private func translationCounts(youdao: Int?, gpt: Int?, sakura: Int?) -> [NovelTranslationSource: Int]? {
    let counts: [NovelTranslationSource: Int] = [
        .youdao: youdao,
        .gpt: gpt,
        .sakura: sakura
    ].compactMapValues { $0 }
    return counts.isEmpty ? nil : counts
}

private extension NovelAccent {
    static func forProvider(_ providerId: String) -> NovelAccent {
        switch providerId {
        case "kakuyomu", "novelup": .plum
        case "syosetu", "alphapolis": .ocean
        default: .moss
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}


/// Coordinates each app's access-token renewal without sharing novel/forum sessions.
public actor NoveliaSessionRenewal {
    public static let shared = NoveliaSessionRenewal()
    private var handlers: [String: @Sendable () async -> String?] = [:]
    private var pending: [String: (id: UUID, task: Task<String?, Never>)] = [:]

    public func register(app: String, handler: @escaping @Sendable () async -> String?) {
        handlers[app] = handler
    }

    public static func claims(_ token: String) -> (subject: String, expiration: Double)? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String,
              let expiration = json["exp"] as? NSNumber else { return nil }
        return (subject, expiration.doubleValue)
    }

    public func token(app: String, current: String?, force: Bool = false) async -> String? {
        guard let current, let claims = Self.claims(current) else { return current }
        guard force || claims.expiration <= Date().timeIntervalSince1970 + 60 else { return current }
        guard let handler = handlers[app] else { return current }
        let entry: (id: UUID, task: Task<String?, Never>)
        if let existing = pending[app] { entry = existing }
        else {
            entry = (UUID(), Task { await handler() })
            pending[app] = entry
        }
        let refreshed = await entry.task.value
        if pending[app]?.id == entry.id { pending[app] = nil }
        guard let refreshed, Self.claims(refreshed)?.subject == claims.subject else { return current }
        return refreshed
    }

    public static func data(session: URLSession, request: URLRequest, app: String,
                            tokenProvider: @Sendable () -> String?) async throws -> (Data, URLResponse) {
        let initial = tokenProvider()
        let token = await shared.token(app: app, current: initial)
        var authenticated = request
        authenticated.setValue(token.map { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
        let result = try await session.data(for: authenticated)
        guard (result.1 as? HTTPURLResponse)?.statusCode == 401, let token else { return result }
        let replacement = await shared.token(app: app, current: token, force: true)
        guard let replacement, replacement != token,
              Self.claims(tokenProvider() ?? "")?.subject == Self.claims(token)?.subject else { return result }
        authenticated.setValue("Bearer \(replacement)", forHTTPHeaderField: "Authorization")
        return try await session.data(for: authenticated)
    }
}
