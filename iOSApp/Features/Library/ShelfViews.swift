import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

/// 未登录时网页收藏与阅读历史的提示。
private struct CloudLoginPrompt: View {
    @EnvironmentObject private var auth: AccountAuthStore
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("登录 Novelia 账号") { auth.isLoginPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(NoveliaStyle.brandGreen)
        }
        .padding(.vertical, 22)
    }
}

/// 网页端阅读历史（发现 → 阅读历史）。
struct CloudReadingHistoryListView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if auth.username == nil {
                    CloudLoginPrompt(title: "登录后同步阅读历史", systemImage: "clock.arrow.circlepath",
                                     message: "登录 Novelia 账号后，可继续阅读网页端最近读过的作品。")
                } else if readingHistory.items.isEmpty && readingHistory.isLoading {
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
                            Text(Self.relativeDate(timestamp))
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

                if auth.username != nil {
                    Button("刷新阅读历史") { Task { await readingHistory.refresh(account: auth.username) } }
                        .font(.system(size: 13, weight: .medium))
                        .tint(NoveliaStyle.brandGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("最近阅读")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.username) { await readingHistory.refresh(account: auth.username) }
    }
}

/// 网页端网络小说收藏（发现 → 收藏）。
struct CloudFavoritesListView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if auth.username == nil {
                    CloudLoginPrompt(title: "登录后同步网页收藏", systemImage: "person.crop.circle.badge.checkmark",
                                     message: "此处会显示你在 Novelia 网页端收藏的作品。")
                } else if favorites.novels.isEmpty && favorites.isLoading {
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
                if auth.username != nil {
                    Button("刷新网页收藏") { Task { await favorites.refresh(account: auth.username) } }
                        .font(.system(size: 13, weight: .medium))
                        .tint(NoveliaStyle.brandGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("网页收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.username) { await favorites.refresh(account: auth.username) }
    }
}

private extension CloudReadingHistoryListView {
    static func relativeDate(_ timestamp: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return "最近阅读：" + formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(timestamp)), relativeTo: Date())
    }
}
