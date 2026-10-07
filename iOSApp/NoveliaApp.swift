import SwiftUI

@main
struct NoveliaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(NoveliaStyle.coral)
        }
    }
}

enum NoveliaStyle {
    static let coral = Color(red: 0.91, green: 0.31, blue: 0.34)
    static let ink = Color(red: 0.15, green: 0.17, blue: 0.20)
    static let muted = Color(red: 0.48, green: 0.49, blue: 0.52)
    static let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
    static let card = Color.white

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
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var readingHistory = ReadingHistoryStore()

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
                SettingsView()
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .background(NoveliaStyle.paper)
        .environmentObject(auth)
        .environmentObject(favorites)
        .environmentObject(readingHistory)
        .sheet(isPresented: $auth.isLoginPresented) {
            NoveliaLoginSheet(auth: auth)
        }
    }
}
