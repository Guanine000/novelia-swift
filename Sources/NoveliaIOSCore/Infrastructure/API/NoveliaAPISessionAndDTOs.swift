import Foundation
import Security

// MARK: - Novelia API 会话凭据、令牌续期与响应 DTO

struct APICloudFolders: Decodable {
    let favoredWeb: [NoveliaCloudFolder]
    let favoredWenku: [NoveliaCloudFolder]

    private enum CodingKeys: String, CodingKey { case favoredWeb, favoredWenku }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favoredWeb = try container.decodeIfPresent([NoveliaCloudFolder].self, forKey: .favoredWeb) ?? []
        favoredWenku = try container.decodeIfPresent([NoveliaCloudFolder].self, forKey: .favoredWenku) ?? []
    }
}

/// 仅保存 Novelia 应用的访问令牌。认证 Cookie 保留在 WKWebView 的网站数据存储中，
/// 该存储由浏览器管理，也是官方登录流程使用的存储。
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
        // 模拟器构建可能采用临时签名，没有钥匙串访问组授权。
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
    case notEPUB

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "API 地址无效。"
        case .invalidResponse: return "服务器返回了无法识别的响应。"
        case let .invalidInput(message): return message
        case .unsupportedWenkuOriginalDownload: return "Novelia 上游暂不支持单独下载文库原文 EPUB。"
        case .notEPUB: return "服务器返回的不是有效的 EPUB 文件，请稍后重试。"
        case let .httpStatus(status, message):
            if let message, !message.isEmpty { return "Novelia API 错误（HTTP \(status)）：\(message)" }
            return "Novelia API 错误（HTTP \(status)）。"
        case let .decoding(message): return "无法解析 Novelia API 响应：\(message)"
        }
    }
}

struct APIPage<Item: Decodable>: Decodable {
    let pageNumber: Int?
    let items: [Item]
}

struct APIWenkuOutline: Decodable {
    let id: String
    let title: String
    let titleZh: String
    let cover: String?
    let favored: String?

    var asOutline: WenkuNovelOutline {
        WenkuNovelOutline(id: id, title: title, titleZh: titleZh, cover: cover, favored: favored)
    }
}

struct APIWenkuDetail: Decodable {
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

struct APIWebOutline: Decodable {
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

struct APIWebDetail: Decodable {
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

struct APIAuthor: Decodable {
    let name: String?
}

struct APITocItem: Decodable {
    let titleJp: String?
    let titleZh: String?
    let chapterId: String?
    let createAt: Int64?
    let updateAt: Int64?
}

struct APIChapter: Decodable {
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
            translationsBySource: translationsBySource,
            originalTitle: titleJp?.nonEmpty
        )
    }
}

extension APIWebDetail {
    func asNovel(providerId: String, novelId: String) -> Novel {
        var volumeTitle: String?, originalVolumeTitle: String?
        let chapters = (toc ?? []).compactMap { item -> NovelChapter? in
            guard let chapterId = item.chapterId?.nonEmpty else {
                volumeTitle = item.titleZh?.nonEmpty ?? item.titleJp?.nonEmpty
                originalVolumeTitle = item.titleJp?.nonEmpty
                return nil
            }
            return NovelChapter(
                id: chapterId,
                title: item.titleZh?.nonEmpty ?? item.titleJp?.nonEmpty ?? chapterId,
                originalText: "",
                translatedText: "",
                originalTitle: item.titleJp?.nonEmpty,
                volumeTitle: volumeTitle, originalVolumeTitle: originalVolumeTitle,
                updatedAt: item.updateAt ?? item.createAt
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

/// 分别协调各应用的访问令牌续期，不共享小说和论坛会话。
/// `NoveliaAPIClient` 与 `ForumAPIClient` 共用的请求超时设置。
public enum NoveliaRequestTimeout {
    /// JSON API 请求。
    public static let api: TimeInterval = 30
    /// 文库小说分卷 EPUB 文件。
    public static let wenkuVolume: TimeInterval = 120
    /// 网络小说 EPUB/TXT 文件，由服务器按请求生成。
    public static let generatedNovelFile: TimeInterval = 180
}

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

    /// JSON 及其他内存响应。认证和重试逻辑见 `send`。
    public static func data(session: URLSession, request: URLRequest, app: String,
                            tokenProvider: @Sendable () -> String?) async throws -> (Data, URLResponse) {
        try await send(request, app: app, tokenProvider: tokenProvider) { try await session.data(for: $0) }
    }

    /// 写入临时位置的大文件。认证和重试逻辑见 `send`。
    public static func download(session: URLSession, request: URLRequest, app: String,
                                tokenProvider: @Sendable () -> String?) async throws -> (URL, URLResponse) {
        try await send(request, app: app, tokenProvider: tokenProvider) { try await session.download(for: $0) }
    }

    /// 两个 API 客户端的请求都经过这里：账户令牌在即将过期时续期；
    /// HTTP 401 会使用同一账户续期后的令牌重试一次；
    /// GET/HEAD 请求在连接中断，或代理返回 502/503/504 时重试一次。
    /// 超时不重试（文件生成可能需要数分钟），
    /// 修改数据的请求也不重试。
    static func send<Body>(_ request: URLRequest, app: String, tokenProvider: @Sendable () -> String?,
                           perform: (URLRequest) async throws -> (Body, URLResponse)) async throws -> (Body, URLResponse) {
        let initial = tokenProvider()
        let token = await shared.token(app: app, current: initial)
        var authenticated = request
        authenticated.setValue(token.map { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
        let result = try await performRetryingTransientFailures(authenticated, perform: perform)
        guard (result.1 as? HTTPURLResponse)?.statusCode == 401, let token else { return result }
        let replacement = await shared.token(app: app, current: token, force: true)
        guard let replacement, replacement != token,
              Self.claims(tokenProvider() ?? "")?.subject == Self.claims(token)?.subject else { return result }
        discard(result.0)
        authenticated.setValue("Bearer \(replacement)", forHTTPHeaderField: "Authorization")
        return try await performRetryingTransientFailures(authenticated, perform: perform)
    }

    /// 临时故障重试前的等待时间（纳秒）；测试中会缩短。
    /// 使用整数而不是 `Duration`，以便在 iOS 15 上编译。
    nonisolated(unsafe) static var transientRetryDelayNanoseconds: UInt64 = 1_000_000_000
    static let transientErrors: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
    static let transientStatuses: Set<Int> = [502, 503, 504]

    private static func performRetryingTransientFailures<Body>(
        _ request: URLRequest, perform: (URLRequest) async throws -> (Body, URLResponse)
    ) async throws -> (Body, URLResponse) {
        let idempotent = ["GET", "HEAD"].contains(request.httpMethod?.uppercased() ?? "GET")
        do {
            let result = try await perform(request)
            guard idempotent, let status = (result.1 as? HTTPURLResponse)?.statusCode,
                  transientStatuses.contains(status) else { return result }
            discard(result.0)
        } catch let error as URLError where idempotent && transientErrors.contains(error.code) {
            // 继续执行下方唯一一次重试。
        }
        try await Task.sleep(nanoseconds: transientRetryDelayNanoseconds)
        return try await perform(request)
    }

    /// 被新请求替代的下载会留下临时文件。
    private static func discard<Body>(_ body: Body) {
        if let file = body as? URL { try? FileManager.default.removeItem(at: file) }
    }
}
