import SwiftUI
import OSLog
import UIKit

@main
struct NoveliaApp: App {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.novelia.ios.port", category: "lifecycle")

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        logger.notice("Application launched, version \(version, privacy: .public) (\(build, privacy: .public))")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .textSelection(.enabled)
        }
    }
}

enum AppThemeColor: String, CaseIterable, Identifiable {
    case novelia
    case ocean
    case plum
    case rose
    case amber
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .novelia: "Novelia 绿"
        case .ocean: "海洋蓝"
        case .plum: "柔和紫"
        case .rose: "莓果红"
        case .amber: "琥珀棕"
        case .custom: "自定义"
        }
    }

    var color: Color {
        switch self {
        case .novelia: Color(red: 85 / 255, green: 151 / 255, blue: 117 / 255)
        case .ocean: Color(red: 48 / 255, green: 112 / 255, blue: 153 / 255)
        case .plum: Color(red: 112 / 255, green: 77 / 255, blue: 151 / 255)
        case .rose: Color(red: 176 / 255, green: 70 / 255, blue: 92 / 255)
        case .amber: Color(red: 145 / 255, green: 96 / 255, blue: 31 / 255)
        case .custom: AppThemeColor.novelia.color
        }
    }

    static func color(for rawValue: String, customHex: String) -> Color {
        guard let theme = AppThemeColor(rawValue: rawValue) else { return AppThemeColor.novelia.color }
        return theme == .custom ? color(fromHex: customHex) : theme.color
    }

    static func color(fromHex hex: String) -> Color {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else {
            return AppThemeColor.novelia.color
        }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    static func hex(from color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "559775"
        }
        return String(
            format: "%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

enum NoveliaStyle {
    static var brandGreen: Color { .accentColor }

    /// 主文字色（深色下近白）。
    static var ink: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.92, alpha: 1)
                : UIColor(red: 0.15, green: 0.17, blue: 0.20, alpha: 1)
        })
    }

    /// 次要文字色（深色下提亮）。
    static var muted: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.65, alpha: 1)
                : UIColor(red: 0.48, green: 0.49, blue: 0.52, alpha: 1)
        })
    }

    /// 页面底色（浅色=米色纸面，深色=近黑）。
    static var paper: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
                : UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        })
    }

    /// 卡片/列表行底色（浅色=白，深色=深灰）。
    static var card: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1)
                : UIColor.white
        })
    }

    static func accent(for value: NovelAccent) -> Color {
        switch value {
        case .plum: Color(red: 0.47, green: 0.35, blue: 0.58)
        case .ocean: Color(red: 0.27, green: 0.52, blue: 0.66)
        case .moss: Color(red: 0.36, green: 0.52, blue: 0.40)
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appThemeColor") private var appThemeColorRaw = AppThemeColor.novelia.rawValue
    @AppStorage("appThemeCustomHex") private var appThemeCustomHex = "559775"
    @Environment(\.openURL) private var openURL
    @AppStorage(NoveliaUpdateStore.enabledKey) private var checksUpdates = true
    @StateObject private var updates = NoveliaUpdateStore()
    @StateObject private var auth = AccountAuthStore()
    @StateObject private var forumAuth = ForumAuthStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var readingHistory = ReadingHistoryStore()
    @StateObject private var wenkuDownloads = WenkuLocalLibraryStore()
    @StateObject private var webNovelDownloads = WebNovelDownloadStore()
    @StateObject private var webDAVSync = WebDAVSyncStore()

    /// 调试/自动化入口：`-openEPUBPrototype` 启动参数直接打开排版原型。
    private var opensPrototypeDirectly: Bool {
        ProcessInfo.processInfo.arguments.contains("-openEPUBPrototype")
    }

    var body: some View {
        TabView {
            NavigationStack {
                ShelfView()
            }
            .tabItem { Label("书架", systemImage: "books.vertical.fill") }

            NavigationStack {
                DiscoverView()
            }
            .tabItem { Label("发现", systemImage: "sparkle.magnifyingglass") }

            NavigationStack {
                WenkuView()
            }
            .tabItem { Label("文库", systemImage: "books.vertical") }

            NavigationStack {
                ForumView()
            }
            .tabItem { Label("论坛", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(AppThemeColor.color(for: appThemeColorRaw, customHex: appThemeCustomHex))
        .background(NoveliaStyle.paper)
        .environmentObject(auth)
        .environmentObject(forumAuth)
        .environmentObject(favorites)
        .environmentObject(readingHistory)
        .environmentObject(wenkuDownloads)
        .environmentObject(webNovelDownloads)
        .environmentObject(webDAVSync)
        .task { await updates.check() }
        .onChange(of: checksUpdates) { _, enabled in
            if enabled { Task { await updates.check(force: true) } }
            else { updates.release = nil }
        }
        .alert("发现新版本", isPresented: Binding(
            get: { updates.release != nil },
            set: { if !$0 { updates.release = nil } }
        ), presenting: updates.release) { release in
            Button("跳转下载") { if let url = release.downloadPage { openURL(url) } }
            Button("取消", role: .cancel) { updates.release = nil }
            Button("忽略此版本") { updates.ignore(release) }
        } message: { release in
            Text("Novelia \(release.version?.display ?? release.tag_name) 已发布，是否前往下载页面？")
        }
        .task {
            auth.forumAuth = forumAuth
            forumAuth.accountAuth = auth
            await NoveliaSessionRenewal.shared.register(app: "n") { [weak auth] in
                guard let auth, await auth.refreshSession() else { return nil }
                return NoveliaSessionTokenVault.read()
            }
            await NoveliaSessionRenewal.shared.register(app: "f") { [weak forumAuth] in
                guard let forumAuth, await forumAuth.refreshSession() else { return nil }
                return await MainActor.run { NoveliaForumSessionTokenVault.read() }
            }
            await restoreSessions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await restoreSessions() } }
        }
        .sheet(isPresented: $auth.isLoginPresented) {
            NoveliaLoginSheet(auth: auth)
        }
        .fullScreenCover(isPresented: .constant(opensPrototypeDirectly)) {
            NavigationStack {
                PrototypeReaderHost(initialURL: nil)
            }
        }
    }

    private func restoreSessions() async {
        if auth.username != nil || forumAuth.username != nil {
            if auth.username == nil || forumAuth.username != auth.username {
                _ = await auth.establishUnifiedSession()
                return
            }
        }
        _ = await NoveliaSessionRenewal.shared.token(app: "n", current: NoveliaSessionTokenVault.read())
        _ = await NoveliaSessionRenewal.shared.token(app: "f", current: NoveliaForumSessionTokenVault.read())
    }

}

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

struct SyncedBlockedTag: Codable, Equatable {
    var blocked: Bool
    var updatedAt: Date
}

@MainActor
final class BlockedTagsStore: ObservableObject {
    static let shared = BlockedTagsStore()
    @Published private(set) var tags: [String]
    @Published private(set) var wenkuTags: [String: [String]]
    private let defaults: UserDefaults
    private(set) var syncStates: [String: SyncedBlockedTag]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        syncStates = defaults.data(forKey: "blockedNovelTags.sync.v1")
            .flatMap { try? JSONDecoder().decode([String: SyncedBlockedTag].self, from: $0) } ?? [:]
        for tag in defaults.stringArray(forKey: "blockedNovelTags") ?? [] where syncStates[tag] == nil {
            syncStates[tag] = SyncedBlockedTag(blocked: true, updatedAt: .distantPast)
        }
        tags = syncStates.filter { $0.value.blocked }.map(\.key).sorted()
        wenkuTags = defaults.dictionary(forKey: "knownWenkuTags") as? [String: [String]] ?? [:]
    }
    func contains(_ tag: String) -> Bool { tags.contains(tag.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func add(_ tag: String) {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !tags.contains(value) else { return }
        syncStates[value] = SyncedBlockedTag(blocked: true, updatedAt: Date()); persist()
    }
    func remove(_ tag: String) {
        syncStates[tag] = SyncedBlockedTag(blocked: false, updatedAt: Date()); persist()
    }
    static func merged(_ local: [String: SyncedBlockedTag], _ remote: [String: SyncedBlockedTag]) -> [String: SyncedBlockedTag] {
        var result = local
        for (tag, value) in remote where !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existing = result[tag] {
                if value.updatedAt > existing.updatedAt || (value.updatedAt == existing.updatedAt && !value.blocked) {
                    result[tag] = value
                }
            } else { result[tag] = value }
        }
        return result
    }
    func applySynced(_ remote: [String: SyncedBlockedTag]) {
        syncStates = Self.merged(syncStates, remote); persist()
    }
    private func persist() {
        tags = syncStates.filter { $0.value.blocked }.map(\.key).sorted()
        defaults.set(tags, forKey: "blockedNovelTags")
        if let data = try? JSONEncoder().encode(syncStates) { defaults.set(data, forKey: "blockedNovelTags.sync.v1") }
    }
    func hides(_ genres: [String]) -> Bool { genres.contains(where: contains) }
    func rememberWenku(id: String, tags: [String]) {
        guard wenkuTags[id] != tags else { return }
        wenkuTags[id] = tags; defaults.set(wenkuTags, forKey: "knownWenkuTags")
    }
}

struct BlockedTagsView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var newTag = ""
    var body: some View {
        Form {
            Section("添加屏蔽标签") {
                TextField("标签名称（精确匹配）", text: $newTag)
                Button("添加") { blocked.add(newTag); newTag = "" }
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("已屏蔽标签") {
                if blocked.tags.isEmpty { Text("暂无屏蔽标签").foregroundStyle(.secondary) }
                ForEach(blocked.tags, id: \.self) { tag in
                    HStack {
                        Text(tag); Spacer()
                        Button("解除屏蔽") { blocked.remove(tag) }.buttonStyle(.borderless)
                    }
                }
            }
            Section {
                Text("含任一屏蔽标签的作品会从发现、搜索和排行榜中隐藏；书架、收藏及下载不受影响。标签按完整名称匹配，设置保存在本机，也可通过手动 WebDAV 同步屏蔽和解除记录。文库列表不返回标签，只能过滤本机已查看过详情的作品。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("标签屏蔽")
    }
}
