import Foundation
import Security

public struct NoveliaAPIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://n.novelia.cc/api/")!

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

    public func searchNovels(query: String, page: Int = 1) async throws -> [Novel] {
        let response: APIPage<APIWebOutline> = try await get(
            path: ["novel"],
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: "20"),
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "provider", value: Self.providers.joined(separator: ",")),
                URLQueryItem(name: "type", value: "0"),
                URLQueryItem(name: "level", value: "1"),
                URLQueryItem(name: "translate", value: "0"),
                URLQueryItem(name: "sort", value: "0")
            ]
        )

        return response.items.compactMap { $0.asNovel }
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

    public func cloudFavoriteFolders() async throws -> [NoveliaCloudFolder] {
        let response: APICloudFolders = try await get(path: ["user", "favored"])
        return response.favoredWeb
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

    private func mutate(path: [String], method: String) async throws {
        _ = try await request(path: path, method: method)
    }

    private func get<T: Decodable>(path: [String], query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path: path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NoveliaAPIError.decoding(error.localizedDescription)
        }
    }

    private func request(path: [String], method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
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
        if method != "GET" && method != "HEAD" {
            request.httpBody = Data()
        }
        if let token = tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
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

    // Mirrors the provider order used by the Android client's public novel-list request.
    private static let providers = ["kakuyomu", "syosetu", "novelup", "hameln", "pixiv", "alphapolis"]

    fileprivate static func providerName(_ id: String) -> String {
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

    private enum CodingKeys: String, CodingKey { case favoredWeb }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favoredWeb = try container.decodeIfPresent([NoveliaCloudFolder].self, forKey: .favoredWeb) ?? []
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
    case httpStatus(Int, String?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "API 地址无效。"
        case .invalidResponse: return "服务器返回了无法识别的响应。"
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

private struct APIWebOutline: Decodable {
    let providerId: String?
    let novelId: String?
    let titleJp: String?
    let titleZh: String?
    let type: String?
    let keywords: [String]?
    let total: Int?
    let favored: String?
    let lastReadAt: Int64?

    var asNovel: Novel? {
        guard let providerId, let novelId else { return nil }
        return Novel(
            id: "remote/\(providerId)/\(novelId)",
            title: titleZh?.nonEmpty ?? titleJp?.nonEmpty ?? novelId,
            author: NoveliaAPIClient.providerName(providerId),
            summary: "\(type?.nonEmpty ?? "网络小说") · \(total ?? 0) 章",
            genres: keywords ?? [],
            chapters: [],
            accent: NovelAccent.forProvider(providerId),
            providerId: providerId,
            novelId: novelId,
            cloudFavoriteFolderID: favored
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
            bilingualParagraphs: bilingualParagraphs
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
            summary: introductionZh?.nonEmpty ?? introductionJp?.nonEmpty ?? "暂无简介",
            genres: [type?.nonEmpty].compactMap { $0 } + (keywords ?? []),
            chapters: chapters,
            accent: NovelAccent.forProvider(providerId),
            providerId: providerId,
            novelId: novelId,
            cloudFavoriteFolderID: favored
        )
    }
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
