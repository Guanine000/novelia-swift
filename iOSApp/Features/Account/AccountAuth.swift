import Foundation
import Combine

@MainActor
final class AccountAuthStore: ObservableObject, AccountSessionProviding {
    @Published private(set) var username: String?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var isLoginPresented = false

    weak var forumAuth: ForumAuthStore?
    private var sessionGeneration = 0
    nonisolated let tokenStore: any SessionTokenStore
    nonisolated var accessToken: String? { tokenStore.read() }
    let configuration: APIConfiguration
    // 上游客户端在 auth.novelia.cc 续期，并读取该主机的 Cookie。
    // Origin 请求头仍使用应用来源（n.novelia.cc）。
    private let refresher: AuthSessionRefresher
    private let cookieStore: any AuthRefreshCookieStore
    /// 与论坛会话共用：两者使用同一刷新 Cookie，续期必须逐个执行。
    let refreshQueue: SerialAsyncGate
    private var refreshTask: (generation: Int, task: Task<Bool, Never>)?

    init(configuration: APIConfiguration = .production, session: URLSession = .shared,
         tokenStore: any SessionTokenStore = NovelKeychainTokenStore(),
         refreshQueue: SerialAsyncGate = SerialAsyncGate(),
         cookieStore: (any AuthRefreshCookieStore)? = nil) {
        self.tokenStore = tokenStore
        self.configuration = configuration
        self.refreshQueue = refreshQueue
        let resolvedCookieStore = cookieStore ?? AuthRefreshCookieKeychainStore(authentication: configuration.authentication)
        self.cookieStore = resolvedCookieStore
        refresher = AuthSessionRefresher(configuration: configuration, session: session, app: "n",
                                         origin: configuration.novelOrigin, cookieStore: resolvedCookieStore)
        let savedToken = tokenStore.read()
        username = savedToken.flatMap { NoveliaSessionRenewal.claims($0)?.subject }
        if savedToken != nil && username == nil { tokenStore.clear() }
    }

    func matchesAccount(_ account: String) -> Bool {
        guard let token = tokenStore.read() else { return false }
        return NoveliaSessionRenewal.claims(token)?.subject == account
    }

    /// 续期进行中再被调用时等待同一结果，不另发请求；退出登录后发起的调用不复用旧结果。
    func refreshSession() async -> Bool {
        await refreshSession(usingWebsiteCookies: false)
    }

    private func refreshSession(usingWebsiteCookies: Bool) async -> Bool {
        let generation = sessionGeneration
        if let refreshTask, refreshTask.generation == generation { return await refreshTask.task.value }
        let task = Task {
            await refreshQueue.run {
                await performRefresh(generation: generation, usingWebsiteCookies: usingWebsiteCookies)
            }
        }
        refreshTask = (generation, task)
        isRefreshing = true
        errorMessage = nil
        let result = await task.value
        if refreshTask?.task == task {
            refreshTask = nil
            isRefreshing = false
        }
        return result
    }

    private func performRefresh(generation: Int, usingWebsiteCookies: Bool) async -> Bool {
        guard generation == sessionGeneration else { return false }
        let authLogger = ShareableLogger(category: "auth")
        do {
            let token = try await refresher.fetchToken(usingWebsiteCookies: usingWebsiteCookies)
            guard Self.username(from: token) != nil else { throw AccountAuthError.invalidToken }
            guard generation == sessionGeneration else { return false }
            try tokenStore.save(token)
            username = Self.username(from: token)
            authLogger.notice(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "succeeded"))
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            if case AccountAuthError.refreshRejected(let status) = error {
                if status == 401 {
                    tokenStore.clear()
                    username = nil
                    authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "unauthorized", status: status))
                    authLogger.notice(AppDiagnosticMessage.authSessionCleared(scope: "novel", reason: "unauthorized"))
                } else {
                    authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "failed", status: status))
                }
            } else {
                let nsError = error as NSError
                authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "failed", domain: nsError.domain, code: nsError.code))
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 清除本应用令牌及对应认证来源的会话 Cookie。
    func logout() {
        clearSession()
        forumAuth?.clearSession()
        let store = cookieStore
        Task { await refreshQueue.run { await store.clear() } }
    }

    func clearSession() {
        if username != nil {
            ShareableLogger(category: "auth").notice(AppDiagnosticMessage.authSessionCleared(scope: "novel", reason: "user"))
        }
        sessionGeneration += 1
        tokenStore.clear()
        username = nil
        errorMessage = nil
    }

    /// 原生账密登录：直连认证接口建立小说会话，随后复用同一刷新 Cookie 建立论坛会话。
    func login(username rawUsername: String, password: String) async -> Bool {
        let trimmed = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            errorMessage = "请填写用户名或邮箱和密码。"
            return false
        }
        let generation = sessionGeneration
        isRefreshing = true
        errorMessage = nil
        let novelSucceeded = await refreshQueue.run {
            await performLogin(username: trimmed, password: password, generation: generation)
        }
        isRefreshing = false
        guard novelSucceeded, generation == sessionGeneration, let account = username else {
            return false
        }
        guard let forumAuth else { return true }
        if forumAuth.username != account { forumAuth.clearSession() }
        guard await forumAuth.refreshSession(), forumAuth.username == account else {
            errorMessage = "账号已登录，论坛会话暂未建立，请重试完成登录。"
            return false
        }
        return true
    }

    private func performLogin(username rawUsername: String, password: String, generation: Int) async -> Bool {
        guard generation == sessionGeneration else { return false }
        let authLogger = ShareableLogger(category: "auth")
        do {
            let directToken = try await refresher.login(username: rawUsername, password: password)
            guard generation == sessionGeneration else { return false }
            let token: String
            if let directToken, Self.username(from: directToken) != nil {
                token = directToken
            } else {
                token = try await refresher.fetchToken()
            }
            guard let parsedUsername = Self.username(from: token) else { throw AccountAuthError.invalidToken }
            guard generation == sessionGeneration else { return false }
            try tokenStore.save(token)
            username = parsedUsername
            authLogger.notice(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "succeeded"))
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            if case AccountAuthError.loginRejected(let status, _) = error {
                authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "failed", status: status))
            } else if case AccountAuthError.refreshRejected(let status) = error {
                authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "failed", status: status))
            } else {
                let nsError = error as NSError
                authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "novel", outcome: "failed", domain: nsError.domain, code: nsError.code))
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 一次网站登录为同一账户建立两个 API 会话。
    func establishUnifiedSession(usingWebsiteCookies: Bool = false) async -> Bool {
        while isRefreshing || forumAuth?.isRefreshing == true {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return false }
        }
        guard !Task.isCancelled, await refreshSession(usingWebsiteCookies: usingWebsiteCookies), let account = username else { return false }
        guard let forumAuth else { return false }
        if forumAuth.username != account { forumAuth.clearSession() }
        guard await forumAuth.refreshSession(), forumAuth.username == account else {
            errorMessage = "账号已登录，论坛会话暂未建立，请重试完成登录。"
            return false
        }
        return true
    }

    static func username(from token: String?) -> String? {
        guard let token else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              let expiration = object["exp"] as? NSNumber,
              expiration.doubleValue > Date().timeIntervalSince1970 else { return nil }
        // JWT 声明仅用于本地显示；授权判断仍由服务器负责。
        return subject
    }
}

@MainActor
final class ForumAuthStore: ObservableObject, AccountSessionProviding {
    @Published private(set) var username: String?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var isLoginPresented = false

    weak var accountAuth: AccountAuthStore?
    private var sessionGeneration = 0
    nonisolated let tokenStore: any SessionTokenStore
    nonisolated var accessToken: String? { tokenStore.read() }
    let configuration: APIConfiguration
    private let refresher: AuthSessionRefresher
    private let cookieStore: any AuthRefreshCookieStore
    /// 与小说会话共用：两者使用同一刷新 Cookie，续期必须逐个执行。
    let refreshQueue: SerialAsyncGate
    private var refreshTask: (generation: Int, task: Task<Bool, Never>)?

    init(configuration: APIConfiguration = .production, session: URLSession = .shared,
         tokenStore: any SessionTokenStore = ForumKeychainTokenStore(),
         refreshQueue: SerialAsyncGate = SerialAsyncGate(),
         cookieStore: (any AuthRefreshCookieStore)? = nil) {
        self.tokenStore = tokenStore
        self.configuration = configuration
        self.refreshQueue = refreshQueue
        let resolvedCookieStore = cookieStore ?? AuthRefreshCookieKeychainStore(authentication: configuration.authentication)
        self.cookieStore = resolvedCookieStore
        refresher = AuthSessionRefresher(configuration: configuration, session: session, app: "f",
                                         origin: configuration.forumOrigin, cookieStore: resolvedCookieStore)
        let savedToken = tokenStore.read()
        username = savedToken.flatMap { NoveliaSessionRenewal.claims($0)?.subject }
        if savedToken != nil && username == nil { tokenStore.clear() }
    }

    func matchesAccount(_ account: String) -> Bool {
        guard let token = tokenStore.read() else { return false }
        return NoveliaSessionRenewal.claims(token)?.subject == account
    }

    /// 续期进行中再被调用时等待同一结果，不另发请求；退出登录后发起的调用不复用旧结果。
    func refreshSession() async -> Bool {
        let generation = sessionGeneration
        if let refreshTask, refreshTask.generation == generation { return await refreshTask.task.value }
        let task = Task { await refreshQueue.run { await performRefresh(generation: generation) } }
        refreshTask = (generation, task)
        isRefreshing = true
        errorMessage = nil
        let result = await task.value
        if refreshTask?.task == task {
            refreshTask = nil
            isRefreshing = false
        }
        return result
    }

    private func performRefresh(generation: Int) async -> Bool {
        guard generation == sessionGeneration else { return false }
        let authLogger = ShareableLogger(category: "auth")
        do {
            let token = try await refresher.fetchToken()
            guard let parsedUsername = AccountAuthStore.username(from: token) else { throw AccountAuthError.invalidToken }
            guard generation == sessionGeneration else { return false }
            if let expected = accountAuth?.username, parsedUsername != expected {
                throw AccountAuthError.invalidToken
            }
            try tokenStore.save(token)
            username = parsedUsername
            authLogger.notice(AppDiagnosticMessage.authSessionRefreshed(scope: "forum", outcome: "succeeded"))
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            if case AccountAuthError.refreshRejected(let status) = error {
                if status == 401 {
                    tokenStore.clear()
                    username = nil
                    authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "forum", outcome: "unauthorized", status: status))
                    authLogger.notice(AppDiagnosticMessage.authSessionCleared(scope: "forum", reason: "unauthorized"))
                } else {
                    authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "forum", outcome: "failed", status: status))
                }
            } else {
                let nsError = error as NSError
                authLogger.error(AppDiagnosticMessage.authSessionRefreshed(scope: "forum", outcome: "failed", domain: nsError.domain, code: nsError.code))
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func logout() {
        clearSession()
        accountAuth?.clearSession()
        let store = cookieStore
        Task { await refreshQueue.run { await store.clear() } }
    }

    func clearSession() {
        if username != nil {
            ShareableLogger(category: "auth").notice(AppDiagnosticMessage.authSessionCleared(scope: "forum", reason: "user"))
        }
        sessionGeneration += 1
        tokenStore.clear()
        username = nil
        errorMessage = nil
    }

    func establishUnifiedSession(usingWebsiteCookies: Bool = false) async -> Bool {
        guard let accountAuth else { return false }
        let success = await accountAuth.establishUnifiedSession(usingWebsiteCookies: usingWebsiteCookies)
        errorMessage = success ? nil : accountAuth.errorMessage
        return success
    }

    func login(username: String, password: String) async -> Bool {
        guard let accountAuth else { return false }
        let success = await accountAuth.login(username: username, password: password)
        if !success { errorMessage = accountAuth.errorMessage }
        else { errorMessage = nil }
        return success
    }
}

/// 小说（n）与论坛（f）共用的认证与续期传输：使用注入的刷新 Cookie 存储与认证站点通信，
/// 并关闭 URLSession 自动 Cookie 处理，避免系统共享存储里旧的刷新 Cookie 混入或被覆盖。
@MainActor
struct AuthSessionRefresher {
    let configuration: APIConfiguration
    let session: URLSession
    let app: String
    /// Origin 请求头使用应用来源（n.novelia.cc / forum.novelia.cc），请求发往认证主机。
    let origin: URL
    let cookieStore: any AuthRefreshCookieStore
    private var refreshURL: URL { configuration.authentication.refreshURL(app: app) }
    private var loginAPIURL: URL { configuration.authentication.loginAPIURL }

    func login(username: String, password: String) async throws -> String? {
        guard loginAPIURL.scheme == "https" else { throw AccountAuthError.invalidResponse }
        let payload: [String: String] = ["app": app, "username": username, "password": password]
        var request = URLRequest(url: loginAPIURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let reason = Self.extractPlainTextReason(data: data, response: http)
            throw AccountAuthError.loginRejected(status: http.statusCode,
                                                 message: Self.mapLoginError(status: http.statusCode, reason: reason))
        }
        let received = Self.responseCookies(from: http, for: loginAPIURL)
        if !received.isEmpty {
            await cookieStore.save(received, replacing: [], for: refreshURL)
        }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    func fetchToken(usingWebsiteCookies: Bool = false) async throws -> String {
        let cookies = if usingWebsiteCookies {
            await cookieStore.websiteCookies(for: refreshURL)
        } else {
            await cookieStore.cookies(for: refreshURL)
        }
        guard !cookies.isEmpty else { throw AccountAuthError.missingSiteSession }
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AccountAuthError.refreshRejected(http.statusCode) }
        // URLSession 与刷新 Cookie 存储相互独立；将轮换后的刷新 Cookie 持久化，供下次续期使用。
        let received = AuthRefreshCookieKeychainStore.filter(Self.responseCookies(from: http, for: refreshURL), for: refreshURL)
        if !received.isEmpty {
            await cookieStore.save(received, replacing: cookies, for: refreshURL)
        } else if usingWebsiteCookies {
            // 认证站点即使没有返回轮换值，随后建立的论坛会话也必须使用这次网页登录的 Cookie。
            await cookieStore.save(cookies, replacing: cookies, for: refreshURL)
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func responseCookies(from response: HTTPURLResponse, for url: URL) -> [HTTPCookie] {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key] = String(describing: pair.value) }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
    }


    /// 仅识别长度受限的 text/plain 业务原因；不回显 HTML 或过长的原始响应正文。
    static func extractPlainTextReason(data: Data, response: HTTPURLResponse) -> String? {
        guard [400, 401, 403, 404, 409, 422].contains(response.statusCode),
              data.count <= 1024 else { return nil }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("text/plain") else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func mapLoginError(status: Int, reason: String?) -> String {
        switch (status, reason) {
        case (401, "密码错误"):
            return "密码错误，请重新输入；忘记密码可在浏览器中找回。"
        case (403, "用户已被封禁"):
            return "账号已被封禁，无法登录。"
        case (404, "用户不存在"):
            return "账号不存在，请检查用户名或注册邮箱是否填写正确。"
        case (400, "未知的应用"), (422, "未知的应用"),
             (400, "无效的请求类型"), (422, "无效的请求类型"):
            return "应用版本与认证服务不兼容，请更新应用后重试。"
        case (400, "用户名长度必须至少为2个字符"), (422, "用户名长度必须至少为2个字符"),
             (400, "用户名长度不能超过16个字符"), (422, "用户名长度不能超过16个字符"):
            return "用户名应为 2–16 个字符。"
        case (400, "用户名前后不能有空格"), (422, "用户名前后不能有空格"):
            return "用户名前后不能有空格，请检查后重试。"
        case (400, "用户名只能包含可打印字符"), (422, "用户名只能包含可打印字符"):
            return "用户名包含不可见字符，请重新输入。"
        case (400, "密码长度必须至少为8个字符"), (422, "密码长度必须至少为8个字符"),
             (400, "密码长度不能超过100个字符"), (422, "密码长度不能超过100个字符"):
            return "密码应为 8–100 个字符。"
        case (400, "密码只能包含可打印字符"), (422, "密码只能包含可打印字符"):
            return "密码包含不可见字符，请重新输入。"
        case (400, "密码不能包含空格"), (422, "密码不能包含空格"):
            return "密码不能包含空格，请检查后重试。"
        case (401, _):
            return "登录未通过认证（HTTP 401），请核对账号和密码。"
        case (403, _):
            return "登录被拒绝（HTTP 403），请稍后重试。"
        case (404, _):
            return "认证请求返回 404，请核对账号或稍后重试。"
        case (429, _):
            return "操作过于频繁，请稍后再试。"
        case (500...599, _):
            return "认证服务暂时异常（HTTP \(status)），请稍后重试。"
        default:
            return "登录失败（HTTP \(status)），请检查填写的信息后重试。"
        }
    }
}

private enum AccountAuthError: LocalizedError {
    case invalidResponse
    case refreshRejected(Int)
    case loginRejected(status: Int, message: String)
    case invalidToken
    case missingSiteSession

    var errorDescription: String? {
        switch self {
        case .missingSiteSession: "认证站点没有可用会话，请重新登录。"
        case .invalidResponse: "认证服务返回了无法识别的响应。"
        case .refreshRejected(401): "登录状态已失效，请重新登录。"
        case let .refreshRejected(status): "认证令牌获取失败（HTTP \(status)）。"
        case let .loginRejected(_, message): message
        case .invalidToken: "认证服务没有返回有效的登录令牌。"
        }
    }
}
