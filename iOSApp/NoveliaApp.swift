import SwiftUI
import OSLog

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
                .tint(NoveliaStyle.brandGreen)
                .textSelection(.enabled)
        }
    }
}

enum NoveliaStyle {
    static let brandGreen = Color(red: 85 / 255, green: 151 / 255, blue: 117 / 255)

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
        .background(NoveliaStyle.paper)
        .environmentObject(auth)
        .environmentObject(forumAuth)
        .environmentObject(favorites)
        .environmentObject(readingHistory)
        .environmentObject(wenkuDownloads)
        .environmentObject(webNovelDownloads)
        .environmentObject(webDAVSync)
        .sheet(isPresented: $auth.isLoginPresented) {
            NoveliaLoginSheet(auth: auth)
        }
        .fullScreenCover(isPresented: .constant(opensPrototypeDirectly)) {
            NavigationStack {
                PrototypeReaderHost(initialURL: nil)
            }
        }
    }
}
