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
    @Environment(\.browseSelection) private var browseSelection
    @Environment(\.browseSelectedID) private var browseSelectedID
    @EnvironmentObject private var auth: ForumAuthStore
    @StateObject private var store: ForumStore
    @State private var isConfirmingLogout = false
    @State private var isPresentingCompose = false
    @State private var isSearching: Bool
    @State private var autoFocusSearch: Bool
    @State private var searchFocusRequest = 0
    @State private var openedPostID: Int64?

    init(initialCategory: String, initialQuery: String, api: any ForumService) {
        let store = ForumStore(api: api)
        store.selectedCategory = initialCategory
        store.query = initialQuery
        _store = StateObject(wrappedValue: store)
        let hasInitialQuery = !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _isSearching = State(initialValue: hasInitialQuery)
        _autoFocusSearch = State(initialValue: !hasInitialQuery)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if isSearching {
                    LibrarySearchField(
                        query: $store.query,
                        prompt: store.source == .all ? "搜索论坛帖子" : "在本页按标题筛选",
                        focusRequest: searchFocusRequest,
                        autoFocus: autoFocusSearch,
                        isLoading: store.source == .all && store.isLoadingPosts,
                        onSubmit: { submitSearch(using: proxy) },
                        onCancel: { closeSearch(using: proxy) }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(NoveliaStyle.paper)
                }
                ForumCategoryBar(categories: store.categories, selectedCategory: store.selectedCategory,
                                 isVisible: store.source == .all) { category in
                    Task { await store.selectCategory(category.slug) }
                }
                if store.source != .all || !store.filterTags.isEmpty {
                    ForumAuxiliaryBar(
                        sourceTitle: store.source != .all ? store.source.title : nil,
                        onClearSource: { Task { await store.selectSource(.all) } },
                        tags: store.filterTags,
                        selectedTagID: store.selectedTagID,
                        onSelectTag: { tagID in
                            store.selectedTagID = tagID
                            Task { await store.loadPosts(page: 0) }
                        }
                    )
                }
                List {
                    Color.clear
                        .frame(height: 1)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id("forum-post-list-top")

                    if (store.isLoadingCategories && store.categories.isEmpty) || (store.isLoadingPosts && visiblePosts.isEmpty) {
                        ForEach(0..<4, id: \.self) { _ in
                            NoveliaListSkeletonCard(showsCover: false)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
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
                        CompatUnavailable(emptyStateTitle, systemImage: emptyStateSystemImage,
                                          description: Text(emptyStateDescription))
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
                        let destination = BrowseDestination.forumPost(post.id)
                        Button {
                            if let browseSelection {
                                browseSelection(destination)
                            } else {
                                openedPostID = post.id
                            }
                        } label: {
                            ForumPostCard(post: post, category: store.categories.first { $0.id == post.categoryId },
                                          isSelected: browseSelectedID == destination.id)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityAddTraits(browseSelectedID == destination.id ? .isSelected : [])
                        .id(destination.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    if store.page > 0 || store.hasNextPage || store.isLoadingPosts {
                        ForumPaginationBar(
                            page: store.page,
                            pageCount: store.pageCount,
                            total: store.total,
                            hasPrevious: store.page > 0,
                            hasNext: store.hasNextPage,
                            isLoading: store.isLoadingPosts,
                            onSelectPage: { target in loadPage(target, using: proxy) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    if let error = store.errorMessage, !store.categories.isEmpty {
                        Text(error).font(.footnote).foregroundStyle(NoveliaStyle.danger)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .compatScrollContentBackgroundHidden()
                .compatScrollDismissesKeyboardInteractively()
                .background(NoveliaStyle.paper)
                .refreshable { await store.refresh() }
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .pageKeyboardActions(browseKeyboardActions(
                destinations: visiblePosts.map { .forumPost($0.id) },
                selectedID: browseSelectedID,
                select: browseSelection,
                read: nil,
                search: {
                    withAnimation { proxy.scrollTo("forum-post-list-top", anchor: .top) }
                    openSearch()
                },
                scrollTo: { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            ) + [.command("n", "发布新帖", action: { isPresentingCompose = true })])
            .compatNavigationDestination(isPresented: $isPresentingCompose) {
                ForumComposeView(categories: store.categories, initialCategorySlug: store.selectedCategory)
            }
            .compatNavigationDestination(item: $openedPostID) { postID in
                ForumPostDetailView(postID: postID)
            }
            .navigationTitle("社区")
            .navigationBarTitleDisplayMode(isSearching ? .inline : .large)
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
                    Button {
                        if isSearching { closeSearch(using: proxy) } else { openSearch() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索帖子")

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
            .confirmationDialog("退出登录？", isPresented: $isConfirmingLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    auth.logout()
                    Task { await store.selectSource(.all) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("小说与论坛使用同一账号，会一起退出。")
            }
            .onValueChange(of: store.query) { _, newValue in
                guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                guard store.source == .all, !store.activeServerQuery.isEmpty else { return }
                Task {
                    if await store.clearSearch() {
                        scrollToTop(using: proxy)
                    }
                }
            }
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

    private func openSearch() {
        autoFocusSearch = true
        withAnimation { isSearching = true }
        searchFocusRequest += 1
    }

    private func submitSearch(using proxy: ScrollViewProxy) {
        Task {
            await store.submitSearch()
            scrollToTop(using: proxy)
        }
    }

    private func closeSearch(using proxy: ScrollViewProxy) {
        withAnimation { isSearching = false }
        Task {
            if await store.clearSearch() {
                scrollToTop(using: proxy)
            }
        }
    }

    private func loadPage(_ page: Int, using proxy: ScrollViewProxy) {
        Task {
            await store.loadPosts(page: page)
            scrollToTop(using: proxy)
        }
    }

    private func scrollToTop(using proxy: ScrollViewProxy) {
        Task {
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo("forum-post-list-top", anchor: .top)
            }
        }
    }

    private var emptyStateTitle: String {
        if filtersCurrentPageOnly { return "本页没有匹配的帖子" }
        if !store.activeServerQuery.isEmpty { return "没有找到匹配的帖子" }
        return "这里还没有帖子"
    }

    private var emptyStateSystemImage: String {
        if filtersCurrentPageOnly || !store.activeServerQuery.isEmpty { return "magnifyingglass" }
        return "bubble.left.and.bubble.right"
    }

    private var emptyStateDescription: String {
        if filtersCurrentPageOnly { return "可翻页查看其他页的帖子。" }
        if !store.activeServerQuery.isEmpty { return "尝试更换关键词或切换分类。" }
        return "切换分类或下拉刷新。"
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

/// 帖子列表行：作者首字母微头像 + 清晰标题层级 + 轻话题标签 + 互动计数，置顶帖带柔和左侧强调条。
private struct ForumPostCard: View {
    let post: ForumPost
    let category: ForumCategory?
    var isSelected = false

    private var isPinned: Bool { post.pinOrder != nil }

    private var avatarTint: Color {
        let palette: [Color] = [
            NoveliaStyle.brandGreen,
            Color(red: 0.27, green: 0.52, blue: 0.66),
            Color(red: 0.47, green: 0.35, blue: 0.58),
            Color(red: 0.72, green: 0.46, blue: 0.26),
            Color(red: 0.33, green: 0.55, blue: 0.52)
        ]
        var hash = 0
        for scalar in post.authorUsername.unicodeScalars {
            hash = (hash &* 31) &+ Int(scalar.value)
        }
        return palette[abs(hash) % palette.count]
    }

    private var authorInitial: String {
        let trimmed = post.authorUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(avatarTint.opacity(0.16))
                    Text(authorInitial)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(avatarTint)
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                Text(post.authorUsername)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NoveliaStyle.ink.opacity(0.85))
                    .lineLimit(1)

                Text("·")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.5))

                Text(post.createdAt.forumDisplayDate)
                    .font(NoveliaStyle.fontCaption)
                    .foregroundStyle(NoveliaStyle.muted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isPinned {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("置顶")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(NoveliaStyle.brandGreen.opacity(0.13), in: Capsule())
                }

                if let title = category?.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(NoveliaStyle.paper, in: Capsule())
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(post.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if post.commentsLocked {
                    Image(systemName: "lock.fill")
                        .font(NoveliaStyle.fontMicro)
                        .foregroundStyle(NoveliaStyle.muted)
                        .accessibilityLabel("已锁定评论")
                }
            }

            if !post.tags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(post.tags.prefix(4)) { tag in
                        Text("#\(tag.name)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NoveliaStyle.brandGreen.opacity(0.85))
                            .lineLimit(1)
                    }
                    if post.tags.count > 4 {
                        Text("+\(post.tags.count - 4)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }
            }

            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(post.commentsCount)")
                        .font(.system(size: 12, weight: post.commentsCount > 0 ? .semibold : .regular, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(post.commentsCount > 0 ? NoveliaStyle.ink.opacity(0.75) : NoveliaStyle.muted)

                HStack(spacing: 4) {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(post.viewsCount)")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(NoveliaStyle.muted)

                Spacer(minLength: 6)

                if post.favorited {
                    HStack(spacing: 3) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                        Text("已收藏")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .accessibilityLabel("已收藏")
                }
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if isPinned {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(NoveliaStyle.brandGreen)
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
        }
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge, isSelected: isSelected)
    }
}

/// 轻量下划线式分类栏：放在 List 上方的普通布局中，避免动态安全区插入带来的跳动。
private struct ForumCategoryBar: View {
    let categories: [ForumCategory]
    let selectedCategory: String
    let isVisible: Bool
    let onSelect: (ForumCategory) -> Void

    private var isShown: Bool { isVisible && !categories.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(categories) { category in
                        let isSelected = selectedCategory == category.slug
                        Button {
                            NoveliaHaptics.selection()
                            onSelect(category)
                        } label: {
                            VStack(spacing: 7) {
                                Text(category.title)
                                    .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? NoveliaStyle.ink : NoveliaStyle.muted)
                                Capsule()
                                    .fill(isSelected ? NoveliaStyle.brandGreen : Color.clear)
                                    .frame(width: 22, height: 2.5)
                            }
                            .padding(.top, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 18)
            }
            Rectangle()
                .fill(NoveliaStyle.hairline)
                .frame(height: 0.75)
        }
        .frame(height: isShown ? 42 : 0)
        .clipped()
        .background(NoveliaStyle.paper)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }
}

/// 将「我的帖子／云端收藏」来源提示与标签筛选合并为紧凑的一行，减少顶部堆叠高度。
private struct ForumAuxiliaryBar: View {
    let sourceTitle: String?
    let onClearSource: () -> Void
    let tags: [ForumTag]
    let selectedTagID: Int64?
    let onSelectTag: (Int64?) -> Void

    private var selectedTagName: String {
        tags.first { $0.id == selectedTagID }?.name ?? "全部标签"
    }

    private var isFilteringTag: Bool { selectedTagID != nil }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let sourceTitle {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(sourceTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Button(action: onClearSource) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("回到全部帖子")
                    }
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                }

                if !tags.isEmpty {
                    Menu {
                        Button("全部标签") { onSelectTag(nil) }
                        ForEach(tags) { tag in
                            Button {
                                onSelectTag(tag.id)
                            } label: {
                                if tag.id == selectedTagID { Label(tag.name, systemImage: "checkmark") }
                                else { Text(tag.name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tag")
                                .font(.system(size: 11, weight: .semibold))
                            Text(selectedTagName)
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(isFilteringTag ? NoveliaStyle.brandGreen : NoveliaStyle.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(isFilteringTag ? NoveliaStyle.brandGreen.opacity(0.12) : NoveliaStyle.card, in: Capsule())
                        .overlay(
                            Capsule().stroke(
                                isFilteringTag ? NoveliaStyle.brandGreen.opacity(0.35) : NoveliaStyle.hairline,
                                lineWidth: 0.75
                            )
                        )
                    }
                    .accessibilityIdentifier("forum-tag-filter")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(NoveliaStyle.paper)
    }
}

/// 翻页栏：胶囊底座承载上下页与当前页码，支持点击页码或行内输入页数跳转（0-based 页码与 1-based 展示自动换算）。
private struct ForumPaginationBar: View {
    let page: Int
    let pageCount: Int
    let total: Int64
    let hasPrevious: Bool
    let hasNext: Bool
    let isLoading: Bool
    let onSelectPage: (Int) -> Void

    @State private var inlineJumpText = ""
    @State private var alertJumpText = ""
    @State private var showsJumpAlert = false
    @FocusState private var inlineJumpFocused: Bool

    private var currentDisplayPage: Int { page + 1 }
    private var effectivePageCount: Int { max(currentDisplayPage, pageCount) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    roundButton("chevron.left", label: "上一页", enabled: hasPrevious && !isLoading) {
                        NoveliaHaptics.selection()
                        onSelectPage(max(0, page - 1))
                    }

                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: 120)
                        } else {
                            Button {
                                alertJumpText = ""
                                showsJumpAlert = true
                            } label: {
                                VStack(spacing: 1) {
                                    Text("第 \(currentDisplayPage) / \(effectivePageCount) 页")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(NoveliaStyle.ink)
                                    Text("共 \(total) 帖")
                                        .font(NoveliaStyle.fontMicro)
                                        .monospacedDigit()
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                                .frame(minWidth: 120)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(effectivePageCount <= 1)
                            .accessibilityLabel("第 \(currentDisplayPage) 页，共 \(effectivePageCount) 页，点按跳转到指定页")
                        }
                    }

                    roundButton("chevron.right", label: "下一页", enabled: hasNext && !isLoading) {
                        NoveliaHaptics.selection()
                        onSelectPage(page + 1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(NoveliaStyle.card, in: Capsule())
                .overlay(Capsule().stroke(NoveliaStyle.hairline, lineWidth: 0.75))
                Spacer(minLength: 0)
            }

            if effectivePageCount > 1 {
                HStack(spacing: 8) {
                    Text("跳至")
                    TextField("\(currentDisplayPage)", text: $inlineJumpText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .monospacedDigit()
                        .focused($inlineJumpFocused)
                        .frame(width: 60, height: 30)
                        .noveliaCard(cornerRadius: NoveliaStyle.radiusSmall)
                        .onSubmit { submitInlineJump() }
                        .accessibilityLabel("页码")
                    Text("/ \(effectivePageCount) 页")
                    Button("跳转") { submitInlineJump() }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(canJumpInline ? .white : NoveliaStyle.muted.opacity(0.6))
                        .background(
                            canJumpInline ? NoveliaStyle.brandGreen : NoveliaStyle.card,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(canJumpInline ? Color.clear : NoveliaStyle.hairline, lineWidth: 0.75)
                        )
                        .buttonStyle(.plain)
                        .disabled(!canJumpInline || isLoading)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NoveliaStyle.muted)
                .compatKeyboardJumpToolbar(isPresented: inlineJumpFocused, action: submitInlineJump)
            }
        }
        .disabled(isLoading)
        .alert("跳转到页码", isPresented: $showsJumpAlert) {
            TextField("1–\(effectivePageCount)", text: $alertJumpText)
                .keyboardType(.numberPad)
            Button("跳转") { jump(to: alertJumpText) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(effectivePageCount) 页")
        }
    }

    private var canJumpInline: Bool {
        Int(inlineJumpText.trimmingCharacters(in: .whitespaces)) != nil
    }

    private func submitInlineJump() {
        jump(to: inlineJumpText)
        inlineJumpText = ""
        inlineJumpFocused = false
    }

    private func jump(to text: String) {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        let clamped = min(max(1, number), effectivePageCount)
        guard clamped != currentDisplayPage else { return }
        NoveliaHaptics.selection()
        onSelectPage(clamped - 1)
    }

    private func roundButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? NoveliaStyle.ink : NoveliaStyle.muted.opacity(0.35))
                .frame(width: 34, height: 34)
                .background(enabled ? NoveliaStyle.paper : Color.clear, in: Circle())
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
                    .foregroundStyle(NoveliaStyle.danger)

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
