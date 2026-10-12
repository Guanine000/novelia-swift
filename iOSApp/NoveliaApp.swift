import SwiftUI
import OSLog
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

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
    @AppStorage(SettingsKey.appThemeColor) private var appThemeColorRaw = AppThemeColor.novelia.rawValue
    @AppStorage(SettingsKey.appThemeCustomHex) private var appThemeCustomHex = "559775"
    @Environment(\.openURL) private var openURL
    @AppStorage(NoveliaUpdateStore.enabledKey) private var checksUpdates = true
    @StateObject private var updates = NoveliaUpdateStore()
    @StateObject private var auth = AccountAuthStore()
    @StateObject private var forumAuth = ForumAuthStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var readingHistory = ReadingHistoryStore()
    @StateObject private var wenkuDownloads = WenkuLocalLibraryStore()
    @StateObject private var wenkuStore = WenkuStore()
    @StateObject private var webNovelDownloads = WebNovelDownloadStore()
    @StateObject private var webDAVSync = WebDAVSyncStore()

    /// 调试/自动化入口：Debug 构建中 `-openEPUBPrototype` 启动参数直接打开样例书。
    private var opensSampleReaderDirectly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-openEPUBPrototype")
        #else
        false
        #endif
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
        .environmentObject(wenkuStore)
        .environmentObject(webNovelDownloads)
        .environmentObject(webDAVSync)
        .task { await updates.check() }
        .task(id: auth.username) {
            await wenkuStore.refreshFavorites(account: auth.username)
        }
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
        .fullScreenCover(isPresented: .constant(opensSampleReaderDirectly)) {
            NavigationStack {
                EPUBReaderHost(initialURL: nil)
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
