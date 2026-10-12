import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct DiscoverView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var query = ""
    @StateObject private var store = DiscoverStore()
    private let showsNavigationBar: Bool

    init(initialQuery: String = "", showsNavigationBar: Bool = false) {
        _query = State(initialValue: initialQuery)
        self.showsNavigationBar = showsNavigationBar
    }

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
        .navigationTitle(showsNavigationBar ? "搜索结果" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
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

struct TagSearchResultsView: View {
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
