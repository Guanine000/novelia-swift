import SwiftUI
import OSLog
import UIKit

struct ShelfView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YOUR PERSONAL LIBRARY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(NoveliaStyle.coral)
                    Text("我的书架")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                Text("网页收藏与最近阅读，一眼接着看。")
                        .font(.system(size: 15))
                        .foregroundStyle(NoveliaStyle.muted)
                }

                readingHistorySection

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("已收藏")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        Spacer()
                        if auth.username != nil {
                            NavigationLink {
                                CloudFavoritesListView()
                            } label: {
                                HStack(spacing: 5) {
                                    Text("全部 \(favorites.novels.count)")
                                    Image(systemName: "chevron.right")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.coral)
                            }
                        }
                    }
                    if auth.username == nil {
                        ContentUnavailableView {
                            Label("登录后同步网页收藏", systemImage: "person.crop.circle.badge.checkmark")
                        } description: {
                            Text("此处会显示你在 Novelia 网页端收藏的作品。")
                        } actions: {
                            Button("登录 Novelia 账号") { auth.isLoginPresented = true }
                                .buttonStyle(.borderedProminent)
                                .tint(NoveliaStyle.coral)
                        }
                        .padding(.vertical, 22)
                    } else if favorites.isLoading && favorites.novels.isEmpty {
                        HStack { Spacer(); ProgressView("正在同步网页收藏…"); Spacer() }
                            .padding(.vertical, 28)
                    } else if favorites.novels.isEmpty {
                        ContentUnavailableView {
                            Label("网页收藏夹为空", systemImage: "heart")
                        } description: {
                            Text("在作品详情中收藏后，这里会与网页端保持同步。")
                        }
                        .padding(.vertical, 22)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(favorites.novels.prefix(5)) { novel in
                                    NavigationLink {
                                        NovelDetailView(novel: novel)
                                    } label: {
                                        ShelfNovelCard(novel: novel)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if let error = favorites.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                        Button("重新同步") { Task { await favorites.refresh(account: auth.username) } }
                            .tint(NoveliaStyle.coral)
                    } else if auth.username != nil {
                        Button("刷新网页收藏") { Task { await favorites.refresh(account: auth.username) } }
                            .font(.system(size: 13, weight: .medium))
                            .tint(NoveliaStyle.coral)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: auth.username) {
            await favorites.refresh(account: auth.username)
            await readingHistory.refresh(account: auth.username)
        }
    }

    @ViewBuilder
    private var readingHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近阅读")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
                if auth.username != nil {
                    NavigationLink {
                        CloudReadingHistoryListView()
                    } label: {
                        HStack(spacing: 5) {
                            Text("查看全部")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.coral)
                    }
                }
            }

            if auth.username == nil {
                ContentUnavailableView {
                    Label("登录后同步阅读历史", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("登录 Novelia 账号后，可继续阅读网页端最近读过的作品。")
                } actions: {
                    Button("登录 Novelia 账号") { auth.isLoginPresented = true }
                        .buttonStyle(.borderedProminent)
                        .tint(NoveliaStyle.coral)
                }
                .padding(.vertical, 12)
            } else if readingHistory.items.isEmpty && readingHistory.isLoading {
                HStack { Spacer(); ProgressView("正在获取网页阅读历史…"); Spacer() }
                    .padding(.vertical, 24)
            } else if readingHistory.items.isEmpty {
                ContentUnavailableView {
                    Label(readingHistory.errorMessage == nil ? "暂无网页阅读记录" : "无法获取网页阅读历史", systemImage: "clock")
                } description: {
                    Text(readingHistory.errorMessage ?? "网页端最近阅读过的作品会显示在这里。")
                } actions: {
                    Button("刷新阅读历史") { Task { await readingHistory.refresh(account: auth.username) } }
                        .buttonStyle(.bordered)
                        .tint(NoveliaStyle.coral)
                }
                .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(readingHistory.items.prefix(5)) { item in
                            NavigationLink {
                                NovelDetailView(novel: item.novel)
                            } label: {
                                ShelfNovelCard(
                                    novel: item.novel,
                                    caption: item.lastReadAt.flatMap { $0 > 0 ? Self.relativeDate($0) : nil }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let error = readingHistory.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button("重新同步") { Task { await readingHistory.refresh(account: auth.username) } }
                        .font(.system(size: 13, weight: .medium))
                        .tint(NoveliaStyle.coral)
                }
            }
        }
    }

    fileprivate static func relativeDate(_ timestamp: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return "最近阅读：" + formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(timestamp)), relativeTo: Date())
    }
}

private struct ShelfNovelCard: View {
    let novel: Novel
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BookCover(novel: novel, width: 126, height: 158)
            Text(novel.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(caption ?? novel.author)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NoveliaStyle.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 126, alignment: .topLeading)
        .padding(8)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct CloudReadingHistoryListView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if readingHistory.items.isEmpty && readingHistory.isLoading {
                    HStack { Spacer(); ProgressView("正在加载阅读历史…"); Spacer() }
                        .padding(.vertical, 28)
                } else if readingHistory.items.isEmpty {
                    ContentUnavailableView {
                        Label("暂无阅读历史", systemImage: "clock")
                    } description: {
                        Text(readingHistory.errorMessage ?? "网页端最近阅读过的作品会显示在这里。")
                    } actions: {
                        Button("重新加载") { Task { await readingHistory.refresh(account: auth.username) } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.coral)
                    }
                }

                ForEach(readingHistory.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        NavigationLink {
                            NovelDetailView(novel: item.novel)
                        } label: {
                            NovelRow(novel: item.novel)
                        }
                        .buttonStyle(.plain)
                        if let timestamp = item.lastReadAt, timestamp > 0 {
                            Text(ShelfView.relativeDate(timestamp))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(NoveliaStyle.muted)
                                .padding(.leading, 12)
                        }
                    }
                }

                if let error = readingHistory.errorMessage, !readingHistory.items.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button("重试加载") {
                        Task {
                            if readingHistory.canLoadMore {
                                await readingHistory.loadMore(account: auth.username, retry: true)
                            } else {
                                await readingHistory.refresh(account: auth.username)
                            }
                        }
                    }
                    .tint(NoveliaStyle.coral)
                } else if readingHistory.canLoadMore {
                    if readingHistory.isLoadingMore {
                        HStack { Spacer(); ProgressView("正在加载更多历史…"); Spacer() }
                            .padding(.vertical, 12)
                    }
                    Color.clear
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .id("history-page-\(readingHistory.items.count)")
                        .task(id: "\(auth.username ?? "")-\(readingHistory.items.count)-\(readingHistory.isLoading)-\(readingHistory.isLoadingMore)") {
                            await readingHistory.loadMore(account: auth.username)
                        }
                } else if !readingHistory.isLoading && !readingHistory.items.isEmpty {
                    Text("已加载全部阅读历史")
                        .font(.system(size: 12))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }

                Button("刷新阅读历史") { Task { await readingHistory.refresh(account: auth.username) } }
                    .font(.system(size: 13, weight: .medium))
                    .tint(NoveliaStyle.coral)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("最近阅读")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.username) { await readingHistory.refresh(account: auth.username) }
    }
}

private struct CloudFavoritesListView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if favorites.novels.isEmpty && favorites.isLoading {
                    HStack { Spacer(); ProgressView("正在同步网页收藏…"); Spacer() }
                        .padding(.vertical, 28)
                } else if favorites.novels.isEmpty {
                    ContentUnavailableView {
                        Label("网页收藏夹为空", systemImage: "heart")
                    } description: {
                        Text(favorites.errorMessage ?? "在作品详情中收藏后，这里会与网页端保持同步。")
                    } actions: {
                        Button("重新加载") { Task { await favorites.refresh(account: auth.username) } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.coral)
                    }
                }

                ForEach(favorites.novels) { novel in
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        NovelRow(novel: novel)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            guard let account = auth.username else { return }
                            Task {
                                do { try await favorites.remove(novel, account: account) }
                                catch { favorites.report(error) }
                            }
                        } label: {
                            Label("取消收藏", systemImage: "heart.slash")
                        }
                    }
                }

                if let error = favorites.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                Button("刷新网页收藏") { Task { await favorites.refresh(account: auth.username) } }
                    .font(.system(size: 13, weight: .medium))
                    .tint(NoveliaStyle.coral)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("网页收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.username) { await favorites.refresh(account: auth.username) }
    }
}

struct DiscoverView: View {
    @State private var query = ""
    @StateObject private var store = DiscoverStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FIND YOUR NEXT STORY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(NoveliaStyle.coral)
                    Text("发现好故事")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                }

                NavigationLink {
                    RankingView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(NoveliaStyle.coral, in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("小说排行榜")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.ink)
                            Text("查看 Novelia 站内热门作品")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    .padding(13)
                    .background(.white, in: RoundedRectangle(cornerRadius: 17))
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(NoveliaStyle.muted)
                    TextField("搜索书名、作者或题材", text: $query)
                        .font(.system(size: 15))
                        .autocorrectionDisabled()
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 15))

                HStack(alignment: .firstTextBaseline) {
                    Text(query.isEmpty ? "热门作品" : "搜索结果")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Spacer()
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Novelia 在线书源")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }

                if let errorMessage = store.errorMessage {
                    ContentUnavailableView {
                        Label("暂时无法连接", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await store.search(query: query) } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.coral)
                    }
                }

                ForEach(store.novels) { novel in
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        FeaturedNovelCard(novel: novel)
                    }
                    .buttonStyle(.plain)
                }
                if store.isLoadingMore {
                    ProgressView("正在加载更多作品…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else if let loadMoreError = store.loadMoreError {
                    VStack(spacing: 8) {
                        Text(loadMoreError)
                            .font(.system(size: 13))
                            .foregroundStyle(NoveliaStyle.muted)
                        Button("重试加载") {
                            Task { await store.loadMore() }
                        }
                        .buttonStyle(.bordered)
                        .tint(NoveliaStyle.coral)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else if store.hasMore, let lastNovel = store.novels.last {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await store.loadMore() }
                        }
                        .accessibilityHidden(true)
                        .id("search-page-trigger-\(lastNovel.id)")
                } else if !store.novels.isEmpty {
                    Text("已显示全部 \(store.novels.count) 部作品")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                if store.novels.isEmpty && store.errorMessage == nil && !store.isLoading {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) { await store.search(query: query) }
    }
}

private struct RankingView: View {
    @State private var page = 1
    @StateObject private var store = RankingStore()

    private var requestKey: String { String(page) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RANKING")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(NoveliaStyle.coral)
                    Text("小说排行榜")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                }

                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(NoveliaStyle.coral)
                    Text("Novelia 站内点击热度 · 一般向作品")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 17))

                if store.isLoading && store.novels.isEmpty {
                    HStack { Spacer(); ProgressView("正在加载排行榜…"); Spacer() }
                        .padding(.vertical, 24)
                }

                if let errorMessage = store.errorMessage {
                    ContentUnavailableView {
                        Label("排行榜加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await loadCurrentPage() } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.coral)
                    }
                }

                ForEach(Array(store.novels.enumerated()), id: \.element.id) { index, novel in
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", (page - 1) * 20 + index + 1))
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(index < 3 && page == 1 ? NoveliaStyle.coral : NoveliaStyle.muted)
                                .frame(width: 34)
                            FeaturedNovelCard(novel: novel)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if !store.novels.isEmpty && store.pageCount > 1 {
                    HStack {
                        Button("上一页") { page = max(1, page - 1) }
                            .disabled(page <= 1 || store.isLoading)
                        Spacer()
                        Text("第 \(page) / \(store.pageCount) 页")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                        Spacer()
                        Button("下一页") { page = min(store.pageCount, page + 1) }
                            .disabled(page >= store.pageCount || store.isLoading)
                    }
                    .buttonStyle(.bordered)
                    .tint(NoveliaStyle.coral)
                    .padding(.vertical, 8)
                } else if !store.novels.isEmpty {
                    Text("共 \(store.novels.count) 部上榜作品")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if !store.isLoading && store.errorMessage == nil {
                    ContentUnavailableView("暂无排行榜作品", systemImage: "chart.bar")
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("小说排行榜")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: requestKey) { await loadCurrentPage() }
    }

    private func loadCurrentPage() async {
        await store.load(page: page)
    }
}

private struct TagSearchResultsView: View {
    let tag: String
    @StateObject private var store = DiscoverStore()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("按标签筛选")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.coral)
                    Text(tag)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                    Text("精确匹配包含此标签的作品")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

                if store.isLoading && store.novels.isEmpty {
                    HStack { Spacer(); ProgressView("正在搜索标签…"); Spacer() }
                        .padding(.vertical, 28)
                }

                if let errorMessage = store.errorMessage {
                    ContentUnavailableView {
                        Label("标签搜索失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            Task { await store.search(query: tag, exactTag: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(NoveliaStyle.coral)
                    }
                }

                ForEach(store.novels) { novel in
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        FeaturedNovelCard(novel: novel)
                    }
                    .buttonStyle(.plain)
                }

                if store.isLoadingMore {
                    ProgressView("正在加载更多作品…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else if let loadMoreError = store.loadMoreError {
                    VStack(spacing: 8) {
                        Text(loadMoreError)
                            .font(.system(size: 13))
                            .foregroundStyle(NoveliaStyle.muted)
                        Button("重试加载") { Task { await store.loadMore() } }
                            .buttonStyle(.bordered)
                            .tint(NoveliaStyle.coral)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else if store.hasMore, let lastNovel = store.novels.last {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { Task { await store.loadMore() } }
                        .accessibilityHidden(true)
                        .id("tag-search-page-\(lastNovel.id)")
                } else if !store.novels.isEmpty {
                    Text("已显示全部 \(store.novels.count) 部作品")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if !store.isLoading && store.errorMessage == nil {
                    ContentUnavailableView.search(text: tag)
                        .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("标签搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.search(query: tag, exactTag: true) }
    }
}

struct NovelDetailView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var webNovelDownloads: WebNovelDownloadStore
    let novel: Novel
    @State private var displayNovel: Novel
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var cloudLastReadChapterID: String?
    @State private var cloudFolders: [NoveliaCloudFolder] = []
    @State private var showCloudFavoriteOptions = false
    @State private var favoriteError: String?
    @State private var showFavoriteError = false
    @State private var isLoadingFavoriteFolders = false
    @State private var downloadRequest: Novel?
    @AppStorage private var savedChapterIndex: Int

    init(novel: Novel) {
        self.novel = novel
        _displayNovel = State(initialValue: novel)
        _savedChapterIndex = AppStorage(wrappedValue: 0, "progress.\(novel.id)")
    }

    private var continueChapterIndex: Int {
        if let cloudLastReadChapterID,
           let cloudIndex = displayNovel.chapters.firstIndex(where: { $0.id == cloudLastReadChapterID }) {
            return cloudIndex
        }
        return min(savedChapterIndex, max(0, displayNovel.chapters.count - 1))
    }

    private var availableTranslationSources: [NovelTranslationSource] {
        guard let counts = displayNovel.translationChapterCounts else { return [] }
        return NovelTranslationSource.allCases.filter { (counts[$0] ?? 0) > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(LinearGradient(
                            colors: [NoveliaStyle.accent(for: displayNovel.accent), NoveliaStyle.ink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 190, height: 190)
                        .offset(x: 205, y: -72)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(displayNovel.genres.joined(separator: " · "))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(displayNovel.title)
                            .font(.system(size: 29, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        HStack(spacing: 8) {
                            Text("著 · \(displayNovel.author)")
                            if let totalCharacters = displayNovel.totalCharacters, totalCharacters > 0 {
                                Text("· \(totalCharacters.formatted()) 字")
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(22)
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 9) {
                    Text("作品简介")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(displayNovel.summary)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(NoveliaStyle.muted)
                }

                if let translationCounts = displayNovel.translationChapterCounts {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("译源进度")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                            ForEach(NovelTranslationSource.allCases) { source in
                                VStack(spacing: 5) {
                                    Text(source.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(NoveliaStyle.ink)
                                    Text("\(translationCounts[source] ?? 0) / \(displayNovel.chapters.count) 章")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 13))
                            }
                        }
                        Text("阅读时可在右上角设置中切换译源。")
                            .font(.system(size: 12))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }

                if !displayNovel.genres.isEmpty {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("标签 · 点击搜索")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)],
                            alignment: .leading,
                            spacing: 9
                        ) {
                            ForEach(displayNovel.genres, id: \.self) { tag in
                                NavigationLink {
                                    TagSearchResultsView(tag: tag)
                                } label: {
                                    Text(tag)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(NoveliaStyle.accent(for: displayNovel.accent))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(.white, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !displayNovel.chapters.isEmpty {
                    NavigationLink {
                        ReaderView(novel: displayNovel, startingAt: continueChapterIndex)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "book.fill")
                                .font(.system(size: 17, weight: .semibold))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("继续阅读")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text(displayNovel.chapters[continueChapterIndex].title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .opacity(0.85)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .background(NoveliaStyle.coral, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }

                if displayNovel.isRemote && !displayNovel.chapters.isEmpty {
                    let progress = webNovelDownloads.progress[displayNovel.id]
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            downloadRequest = displayNovel
                        } label: {
                            HStack(spacing: 10) {
                                if progress != nil {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: webNovelDownloads.isDownloaded(displayNovel.id) ? "arrow.clockwise" : "arrow.down.to.line")
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(progress == nil
                                         ? (webNovelDownloads.isDownloaded(displayNovel.id) ? "重新下载全书" : "选择译源并下载")
                                         : "正在下载 \(progress!.completed) / \(progress!.total) 章")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                    Text("下载后可在“我的 → 我的下载”离线阅读")
                                        .font(.system(size: 12, weight: .medium)).opacity(0.82)
                                }
                                Spacer()
                                if let progress {
                                    ProgressView(value: progress.fraction).tint(.white).frame(width: 48)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(NoveliaStyle.accent(for: displayNovel.accent), in: RoundedRectangle(cornerRadius: 15))
                        }
                        .buttonStyle(.plain)
                        .disabled(progress != nil)
                        if let error = webNovelDownloads.errors[displayNovel.id] {
                            Text("下载失败：\(error)")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                }

                if displayNovel.isRemote,
                   let providerId = displayNovel.providerId,
                   let novelId = displayNovel.novelId {
                    NavigationLink {
                        NovelCommentsView(title: displayNovel.title, subjectKey: "web-\(providerId)-\(novelId)")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 17, weight: .semibold))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("评论区")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text("查看或参与 Novelia 网页端讨论")
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(0.82)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(NoveliaStyle.ink)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("章节目录")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(displayNovel.chapters.count) 章")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                }

                if isLoadingDetail {
                    HStack { Spacer(); ProgressView("加载作品信息…"); Spacer() }
                        .padding(.vertical, 16)
                } else if let detailError {
                    ContentUnavailableView {
                        Label("作品信息加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(detailError)
                    } actions: {
                        Button("重试") { Task { await loadDetail() } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.coral)
                    }
                } else if displayNovel.chapters.isEmpty {
                    Text("没有可阅读的章节。")
                        .font(.system(size: 14))
                        .foregroundStyle(NoveliaStyle.muted)
                        .padding(.vertical, 12)
                }

                ForEach(Array(displayNovel.chapters.enumerated()), id: \.element.id) { index, chapter in
                    NavigationLink {
                        ReaderView(novel: displayNovel, startingAt: index)
                    } label: {
                        HStack(spacing: 13) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.coral)
                                .frame(width: 35, height: 35)
                                .background(NoveliaStyle.coral.opacity(0.09), in: Circle())
                            Text(chapter.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(NoveliaStyle.muted.opacity(0.6))
                        }
                        .padding(13)
                        .background(.white, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(novel.id)|\(auth.username ?? "")") { await loadDetail() }
        .sheet(item: $downloadRequest) { requestedNovel in
            WebNovelDownloadSheet(novel: requestedNovel, availableSources: availableTranslationSources)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favoriteTapped()
                } label: {
                    Image(systemName: isCloudFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(NoveliaStyle.coral)
                }
                .accessibilityLabel(isCloudFavorite ? "取消网页收藏" : "收藏到网页端")
                .disabled(isLoadingDetail || isLoadingFavoriteFolders)
            }
        }
        .confirmationDialog("收藏到网页端", isPresented: $showCloudFavoriteOptions, titleVisibility: .visible) {
            ForEach(cloudFolders) { folder in
                Button(folder.title) {
                    guard let account = auth.username else { return }
                    Task {
                        do {
                            try await favorites.add(displayNovel, to: folder, account: account)
                            displayNovel = displayNovel.settingCloudFavoriteFolder(folder.id)
                        }
                        catch { presentFavoriteError(error) }
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择 Novelia 网页端的收藏夹。")
        }
        .alert("网页收藏同步失败", isPresented: $showFavoriteError) {
            Button("好", role: .cancel) {}
            if auth.username == nil {
                Button("登录") { auth.isLoginPresented = true }
            }
        } message: {
            Text(favoriteError ?? "请稍后重试。")
        }
    }

    @MainActor
    private func loadDetail() async {
        guard novel.isRemote, let providerId = novel.providerId, let novelId = novel.novelId else { return }
        let account = auth.username
        let token = NoveliaSessionTokenVault.read()
        let api = NoveliaAPIClient(tokenProvider: { token })
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }
        do {
            let detail = try await api.novelForContinuation(providerId: providerId, novelId: novelId)
            guard !Task.isCancelled, auth.username == account else { return }
            displayNovel = detail.novel
            cloudLastReadChapterID = detail.lastReadChapterID
            favorites.updateStatus(from: detail.novel, account: account)
        } catch {
            guard !Task.isCancelled else { return }
            detailError = error.localizedDescription
        }
    }

    private var isCloudFavorite: Bool {
        favorites.contains(displayNovel) || favorites.folderID(for: displayNovel) != nil
    }

    private func favoriteTapped() {
        guard let account = auth.username else {
            auth.isLoginPresented = true
            return
        }
        if isCloudFavorite {
            Task {
                do {
                    try await favorites.remove(displayNovel, account: account)
                    displayNovel = displayNovel.settingCloudFavoriteFolder(nil)
                }
                catch { presentFavoriteError(error) }
            }
            return
        }
        isLoadingFavoriteFolders = true
        Task {
            defer { isLoadingFavoriteFolders = false }
            do {
                cloudFolders = try await favorites.folders(account: account)
                guard auth.username == account else { return }
                if cloudFolders.isEmpty {
                    throw NoveliaFavoritesUIError.noFolders
                }
                showCloudFavoriteOptions = true
            } catch {
                presentFavoriteError(error)
            }
        }
    }

    private func presentFavoriteError(_ error: Error) {
        favoriteError = error.localizedDescription
        showFavoriteError = true
    }
}

private struct WebNovelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: WebNovelDownloadStore
    let novel: Novel
    let availableSources: [NovelTranslationSource]

    @State private var selectedSourceRaw: String
    @State private var isDownloading = false
    @State private var didFinish = false

    init(novel: Novel, availableSources: [NovelTranslationSource]) {
        self.novel = novel
        self.availableSources = availableSources
        let preferredSource = UserDefaults.standard.string(forKey: "readerTranslationSource")
        let initialSource = preferredSource.flatMap { value in
            availableSources.first(where: { $0.rawValue == value })?.rawValue
        } ?? availableSources.first?.rawValue ?? "original"
        _selectedSourceRaw = State(initialValue: initialSource)
    }

    private var selectedSource: NovelTranslationSource? {
        NovelTranslationSource(rawValue: selectedSourceRaw)
    }

    private var progress: WebNovelDownloadProgress? { downloads.progress[novel.id] }

    var body: some View {
        NavigationStack {
            Form {
                Section("下载内容") {
                    Text(novel.title).font(.headline)
                    Text("共 \(novel.chapters.count) 章，下载完成后可离线阅读。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("翻译源") {
                    Picker("内容", selection: $selectedSourceRaw) {
                        Text("原文").tag("original")
                        ForEach(availableSources) { source in
                            let count = novel.translationChapterCounts?[source] ?? 0
                            Text("\(source.title)（\(count) 章）").tag(source.rawValue)
                        }
                    }
                    Text("下载后会保存所选译源的内容。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let progress {
                    Section("下载进度") {
                        ProgressView(value: progress.fraction)
                        Text("已下载 \(progress.completed) / \(progress.total) 章")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = downloads.errors[novel.id] {
                    Section { Text("下载失败：\(error)").font(.footnote).foregroundStyle(.red) }
                }
                if didFinish {
                    Section { Label("下载完成，可在“我的下载”中阅读", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Section {
                    Button {
                        isDownloading = true
                        Task {
                            await downloads.download(novel, translationSource: selectedSource)
                            isDownloading = false
                            didFinish = downloads.isDownloaded(novel.id) && downloads.errors[novel.id] == nil
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isDownloading { ProgressView() } else { Text("开始下载") }
                            Spacer()
                        }
                    }
                    .disabled(isDownloading || progress != nil || novel.chapters.isEmpty)
                }
            }
            .navigationTitle("下载全书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
        }
    }
}

struct NovelCommentsView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    let title: String
    let subjectKey: String

    @State private var commentPage: NoveliaCommentPage?
    @State private var page = 1
    @State private var draft = ""
    @State private var replyRoot: NoveliaComment?
    @State private var extraReplies: [Int: NoveliaCommentPage] = [:]
    @State private var loadingReplyIDs: Set<Int> = []
    @State private var isLoading = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sendError: String?

    private let pageSize = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                    Text("与 Novelia 网页端实时同步")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                }

                if auth.username != nil {
                    composer
                } else {
                    Button {
                        auth.isLoginPresented = true
                    } label: {
                        Label("登录后发表评论", systemImage: "person.crop.circle.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(NoveliaStyle.coral, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("评论")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    if let commentPage {
                        Text("共 \(commentPage.total) 条")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }

                if isLoading && commentPage == nil {
                    HStack { Spacer(); ProgressView("加载评论…"); Spacer() }
                        .padding(.vertical, 25)
                } else if let errorMessage, commentPage == nil {
                    ContentUnavailableView {
                        Label("评论加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await loadComments() } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.coral)
                    }
                } else if let commentPage, commentPage.items.isEmpty {
                    ContentUnavailableView("还没有评论", systemImage: "text.bubble", description: Text("来发表第一条评论吧。"))
                } else if let commentPage {
                    ForEach(commentPage.items) { comment in
                        commentThread(comment)
                    }

                    if commentPage.total > pageSize {
                        HStack {
                            Button("上一页") { Task { await loadComments(page: page - 1) } }
                                .disabled(page <= 1 || isLoading)
                            Spacer()
                            Text("第 \(page) / \(max(1, Int(ceil(Double(commentPage.total) / Double(pageSize)))) ) 页")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NoveliaStyle.muted)
                            Spacer()
                            Button("下一页") { Task { await loadComments(page: page + 1) } }
                                .disabled(page >= Int(ceil(Double(commentPage.total) / Double(pageSize))) || isLoading)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .tint(NoveliaStyle.coral)
                        .padding(.top, 5)
                    }
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("评论区")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: subjectKey) { await loadComments() }
        .alert("操作未完成", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("好", role: .cancel) { sendError = nil }
            if auth.username == nil { Button("登录") { auth.isLoginPresented = true } }
        } message: {
            Text(sendError ?? "请稍后重试。")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let replyRoot {
                HStack {
                    Text("回复 @\(replyRoot.authorUsername)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.coral)
                    Spacer()
                    Button("取消回复") { self.replyRoot = nil }
                        .font(.system(size: 12, weight: .medium))
                }
            }
            TextEditor(text: $draft)
                .frame(minHeight: 86)
                .padding(7)
                .scrollContentBackground(.hidden)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(replyRoot == nil ? "写下你的评论…" : "写下你的回复…")
                            .font(.system(size: 14))
                            .foregroundStyle(NoveliaStyle.muted.opacity(0.7))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 15)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("以 \(auth.username ?? "") 的身份评论")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted)
                Spacer()
                Button {
                    Task { await sendComment() }
                } label: {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Label("发送", systemImage: "paperplane.fill")
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(NoveliaStyle.coral, in: Capsule())
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }

    private func commentThread(_ comment: NoveliaComment) -> some View {
        let initialReplies = comment.replies?.items ?? []
        let appendedReplies = extraReplies[comment.id]?.items ?? []
        let visibleReplies = initialReplies + appendedReplies
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(comment.authorUsername)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(NoveliaStyle.ink)
                Spacer()
                Text(formattedDate(comment.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted)
            }
            Text(comment.content)
                .font(.system(size: 14))
                .foregroundStyle(NoveliaStyle.ink)
                .lineSpacing(4)
                .textSelection(.enabled)

            if auth.username != nil {
                Button {
                    replyRoot = comment
                } label: {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NoveliaStyle.coral)
            }

            if !visibleReplies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleReplies) { reply in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(NoveliaStyle.coral.opacity(0.35))
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(reply.authorUsername)
                                        .font(.system(size: 11, weight: .bold))
                                    Spacer()
                                    Text(formattedDate(reply.createdAt))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                                Text(reply.content)
                                    .font(.system(size: 12))
                                    .lineSpacing(3)
                            }
                        }
                        .foregroundStyle(NoveliaStyle.ink)
                    }
                }
                .padding(.leading, 4)
            }
            if comment.replyCount > visibleReplies.count {
                Button {
                    Task { await loadMoreReplies(for: comment, loadedCount: visibleReplies.count) }
                } label: {
                    if loadingReplyIDs.contains(comment.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("加载更多回复（剩余 \(comment.replyCount - visibleReplies.count) 条）")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(NoveliaStyle.coral)
                .disabled(loadingReplyIDs.contains(comment.id))
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 15))
    }

    @MainActor
    private func loadComments(page requestedPage: Int? = nil) async {
        let targetPage = requestedPage ?? page
        guard targetPage > 0 else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let token = NoveliaSessionTokenVault.read()
            let api = NoveliaAPIClient(tokenProvider: { token })
            let result = try await api.novelComments(subjectKey: subjectKey, page: targetPage, pageSize: pageSize)
            commentPage = result
            page = targetPage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func sendComment() async {
        guard auth.username != nil else {
            auth.isLoginPresented = true
            return
        }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let token = NoveliaSessionTokenVault.read()
            let api = NoveliaAPIClient(tokenProvider: { token })
            try await api.postNovelComment(subjectKey: subjectKey, content: content, rootID: replyRoot?.id)
            draft = ""
            replyRoot = nil
            await loadComments(page: 1)
        } catch {
            sendError = error.localizedDescription
        }
    }

    @MainActor
    private func loadMoreReplies(for comment: NoveliaComment, loadedCount: Int) async {
        guard loadingReplyIDs.insert(comment.id).inserted else { return }
        defer { loadingReplyIDs.remove(comment.id) }
        do {
            let token = NoveliaSessionTokenVault.read()
            let api = NoveliaAPIClient(tokenProvider: { token })
            let nextPage = loadedCount / 20 + 1
            let result = try await api.novelCommentReplies(
                subjectKey: subjectKey,
                rootID: comment.id,
                page: nextPage,
                pageSize: 20
            )
            var existing = extraReplies[comment.id] ?? NoveliaCommentPage(total: result.total, items: [])
            let existingIDs = Set(existing.items.map(\.id))
            existing = NoveliaCommentPage(
                total: result.total,
                items: existing.items + result.items.filter { !existingIDs.contains($0.id) }
            )
            extraReplies[comment.id] = existing
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .numeric, time: .shortened)
    }
}

private enum NoveliaFavoritesUIError: LocalizedError {
    case noFolders

    var errorDescription: String? { "网页账号下没有可用的收藏夹，请先在 Novelia 网页端创建收藏夹。" }
}

private struct ContinueReadingCard: View {
    let novel: Novel
    @AppStorage private var savedChapterIndex: Int

    init(novel: Novel) {
        self.novel = novel
        _savedChapterIndex = AppStorage(wrappedValue: 0, "progress.\(novel.id)")
    }

    var body: some View {
        HStack(spacing: 16) {
            BookCover(novel: novel, width: 82, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                Text("接着上次")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(NoveliaStyle.coral)
                Text(novel.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                Text(novel.chapters[min(savedChapterIndex, novel.chapters.count - 1)].title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(NoveliaStyle.muted)
                HStack(spacing: 6) {
                    Text("继续阅读")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NoveliaStyle.coral)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 21))
        .overlay(alignment: .trailing) {
            Image(systemName: "sparkle")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(NoveliaStyle.coral.opacity(0.7))
                .padding(15)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct FeaturedNovelCard: View {
    let novel: Novel

    var body: some View {
        HStack(spacing: 15) {
            BookCover(novel: novel, width: 82, height: 112)
            VStack(alignment: .leading, spacing: 7) {
                Text(novel.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                Text(novel.author)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted)
                Text(novel.summary)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .lineSpacing(3)
                    .foregroundStyle(NoveliaStyle.muted)
                Text(novel.genres.joined(separator: "  ·  "))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.accent(for: novel.accent))
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(.white, in: RoundedRectangle(cornerRadius: 19))
    }
}

private struct NovelRow: View {
    let novel: Novel

    var body: some View {
        HStack(spacing: 13) {
            BookCover(novel: novel, width: 61, height: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(novel.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                Text(novel.author)
                    .font(.system(size: 12))
                    .foregroundStyle(NoveliaStyle.muted)
                Text("\(novel.chapters.count) 章  ·  \(novel.genres.first ?? "小说")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.5))
        }
        .padding(11)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
    }
}

struct BookCover: View {
    let novel: Novel
    var width: CGFloat = 74
    var height: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [NoveliaStyle.accent(for: novel.accent), NoveliaStyle.ink.opacity(0.95)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: width * 0.8)
                .offset(x: width * 0.42, y: -height * 0.48)
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: novel.accent == .ocean ? "water.waves" : "moon.stars.fill")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
                Text(novel.title)
                    .font(.system(size: max(9, width * 0.16), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
            }
            .padding(width * 0.12)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("\(novel.title) 封面")
    }
}

enum MyDownloadsTab: String, CaseIterable, Identifiable {
    case network, wenku
    var id: String { rawValue }
    var title: String { self == .network ? "网络小说" : "文库" }
}

struct MyDownloadsView: View {
    @EnvironmentObject private var webNovelDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @State private var selectedTab: MyDownloadsTab

    init(initialTab: MyDownloadsTab = .network) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("下载内容", selection: $selectedTab) {
                ForEach(MyDownloadsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Group {
                switch selectedTab {
                case .network: networkDownloads
                case .wenku: wenkuDownloadsList
                }
            }
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("我的下载")
        .navigationBarTitleDisplayMode(.inline)
        .task { await wenkuDownloads.refreshMissingMetadata() }
    }

    private var networkDownloads: some View {
        Group {
            if webNovelDownloads.books.isEmpty {
                ContentUnavailableView {
                    Label("暂无网络小说下载", systemImage: "arrow.down.book")
                } description: {
                    Text("打开网络小说详情，选择“下载全书”后即可在这里离线阅读。")
                }
            } else {
                List {
                    ForEach(webNovelDownloads.books) { book in
                        NavigationLink {
                            DownloadedWebNovelReader(book: book)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(book.novel.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(NoveliaStyle.ink)
                                    .lineLimit(2)
                                Text(book.novel.author)
                                    .font(.system(size: 12))
                                    .foregroundStyle(NoveliaStyle.muted)
                                    .lineLimit(1)
                                if let source = book.translationSource {
                                    Text("译源：\(source.title)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(NoveliaStyle.muted)
                                } else {
                                    Text("原文")
                                        .font(.system(size: 11))
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                                Text("\(book.novel.chapters.count) 章 · \(book.downloadedAt.formatted(date: .numeric, time: .omitted))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                            .padding(.vertical, 5)
                        }
                        .listRowBackground(Color.white)
                        .swipeActions {
                            Button(role: .destructive) {
                                webNovelDownloads.remove(book)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var wenkuDownloadsList: some View {
        Group {
            if wenkuDownloads.books.isEmpty {
                ContentUnavailableView {
                    Label("暂无文库下载", systemImage: "book.closed")
                } description: {
                    Text("在文库作品详情下载 EPUB 后，可从这里导出到“文件”或其他阅读 App。")
                }
            } else {
                List {
                    ForEach(wenkuDownloads.books) { book in
                        ShareLink(item: wenkuDownloads.fileURL(for: book)) {
                            HStack(spacing: 12) {
                                if let coverURL = wenkuDownloads.coverURL(for: book),
                                   let image = UIImage(contentsOfFile: coverURL.path) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 52, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                } else {
                                    Image(systemName: "book.closed.fill")
                                        .font(.title2).foregroundStyle(NoveliaStyle.coral)
                                        .frame(width: 52, height: 72)
                                        .background(NoveliaStyle.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                    if let author = book.author, !author.isEmpty {
                                        Text(author).font(.system(size: 11)).foregroundStyle(NoveliaStyle.muted).lineLimit(1)
                                    }
                                    if let description = book.bookDescription, !description.isEmpty {
                                        Text(description).font(.system(size: 11)).foregroundStyle(NoveliaStyle.muted).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "square.and.arrow.up").foregroundStyle(NoveliaStyle.coral)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.white)
                        .swipeActions {
                            ShareLink(item: wenkuDownloads.fileURL(for: book)) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                            Button(role: .destructive) { wenkuDownloads.remove(book) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct DownloadedWebNovelReader: View {
    @EnvironmentObject private var downloads: WebNovelDownloadStore
    let book: DownloadedWebNovel
    @State private var chapters: [String: NovelChapter]?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let chapters {
                ReaderView(
                    novel: book.novel,
                    startingAt: 0,
                    offlineChapters: chapters,
                    offlineTranslationSource: book.translationSource
                )
            } else if let errorMessage {
                ContentUnavailableView("无法打开下载内容", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("正在打开下载内容…")
            }
        }
        .task {
            guard chapters == nil, errorMessage == nil else { return }
            do { chapters = try await downloads.chapters(for: book) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @AppStorage("readerFontSize") private var fontSize = 20.0
    @AppStorage("readerMode") private var modeRaw = ReaderMode.bilingual.rawValue
    @State private var isExportingLogs = false
    @State private var isShowingLogShare = false
    @State private var logFileURL: URL?
    @State private var logExportError: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var selectedMode: ReaderMode {
        ReaderMode(rawValue: modeRaw) ?? .bilingual
    }

    var body: some View {
        Form {
            Section("Novelia 账号") {
                if let username = auth.username {
                    LabeledContent("已登录", value: username)
                    Button("退出登录", role: .destructive) { auth.logout() }
                } else {
                    Text("登录后可使用需要账号的服务。密码由 Novelia 认证网页处理，App 只保存会话令牌。")
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                    Button {
                        auth.errorMessage = nil
                        auth.isLoginPresented = true
                    } label: {
                        Label("登录 / 注册", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .tint(NoveliaStyle.coral)
                }
            }
            Section("阅读体验") {
                Picker("显示语言", selection: $modeRaw) {
                    ForEach(ReaderMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("正文字号")
                        Spacer()
                        Text("\(Int(fontSize)) pt")
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    Slider(value: $fontSize, in: 16...30, step: 1)
                        .tint(NoveliaStyle.coral)
                }
            }
            Section("下载") {
                NavigationLink {
                    MyDownloadsView()
                } label: {
                    Label("我的下载", systemImage: "arrow.down.circle")
                }
            }
            Section("版本") {
                LabeledContent("当前版本", value: appVersion)
                LabeledContent("平台", value: "iOS 17+")
            }
            Section("诊断") {
                Button {
                    exportLogs()
                } label: {
                    if isExportingLogs {
                        Label("正在准备日志…", systemImage: "hourglass")
                    } else {
                        Label("导出应用日志", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExportingLogs)
                Text("导出最近 7 天本应用可读取的日志，可保存到“文件”或分享给支持人员。")
                    .font(.system(size: 13))
                    .foregroundStyle(NoveliaStyle.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NoveliaStyle.paper)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingLogShare) {
            if let logFileURL {
                LogActivitySheet(activityItems: [logFileURL])
            }
        }
        .alert("无法导出日志", isPresented: Binding(
            get: { logExportError != nil },
            set: { if !$0 { logExportError = nil } }
        )) {
            Button("好", role: .cancel) { logExportError = nil }
        } message: {
            Text(logExportError ?? "")
        }
    }

    private func exportLogs() {
        guard !isExportingLogs else { return }
        isExportingLogs = true
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ApplicationLogExporter.makeFile()
                }.value
                logFileURL = url
                isShowingLogShare = true
            } catch {
                logExportError = error.localizedDescription
            }
            isExportingLogs = false
        }
    }
}

private enum ApplicationLogExporter {
    static func makeFile() throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let entries = try store.getEntries(at: store.position(date: startDate))
        let formatter = ISO8601DateFormatter()
        let messages = entries.compactMap { entry -> String? in
            guard let entry = entry as? OSLogEntryLog else { return nil }
            return "\(formatter.string(from: entry.date)) [\(entry.level)] [\(entry.subsystem):\(entry.category)] \(entry.composedMessage)"
        }
        let recentMessages = Array(messages.suffix(5_000))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        var lines = [
            "Novelia iOS 应用日志",
            "版本：\(version) (\(build))",
            "导出时间：\(formatter.string(from: Date()))",
            "范围：最近 7 天，最多 5000 条当前进程日志",
            ""
        ]
        lines.append(contentsOf: recentMessages.isEmpty ? ["系统日志存储中没有可导出的应用日志。"] : recentMessages)

        let filename = "Novelia-logs-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private struct LogActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
