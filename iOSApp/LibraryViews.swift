import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

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
                        .foregroundStyle(NoveliaStyle.brandGreen)
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
                                .foregroundStyle(NoveliaStyle.brandGreen)
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
                                .tint(NoveliaStyle.brandGreen)
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
                            .tint(NoveliaStyle.brandGreen)
                    } else if auth.username != nil {
                        Button("刷新网页收藏") { Task { await favorites.refresh(account: auth.username) } }
                            .font(.system(size: 13, weight: .medium))
                            .tint(NoveliaStyle.brandGreen)
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
                        .foregroundStyle(NoveliaStyle.brandGreen)
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
                        .tint(NoveliaStyle.brandGreen)
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
                        .tint(NoveliaStyle.brandGreen)
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
                        .tint(NoveliaStyle.brandGreen)
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
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))
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
                            .tint(NoveliaStyle.brandGreen)
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
                    .tint(NoveliaStyle.brandGreen)
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
                    .tint(NoveliaStyle.brandGreen)
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
                            .tint(NoveliaStyle.brandGreen)
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
                    .tint(NoveliaStyle.brandGreen)
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
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var query = ""
    @StateObject private var store = DiscoverStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FIND YOUR NEXT STORY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(NoveliaStyle.brandGreen)
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
                            .background(NoveliaStyle.brandGreen, in: RoundedRectangle(cornerRadius: 13))
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
                    .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))
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
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 15))

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
                            .tint(NoveliaStyle.brandGreen)
                    }
                }

                ForEach(store.novels.filter { !blocked.hides($0.genres) }) { novel in
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
                        .tint(NoveliaStyle.brandGreen)
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
                if !store.wenkuNovels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("文库（中文译本）")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.ink)
                            Spacer()
                            Text("共 \(store.wenkuNovels.count) 部")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                        Text("网络小说书源没有匹配结果，以下是在文库中找到的作品。进入文库详情页可以跳转到对应的网络小说。")
                            .font(.system(size: 12))
                            .foregroundStyle(NoveliaStyle.muted)
                        ForEach(store.wenkuNovels) { novel in
                            NavigationLink {
                                WenkuDetailView(outline: novel)
                            } label: {
                                WenkuNovelRow(novel: novel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                if store.novels.isEmpty && store.wenkuNovels.isEmpty && store.errorMessage == nil && !store.isLoading {
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
    @ObservedObject private var blocked = BlockedTagsStore.shared
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
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Text("小说排行榜")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                }

                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Text("Novelia 站内点击热度 · 一般向作品")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))

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
                            .tint(NoveliaStyle.brandGreen)
                    }
                }

                ForEach(Array(store.novels.enumerated()).filter { !blocked.hides($0.element.genres) }, id: \.element.id) { index, novel in
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", (page - 1) * 20 + index + 1))
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(index < 3 && page == 1 ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
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
                    .tint(NoveliaStyle.brandGreen)
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
    @ObservedObject private var blocked = BlockedTagsStore.shared
    let tag: String
    @StateObject private var store = DiscoverStore()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("按标签筛选")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.brandGreen)
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
                        .tint(NoveliaStyle.brandGreen)
                    }
                }

                ForEach(store.novels.filter { !blocked.hides($0.genres) }) { novel in
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
                            .tint(NoveliaStyle.brandGreen)
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
    @ObservedObject private var blocked = BlockedTagsStore.shared
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
                        if let originalTitle = displayNovel.distinctOriginalTitle {
                            Text("原名：\(originalTitle)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                        }
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

                if let wenkuId = displayNovel.wenkuId {
                    NavigationLink {
                        WenkuDetailView(outline: WenkuNovelOutline(id: wenkuId, title: "正在加载…"))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "books.vertical").font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("文库版").font(.headline)
                                Text("查看对应的 Novelia 文库作品")
                                    .font(.caption).foregroundStyle(NoveliaStyle.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .padding(14)
                        .background(NoveliaStyle.brandGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

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
                                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 13))
                            }
                        }
                        Text("阅读时可在右上角设置中切换译源。")
                            .font(.system(size: 12))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }

                if !displayNovel.genres.isEmpty {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("标签 · 点击搜索，长按屏蔽")
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
                                        .background(NoveliaStyle.card, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(blocked.contains(tag) ? "解除屏蔽此标签" : "屏蔽此标签", systemImage: "eye.slash") {
                                        if blocked.contains(tag) { blocked.remove(tag) } else { blocked.add(tag) }
                                    }
                                }
                            }
                        }
                        NavigationLink("管理屏蔽标签") { BlockedTagsView() }
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
                        .background(NoveliaStyle.brandGreen, in: RoundedRectangle(cornerRadius: 15))
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
                                         ? (webNovelDownloads.isDownloaded(displayNovel.id) ? "重新下载全书 EPUB" : "下载全书 EPUB")
                                         : "正在下载整本小说…")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                    Text("选择原文、译文或双语 EPUB，下载后可在 App 内阅读")
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
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 15))
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
                            .tint(NoveliaStyle.brandGreen)
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
                                .foregroundStyle(NoveliaStyle.brandGreen)
                                .frame(width: 35, height: 35)
                                .background(NoveliaStyle.brandGreen.opacity(0.09), in: Circle())
                            Text(chapter.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(NoveliaStyle.muted.opacity(0.6))
                        }
                        .padding(13)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 15))
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
                        .foregroundStyle(NoveliaStyle.brandGreen)
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
        let api = NoveliaAPIClient()
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

    @State private var selectedMode: WebNovelDownloadMode
    @State private var selectedSourceRaw: String
    @State private var isDownloading = false
    @State private var didFinish = false

    init(novel: Novel, availableSources: [NovelTranslationSource]) {
        self.novel = novel
        self.availableSources = availableSources
        _selectedMode = State(initialValue: availableSources.isEmpty ? .original : .translated)
        let preferredSource = UserDefaults.standard.string(forKey: "readerTranslationSource")
        let initialSource = preferredSource.flatMap { value in
            availableSources.first(where: { $0.rawValue == value })?.rawValue
        } ?? availableSources.first?.rawValue ?? "original"
        _selectedSourceRaw = State(initialValue: initialSource)
    }

    private var selectedSource: NovelTranslationSource? {
        NovelTranslationSource(rawValue: selectedSourceRaw)
    }

    private var effectiveSource: NovelTranslationSource? {
        selectedMode == .original ? nil : selectedSource
    }

    private var progress: WebNovelDownloadProgress? { downloads.progress[novel.id] }

    var body: some View {
        NavigationStack {
            Form {
                Section("下载内容") {
                    Text(novel.title).font(.headline)
                    Text("通过 Novelia 官方整本下载接口获取文件，可在“我的下载”中阅读或导出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("语言") {
                    Picker("下载内容", selection: $selectedMode) {
                        ForEach(WebNovelDownloadMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                                .disabled(mode != .original && availableSources.isEmpty)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isDownloading)
                    if selectedMode != .original {
                        Picker("译源", selection: $selectedSourceRaw) {
                            ForEach(availableSources) { source in
                                let count = novel.translationChapterCounts?[source] ?? 0
                                Text("\(source.title)（\(count) 章）").tag(source.rawValue)
                            }
                        }
                        .disabled(isDownloading)
                        Text(selectedMode == .bilingual
                             ? "双语文件会同时包含原文和所选译源的译文。"
                             : "下载文件只包含所选译源的译文。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    Section("下载进度") {
                        ProgressView(value: progress.fraction)
                        Text(progress.completed == progress.total ? "整本小说已下载" : "正在从 Novelia 获取整本小说…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = downloads.errors[novel.id] {
                    Section { Text("下载失败：\(error)").font(.footnote).foregroundStyle(.red) }
                }
                if didFinish {
                    Section { Label("\(selectedMode.title) EPUB 下载完成，可在“我的下载”中阅读或导出", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Section {
                    Button {
                        isDownloading = true
                        Task {
                            await downloads.download(novel, mode: selectedMode,
                                                     translationSource: effectiveSource)
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
                    .disabled(isDownloading || progress != nil || (selectedMode != .original && effectiveSource == nil))
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
                            .background(NoveliaStyle.brandGreen, in: RoundedRectangle(cornerRadius: 13))
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
                            .tint(NoveliaStyle.brandGreen)
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
                        .tint(NoveliaStyle.brandGreen)
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
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Spacer()
                    Button("取消回复") { self.replyRoot = nil }
                        .font(.system(size: 12, weight: .medium))
                }
            }
            TextEditor(text: $draft)
                .frame(minHeight: 86)
                .padding(7)
                .scrollContentBackground(.hidden)
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 12))
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
                .background(NoveliaStyle.brandGreen, in: Capsule())
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
            ForumMarkdownBody(markdown: comment.content, mode: .comment)
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
                .foregroundStyle(NoveliaStyle.brandGreen)
            }

            if !visibleReplies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleReplies) { reply in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(NoveliaStyle.brandGreen.opacity(0.35))
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
                                ForumMarkdownBody(markdown: reply.content, mode: .comment)
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
                .foregroundStyle(NoveliaStyle.brandGreen)
                .disabled(loadingReplyIDs.contains(comment.id))
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 15))
    }

    @MainActor
    private func loadComments(page requestedPage: Int? = nil) async {
        let targetPage = requestedPage ?? page
        guard targetPage > 0 else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let api = NoveliaAPIClient()
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
            let api = NoveliaAPIClient()
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
            let api = NoveliaAPIClient()
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
                    .foregroundStyle(NoveliaStyle.brandGreen)
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
                .foregroundStyle(NoveliaStyle.brandGreen)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 21))
        .overlay(alignment: .trailing) {
            Image(systemName: "sparkle")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(NoveliaStyle.brandGreen.opacity(0.7))
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
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 19))
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
                Text(metadata(for: novel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.5))
        }
        .padding(11)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))
    }

    private func metadata(for novel: Novel) -> String {
        let detail: String
        if let totalCharacters = novel.totalCharacters, totalCharacters > 0 {
            detail = "\(totalCharacters.formatted()) 字"
        } else if !novel.chapters.isEmpty {
            detail = "\(novel.chapters.count) 章"
        } else {
            detail = novel.genres.first ?? "小说"
        }
        if let genre = novel.genres.first, detail != genre {
            return "\(detail)  ·  \(genre)"
        }
        return detail
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

private enum MyDownloadsImportError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        "只支持导入 .txt 或 .epub 文件。"
    }
}

struct MyDownloadsView: View {
    @EnvironmentObject private var webNovelDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var webDAVSync: WebDAVSyncStore
    @StateObject private var txtChapterRuleStore = TXTChapterRuleStore.shared
    @State private var selectedTab: MyDownloadsTab
    @State private var prototypeTarget: PrototypeDownloadTarget?
    @State private var txtReaderTarget: DownloadedWebNovel?
    @State private var wenkuTXTTarget: LocalWenkuEPUB?
    @State private var moveError: String?
    @State private var isShowingFileImporter = false
    @State private var isImporting = false
    @State private var importCompletedCount = 0
    @State private var importTotalCount = 0
    @State private var importError: String?
    @State private var syncTask: Task<Void, Never>?
    @State private var hasTriggeredSync = false
    @State private var isShowingSyncProgress = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        if hasTriggeredSync || webDAVSync.isSyncing {
                            isShowingSyncProgress = true
                        } else {
                            hasTriggeredSync = true
                            syncTask = Task {
                                await webDAVSync.sync(web: webNovelDownloads, wenku: wenkuDownloads)
                            }
                        }
                    } label: {
                        if webDAVSync.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .accessibilityLabel(webDAVSync.isSyncing ? "查看同步进度" : "WebDAV 同步")
                    .disabled(!webDAVSync.isEnabled)

                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("导入 TXT / EPUB", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入 TXT 或 EPUB")
                }
            }
        }
        .sheet(isPresented: $isShowingSyncProgress) {
            WebDAVSyncProgressPanel(onCancel: { syncTask?.cancel() }) {
                syncTask = Task { await webDAVSync.sync(web: webNovelDownloads, wenku: wenkuDownloads) }
            }
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: webDAVSync.isEnabled) { _, isEnabled in
            if !isEnabled { syncTask?.cancel() }
        }
        .navigationDestination(item: $prototypeTarget) { target in
            PrototypeReaderHost(initialURL: target.url)
        }
        .navigationDestination(item: $txtReaderTarget) { book in
            if let url = webNovelDownloads.fileURL(for: book) {
                DownloadedWebNovelTXTReader(url: url, title: book.novel.title, rules: txtChapterRuleStore.configuration)
            } else {
                ContentUnavailableView("TXT 文件不存在", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationDestination(item: $wenkuTXTTarget) { book in
            DownloadedWebNovelTXTReader(url: wenkuDownloads.fileURL(for: book), title: book.title, rules: txtChapterRuleStore.configuration)
        }
        .fullScreenCover(isPresented: $isShowingFileImporter) {
            PrototypeFilePicker(contentTypes: [
                UTType(filenameExtension: "txt") ?? .plainText,
                UTType(filenameExtension: "epub") ?? .data
            ], allowsMultipleSelection: true) { urls in
                Task { await importFiles(urls) }
            }
            .ignoresSafeArea()
        }
        .alert("导入", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("移动失败", isPresented: .init(
            get: { moveError != nil }, set: { if !$0 { moveError = nil } }
        )) {
            Button("好", role: .cancel) { moveError = nil }
        } message: { Text(moveError ?? "") }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 12) {
                        Label("正在导入书籍", systemImage: "books.vertical")
                            .font(.system(size: 16, weight: .semibold))
                        ProgressView(value: Double(importCompletedCount), total: Double(max(importTotalCount, 1)))
                            .tint(NoveliaStyle.brandGreen)
                        Text("已处理 \(importCompletedCount) / \(importTotalCount) 个文件")
                            .font(.system(size: 13))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    .padding(20)
                    .frame(width: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.45), lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
                }
                .transition(.opacity)
            }
        }
    }

    /// 从 Files 批量导入：逐项复制并登记到本地书库，完成后留在列表页。
    private func importFiles(_ pickedURLs: [URL]) async {
        guard !pickedURLs.isEmpty else { return }
        isImporting = true
        importCompletedCount = 0
        importTotalCount = pickedURLs.count
        defer { isImporting = false }

        var failures: [String] = []
        for (index, pickedURL) in pickedURLs.enumerated() {
            do {
                try await importFile(pickedURL)
            } catch {
                failures.append("\(pickedURL.lastPathComponent)：\(error.localizedDescription)")
            }
            importCompletedCount = index + 1
        }

        if pickedURLs.count > failures.count {
            selectedTab = .wenku
        }
        if !failures.isEmpty {
            let succeeded = pickedURLs.count - failures.count
            importError = "批量导入完成：成功 \(succeeded) 个，失败 \(failures.count) 个。\n" + failures.joined(separator: "\n")
        }
    }

    private func importFile(_ pickedURL: URL) async throws {
        let extensionName = pickedURL.pathExtension.lowercased()
        if extensionName == "txt" {
            TXTDiagnosticLog.logger.info("TXT import started")
        }
        guard extensionName == "txt" || extensionName == "epub" else {
            throw MyDownloadsImportError.unsupportedFile
        }
        let needsScope = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }
        let destination = wenkuDownloads.downloadDestination(for: pickedURL.lastPathComponent)
        var coordinatedError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: pickedURL, options: .forUploading,
                                       error: &coordinatedError) { sourceURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch { copyError = error }
        }
        if let error = coordinatedError ?? copyError {
            if extensionName == "txt" {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT import copy failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            }
            throw error
        }
        let title = pickedURL.deletingPathExtension().lastPathComponent
        do {
            try await wenkuDownloads.registerDownloadedFile(at: destination, title: title)
        } catch {
            if extensionName == "txt" {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT import registration failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            }
            throw error
        }
        if extensionName == "txt" {
            TXTDiagnosticLog.logger.info("TXT import completed")
        }
    }

    private var networkDownloads: some View {
        Group {
            if webNovelDownloads.books.isEmpty {
                ContentUnavailableView {
                    Label("暂无网络小说下载", systemImage: "arrow.down.book")
                } description: {
                    Text("网络小说 EPUB 下载和导入的 TXT 文件会显示在这里，可阅读或导出。")
                }
            } else {
                List {
                    ForEach(webNovelDownloads.books) { book in
                        Group {
                            if let fileURL = webNovelDownloads.fileURL(for: book) {
                                Button {
                                    if book.resolvedFileFormat == .txt {
                                        txtReaderTarget = book
                                    } else {
                                        prototypeTarget = PrototypeDownloadTarget(url: fileURL, title: book.novel.title)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        networkDownloadRow(book, isFile: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right")
                                            .font(.footnote)
                                            .foregroundStyle(NoveliaStyle.muted)
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    DownloadedWebNovelReader(book: book)
                                } label: {
                                    networkDownloadRow(book, isFile: false)
                                }
                            }
                        }
                        .listRowBackground(NoveliaStyle.card)
                        .swipeActions {
                            Button {
                                Task { await moveToWenku(book) }
                            } label: {
                                Label("移至文库", systemImage: "arrow.right.arrow.left")
                            }
                            .tint(.orange)
                            if webNovelDownloads.fileURL(for: book) != nil {
                                ShareLink(item: webNovelDownloads.fileURL(for: book)!) {
                                    Label("导出", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
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

    @ViewBuilder
    private func networkDownloadRow(_ book: DownloadedWebNovel, isFile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(book.novel.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(2)
            Text(book.novel.author)
                .font(.system(size: 12))
                .foregroundStyle(NoveliaStyle.muted)
                .lineLimit(1)
            if book.resolvedDownloadMode == .original {
                Text("原文")
                    .font(.system(size: 11))
                    .foregroundStyle(NoveliaStyle.muted)
            } else {
                Text("\(book.resolvedDownloadMode.title) · 译源：\(book.translationSource?.title ?? "未知")")
                    .font(.system(size: 11))
                    .foregroundStyle(NoveliaStyle.muted)
            }
            HStack {
                Text("\(book.resolvedFileFormat.title) · \(book.novel.chapters.count) 章 · \(book.downloadedAt.formatted(date: .numeric, time: .omitted))")
                Spacer()
                if isFile { Image(systemName: "square.and.arrow.up") }
            }
            .font(.system(size: 11))
            .foregroundStyle(NoveliaStyle.muted)
        }
        .padding(.vertical, 5)
    }

    private var wenkuDownloadsList: some View {
        Group {
            if wenkuDownloads.books.isEmpty {
                ContentUnavailableView {
                    Label("暂无本地书籍", systemImage: "book.closed")
                } description: {
                    Text("导入 TXT 或 EPUB 后，可在这里阅读、导出或管理本地书籍。")
                }
            } else {
                List {
                    ForEach(wenkuDownloads.books) { book in
                        HStack(spacing: 12) {
                            Button {
                                if book.resolvedFileFormat == .txt {
                                    wenkuTXTTarget = book
                                } else {
                                    prototypeTarget = PrototypeDownloadTarget(
                                        url: wenkuDownloads.fileURL(for: book), title: book.title
                                    )
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    if let coverURL = wenkuDownloads.coverURL(for: book),
                                       let image = UIImage(contentsOfFile: coverURL.path) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 52, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                    } else {
                                        Image(systemName: "book.closed.fill")
                                            .font(.title2).foregroundStyle(NoveliaStyle.brandGreen)
                                            .frame(width: 52, height: 72)
                                            .background(NoveliaStyle.brandGreen.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(book.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                        Text(book.resolvedFileFormat.title)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(NoveliaStyle.brandGreen)
                                        if let author = book.author, !author.isEmpty {
                                            Text(author).font(.system(size: 11)).foregroundStyle(NoveliaStyle.muted).lineLimit(1)
                                        }
                                        if let description = book.bookDescription, !description.isEmpty {
                                            Text(description).font(.system(size: 11)).foregroundStyle(NoveliaStyle.muted).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ShareLink(item: wenkuDownloads.fileURL(for: book)) {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(NoveliaStyle.card)
                        .swipeActions {
                            Button {
                                moveToNetwork(book)
                            } label: {
                                Label("移至网络小说", systemImage: "arrow.right.arrow.left")
                            }
                            .tint(.orange)
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

    private func moveToWenku(_ book: DownloadedWebNovel) async {
        guard let source = webNovelDownloads.fileURL(for: book) else {
            moveError = "这本旧版下载只有章节缓存，没有完整 EPUB/TXT 文件，无法移动。"
            return
        }
        do {
            let created = try await wenkuDownloads.importForMove(from: source, sourceBook: book)
            do { try webNovelDownloads.removeForMove(book) }
            catch { wenkuDownloads.remove(created); throw error }
        } catch { moveError = error.localizedDescription }
    }

    private func moveToNetwork(_ book: LocalWenkuEPUB) {
        do {
            let created = try webNovelDownloads.importForMove(from: wenkuDownloads.fileURL(for: book), book: book)
            do { try wenkuDownloads.removeForMove(book) }
            catch { webNovelDownloads.remove(created); throw error }
        } catch { moveError = error.localizedDescription }
    }
}

private struct DownloadedWebNovelTXTReader: View {
    @AppStorage("readerFontSize") private var fontSize = 20.0
    @AppStorage("readerAppearance") private var appearanceRaw = ReaderAppearance.system.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    let url: URL
    let title: String
    let rules: TXTChapterRuleConfiguration
    @State private var chapters: [TXTChapter]?
    @State private var chapterIndex = 0
    @State private var bodyChunks: [String] = []
    @State private var bodyChunksChapterIndex: Int?
    @State private var isShowingContents = false
    @State private var errorMessage: String?

    private var appearance: ReaderAppearance {
        ReaderAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Group {
            if let chapters, chapters.indices.contains(chapterIndex) {
                let chapter = chapters[chapterIndex]
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Color.clear.frame(height: 1).id("txt-reader-top")
                            if let volumeTitle = chapter.volumeTitle {
                                Text(volumeTitle)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                            }
                            Text(chapter.title)
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .foregroundStyle(appearance.primaryText(system: systemColorScheme))
                            if bodyChunksChapterIndex == chapterIndex {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(bodyChunks.indices, id: \.self) { index in
                                        Text(bodyChunks[index])
                                            .font(.system(size: fontSize, design: .serif))
                                            .lineSpacing(9)
                                            .foregroundStyle(appearance.primaryText(system: systemColorScheme))
                                            .textSelection(.enabled)
                                    }
                                }
                            } else {
                                ProgressView("正在排版章节…")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 36)
                    }
                    .onChange(of: chapterIndex) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("txt-reader-top", anchor: .top)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        chapterControls(count: chapters.count)
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("无法读取 TXT", systemImage: "doc.text.magnifyingglass", description: Text(errorMessage))
            } else {
                ProgressView("正在打开 TXT…")
            }
        }
        .background(ReaderBackgroundView(dark: appearance.isDark(system: systemColorScheme), fallback: appearance.background(system: systemColorScheme)).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if chapters != nil {
                    Button { isShowingContents = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("章节目录")
                }
                Button { fontSize = max(16, fontSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel("缩小字号")
                Button { fontSize = min(30, fontSize + 1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel("放大字号")
                Menu {
                    Picker("阅读主题", selection: $appearanceRaw) {
                        ForEach(ReaderAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .accessibilityLabel("阅读主题")
            }
        }
        .sheet(isPresented: $isShowingContents) {
            NavigationStack {
                List {
                    if let chapters {
                        ForEach(chapters.indices, id: \.self) { index in
                            Button {
                                chapterIndex = index
                                isShowingContents = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let volume = chapters[index].volumeTitle {
                                        Text(volume).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(chapters[index].title)
                                        .foregroundStyle(index == chapterIndex ? NoveliaStyle.brandGreen : .primary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("章节目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { isShowingContents = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: url) {
            do {
                chapters = try await Task.detached(priority: .userInitiated) {
                    let text = try TXTTextDecoder.decode(contentsOf: url)
                    return TXTChapterParser.parse(text, rules: rules)
                }.value
            } catch {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT reader load failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
        .task(id: "\(url.path)|\(chapterIndex)|\(chapters?.count ?? 0)") {
            guard let chapters, chapters.indices.contains(chapterIndex) else { return }
            let body = chapters[chapterIndex].body
            let chunks = await Task.detached(priority: .userInitiated) {
                ReaderTextChunker.chunks(body)
            }.value
            guard !Task.isCancelled else { return }
            bodyChunks = chunks
            bodyChunksChapterIndex = chapterIndex
        }
    }

    private func chapterControls(count: Int) -> some View {
        HStack {
            Button {
                chapterIndex = max(0, chapterIndex - 1)
            } label: {
                Label("上一章", systemImage: "chevron.left")
            }
            .disabled(chapterIndex == 0)
            Spacer()
            Text("\(chapterIndex + 1) / \(count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(appearance.secondaryText(system: systemColorScheme))
            Spacer()
            Button {
                chapterIndex = min(count - 1, chapterIndex + 1)
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(chapterIndex >= count - 1)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
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
                    startingAt: UserDefaults.standard.integer(forKey: "progress.\(book.id)"),
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
    @AppStorage(NoveliaUpdateStore.enabledKey) private var checksUpdates = true
    @EnvironmentObject private var auth: AccountAuthStore
    @AppStorage("appThemeColor") private var themeColorRaw = AppThemeColor.novelia.rawValue
    @AppStorage("appThemeCustomHex") private var themeCustomHex = "559775"
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
                    .tint(NoveliaStyle.brandGreen)
                }
            }
            Section("内容筛选") {
                NavigationLink("标签屏蔽") { BlockedTagsView() }
            }
            Section("阅读体验") {
                NavigationLink("阅读背景") { ReaderBackgroundSettingsView() }
                Picker(selection: $themeColorRaw) {
                    ForEach(AppThemeColor.allCases) { option in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(option == .custom ? AppThemeColor.color(fromHex: themeCustomHex) : option.color)
                                .frame(width: 12, height: 12)
                            Text(option.title)
                        }
                        .tag(option.rawValue)
                    }
                } label: {
                    Label("主题色", systemImage: "paintpalette")
                }
                if AppThemeColor(rawValue: themeColorRaw) == .custom {
                    ColorPicker(
                        "自定义颜色",
                        selection: Binding(
                            get: { AppThemeColor.color(fromHex: themeCustomHex) },
                            set: { themeCustomHex = AppThemeColor.hex(from: $0) }
                        ),
                        supportsOpacity: false
                    )
                }
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
                        .tint(NoveliaStyle.brandGreen)
                }
                NavigationLink {
                    TXTChapterRulesView()
                } label: {
                    Label("TXT 分章规则", systemImage: "text.alignleft")
                }
            }
            Section("下载") {
                NavigationLink {
                    MyDownloadsView()
                } label: {
                    Label("我的下载", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    WebDAVSyncView()
                } label: {
                    Label("WebDAV 同步", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Section("版本") {
                Toggle("启动时检查更新", isOn: $checksUpdates)
                LabeledContent("当前版本", value: appVersion)
                LabeledContent("平台", value: "iOS 17+")
                NavigationLink("开源许可") {
                    ThirdPartyLicensesView()
                }
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

private struct TXTChapterRulesView: View {
    @StateObject private var ruleStore = TXTChapterRuleStore.shared
    @State private var isShowingEditor = false
    @State private var editingRule: TXTChapterRule?

    private var builtInRules: [TXTChapterRule] { ruleStore.rules.filter(\.isBuiltIn) }
    private var customRules: [TXTChapterRule] { ruleStore.rules.filter { !$0.isBuiltIn } }

    var body: some View {
        Form {
            Section {
                Text("规则按行匹配。关闭某条规则后，TXT 阅读器会忽略对应格式；自定义规则需匹配整行，并建议使用 ^ 和 $ 限定边界。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("内置规则") {
                ForEach(builtInRules) { rule in
                    ruleRow(rule, editable: false)
                }
            }
            Section {
                if customRules.isEmpty {
                    Text("还没有自定义规则。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(customRules) { rule in
                    ruleRow(rule, editable: true)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                ruleStore.deleteCustomRule(rule)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
                Button {
                    editingRule = nil
                    isShowingEditor = true
                } label: {
                    Label("添加自定义规则", systemImage: "plus")
                }
            } header: {
                Text("自定义规则")
            } footer: {
                Text("自定义正则只检查整行。启用后重新打开 TXT，即可按新规则生成章节目录。")
            }
            Section("分章保护") {
                Text("标题还会经过行长、句末标点、开头目录和编号顺序检查。若最终识别出的章节少于 3 个，阅读器会保留全文，不进行猜测切分。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("TXT 分章规则")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingEditor) {
            TXTChapterRuleEditor(rule: editingRule) { rule in
                ruleStore.saveCustomRule(rule)
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: TXTChapterRule, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                if editable {
                    Button {
                        editingRule = rule
                        isShowingEditor = true
                    } label: {
                        Text(rule.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(rule.name)
                        .font(.system(size: 15, weight: .semibold))
                }
                Toggle("启用", isOn: Binding(
                    get: { ruleStore.rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
                    set: { ruleStore.setEnabled($0, for: rule.id) }
                ))
                .labelsHidden()
            }
            Text(rule.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(rule.pattern)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct TXTChapterRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let originalRule: TXTChapterRule?
    let onSave: (TXTChapterRule) -> Void
    @State private var name: String
    @State private var pattern: String
    @State private var errorMessage: String?

    init(rule: TXTChapterRule?, onSave: @escaping (TXTChapterRule) -> Void) {
        originalRule = rule
        self.onSave = onSave
        _name = State(initialValue: rule?.name ?? "")
        _pattern = State(initialValue: rule?.pattern ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则名称") {
                    TextField("例如：自定义章节格式", text: $name)
                }
                Section("整行正则表达式") {
                    TextField(#"例如：^第\d+节.*$"#, text: $pattern, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("使用系统正则语法。规则必须匹配整行；推荐以 ^ 开始、以 $ 结束。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(originalRule == nil ? "新建分章规则" : "编辑分章规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "请填写规则名称。"
            return
        }
        guard !cleanPattern.isEmpty else {
            errorMessage = "请填写正则表达式。"
            return
        }
        guard (try? NSRegularExpression(pattern: cleanPattern)) != nil else {
            errorMessage = "正则表达式格式无效，请检查括号、方括号和转义符。"
            return
        }
        let rule = TXTChapterRule(
            id: originalRule?.id ?? UUID().uuidString,
            name: cleanName,
            pattern: cleanPattern,
            explanation: "用户自定义规则。",
            isEnabled: originalRule?.isEnabled ?? true,
            isBuiltIn: false
        )
        onSave(rule)
        dismiss()
    }
}

private enum ApplicationLogExporter {
    static func makeFile() throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let entries = try store.getEntries(at: store.position(date: startDate))
        let formatter = ISO8601DateFormatter()
        let logEntries = entries.compactMap { $0 as? OSLogEntryLog }
        let recentEntries = Array(logEntries.suffix(5_000))
        let messages = recentEntries.map {
            "\(formatter.string(from: $0.date)) [\($0.level)] [\($0.subsystem):\($0.category)] \($0.composedMessage)"
        }
        let txtDiagnosticCount = recentEntries.filter {
            $0.subsystem == "cc.novelia.ios.port" && $0.category == "txt"
        }.count
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        var lines = [
            "Novelia iOS 应用日志",
            "版本：\(version) (\(build))",
            "导出时间：\(formatter.string(from: Date()))",
            "范围：最近 7 天，最多 5000 条当前进程日志",
            "本次导出条数：\(recentEntries.count)",
            "TXT 导入 / 解码 / 分章诊断条数：\(txtDiagnosticCount)",
            ""
        ]
        lines.append(contentsOf: messages.isEmpty ? ["系统日志存储中没有可导出的应用日志。"] : messages)

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

// MARK: - 排版原型导航目标

/// 从“我的下载”推入排版原型的目标书；url 为 nil 时使用样例书。
struct PrototypeDownloadTarget: Identifiable, Hashable {
    let id = UUID()
    let url: URL?
    let title: String
}

private struct ThirdPartyLicensesView: View {
    private let packages: [(name: String, version: String, license: String, file: String)] = [
        ("CryptoSwift", "1.10.0", "Zlib", "CryptoSwift-LICENSE.txt"),
        ("DifferenceKit", "1.3.0", "Apache-2.0", "DifferenceKit-LICENSE.txt"),
        ("Fuzi", "4.0.1", "MIT", "Fuzi-LICENSE.txt"),
        ("GCDWebServer", "4.0.1", "BSD-3-Clause", "GCDWebServer-LICENSE.txt"),
        ("SQLite.swift", "0.16.0", "MIT", "SQLite.swift-LICENSE.txt"),
        ("swift-toolkit", "3.11.0", "BSD-3-Clause", "swift-toolkit-LICENSE.txt"),
        ("SwiftSoup", "2.13.7", "MIT", "SwiftSoup-LICENSE.txt"),
        ("YueduCoreText", "0.8.0", "MPL-2.0", "YueduCoreText-LICENSE.txt"),
        ("Zip", "2.1.2", "MIT", "Zip-LICENSE.txt"),
        ("ZIPFoundation", "3.0.1", "MIT", "ZIPFoundation-LICENSE.txt")
    ]

    var body: some View {
        List {
            Section("本应用") {
                Text("本项目自有源代码和项目文档采用 GNU GPL-3.0-only。该许可允许用户复制、修改和再分发；本软件不提供任何担保。")
                NavigationLink("GNU GPL-3.0-only 完整文本") {
                    licenseText("GPL-3.0-only.txt", title: "GNU GPL-3.0-only")
                }
                Text("本项目是参考 GPL-3.0-only 安卓客户端 nobYoQ/novelia 制作的 Swift iOS 移植版本，包含 iOS 平台实现及后续修改。上游版权声明：Copyright (C) 2026 Novelia Android contributors. 本 iOS 移植及新增部分：Copyright (C) 2026 Novelia iOS contributors。修改版本日期：2026-10-10。")
                Link("查看对应版本的源码仓库", destination: URL(string: "https://github.com/Guanine000/novelia-swift")!)
                Text("源码仓库公开可访问。Release 同时提供对应版本的完整源码及第三方许可材料。")
            }
            Section {
                Text("本应用使用的第三方软件及其原始许可文本。YueduCoreText 的 NOTICE 包含 Unicode License v3。")
            }
            Section("依赖") {
                ForEach(packages, id: \.name) { package in
                    NavigationLink {
                        licenseText(package.file, title: package.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name)
                            Text("\(package.version) · \(package.license)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("附加声明") {
                NavigationLink("YueduCoreText NOTICE / Unicode License v3") {
                    licenseText("YueduCoreText-NOTICE.txt", title: "附加声明")
                }
                Link("YueduCoreText 0.8.0 对应源码", destination: URL(string: "https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe")!)
            }
        }
        .navigationTitle("开源许可")
    }

    private func licenseText(_ file: String, title: String) -> some View {
        let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "ThirdPartyLicenses")
        let content = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return ScrollView {
            Text(content ?? "许可文件未找到：\(file)")
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
