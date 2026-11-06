import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

struct ForumView: View {
    @EnvironmentObject private var services: AppServices
    var initialCategory: String = ""
    var initialQuery: String = ""
    var body: some View {
        ForumContentView(initialCategory: initialCategory, initialQuery: initialQuery, api: services.api.forum)
    }
}

private struct ForumContentView: View {
    @EnvironmentObject private var auth: ForumAuthStore
    @StateObject private var store: ForumStore
    @State private var isConfirmingLogout = false
    @State private var openedPostID: Int64?

    init(initialCategory: String, initialQuery: String, api: any ForumService) {
        let store = ForumStore(api: api)
        store.selectedCategory = initialCategory
        store.query = initialQuery
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ForumCategoryBar(categories: store.categories, selectedCategory: store.selectedCategory,
                                 isVisible: store.source == .all) { category in
                    Task { await store.selectCategory(category.slug) }
                }
                if store.source != .all {
                    ForumSourceChip(title: store.source.title) {
                        Task { await store.selectSource(.all) }
                    }
                }
                if !store.filterTags.isEmpty {
                    ForumTagFilter(
                        tags: store.filterTags,
                        selectedTagID: store.selectedTagID
                    ) { tagID in
                        store.selectedTagID = tagID
                        Task { await store.loadPosts(page: 0) }
                    }
                }
                List {
                    Color.clear
                        .frame(height: 1)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id("forum-post-list-top")

                    if store.isLoadingCategories && store.categories.isEmpty {
                        HStack { Spacer(); ProgressView("正在连接论坛…"); Spacer() }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    if store.categories.isEmpty, !store.isLoadingCategories, let error = store.errorMessage {
                        CompatUnavailable {
                            Label("论坛暂时无法访问", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { Task { await store.refresh() } }
                                .buttonStyle(.borderedProminent).tint(NoveliaStyle.brandGreen)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else if visiblePosts.isEmpty, !store.isLoadingPosts, store.errorMessage == nil {
                        CompatUnavailable(store.posts.isEmpty ? "这里还没有帖子" : "本页没有匹配的帖子", systemImage: "bubble.left.and.bubble.right",
                                               description: Text(filtersCurrentPageOnly ? "可翻页查看其他页的帖子。" : "切换分类或调整搜索词。"))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    if filtersCurrentPageOnly {
                        Label("“我的帖子”和“收藏”不支持服务器搜索，只在本页按标题筛选。", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.muted)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    ForEach(visiblePosts) { post in
                        Button {
                            openedPostID = post.id
                        } label: {
                            ForumPostCard(post: post, category: store.categories.first { $0.id == post.categoryId })
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    if store.page > 0 || store.hasNextPage || store.isLoadingPosts {
                        ForumPaginationBar(
                            page: store.page,
                            total: store.total,
                            hasPrevious: store.page > 0,
                            hasNext: store.hasNextPage,
                            isLoading: store.isLoadingPosts,
                            onPrevious: { loadPage(max(0, store.page - 1), using: proxy) },
                            onNext: { loadPage(store.page + 1, using: proxy) }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    if let error = store.errorMessage, !store.categories.isEmpty {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .compatScrollContentBackgroundHidden()
                .background(NoveliaStyle.paper)
                .compatNavigationDestination(item: $openedPostID) { postID in
                    ForumPostDetailView(postID: postID)
                }
                .navigationTitle("论坛")
                .toolbar {
                    ToolbarItem(placement: .compatTopBarLeading) {
                        Menu {
                            Button("全部帖子", systemImage: "text.bubble") { Task { await store.selectSource(.all) } }
                            Button("我的帖子", systemImage: "person.text.rectangle") {
                                guard auth.username != nil else { auth.isLoginPresented = true; return }
                                Task { await store.selectSource(.myPosts) }
                            }
                            Button("云端收藏", systemImage: "bookmark") {
                                guard auth.username != nil else { auth.isLoginPresented = true; return }
                                Task { await store.selectSource(.favorites) }
                            }
                            if auth.username != nil {
                                Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    isConfirmingLogout = true
                                }
                            } else {
                                Button("登录 Novelia", systemImage: "person.crop.circle.badge.plus") { auth.isLoginPresented = true }
                            }
                        } label: {
                            Label(auth.username ?? "我的", systemImage: "person.crop.circle")
                                .labelStyle(.iconOnly)
                        }
                    }
                    ToolbarItemGroup(placement: .compatTopBarTrailing) {
                        Menu {
                            ForEach(ForumSort.allCases) { option in
                                Button {
                                    store.sort = option
                                    Task { await store.loadPosts(page: 0) }
                                } label: {
                                    if store.sort == option { Label(option.title, systemImage: "checkmark") }
                                    else { Text(option.title) }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("排序：\(store.sort.title)")

                        NavigationLink {
                            ForumComposeView(categories: store.categories, initialCategorySlug: store.selectedCategory)
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("发布新帖")
                    }
                }
                .searchable(text: $store.query, prompt: "搜索论坛帖子")
                .confirmationDialog("退出登录？", isPresented: $isConfirmingLogout, titleVisibility: .visible) {
                    Button("退出登录", role: .destructive) {
                        auth.logout()
                        Task { await store.selectSource(.all) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("小说与论坛使用同一账号，会一起退出。")
                }
                .onSubmit(of: .search) { Task { await store.loadPosts(page: 0) } }
                .refreshable { await store.refresh() }
                .task { if store.categories.isEmpty { await store.refresh() } }
                .sheet(isPresented: $auth.isLoginPresented) {
                    ForumLoginSheet(auth: auth)
                }
                .overlay {
                    if let error = store.errorMessage {
                        ForumErrorOverlay(
                            message: error,
                            onDismiss: { store.clearError() },
                            onRetry: { Task { await store.refresh() } }
                        )
                    }
                }
            }
        }
    }

    private func loadPage(_ page: Int, using proxy: ScrollViewProxy) {
        Task {
            await store.loadPosts(page: page)
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo("forum-post-list-top", anchor: .top)
            }
        }
    }

    /// “我的帖子”和“收藏”的接口不接受搜索词，只能在已取回的本页中筛选标题。
    private var filtersCurrentPageOnly: Bool {
        store.source != .all && !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visiblePosts: [ForumPost] {
        guard filtersCurrentPageOnly else { return store.posts }
        let term = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.posts.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }
}

private extension ForumFeedSource {
    var title: String {
        switch self {
        case .all: "全部帖子"
        case .favorites: "云端收藏"
        case .myPosts: "我的帖子"
        }
    }
}

/// 帖子列表行：白卡 + 分类胶囊 + 标题 + 标签 + 统计，行间留白由列表行距提供。
private struct ForumPostCard: View {
    let post: ForumPost
    let category: ForumCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if post.pinOrder != nil {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NoveliaStyle.brandGreen)
                        .accessibilityLabel("置顶")
                }
                Text(category?.title ?? "论坛")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                if post.commentsLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(NoveliaStyle.muted)
                        .accessibilityLabel("已锁定评论")
                }
                Spacer(minLength: 8)
                Text(post.createdAt.forumDisplayDate)
                    .font(.system(size: 11))
                    .foregroundStyle(NoveliaStyle.muted)
            }
            Text(post.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !post.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(post.tags.prefix(4)) { tag in
                        Text(tag.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(NoveliaStyle.muted.opacity(0.10), in: Capsule())
                    }
                    if post.tags.count > 4 {
                        Text("+\(post.tags.count - 4)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }
            }
            HStack(spacing: 14) {
                Text(post.authorUsername)
                    .lineLimit(1)
                Label("\(post.commentsCount)", systemImage: "bubble.right")
                Label("\(post.viewsCount)", systemImage: "eye")
                Spacer(minLength: 6)
                if post.favorited {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(NoveliaStyle.brandGreen)
                        .accessibilityLabel("已收藏")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(NoveliaStyle.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(NoveliaStyle.muted.opacity(0.12), lineWidth: 1)
        )
    }
}

/// 将分类控件放在 List 上方的普通布局中，避免使用动态安全区插入，
/// 防止切换内容列表后留下已折叠但未更新的安全区间距。
private struct ForumCategoryBar: View {
    let categories: [ForumCategory]
    let selectedCategory: String
    let isVisible: Bool
    let onSelect: (ForumCategory) -> Void

    private var isShown: Bool { isVisible && !categories.isEmpty }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    Button { onSelect(category) } label: {
                        Text(category.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selectedCategory == category.slug ? .white : NoveliaStyle.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selectedCategory == category.slug ? NoveliaStyle.brandGreen : Color.clear, in: Capsule())
                            .overlay {
                                Capsule().stroke(
                                    selectedCategory == category.slug ? Color.clear : NoveliaStyle.muted.opacity(0.28),
                                    lineWidth: 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedCategory == category.slug ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(height: isShown ? 48 : 0)
        .clipped()
        .background(NoveliaStyle.paper)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }
}

/// 「我的帖子／云端收藏」时显示当前来源，便于一键回到全部帖子。
private struct ForumSourceChip: View {
    let title: String
    let onClear: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回到全部帖子")
            }
            .foregroundStyle(NoveliaStyle.brandGreen)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(NoveliaStyle.brandGreen.opacity(0.10), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(NoveliaStyle.paper)
    }
}

/// 小说分类下的标签筛选，取代系统 Picker，保持与分类胶囊同一视觉语言。
private struct ForumTagFilter: View {
    let tags: [ForumTag]
    let selectedTagID: Int64?
    let onSelect: (Int64?) -> Void

    private var selectedName: String {
        tags.first { $0.id == selectedTagID }?.name ?? "全部标签"
    }

    private var isFiltering: Bool { selectedTagID != nil }

    var body: some View {
        HStack {
            Menu {
                Button("全部标签") { onSelect(nil) }
                ForEach(tags) { tag in
                    Button {
                        onSelect(tag.id)
                    } label: {
                        if tag.id == selectedTagID { Label(tag.name, systemImage: "checkmark") }
                        else { Text(tag.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tag")
                        .font(.system(size: 11, weight: .semibold))
                    Text(selectedName)
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(isFiltering ? NoveliaStyle.brandGreen : NoveliaStyle.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isFiltering ? NoveliaStyle.brandGreen.opacity(0.10) : NoveliaStyle.card, in: Capsule())
                .overlay(
                    Capsule().stroke(
                        isFiltering ? NoveliaStyle.brandGreen.opacity(0.35) : NoveliaStyle.muted.opacity(0.22),
                        lineWidth: 1
                    )
                )
            }
            .accessibilityIdentifier("forum-tag-filter")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(NoveliaStyle.paper)
    }
}

/// 翻页栏：两端圆形箭头 + 中间页码胶囊，替代原来的文字按钮。
private struct ForumPaginationBar: View {
    let page: Int
    let total: Int64
    let hasPrevious: Bool
    let hasNext: Bool
    let isLoading: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            roundButton("chevron.left", label: "上一页", enabled: hasPrevious && !isLoading, action: onPrevious)

            Group {
                if isLoading {
                    ProgressView()
                        .frame(minWidth: 108)
                } else {
                    Text("第 \(page + 1) 页 · 共 \(total) 帖")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(minWidth: 108)
                }
            }

            roundButton("chevron.right", label: "下一页", enabled: hasNext && !isLoading, action: onNext)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func roundButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? NoveliaStyle.ink : NoveliaStyle.muted.opacity(0.5))
                .frame(width: 38, height: 38)
                .background(NoveliaStyle.card, in: Circle())
                .overlay(
                    Circle().stroke(NoveliaStyle.muted.opacity(enabled ? 0.22 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct ForumErrorOverlay: View {
    let message: String
    let onDismiss: () -> Void
    var onRetry: (() -> Void)? = nil
    @State private var didCopy = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                Label("论坛遇到问题", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                ScrollView {
                    Text(message)
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = message
                        didCopy = true
                    } label: {
                        Label(didCopy ? "已复制" : "复制错误信息", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)

                    if let onRetry {
                        Button("重试", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                    Button("关闭", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .tint(NoveliaStyle.ink)
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(NoveliaStyle.muted.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .zIndex(100)
    }
}
