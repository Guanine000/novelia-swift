import Combine
import Foundation
import Security
import SwiftUI
import UIKit
import WebKit

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
        let resolvedCookieStore = cookieStore ?? AuthRefreshCookieKeychainStore()
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

    /// 清除本应用令牌与本机保存的刷新 Cookie，不清空系统浏览器或网页存储中的其他会话。
    func logout() {
        clearSession()
        forumAuth?.clearSession()
        let store = cookieStore
        Task { await store.clear() }
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
    func establishUnifiedSession() async -> Bool {
        while isRefreshing || forumAuth?.isRefreshing == true {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return false }
        }
        guard !Task.isCancelled, await refreshSession(), let account = username else { return false }
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
        let resolvedCookieStore = cookieStore ?? AuthRefreshCookieKeychainStore()
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
        Task { await store.clear() }
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

    func establishUnifiedSession() async -> Bool {
        guard let accountAuth else { return false }
        let success = await accountAuth.establishUnifiedSession()
        if !success { errorMessage = accountAuth.errorMessage }
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

enum NoveliaForumSessionTokenVault {
    private static let service = "cc.novelia.ios.session"
    private static let account = "forum-access-token"
#if targetEnvironment(simulator)
    private static let simulatorFallbackKey = "novelia.forum-session-token.simulator"
#endif

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
#if targetEnvironment(simulator)
            return UserDefaults.standard.string(forKey: simulatorFallbackKey)
#else
            return nil
#endif
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
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

    static func clear() {
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
            await cookieStore.save(received, for: loginAPIURL)
        }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    func fetchToken() async throws -> String {
        let cookies = await cookieStore.cookies(for: refreshURL)
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
        let received = Self.responseCookies(from: http, for: refreshURL)
        if !received.isEmpty {
            await cookieStore.save(received, for: refreshURL)
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

struct NoveliaLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AccountAuthStore

    var body: some View {
        NoveliaNativeLoginForm(
            configuration: auth.configuration.authentication,
            isBusy: auth.isRefreshing,
            errorMessage: auth.errorMessage,
            existingAccountUsername: nil,
            onClearError: { auth.errorMessage = nil },
            onSyncExistingAccount: nil,
            onSubmit: { username, password in
                if await auth.login(username: username, password: password) {
                    dismiss()
                    return true
                }
                return false
            },
            onClose: { dismiss() }
        )
    }
}

struct ForumLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: ForumAuthStore

    var body: some View {
        NoveliaNativeLoginForm(
            configuration: auth.configuration.authentication,
            isBusy: auth.isRefreshing || auth.accountAuth?.isRefreshing == true,
            errorMessage: auth.errorMessage,
            existingAccountUsername: auth.accountAuth?.username,
            onClearError: { auth.errorMessage = nil },
            onSyncExistingAccount: {
                if await auth.establishUnifiedSession() {
                    dismiss()
                    return true
                }
                return false
            },
            onSubmit: { username, password in
                if await auth.login(username: username, password: password) {
                    dismiss()
                    return true
                }
                return false
            },
            onClose: { dismiss() }
        )
    }
}

private struct LoginCredentials: Equatable {
    var username = ""
    var password = ""
}

/// 原生账密登录表单；注册与找回密码通过外部浏览器打开已校验的官网链接，避免内置 Turnstile 网页桥接。
private struct NoveliaNativeLoginForm: View {
    @Environment(\.openURL) private var openURL
    let configuration: AuthenticationConfiguration
    let isBusy: Bool
    let errorMessage: String?
    let existingAccountUsername: String?
    let onClearError: () -> Void
    let onSyncExistingAccount: (() async -> Bool)?
    let onSubmit: (String, String) async -> Bool
    let onClose: () -> Void

    @State private var credentials = LoginCredentials()
    @State private var dismissKeyboardToken = 0

    private var canSubmit: Bool {
        !isBusy && !credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !credentials.password.isEmpty
    }

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登录 Novelia 账号")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(NoveliaStyle.ink)
                        Text("使用用户名或注册邮箱登录，将同时建立小说与社区会话。")
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.muted)
                    }

                    if let existingAccountUsername, let onSyncExistingAccount {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("当前已登录账号「\(existingAccountUsername)」，可直接同步社区会话，或在下方重新输入账号登录。")
                                .font(.footnote)
                                .foregroundStyle(NoveliaStyle.muted)
                            Button {
                                Task { _ = await onSyncExistingAccount() }
                            } label: {
                                HStack(spacing: 8) {
                                    if isBusy { ProgressView().controlSize(.small) }
                                    Text(isBusy ? "同步中…" : "使用当前账号同步社区会话")
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .tint(NoveliaStyle.brandGreen)
                            .disabled(isBusy)
                        }
                        .padding(14)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
                    }

                    LoginCredentialsCardView(
                        credentials: $credentials,
                        isEnabled: !isBusy,
                        dismissKeyboardToken: dismissKeyboardToken,
                        onSubmit: { submitIfReady() }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))

                    if let errorMessage, !errorMessage.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(NoveliaStyle.danger)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(NoveliaStyle.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        submitIfReady()
                    } label: {
                        HStack(spacing: 8) {
                            if isBusy {
                                ProgressView()
                                    .tint(.white)
                                    .controlSize(.small)
                            }
                            Text(isBusy ? "登录中…" : "登录")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(!canSubmit)

                    VStack(spacing: 8) {
                        Text("还没有账号，或忘记密码？")
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.muted)
                        Button {
                            openURL(configuration.loginURL(app: "n"))
                        } label: {
                            HStack(spacing: 4) {
                                Text("在浏览器中注册 / 找回密码")
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .font(.footnote.weight(.medium))
                        }
                        .tint(NoveliaStyle.brandGreen)
                        .disabled(isBusy)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("登录 Novelia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }
                        .disabled(isBusy)
                }
            }
        }
        .onAppear { onClearError() }
        .onDisappear { credentials.password = "" }
    }

    private func submitIfReady() {
        guard canSubmit else { return }
        let submitted = credentials
        dismissKeyboardToken &+= 1
        Task {
            if await onSubmit(submitted.username, submitted.password) {
                credentials.password = ""
            }
        }
    }
}

/// 监听所有 UIKit 写入路径（包括系统钥匙串静默设置 .text / insertText / replace）的输入框。
private final class AutoFillAwareTextField: UITextField {
    var onTextMutation: (() -> Void)?

    override var text: String? {
        didSet {
            if text != oldValue {
                onTextMutation?()
            }
        }
    }

    override func insertText(_ text: String) {
        super.insertText(text)
        onTextMutation?()
    }

    override func replace(_ range: UITextRange, withText text: String) {
        super.replace(range, withText: text)
        onTextMutation?()
    }
}

/// 单一 UIKit 凭据容器：用户名与密码框作为直接同级视图共处同一父视图，避免 SwiftUI 包装层与焦点回写打断 iCloud 钥匙串自动填充。
private final class LoginCredentialsContainerView: UIView {
    let usernameField = AutoFillAwareTextField(frame: .zero)
    let passwordField = AutoFillAwareTextField(frame: .zero)
    let visibilityButton = UIButton(type: .system)
    private var isPasswordVisible = false
    var onToggleVisibility: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear

        let mutedColor = UIColor(NoveliaStyle.muted)
        let hairlineColor = UIColor(NoveliaStyle.hairline)

        let userIcon = makeIconView(systemName: "person", tint: mutedColor)
        let lockIcon = makeIconView(systemName: "lock", tint: mutedColor)

        configureField(
            usernameField,
            placeholder: "用户名或邮箱",
            contentType: .username,
            isSecure: false,
            returnKeyType: .next
        )
        configureField(
            passwordField,
            placeholder: "密码",
            contentType: .password,
            isSecure: true,
            returnKeyType: .go
        )

        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.tintColor = mutedColor
        visibilityButton.addTarget(self, action: #selector(handleVisibilityTap), for: .touchUpInside)
        updateVisibilityButtonAppearance()

        let divider = UIView(frame: .zero)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = hairlineColor

        let usernameRow = UIView(frame: .zero)
        usernameRow.translatesAutoresizingMaskIntoConstraints = false
        usernameRow.addSubview(userIcon)

        let passwordRow = UIView(frame: .zero)
        passwordRow.translatesAutoresizingMaskIntoConstraints = false
        passwordRow.addSubview(lockIcon)
        passwordRow.addSubview(visibilityButton)

        addSubview(usernameRow)
        addSubview(divider)
        addSubview(passwordRow)
        addSubview(usernameField)
        addSubview(passwordField)

        NSLayoutConstraint.activate([
            usernameRow.topAnchor.constraint(equalTo: topAnchor),
            usernameRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            usernameRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            usernameRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            userIcon.leadingAnchor.constraint(equalTo: usernameRow.leadingAnchor, constant: 14),
            userIcon.centerYAnchor.constraint(equalTo: usernameRow.centerYAnchor),
            userIcon.widthAnchor.constraint(equalToConstant: 20),

            usernameField.leadingAnchor.constraint(equalTo: userIcon.trailingAnchor, constant: 10),
            usernameField.trailingAnchor.constraint(equalTo: usernameRow.trailingAnchor, constant: -14),
            usernameField.topAnchor.constraint(equalTo: usernameRow.topAnchor, constant: 12),
            usernameField.bottomAnchor.constraint(equalTo: usernameRow.bottomAnchor, constant: -12),

            divider.topAnchor.constraint(equalTo: usernameRow.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            passwordRow.topAnchor.constraint(equalTo: divider.bottomAnchor),
            passwordRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            passwordRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            passwordRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            passwordRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            lockIcon.leadingAnchor.constraint(equalTo: passwordRow.leadingAnchor, constant: 14),
            lockIcon.centerYAnchor.constraint(equalTo: passwordRow.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 20),

            passwordField.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 10),
            passwordField.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -6),
            passwordField.topAnchor.constraint(equalTo: passwordRow.topAnchor, constant: 12),
            passwordField.bottomAnchor.constraint(equalTo: passwordRow.bottomAnchor, constant: -12),

            visibilityButton.trailingAnchor.constraint(equalTo: passwordRow.trailingAnchor, constant: -10),
            visibilityButton.centerYAnchor.constraint(equalTo: passwordRow.centerYAnchor),
            visibilityButton.widthAnchor.constraint(equalToConstant: 32),
            visibilityButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func makeIconView(systemName: String, tint: UIColor) -> UIImageView {
        let imageView = UIImageView(image: UIImage(systemName: systemName))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = tint
        imageView.contentMode = .scaleAspectFit
        return imageView
    }

    private func configureField(
        _ field: AutoFillAwareTextField,
        placeholder: String,
        contentType: UITextContentType,
        isSecure: Bool,
        returnKeyType: UIReturnKeyType
    ) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = placeholder
        field.textContentType = contentType
        field.isSecureTextEntry = isSecure
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.keyboardType = .default
        field.returnKeyType = returnKeyType
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.clearButtonMode = .whileEditing
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @objc private func handleVisibilityTap() {
        isPasswordVisible.toggle()
        onToggleVisibility?()
        updateVisibilityButtonAppearance()
    }

    func applyPasswordVisibility() {
        let shouldBeSecure = !isPasswordVisible
        guard passwordField.isSecureTextEntry != shouldBeSecure else { return }
        let wasFirstResponder = passwordField.isFirstResponder
        let existing = passwordField.text
        passwordField.isSecureTextEntry = shouldBeSecure
        if wasFirstResponder, let existing {
            passwordField.text = nil
            passwordField.insertText(existing)
        }
    }

    private func updateVisibilityButtonAppearance() {
        let symbol = isPasswordVisible ? "eye.slash" : "eye"
        visibilityButton.setImage(UIImage(systemName: symbol), for: .normal)
        visibilityButton.accessibilityLabel = isPasswordVisible ? "隐藏密码" : "显示密码"
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : 320
        let fitted = systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: max(97, ceil(fitted.height)))
    }
}

private struct LoginCredentialsCardView: UIViewRepresentable {
    @Binding var credentials: LoginCredentials
    let isEnabled: Bool
    let dismissKeyboardToken: Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> LoginCredentialsContainerView {
        let container = LoginCredentialsContainerView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.container = container
        container.usernameField.text = credentials.username
        container.passwordField.text = credentials.password

        container.usernameField.delegate = coordinator
        container.passwordField.delegate = coordinator
        container.usernameField.addTarget(coordinator, action: #selector(Coordinator.fieldsDidChange), for: .editingChanged)
        container.passwordField.addTarget(coordinator, action: #selector(Coordinator.fieldsDidChange), for: .editingChanged)
        container.usernameField.onTextMutation = { [weak coordinator] in coordinator?.syncFromFields() }
        container.passwordField.onTextMutation = { [weak coordinator] in coordinator?.syncFromFields() }
        container.onToggleVisibility = { [weak coordinator, weak container] in
            guard let coordinator, let container else { return }
            coordinator.isApplyingFromSwiftUI = true
            container.applyPasswordVisibility()
            coordinator.isApplyingFromSwiftUI = false
            coordinator.syncFromFields()
        }

        coordinator.observeNotifications(for: container)
        return container
    }

    func updateUIView(_ uiView: LoginCredentialsContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.container = uiView

        // 只应用 SwiftUI 主动变更。系统填充尚未回传时，旧的绑定值仍是已知快照。
        if credentials != coordinator.lastPublishedCredentials {
            coordinator.lastPublishedCredentials = credentials
            coordinator.isApplyingFromSwiftUI = true
            uiView.usernameField.text = credentials.username
            uiView.passwordField.text = credentials.password
            coordinator.isApplyingFromSwiftUI = false
        }

        if uiView.usernameField.isEnabled != isEnabled {
            uiView.usernameField.isEnabled = isEnabled
        }
        if uiView.passwordField.isEnabled != isEnabled {
            uiView.passwordField.isEnabled = isEnabled
        }
        if uiView.visibilityButton.isEnabled != isEnabled {
            uiView.visibilityButton.isEnabled = isEnabled
        }

        // 不在常规 updateUIView 中强行修改第一响应者，仅在点击提交时收起键盘。
        if dismissKeyboardToken != coordinator.lastDismissKeyboardToken {
            coordinator.lastDismissKeyboardToken = dismissKeyboardToken
            uiView.endEditing(true)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LoginCredentialsCardView
        weak var container: LoginCredentialsContainerView?
        var isApplyingFromSwiftUI = false
        var lastPublishedCredentials: LoginCredentials
        private var isFieldSyncScheduled = false
        var lastDismissKeyboardToken = 0
        private var observers: [NSObjectProtocol] = []

        init(_ parent: LoginCredentialsCardView) {
            self.parent = parent
            self.lastPublishedCredentials = parent.credentials
            self.lastDismissKeyboardToken = parent.dismissKeyboardToken
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observeNotifications(for container: LoginCredentialsContainerView) {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: UITextField.textDidChangeNotification,
                    object: container.usernameField,
                    queue: .main
                ) { [weak self] _ in self?.syncFromFields() },
                center.addObserver(
                    forName: UITextField.textDidChangeNotification,
                    object: container.passwordField,
                    queue: .main
                ) { [weak self] _ in self?.syncFromFields() },
            ]
        }

        @objc func fieldsDidChange() {
            syncFromFields()
        }

        func syncFromFields() {
            guard !isApplyingFromSwiftUI, !isFieldSyncScheduled else { return }
            isFieldSyncScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFieldSyncScheduled = false
                self.publishCurrentFields()
            }
        }

        private func publishCurrentFields() {
            guard let container else { return }
            // 系统可能先后写入两个字段。读取当前表单一次，将整组凭据一起发布。
            let credentials = LoginCredentials(
                username: container.usernameField.text ?? "",
                password: container.passwordField.text ?? ""
            )
            guard credentials != lastPublishedCredentials else { return }
            lastPublishedCredentials = credentials
            parent.credentials = credentials
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            syncFromFields()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            syncFromFields()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            syncFromFields()
            if textField === container?.usernameField {
                container?.passwordField.becomeFirstResponder()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onSubmit()
                }
            }
            return false
        }
    }
}

/// 刷新 Cookie 存储接口：生产使用 Keychain（首次为空时兼容读取旧 WKHTTPCookieStore），测试与独立验证使用内存实现。
@MainActor
protocol AuthRefreshCookieStore: AnyObject {
    func cookies(for url: URL) async -> [HTTPCookie]
    func save(_ cookies: [HTTPCookie], for url: URL) async
    func clear() async
}

@MainActor
final class AuthRefreshCookieKeychainStore: AuthRefreshCookieStore {
    private static let service = "cc.novelia.ios.session"
    private static let account = "auth-refresh-cookies"
#if targetEnvironment(simulator)
    private static let simulatorFallbackKey = "novelia.auth-refresh-cookies.simulator"
#endif

    private struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresAt: TimeInterval?
        let isSecure: Bool
        let version: Int

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expiresAt = cookie.expiresDate?.timeIntervalSince1970
            isSecure = cookie.isSecure
            version = cookie.version
        }

        func toHTTPCookie() -> HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .version: version
            ]
            if let expiresAt {
                properties[.expires] = Date(timeIntervalSince1970: expiresAt)
            }
            if isSecure {
                properties[.secure] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
    }

    private let allowsLegacyWebKitMigration: Bool

    init(allowsLegacyWebKitMigration: Bool = true) {
        self.allowsLegacyWebKitMigration = allowsLegacyWebKitMigration
    }

    func cookies(for url: URL) async -> [HTTPCookie] {
        let now = Date()
        let stored = loadStoredCookies().compactMap { $0.toHTTPCookie() }
            .filter { $0.expiresDate.map { $0 > now } ?? true }
        let matched = Self.filter(stored, for: url)
        if !matched.isEmpty || !allowsLegacyWebKitMigration {
            return matched
        }
        // 兼容升级自旧版 WKWebView 登录的账号：Keychain 尚无刷新 Cookie 时回退读取一次网页存储。
        let legacy: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return Self.filter(legacy.filter { $0.expiresDate.map { $0 > now } ?? true }, for: url)
    }

    func save(_ cookies: [HTTPCookie], for url: URL) async {
        guard !cookies.isEmpty else { return }
        let now = Date()
        var merged = loadStoredCookies().compactMap { $0.toHTTPCookie() }
            .filter { $0.expiresDate.map { $0 > now } ?? true }
        for incoming in cookies {
            merged.removeAll { existing in
                existing.name == incoming.name
                    && existing.domain.lowercased() == incoming.domain.lowercased()
                    && existing.path == incoming.path
            }
            if incoming.expiresDate.map({ $0 > now }) ?? true {
                merged.append(incoming)
            }
        }
        persist(merged.map(StoredCookie.init))
    }

    func clear() async {
        SecItemDelete(baseQuery as CFDictionary)
#if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: Self.simulatorFallbackKey)
#endif
    }

    static func filter(_ cookies: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            let rawDomain = cookie.domain.lowercased()
            let domain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
            let domainMatches = host == domain || host.hasSuffix(".\(domain)")
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : "\(cookiePath)/")
            return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https")
        }
    }

    private func loadStoredCookies() -> [StoredCookie] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let data: Data?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let raw = result as? Data {
            data = raw
        } else {
#if targetEnvironment(simulator)
            data = UserDefaults.standard.data(forKey: Self.simulatorFallbackKey)
#else
            data = nil
#endif
        }
        guard let data else { return [] }
        return (try? JSONDecoder().decode([StoredCookie].self, from: data)) ?? []
    }

    private func persist(_ cookies: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
#if targetEnvironment(simulator)
            if addStatus == errSecMissingEntitlement || addStatus == errSecNotAvailable {
                UserDefaults.standard.set(data, forKey: Self.simulatorFallbackKey)
            }
#else
            _ = addStatus
#endif
        } else if status != errSecSuccess {
#if targetEnvironment(simulator)
            if status == errSecMissingEntitlement || status == errSecNotAvailable {
                UserDefaults.standard.set(data, forKey: Self.simulatorFallbackKey)
            }
#endif
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }
}

@MainActor
final class MemoryAuthRefreshCookieStore: AuthRefreshCookieStore {
    private var stored: [HTTPCookie] = []

    func cookies(for url: URL) async -> [HTTPCookie] {
        let now = Date()
        return AuthRefreshCookieKeychainStore.filter(
            stored.filter { $0.expiresDate.map { $0 > now } ?? true },
            for: url
        )
    }

    func save(_ cookies: [HTTPCookie], for url: URL) async {
        let now = Date()
        stored.removeAll { $0.expiresDate.map { $0 <= now } ?? false }
        for incoming in cookies {
            stored.removeAll { existing in
                existing.name == incoming.name
                    && existing.domain.lowercased() == incoming.domain.lowercased()
                    && existing.path == incoming.path
            }
            if incoming.expiresDate.map({ $0 > now }) ?? true {
                stored.append(incoming)
            }
        }
    }

    func clear() async {
        stored.removeAll()
    }
}

struct NovelKeychainTokenStore: SessionTokenStore {
    func read() -> String? { NoveliaSessionTokenVault.read() }
    func save(_ token: String) throws { try NoveliaSessionTokenVault.save(token) }
    func clear() { NoveliaSessionTokenVault.clear() }
}
struct ForumKeychainTokenStore: SessionTokenStore {
    func read() -> String? { NoveliaForumSessionTokenVault.read() }
    func save(_ token: String) throws { try NoveliaForumSessionTokenVault.save(token) }
    func clear() { NoveliaForumSessionTokenVault.clear() }
}
