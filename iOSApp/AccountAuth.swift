import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

@MainActor
final class AccountAuthStore: ObservableObject {
    @Published private(set) var username: String?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var isLoginPresented = false

    private let cookieStore = WKWebsiteDataStore.default().httpCookieStore
    private let siteOrigin = URL(string: "https://n.novelia.cc")!
    // The upstream client refreshes at auth.novelia.cc and reads that host's cookie.
    // Its Origin header remains the app origin (n.novelia.cc).
    private let refreshURL = URL(string: "https://auth.novelia.cc/api/v1/auth/refresh?app=n")!

    init() {
        let savedToken = NoveliaSessionTokenVault.read()
        username = Self.username(from: savedToken)
        if savedToken != nil && username == nil { NoveliaSessionTokenVault.clear() }
    }

    func refreshSession() async -> Bool {
        guard !isRefreshing else { return false }
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

            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.username(from: token) != nil else { throw AccountAuthError.invalidToken }
            try NoveliaSessionTokenVault.save(token)
            username = Self.username(from: token)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Mirrors the upstream client's local logout: clear this app token but retain the
    /// shared authentication website cookies, so another Novelia client session is unaffected.
    func logout() {
        NoveliaSessionTokenVault.clear()
        username = nil
        errorMessage = nil
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

    private static func username(from token: String?) -> String? {
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
        // JWT claims are used only for local display; authorization stays server-side.
        return subject
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
                    onLoginSuccess: {
                        Task {
                            if await auth.refreshSession() { dismiss() }
                        }
                    },
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
                            if await auth.refreshSession() { dismiss() }
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
    }
}

private struct NoveliaAuthWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let onLoginSuccess: () -> Void
    let onLoadFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginSuccess: onLoginSuccess, onLoadFailure: onLoadFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "noveliaAuth")
        // The upstream Android app enables third-party cookies for an auth iframe.
        // WKWebView has no equivalent switch, so load auth.novelia.cc as the top-level
        // page instead. Its postMessage to window.parent is then delivered to itself.
        let script = """
        window.addEventListener('message', function(event) {
          if (event.origin === 'https://auth.novelia.cc' && event.data && event.data.type === 'login_success') {
            window.webkit.messageHandlers.noveliaAuth.postMessage('login_success');
          }
        });
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
            URLQueryItem(name: "app", value: "n"),
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
            // Keep secure identity-provider redirects inside this same WKWebView so
            // they can complete the login flow and preserve its cookie session.
            guard url.scheme == "https" else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
