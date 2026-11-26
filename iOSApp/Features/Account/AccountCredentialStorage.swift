import Foundation
import Security
import WebKit

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

/// 刷新 Cookie 存储接口。生产在网页与 Keychain 之间衔接会话，独立验证使用内存实现。
@MainActor
protocol AuthRefreshCookieStore: AnyObject {
    func cookies(for url: URL) async -> [HTTPCookie]
    func websiteCookies(for url: URL) async -> [HTTPCookie]
    func save(_ cookies: [HTTPCookie], replacing previous: [HTTPCookie], for url: URL) async
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

    private let authentication: AuthenticationConfiguration

    init(authentication: AuthenticationConfiguration) {
        self.authentication = authentication
    }

    func cookies(for url: URL) async -> [HTTPCookie] {
        let now = Date()
        let stored = loadStoredCookies().compactMap { $0.toHTTPCookie() }
            .filter { $0.expiresDate.map { $0 > now } ?? true }
        let matched = Self.filter(stored, for: url)
        if !matched.isEmpty { return matched }
        // 兼容旧版只在 WebKit 持有刷新 Cookie 的会话。
        return await websiteCookies(for: url)
    }

    func websiteCookies(for url: URL) async -> [HTTPCookie] {
        let cookies = await allWebsiteCookies()
        return Self.filter(cookies.filter { $0.expiresDate.map { $0 > Date() } ?? true }, for: url)
    }

    private func allWebsiteCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    func save(_ cookies: [HTTPCookie], replacing previous: [HTTPCookie], for url: URL) async {
        let now = Date()
        let matched = Self.filter(cookies, for: url)
        guard !matched.isEmpty else { return }
        var merged = loadStoredCookies().compactMap { $0.toHTTPCookie() }
            .filter { $0.expiresDate.map { $0 > now } ?? true }
        for incoming in matched {
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
        // 只轮换网页里仍等于本次请求所用的 Cookie，保留请求期间新完成的网页登录。
        let website = WKWebsiteDataStore.default().httpCookieStore
        let existing = await websiteCookies(for: url)
        for cookie in matched {
            guard let used = previous.first(where: { Self.sameCookie($0, cookie) }),
                  let current = existing.first(where: { Self.sameCookie($0, cookie) }),
                  used.value == current.value,
                  cookie.value != current.value || cookie.expiresDate != current.expiresDate else { continue }
            await withCheckedContinuation { continuation in
                website.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    func clear() async {
        SecItemDelete(baseQuery as CFDictionary)
#if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: Self.simulatorFallbackKey)
#endif
        let website = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await allWebsiteCookies()
        for cookie in Self.filter(cookies, for: authentication.refreshURL(app: "n")) {
            await withCheckedContinuation { continuation in
                website.delete(cookie) { continuation.resume() }
            }
        }
    }

    private static func sameCookie(_ lhs: HTTPCookie, _ rhs: HTTPCookie) -> Bool {
        lhs.name == rhs.name && lhs.domain.lowercased() == rhs.domain.lowercased() && lhs.path == rhs.path
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

    func websiteCookies(for url: URL) async -> [HTTPCookie] {
        await cookies(for: url)
    }

    func save(_ cookies: [HTTPCookie], replacing previous: [HTTPCookie], for url: URL) async {
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
