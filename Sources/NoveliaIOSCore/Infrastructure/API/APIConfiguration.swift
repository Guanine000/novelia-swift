// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// App 组装时选择的 API、网页与认证地址；不从用户偏好中切换后台。
/// 链接识别与登录校验共用这些来源，替换时需保持地址、端口和认证配置一致。
public struct APIConfiguration: Sendable {
    public let novelAPI: URL
    public let forumAPI: URL
    public let bookCommentsOrigin: URL
    public let novelOrigin: URL
    public let forumOrigin: URL
    public let authentication: AuthenticationConfiguration
    public let legacyNovelHosts: Set<String>

    public init(novelAPI: URL, forumAPI: URL, bookCommentsOrigin: URL,
                novelOrigin: URL, forumOrigin: URL,
                authentication: AuthenticationConfiguration,
                legacyNovelHosts: Set<String> = []) {
        self.novelAPI = novelAPI
        self.forumAPI = forumAPI
        self.bookCommentsOrigin = bookCommentsOrigin
        self.novelOrigin = novelOrigin
        self.forumOrigin = forumOrigin
        self.authentication = authentication
        self.legacyNovelHosts = legacyNovelHosts
    }

    public static let production = APIConfiguration(
        novelAPI: URL(string: "https://n.novelia.cc/api/")!,
        forumAPI: URL(string: "https://forum.novelia.cc/api/v1/")!,
        bookCommentsOrigin: URL(string: "https://forum.novelia.cc/")!,
        novelOrigin: URL(string: "https://n.novelia.cc")!,
        forumOrigin: URL(string: "https://forum.novelia.cc")!,
        authentication: try! AuthenticationConfiguration(origin: URL(string: "https://auth.novelia.cc")!),
        legacyNovelHosts: ["novelia.cc", "www.novelia.cc", "books.fishhawk.top"]
    )

    public func forumURL(path: String, query: [URLQueryItem] = []) -> URL {
        var url = forumOrigin
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url!
    }

    func recognizesForumURL(_ url: URL, includeWWW: Bool = true) -> Bool {
        matches(url, origin: forumOrigin, aliases: includeWWW ? ["www." + (forumOrigin.host ?? "")] : [])
    }

    func recognizesNovelURL(_ url: URL) -> Bool {
        if matches(url, origin: novelOrigin) { return true }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return false }
        return parts.host.map { legacyNovelHosts.contains($0.lowercased()) } ?? false
    }

    private func matches(_ url: URL, origin: URL, aliases: Set<String> = []) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == origin.scheme, parts.user == nil, parts.password == nil,
              (parts.port ?? 443) == (origin.port ?? 443),
              let host = parts.host?.lowercased() else { return false }
        return host == origin.host?.lowercased() || aliases.contains(host)
    }
}

/// 登录桥接的可信来源与入口配置；构造时校验 HTTPS origin，网页与原生校验使用同一来源。
public struct AuthenticationConfiguration: Sendable {
    public let origin: URL
    public let refreshPath: String
    public let loginPath: String
    public let registerPath: String

    public init(origin: URL, refreshPath: String = "/api/v1/auth/refresh",
                loginPath: String = "/api/v1/auth/login",
                registerPath: String = "/api/v1/auth/register") throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConfigurationError.invalidAuthenticationOrigin
        }
        for path in [refreshPath, loginPath, registerPath] {
            guard path.hasPrefix("/"), !path.hasPrefix("//"),
                  !path.contains("?"), !path.contains("#"), !path.contains("\\") else {
                throw ConfigurationError.invalidAuthenticationPath
            }
        }
        var normalized = parts
        normalized.path = ""
        normalized.host = host.lowercased()
        if normalized.port == 443 { normalized.port = nil }
        self.origin = normalized.url!
        self.refreshPath = refreshPath
        self.loginPath = loginPath
        self.registerPath = registerPath
    }

    public func refreshURL(app: String) -> URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = refreshPath
        parts.queryItems = [URLQueryItem(name: "app", value: app)]
        return parts.url!
    }

    public func loginURL(app: String) -> URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/"
        parts.queryItems = [URLQueryItem(name: "app", value: app), URLQueryItem(name: "theme", value: "system")]
        return parts.url!
    }

    /// WebKit 可能用 0 表示默认 HTTPS 端口；比较来源时统一按 443 处理。
    public func trusts(scheme: String, host: String, port: Int) -> Bool {
        scheme == "https" && host.lowercased() == origin.host?.lowercased()
            && (port == 0 ? 443 : port) == (origin.port ?? 443)
    }

    /// 配置值先编码为 JSON 再传入桥接脚本，避免把地址字符串当成可执行 JavaScript。
    public var loginSuccessScript: String {
        func literal(_ value: String) -> String {
            let data = try! JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        }
        return """
        (() => {
          const trustedOrigin = \(literal(origin.absoluteString));
          const loginPath = \(literal(loginPath));
          const registerPath = \(literal(registerPath));
          const notify = () => window.webkit.messageHandlers.noveliaAuth.postMessage('login_success');
          window.addEventListener('message', function(event) {
            if (event.origin === trustedOrigin && event.data && event.data.type === 'login_success') {
              notify();
            }
          });
          const originalFetch = window.fetch;
          window.fetch = async function(input, options) {
            const response = await originalFetch.apply(this, arguments);
            const url = new URL(input instanceof Request ? input.url : input, window.location.href);
            const method = String(options?.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
            if (window.location.origin === trustedOrigin &&
                url.origin === window.location.origin && method === 'POST' && response.ok &&
                (url.pathname === loginPath || url.pathname === registerPath)) {
              notify();
            }
            return response;
          };
        })();
        """
    }

    public enum ConfigurationError: Error {
        case invalidAuthenticationOrigin
        case invalidAuthenticationPath
    }
}
