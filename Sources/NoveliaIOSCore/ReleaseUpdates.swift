import Combine
import Foundation

// GitHub release check offered at launch (see "我的 → 版本").

/// Stable release numbers only; prereleases are intentionally excluded.
struct NoveliaReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    var display: String { parts.map(String.init).joined(separator: ".") }
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

@MainActor
final class NoveliaUpdateStore: ObservableObject {
    static let enabledKey = "automaticallyCheckGitHubUpdates"
    static let ignoredKey = "ignoredGitHubReleaseVersion"
    @Published var release: NoveliaGitHubRelease?
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
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Guanine000/novelia-swift/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Novelia-iOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard defaults.bool(forKey: Self.enabledKey), let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return }
            let candidate = try JSONDecoder().decode(NoveliaGitHubRelease.self, from: data)
            if candidate.shouldOffer(current: currentVersion, ignored: defaults.string(forKey: Self.ignoredKey) ?? "") {
                release = candidate
            }
        } catch {
            // An unavailable update service must not interrupt reading or login.
        }
    }

    func ignore(_ candidate: NoveliaGitHubRelease) {
        defaults.set(candidate.version?.display, forKey: Self.ignoredKey)
        release = nil
    }
}
