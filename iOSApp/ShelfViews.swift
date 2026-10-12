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
