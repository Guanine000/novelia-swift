import Foundation

/// Forum API contract follows the GPL-3.0 Android client at nobYoQ/novelia.
/// This iOS adaptation is separately maintained under this repository's GPL-3.0-only license.
public struct ForumAPIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://forum.novelia.cc/api/v1/")!

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    public init(
        baseURL: URL = ForumAPIClient.defaultBaseURL,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func categories() async throws -> [ForumCategory] {
        try await get(path: ["category"])
    }

    public func posts(
        page: Int = 0,
        pageSize: Int = 20,
        category: String = "",
        query: String = "",
        sort: ForumSort = .active,
        tagID: Int64? = nil,
        source: ForumFeedSource = .all
    ) async throws -> ForumPage<ForumPost> {
        guard page >= 0, pageSize > 0, pageSize <= 100 else { throw ForumAPIError.invalidInput("论坛分页参数无效。") }
        var items = [
            URLQueryItem(name: "page", value: String(page + 1)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ]
        if source == .all, !category.isEmpty { items.append(URLQueryItem(name: "category", value: category)) }
        if source == .all, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if source == .all { items.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        if source == .all, category == "novel", let tagID, tagID > 0 {
            items.append(URLQueryItem(name: "tag", value: String(tagID)))
        }
        let path = source == .favorites ? ["me", "favorite"] : source == .myPosts ? ["me", "post"] : ["post", ""]
        return try await get(path: path, query: items)
    }

    public func post(id: Int64) async throws -> ForumPost {
        try await get(path: ["post", String(id), ""])
    }

    public func comments(postID: Int64, page: Int = 0, pageSize: Int = 20) async throws -> ForumPage<ForumComment> {
        guard page >= 0, pageSize > 0, pageSize <= 100 else { throw ForumAPIError.invalidInput("论坛分页参数无效。") }
        return try await get(path: ["post", String(postID), "comment"], query: paging(page: page, pageSize: pageSize))
    }

    public func replies(postID: Int64, rootID: Int64, page: Int = 0, pageSize: Int = 20) async throws -> ForumPage<ForumComment> {
        guard page >= 0, pageSize > 0, pageSize <= 100 else { throw ForumAPIError.invalidInput("论坛分页参数无效。") }
        return try await get(
            path: ["post", String(postID), "comment", String(rootID), "reply"],
            query: paging(page: page, pageSize: pageSize)
        )
    }

    public func createComment(postID: Int64, content: String, rootID: Int64? = nil) async throws -> ForumComment {
        let length = content.unicodeScalars.count
        guard (1...1_000).contains(length) else { throw ForumAPIError.invalidInput("评论长度需为 1–1,000 个字符。") }
        if let rootID, rootID <= 0 { throw ForumAPIError.invalidInput("回复目标无效。") }
        var body: [String: Any] = ["content": content]
        if let rootID { body["rootId"] = rootID }
        return try await request(
            path: ["post", String(postID), "comment"],
            method: "POST",
            body: JSONSerialization.data(withJSONObject: body),
            as: ForumComment.self
        )
    }

    /// Updates one of the authenticated user's comments (including a reply).
    public func updateComment(postID: Int64, commentID: Int64, content: String) async throws -> ForumComment {
        guard postID > 0, commentID > 0 else { throw ForumAPIError.invalidInput("评论无效。") }
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1_000).contains(normalized.unicodeScalars.count) else {
            throw ForumAPIError.invalidInput("评论长度需为 1–1,000 个字符。")
        }
        return try await request(
            path: ["post", String(postID), "comment", String(commentID)],
            method: "PATCH",
            body: JSONSerialization.data(withJSONObject: ["content": content]),
            as: ForumComment.self
        )
    }

    public func createPost(categoryID: Int64, title: String, content: String, tagIDs: [Int64] = []) async throws -> ForumPost {
        let titleLength = title.unicodeScalars.count
        let contentLength = content.unicodeScalars.count
        guard (2...100).contains(titleLength) else { throw ForumAPIError.invalidInput("标题长度需为 2–100 个字符。") }
        guard (1...20_000).contains(contentLength) else { throw ForumAPIError.invalidInput("正文长度需为 1–20,000 个字符。") }
        guard tagIDs.count <= 3 else { throw ForumAPIError.invalidInput("每篇帖子最多选择 3 个标签。") }
        return try await request(
            path: ["post", ""],
            method: "POST",
            body: JSONEncoder().encode(ForumPostInput(categoryId: categoryID, title: title, content: content, tagIds: tagIDs)),
            as: ForumPost.self
        )
    }

    /// Matches the official forum editor's PATCH contract.
    public func updatePost(id: Int64, categoryID: Int64, title: String, content: String, tagIDs: [Int64] = []) async throws -> ForumPost {
        guard id > 0, categoryID > 0 else { throw ForumAPIError.invalidInput("帖子或分类无效。") }
        guard (2...100).contains(title.unicodeScalars.count) else { throw ForumAPIError.invalidInput("标题长度需为 2–100 个字符。") }
        guard (1...20_000).contains(content.unicodeScalars.count) else { throw ForumAPIError.invalidInput("正文长度需为 1–20,000 个字符。") }
        guard tagIDs.count <= 3 else { throw ForumAPIError.invalidInput("每篇帖子最多选择 3 个标签。") }
        return try await request(path: ["post", String(id), ""], method: "PATCH",
            body: JSONEncoder().encode(ForumPostInput(categoryId: categoryID, title: title, content: content, tagIds: tagIDs)),
            as: ForumPost.self)
    }

    public func setFavorite(postID: Int64, isFavorite: Bool) async throws {
        _ = try await request(path: ["post", String(postID), "favorite"], method: isFavorite ? "PUT" : "DELETE", as: EmptyResponse.self)
    }

    private func paging(page: Int, pageSize: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(page + 1)), URLQueryItem(name: "page_size", value: String(pageSize))]
    }

    private func get<T: Decodable>(path: [String], query: [URLQueryItem] = []) async throws -> T {
        try await request(path: path, method: "GET", query: query, as: T.self)
    }

    @discardableResult
    private func request<T: Decodable>(
        path: [String],
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        as type: T.Type
    ) async throws -> T {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ForumAPIError.invalidURL
        }
        var basePath = components.percentEncodedPath
        if !basePath.hasSuffix("/") { basePath += "/" }
        let encodedPath = path.map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? $0
        }.joined(separator: "/")
        components.percentEncodedPath = basePath + encodedPath + (method == "GET" && path.last == "category" ? "/" : "")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ForumAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = NoveliaRequestTimeout.api
        let (data, response) = try await NoveliaSessionRenewal.data(session: session, request: request, app: "f", tokenProvider: tokenProvider)
        guard let http = response as? HTTPURLResponse else { throw ForumAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let jsonMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["message"] as? String ?? $0["msg"] as? String ?? $0["error"] as? String }
            let textMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverMessage = jsonMessage ?? textMessage.flatMap { $0.isEmpty ? nil : $0 }
            throw ForumAPIError.httpStatus(http.statusCode, serverMessage)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ForumAPIError.decoding(error.localizedDescription) }
    }
}

public enum ForumAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidInput(String)
    case httpStatus(Int, String?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "论坛 API 地址无效。"
        case .invalidResponse: return "论坛返回了无法识别的响应。"
        case let .invalidInput(message): return message
        case let .httpStatus(status, message):
            if let message, !message.isEmpty, message.count <= 300, !message.contains("<"), !message.contains(">") {
                return "论坛 API 错误（HTTP \(status)）：\(message)"
            }
            return "论坛 API 错误（HTTP \(status)）。"
        case let .decoding(message): return "无法解析论坛响应：\(message)"
        }
    }
}

public struct ForumPage<Item: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let total: Int64
    public let items: [Item]
}

public struct ForumTag: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let color: Int
    public let sortOrder: Int

    public init(id: Int64, name: String, color: Int = 0, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey { case id, name, color, sortOrder }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        color = try values.decodeIfPresent(Int.self, forKey: .color) ?? 0
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

public struct ForumCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let slug: String
    public let tags: [ForumTag]

    private enum CodingKeys: String, CodingKey { case id, slug, tags }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        slug = try values.decode(String.self, forKey: .slug)
        tags = try values.decodeIfPresent([ForumTag].self, forKey: .tags) ?? []
    }

    public var title: String {
        switch slug {
        case "novel": "小说讨论"
        case "announcements": "站务公告"
        case "guide": "使用指南"
        case "feedback": "意见反馈"
        default: slug
        }
    }
}

public struct ForumPost: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let categoryId: Int64
    public let title: String
    public let authorId: Int64
    public let authorUsername: String
    public let status: Int
    public let viewsCount: Int64
    public let commentsCount: Int64
    public let commentsLocked: Bool
    public let pinOrder: Int?
    public let favorited: Bool
    public let createdAt: String
    public let updatedAt: String
    public let activeAt: String
    public let tags: [ForumTag]
    public let content: String

    private enum CodingKeys: String, CodingKey {
        case id, categoryId, title, authorId, authorUsername, status, viewsCount, commentsCount
        case commentsLocked, pinOrder, favorited, createdAt, updatedAt, activeAt, tags, content
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        categoryId = try values.decode(Int64.self, forKey: .categoryId)
        title = try values.decode(String.self, forKey: .title)
        authorId = try values.decodeIfPresent(Int64.self, forKey: .authorId) ?? 0
        authorUsername = try values.decodeIfPresent(String.self, forKey: .authorUsername) ?? ""
        status = try values.decodeIfPresent(Int.self, forKey: .status) ?? 0
        viewsCount = try values.decodeIfPresent(Int64.self, forKey: .viewsCount) ?? 0
        commentsCount = try values.decodeIfPresent(Int64.self, forKey: .commentsCount) ?? 0
        commentsLocked = try values.decodeIfPresent(Bool.self, forKey: .commentsLocked) ?? false
        pinOrder = try values.decodeIfPresent(Int.self, forKey: .pinOrder)
        favorited = try values.decodeIfPresent(Bool.self, forKey: .favorited) ?? false
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        activeAt = try values.decodeIfPresent(String.self, forKey: .activeAt) ?? updatedAt
        tags = try values.decodeIfPresent([ForumTag].self, forKey: .tags) ?? []
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
    }
}

public struct ForumComment: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let postId: Int64
    public let rootId: Int64?
    public let content: String
    public let authorId: Int64
    public let authorUsername: String
    public let status: Int
    public let createdAt: String
    public let updatedAt: String
    public let replyCount: Int64?
    public let replies: ForumPage<ForumComment>?

    public var replyRootID: Int64 { rootId ?? id }

    private enum CodingKeys: String, CodingKey {
        case id, postId, rootId, content, authorId, authorUsername, status, createdAt, updatedAt, replyCount, replies
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        postId = try values.decodeIfPresent(Int64.self, forKey: .postId) ?? 0
        rootId = try values.decodeIfPresent(Int64.self, forKey: .rootId)
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
        authorId = try values.decodeIfPresent(Int64.self, forKey: .authorId) ?? 0
        authorUsername = try values.decodeIfPresent(String.self, forKey: .authorUsername) ?? ""
        status = try values.decodeIfPresent(Int.self, forKey: .status) ?? 0
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        replyCount = try values.decodeIfPresent(Int64.self, forKey: .replyCount)
        replies = try values.decodeIfPresent(ForumPage<ForumComment>.self, forKey: .replies)
    }
}

public struct ForumPostInput: Codable, Hashable, Sendable {
    public let categoryId: Int64
    public let title: String
    public let content: String
    public let tagIds: [Int64]

    public init(categoryId: Int64, title: String, content: String, tagIds: [Int64] = []) {
        self.categoryId = categoryId
        self.title = title
        self.content = content
        self.tagIds = tagIds
    }
}

public enum ForumSort: String, CaseIterable, Identifiable, Sendable {
    case active, newest, updated, views, comments
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .active: "最近活跃"
        case .newest: "最新发布"
        case .updated: "最新更新"
        case .views: "浏览最多"
        case .comments: "评论最多"
        }
    }
}

public enum ForumFeedSource: Equatable, Sendable {
    case all, favorites, myPosts
}

private struct EmptyResponse: Decodable {
    init() {}
}
