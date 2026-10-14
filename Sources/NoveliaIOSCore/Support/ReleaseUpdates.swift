import Combine
import Foundation

// GitHub release check offered at launch (see "我的 → 版本").

/// 发布标签与本机版本号。兼容常见写法：
/// - 前缀：`v`、`V`，以及由字母、`-`、`_` 组成的前缀（如 `release-`、`Novelia-v`）；
/// - 1–4 段数字，缺少的段按 0 比较（`0.20` 与 `0.20.0` 相同）；
/// - SemVer 预发布后缀 `-test.2`：低于同号正式版，按 SemVer 规则比较；
/// - 构建元数据 `+34`：不参与比较。
/// 数字段含非数字（如 `0.x.0`）或出现其他字符时无效。
struct NoveliaReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    /// 预发布标识，按 `.` 分段；正式版为空。
    let prerelease: [String]

    init?(_ text: String) {
        var value = Substring(text.trimmingCharacters(in: .whitespaces))
        guard let firstDigit = value.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        let prefix = value[..<firstDigit]
        guard prefix.count <= 24, prefix.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "-" || $0 == "_" }) else { return nil }
        value = value[firstDigit...]
        if let plus = value.firstIndex(of: "+") {
            let build = value[value.index(after: plus)...]
            guard Self.isValidIdentifierList(build) else { return nil }
            value = value[..<plus]
        }
        var pre: [String] = []
        if let dash = value.firstIndex(of: "-") {
            let tail = value[value.index(after: dash)...]
            guard Self.isValidIdentifierList(tail) else { return nil }
            pre = tail.split(separator: ".").map(String.init)
            value = value[..<dash]
        }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        parts = fields.map { Int($0)! }
        prerelease = pre
    }

    private static func isValidIdentifierList(_ text: Substring) -> Bool {
        let ids = text.split(separator: ".", omittingEmptySubsequences: false)
        return !ids.isEmpty && ids.allSatisfy { id in
            !id.isEmpty && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    /// 至少显示三段，如 `0.20.0`、`0.20.0-test.2`。可再次解析为相等的版本，用于保存“忽略此版本”。
    var display: String {
        let numbers = (parts + Array(repeating: 0, count: max(0, 3 - parts.count))).map(String.init).joined(separator: ".")
        return isPrerelease ? numbers + "-" + prerelease.joined(separator: ".") : numbers
    }

    private var paddedParts: [Int] { parts + Array(repeating: 0, count: 4 - parts.count) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.paddedParts == rhs.paddedParts && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.paddedParts != rhs.paddedParts { return lhs.paddedParts.lexicographicallyPrecedes(rhs.paddedParts) }
        // 同号时：有预发布标识的版本较低；都有时逐段比较（数字段按数值、数字段低于字母段，前缀相同时段少者较低）。
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, _): return false
        case (true, false): return true
        case (true, true):
            for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
                switch (Int(a), Int(b)) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a < b
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }
}

struct NoveliaGitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    var version: NoveliaReleaseVersion? { NoveliaReleaseVersion(tag_name) }
    var downloadPage: URL? {
        guard let url = URL(string: html_url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host == "github.com", c.user == nil, c.password == nil,
              c.port == nil, c.path.hasPrefix("/Guanine000/novelia-swift/releases/tag/") else { return nil }
        return url
    }
    func shouldOffer(current: String, ignored: String) -> Bool {
        guard !draft, !prerelease, downloadPage != nil, let version,
              let installed = NoveliaReleaseVersion(current), version > installed else { return false }
        return NoveliaReleaseVersion(ignored) != version
    }
}

/// 手动检查 App 更新的结果；有新版本时同时设置 `NoveliaUpdateStore.release`，由根视图弹出下载提示。
enum NoveliaManualUpdateResult: Equatable {
    case available
    case upToDate(current: String)
    case failed
    case rateLimited
}

private enum NoveliaUpdateError: Error { case rateLimited }

@MainActor
final class NoveliaUpdateStore: ObservableObject {
    static let enabledKey = "automaticallyCheckGitHubUpdates"
    static let ignoredKey = "ignoredGitHubReleaseVersion"
    @Published var release: NoveliaGitHubRelease?
    @Published private(set) var isCheckingManually = false
    private var checkedThisLaunch = false
    private var isChecking = false
    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersion: String

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
        defaults.register(defaults: [Self.enabledKey: true])
    }

    func check(force: Bool = false) async {
        guard defaults.bool(forKey: Self.enabledKey), !isChecking, force || !checkedThisLaunch else { return }
        checkedThisLaunch = true
        isChecking = true
        defer { isChecking = false }
        // 更新服务不可用时，不能中断阅读或登录。
        guard let candidate = try? await fetchLatest(), defaults.bool(forKey: Self.enabledKey) else { return }
        if candidate.shouldOffer(current: currentVersion, ignored: defaults.string(forKey: Self.ignoredKey) ?? "") {
            release = candidate
        }
    }

    /// “我的 → 版本 → 检查更新”：不受启动检查开关限制，也会再次提示之前忽略的版本。
    func checkManually() async -> NoveliaManualUpdateResult {
        guard !isCheckingManually else { return .failed }
        isCheckingManually = true
        defer { isCheckingManually = false }
        let candidate: NoveliaGitHubRelease
        do { candidate = try await fetchLatest() }
        catch NoveliaUpdateError.rateLimited { return .rateLimited }
        catch { return .failed }
        guard candidate.shouldOffer(current: currentVersion, ignored: "") else { return .upToDate(current: currentVersion) }
        release = candidate
        return .available
    }

    private func fetchLatest() async throws -> NoveliaGitHubRelease {
        do { return try await fetchAPIRelease() }
        catch {
            let primaryError = error
            // 匿名 API 按出口 IP 限流；正式版网页使用独立入口，跟随 latest 重定向取得同一发布标签。
            // 不解析网页正文，不使用镜像或携带账号令牌；备用入口失败时保留原错误以准确提示限流。
            do { return try await fetchReleasePage() }
            catch { throw primaryError }
        }
    }

    private func fetchAPIRelease() async throws -> NoveliaGitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Guanine000/novelia-swift/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Novelia-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if (http.statusCode == 403 || http.statusCode == 429),
           http.statusCode == 429 || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw NoveliaUpdateError.rateLimited
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let candidate = try JSONDecoder().decode(NoveliaGitHubRelease.self, from: data)
        guard !candidate.draft, !candidate.prerelease, candidate.downloadPage != nil,
              candidate.version != nil else { throw URLError(.cannotParseResponse) }
        return candidate
    }

    private func fetchReleasePage() async throws -> NoveliaGitHubRelease {
        var request = URLRequest(url: URL(string: "https://github.com/Guanine000/novelia-swift/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("Novelia-iOS", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url else {
            throw URLError(.badServerResponse)
        }
        let candidate = NoveliaGitHubRelease(tag_name: url.lastPathComponent, html_url: url.absoluteString,
                                            draft: false, prerelease: false)
        guard candidate.downloadPage != nil, let version = candidate.version, !version.isPrerelease else {
            throw URLError(.cannotParseResponse)
        }
        return candidate
    }

    func ignore(_ candidate: NoveliaGitHubRelease) {
        defaults.set(candidate.version?.display, forKey: Self.ignoredKey)
        release = nil
    }
}
