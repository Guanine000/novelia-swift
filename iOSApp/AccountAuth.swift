import Combine
import Foundation
import Security
import SwiftUI
import UIKit
import WebKit

@MainActor
final class AccountAuthStore: ObservableObject {
    @Published private(set) var username: String?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var isLoginPresented = false

    weak var forumAuth: ForumAuthStore?
    private var sessionGeneration = 0
    private let cookieStore = WKWebsiteDataStore.default().httpCookieStore
    private let siteOrigin = URL(string: "https://n.novelia.cc")!
    // 上游客户端在 auth.novelia.cc 续期，并读取该主机的 Cookie。
    // Origin 请求头仍使用应用来源（n.novelia.cc）。
    private let refreshURL = URL(string: "https://auth.novelia.cc/api/v1/auth/refresh?app=n")!

    init() {
        let savedToken = NoveliaSessionTokenVault.read()
        username = savedToken.flatMap { NoveliaSessionRenewal.claims($0)?.subject }
        if savedToken != nil && username == nil { NoveliaSessionTokenVault.clear() }
    }

    func refreshSession() async -> Bool {
        guard !isRefreshing else { return false }
        let generation = sessionGeneration
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let cookies = await cookiesForSite()
            guard !cookies.isEmpty else {
                errorMessage = "认证站点没有可用会话。请先在上方登录页面登录，再点“完成登录”。"
                return false
            }

            var request = URLRequest(url: refreshURL)
            request.httpMethod = "POST"
            request.httpBody = Data()
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(siteOrigin.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AccountAuthError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AccountAuthError.refreshRejected(http.statusCode)
            }

            // URLSession 与 WKWebView 的 Cookie 存储相互独立。将轮换后的
            // 刷新 Cookie 写回认证网页视图，供下次续期使用。
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = String(describing: pair.value) }
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: refreshURL) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    cookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.username(from: token) != nil else { throw AccountAuthError.invalidToken }
            guard generation == sessionGeneration else { return false }
            try NoveliaSessionTokenVault.save(token)
            username = Self.username(from: token)
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            if case AccountAuthError.refreshRejected(401) = error {
                NoveliaSessionTokenVault.clear()
                username = nil
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 与上游客户端的本地退出行为一致：清除本应用令牌，但保留
    /// 共用认证网站的 Cookie，避免影响其他 Novelia 客户端会话。
    func logout() {
        clearSession()
        forumAuth?.clearSession()
    }

    func clearSession() {
        sessionGeneration += 1
        NoveliaSessionTokenVault.clear()
        username = nil
        errorMessage = nil
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

    private func cookiesForSite() async -> [HTTPCookie] {
        let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let host = refreshURL.host ?? "auth.novelia.cc"
        let path = refreshURL.path
        return allCookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let domainMatches = host == domain || host.hasSuffix(".\(domain)")
            let pathMatches = path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : "\(cookie.path)/")
            return domainMatches && pathMatches && (!cookie.isSecure || refreshURL.scheme == "https")
        }
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
final class ForumAuthStore: ObservableObject {
    @Published private(set) var username: String?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var isLoginPresented = false

    weak var accountAuth: AccountAuthStore?
    private var sessionGeneration = 0
    private let cookieStore = WKWebsiteDataStore.default().httpCookieStore
    private let siteOrigin = URL(string: "https://forum.novelia.cc")!
    private let refreshURL = URL(string: "https://auth.novelia.cc/api/v1/auth/refresh?app=f")!

    init() {
        let savedToken = NoveliaForumSessionTokenVault.read()
        username = savedToken.flatMap { NoveliaSessionRenewal.claims($0)?.subject }
        if savedToken != nil && username == nil { NoveliaForumSessionTokenVault.clear() }
    }

    func refreshSession() async -> Bool {
        guard !isRefreshing else { return false }
        let generation = sessionGeneration
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            let cookies = await cookiesForSite()
            guard !cookies.isEmpty else {
                errorMessage = "认证站点没有可用会话。请先在上方登录页面登录，再点“完成登录”。"
                return false
            }
            var request = URLRequest(url: refreshURL)
            request.httpMethod = "POST"
            request.httpBody = Data()
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(siteOrigin.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AccountAuthError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw AccountAuthError.refreshRejected(http.statusCode) }
            // URLSession 与 WKWebView 的 Cookie 存储相互独立。将轮换后的
            // 刷新 Cookie 写回认证网页视图，供下次续期使用。
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = String(describing: pair.value) }
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: refreshURL) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    cookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedUsername = AccountAuthStore.username(from: token) else { throw AccountAuthError.invalidToken }
            guard generation == sessionGeneration else { return false }
            if let expected = accountAuth?.username, parsedUsername != expected {
                throw AccountAuthError.invalidToken
            }
            try NoveliaForumSessionTokenVault.save(token)
            username = parsedUsername
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            if case AccountAuthError.refreshRejected(401) = error {
                NoveliaForumSessionTokenVault.clear()
                username = nil
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func logout() {
        clearSession()
        accountAuth?.clearSession()
    }

    func clearSession() {
        sessionGeneration += 1
        NoveliaForumSessionTokenVault.clear()
        username = nil
        errorMessage = nil
    }

    func establishUnifiedSession() async -> Bool {
        guard let accountAuth else { return false }
        let success = await accountAuth.establishUnifiedSession()
        if !success { errorMessage = accountAuth.errorMessage }
        return success
    }

    private func cookiesForSite() async -> [HTTPCookie] {
        let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let host = refreshURL.host ?? "auth.novelia.cc"
        let path = refreshURL.path
        return allCookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let domainMatches = host == domain || host.hasSuffix(".\(domain)")
            let pathMatches = path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : "\(cookie.path)/")
            return domainMatches && pathMatches && (!cookie.isSecure || refreshURL.scheme == "https")
        }
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

private enum AccountAuthError: LocalizedError {
    case invalidResponse
    case refreshRejected(Int)
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "认证服务返回了无法识别的响应。"
        case .refreshRejected(401): "登录状态已失效，请重新登录。"
        case let .refreshRejected(status): "认证令牌获取失败（HTTP \(status)）。"
        case .invalidToken: "认证服务没有返回有效的登录令牌。"
        }
    }
}

struct NoveliaLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AccountAuthStore
    @State private var webView: WKWebView?
    @State private var loginCompletionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在 Novelia 官方认证页面登录、注册或找回密码。账号密码由认证网站直接处理，不会交给本 App。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                NoveliaAuthWebView(
                    webView: $webView,
                    appID: "n",
                    onLoginSuccess: { completeLogin() },
                    onLoadFailure: { message in
                        auth.errorMessage = message
                    }
                )
            }
            .navigationTitle("登录 Novelia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(auth.isRefreshing ? "验证中…" : "完成登录") {
                        Task {
                            if await auth.establishUnifiedSession() { dismiss() }
                        }
                    }
                    .disabled(auth.isRefreshing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage = auth.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial)
                }
            }
        }
        .onDisappear { loginCompletionTask?.cancel() }
    }

    private func completeLogin() {
        guard loginCompletionTask == nil else { return }
        loginCompletionTask = Task { @MainActor in
            defer { loginCompletionTask = nil }
            do {
                // 等待 WebKit 更新响应 Cookie，再等待已有的
                // 续期任务完成，避免丢失本次登录成功信号。
                try await Task.sleep(nanoseconds: 150_000_000)
                while auth.isRefreshing {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                if await auth.establishUnifiedSession(), !Task.isCancelled { dismiss() }
            } catch { /* Closing the sheet cancels automatic completion. */ }
        }
    }

}

struct NoveliaAuthWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let appID: String
    let onLoginSuccess: () -> Void
    let onLoadFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginSuccess: onLoginSuccess, onLoadFailure: onLoadFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "noveliaAuth")
        // 上游 Android 应用为认证 iframe 启用第三方 Cookie。
        // WKWebView 没有对应开关，因此将 auth.novelia.cc 作为顶层
        // 页面加载。它发送给 window.parent 的 postMessage 此时会发送给自身。
        let script = """
        (() => {
          const notify = () => window.webkit.messageHandlers.noveliaAuth.postMessage('login_success');
          window.addEventListener('message', function(event) {
            if (event.origin === 'https://auth.novelia.cc' && event.data && event.data.type === 'login_success') {
              notify();
            }
          });
          // 官方顶层页面显示提示消息，而不发送 postMessage。
          // 仅观察身份提供方登录或注册成功的 POST 响应；
          // 不读取请求正文、响应正文、凭据或 Cookie 值。
          const originalFetch = window.fetch;
          window.fetch = async function(input, options) {
            const response = await originalFetch.apply(this, arguments);
            const url = new URL(input instanceof Request ? input.url : input, window.location.href);
            const method = String(options?.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
            if (window.location.origin === 'https://auth.novelia.cc' &&
                url.origin === window.location.origin && method === 'POST' && response.ok &&
                (url.pathname === '/api/v1/auth/login' || url.pathname === '/api/v1/auth/register')) {
              notify();
            }
            return response;
          };
        })();
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        context.coordinator.webView = view
        webView = view

        var components = URLComponents(string: "https://auth.novelia.cc/")!
        components.queryItems = [
            URLQueryItem(name: "app", value: appID),
            URLQueryItem(name: "theme", value: "system")
        ]
        view.load(URLRequest(url: components.url!))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onLoginSuccess = onLoginSuccess
        context.coordinator.onLoadFailure = onLoadFailure
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "noveliaAuth")
        uiView.navigationDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onLoginSuccess: () -> Void
        var onLoadFailure: (String) -> Void
        weak var webView: WKWebView?

        init(onLoginSuccess: @escaping () -> Void, onLoadFailure: @escaping (String) -> Void) {
            self.onLoginSuccess = onLoginSuccess
            self.onLoadFailure = onLoadFailure
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "noveliaAuth",
                  message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == "auth.novelia.cc",
                  message.body as? String == "login_success" else { return }
            DispatchQueue.main.async { self.onLoginSuccess() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        private func reportLoadFailure(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.onLoadFailure("认证页面加载失败：\(error.localizedDescription)（\(nsError.code)）")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // 将安全的身份提供方重定向保留在同一个 WKWebView 中，
            // 使其完成登录流程并保留 Cookie 会话。
            guard url.scheme == "https" else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

struct ForumLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: ForumAuthStore
    @State private var webView: WKWebView?
    @State private var loginCompletionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("使用同一个 Novelia 账号登录小说与论坛。账号密码由官方认证网站直接处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                NoveliaAuthWebView(webView: $webView, appID: "f", onLoginSuccess: {
                    completeLogin()
                }, onLoadFailure: { auth.errorMessage = $0 })
            }
            .navigationTitle("登录 Novelia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(auth.isRefreshing ? "验证中…" : "完成登录") {
                        Task { if await auth.establishUnifiedSession() { dismiss() } }
                    }
                    .disabled(auth.isRefreshing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage = auth.errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
                }
            }
        }
        .onDisappear { loginCompletionTask?.cancel() }
    }

    private func completeLogin() {
        guard loginCompletionTask == nil else { return }
        loginCompletionTask = Task { @MainActor in
            defer { loginCompletionTask = nil }
            do {
                // 等待 WebKit 更新响应 Cookie，再等待已有的
                // 续期任务完成，避免丢失本次登录成功信号。
                try await Task.sleep(nanoseconds: 150_000_000)
                while auth.isRefreshing {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                if await auth.establishUnifiedSession(), !Task.isCancelled { dismiss() }
            } catch { /* Closing the sheet cancels automatic completion. */ }
        }
    }

}
