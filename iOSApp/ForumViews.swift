import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

@MainActor
final class ForumStore: ObservableObject {
    @Published private(set) var categories: [ForumCategory] = []
    @Published private(set) var posts: [ForumPost] = []
    @Published private(set) var total: Int64 = 0
    @Published private(set) var page = 0
    @Published private(set) var isLoadingCategories = false
    @Published private(set) var isLoadingPosts = false
    @Published private(set) var errorMessage: String?
    @Published var selectedCategory = ""
    @Published var query = ""
    @Published var selectedTagID: Int64?

    var filterTags: [ForumTag] {
        guard source == .all, selectedCategory == "novel" else { return [] }
        return categories.first(where: { $0.slug == "novel" })?.tags
            .filter { ["书单", "工具", "教程", "资源"].contains($0.name) }
            .sorted { $0.sortOrder < $1.sortOrder } ?? []
    }
    @Published var sort: ForumSort = .active
    @Published var source: ForumFeedSource = .all

    private let pageSize = 20
    private var requestGeneration = 0
    private let api: ForumAPIClient

    init(api: ForumAPIClient = ForumAPIClient(tokenProvider: { NoveliaForumSessionTokenVault.read() })) {
        self.api = api
    }

    func selectCategory(_ slug: String) async {
        selectedTagID = nil
        selectedCategory = slug
        await loadPosts(page: 0)
    }

    func loadCategories() async {
        guard !isLoadingCategories else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }
        do {
            let fetched = try await api.categories().sorted { categoryOrder($0.slug) < categoryOrder($1.slug) }
            categories = fetched
            if !fetched.contains(where: { $0.slug == selectedCategory }) {
                selectedCategory = fetched.first?.slug ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPosts(page requestedPage: Int = 0) async {
        guard requestedPage >= 0 else { return }
        requestGeneration += 1
        let generation = requestGeneration
        isLoadingPosts = true
        errorMessage = nil
        defer { if generation == requestGeneration { isLoadingPosts = false } }
        do {
            let result = try await api.posts(
                page: requestedPage,
                pageSize: pageSize,
                category: selectedCategory,
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                sort: sort,
                tagID: filterTags.contains(where: { $0.id == selectedTagID }) ? selectedTagID : nil,
                source: source
            )
            guard generation == requestGeneration else { return }
            posts = result.items
            total = result.total
            page = requestedPage
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        if categories.isEmpty { await loadCategories() }
        await loadPosts(page: 0)
    }

    func clearError() {
        errorMessage = nil
    }

    func selectSource(_ value: ForumFeedSource) async {
        source = value
        selectedTagID = nil
        await loadPosts(page: 0)
    }

    private func categoryOrder(_ slug: String) -> Int {
        switch slug {
        case "announcements": 0
        case "novel": 1
        case "feedback": 2
        default: 3
        }
    }
}

struct ForumView: View {
    @EnvironmentObject private var auth: ForumAuthStore
    @StateObject private var store = ForumStore()

    init(initialCategory: String = "", initialQuery: String = "") {
        let store = ForumStore()
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
                if !store.filterTags.isEmpty {
                    HStack {
                        Text("标签").foregroundStyle(NoveliaStyle.muted)
                        Picker("标签筛选", selection: $store.selectedTagID) {
                            Text("全部标签").tag(nil as Int64?)
                            ForEach(store.filterTags) { tag in
                                Text(tag.name).tag(Optional(tag.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("forum-tag-filter")
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(NoveliaStyle.paper)
                    .onChange(of: store.selectedTagID) { _, _ in
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
                    }

                    if store.categories.isEmpty, !store.isLoadingCategories, let error = store.errorMessage {
                        ContentUnavailableView {
                            Label("论坛暂时无法访问", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { Task { await store.refresh() } }
                                .buttonStyle(.borderedProminent).tint(NoveliaStyle.brandGreen)
                        }
                        .listRowBackground(Color.clear)
                    } else if visiblePosts.isEmpty, !store.isLoadingPosts, store.errorMessage == nil {
                        ContentUnavailableView(store.posts.isEmpty ? "这里还没有帖子" : "没有匹配的帖子", systemImage: "bubble.left.and.bubble.right", description: Text("切换分类或调整搜索词。"))
                            .listRowBackground(Color.clear)
                    }

                    ForEach(visiblePosts) { post in
                        NavigationLink {
                            ForumPostDetailView(postID: post.id)
                        } label: {
                            ForumPostRow(post: post, category: store.categories.first { $0.id == post.categoryId })
                        }
                        .listRowBackground(NoveliaStyle.card)
                    }

                    if store.total > 20 {
                        HStack {
                            Button("上一页") { loadPage(max(0, store.page - 1), using: proxy) }
                                .disabled(store.page == 0 || store.isLoadingPosts)
                            Spacer()
                            Text("第 \(store.page + 1) 页 · 共 \(store.total) 帖")
                                .font(.caption).foregroundStyle(NoveliaStyle.muted)
                            Spacer()
                            Button("下一页") { loadPage(store.page + 1, using: proxy) }
                                .disabled(Int64((store.page + 1) * 20) >= store.total || store.isLoadingPosts)
                        }
                        .listRowBackground(Color.clear)
                    }
                    if store.isLoadingPosts {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                    }
                    if let error = store.errorMessage, !store.categories.isEmpty {
                        Text(error).font(.footnote).foregroundStyle(.red).listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(NoveliaStyle.paper)
                .navigationTitle("论坛")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
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
                                    auth.logout()
                                    Task { await store.selectSource(.all) }
                                }
                            } else {
                                Button("登录 Novelia", systemImage: "person.crop.circle.badge.plus") { auth.isLoginPresented = true }
                            }
                        } label: {
                            Label(auth.username ?? "我的", systemImage: "person.crop.circle")
                                .labelStyle(.iconOnly)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            ForumComposeView(categories: store.categories, initialCategorySlug: store.selectedCategory)
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("发布新帖")
                    }
                    ToolbarItem(placement: .principal) {
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
                        } label: { Text(store.sort.title).font(.subheadline.weight(.semibold)) }
                    }
                }
                .searchable(text: $store.query, prompt: "搜索论坛帖子")
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

    private var visiblePosts: [ForumPost] {
        guard store.source != .all else { return store.posts }
        let term = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.posts }
        return store.posts.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }
}

private struct ForumPostRow: View {
    let post: ForumPost
    let category: ForumCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if post.pinOrder != nil { Image(systemName: "pin.fill").foregroundStyle(NoveliaStyle.brandGreen) }
                Text(category?.title ?? "论坛")
                    .foregroundStyle(NoveliaStyle.brandGreen)
                if post.commentsLocked { Image(systemName: "lock.fill").foregroundStyle(NoveliaStyle.muted) }
                Spacer()
                Text(post.createdAt.forumDisplayDate).foregroundStyle(NoveliaStyle.muted)
            }
            .font(.caption)
            Text(post.title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(2)
            if !post.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(post.tags) { tag in
                            Text(tag.name).font(.caption2.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(NoveliaStyle.brandGreen.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Text(post.authorUsername)
                Label("\(post.commentsCount)", systemImage: "bubble.right")
                Label("\(post.viewsCount)", systemImage: "eye")
                Spacer()
                if post.favorited { Image(systemName: "bookmark.fill").foregroundStyle(NoveliaStyle.brandGreen) }
            }
            .font(.caption2).foregroundStyle(NoveliaStyle.muted)
        }
        .padding(.vertical, 7)
    }
}

private struct ForumPostDetailView: View {
    @EnvironmentObject private var auth: ForumAuthStore
    let postID: Int64
    let initialFragment: String?

    @State private var post: ForumPost?
    @State private var comments: [ForumComment] = []
    @State private var totalComments: Int64 = 0
    @State private var commentPage = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var draft = ""
    @State private var replyRoot: ForumComment?
    @State private var isComposerPresented = false
    @State private var isSending = false
    @State private var favoriteInProgress = false
    @State private var isPostEditorPresented = false
    @State private var isPreparingEdit = false
    @State private var editCategories: [ForumCategory] = []
    @State private var operationError: String?
    @State private var linkedPostRoute: ForumPostRoute?
    @State private var requestedAnchor: String?
    @State private var isLinkedPostPresented = false

    init(postID: Int64, initialFragment: String? = nil) {
        self.postID = postID
        self.initialFragment = initialFragment
        _requestedAnchor = State(initialValue: initialFragment)
    }

    private var api: ForumAPIClient { ForumAPIClient(tokenProvider: { NoveliaForumSessionTokenVault.read() }) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let post {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(post.title).font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(NoveliaStyle.ink)
                            HStack {
                                Text(post.authorUsername)
                                Spacer()
                                Text(post.createdAt.forumDisplayDate)
                            }
                            .font(.caption).foregroundStyle(NoveliaStyle.muted)
                            ForumMarkdownBody(markdown: post.content)
                            HStack {
                                Label("\(post.viewsCount) 次浏览", systemImage: "eye")
                                Label("\(post.commentsCount) 条评论", systemImage: "bubble.right")
                                Spacer()
                                if auth.username == post.authorUsername {
                                    Button { Task { await preparePostEditor() } } label: {
                                        Label("编辑", systemImage: "square.and.pencil")
                                    }
                                    .disabled(isPreparingEdit)
                                }
                                Button {
                                    guard auth.username != nil else { auth.isLoginPresented = true; return }
                                    Task { await toggleFavorite() }
                                } label: {
                                    Label(post.favorited ? "已收藏" : "收藏", systemImage: post.favorited ? "bookmark.fill" : "bookmark")
                                }
                                .disabled(favoriteInProgress)
                            }
                            .font(.caption)
                            .tint(NoveliaStyle.brandGreen)
                        }
                        .padding(16).background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 16))
                    } else if isLoading {
                        HStack { Spacer(); ProgressView("正在加载帖子…"); Spacer() }
                    } else if let errorMessage {
                        ContentUnavailableView("帖子加载失败", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                        Button("重试") { Task { await load() } }.buttonStyle(.borderedProminent).tint(NoveliaStyle.brandGreen)
                    }

                    if let post, !post.commentsLocked {
                        Button {
                            beginComment()
                        } label: {
                            Label(auth.username == nil ? "登录 Novelia后发表评论" : "发表评论", systemImage: "square.and.pencil")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .tint(NoveliaStyle.brandGreen)
                    } else if post?.commentsLocked == true {
                        Label("该帖子已关闭评论。", systemImage: "lock.fill").font(.footnote).foregroundStyle(NoveliaStyle.muted)
                    }

                    HStack {
                        Text("评论").font(.headline)
                        Spacer()
                        Text("共 \(totalComments) 条").font(.caption).foregroundStyle(NoveliaStyle.muted)
                    }
                    ForEach(comments) { comment in
                        ForumCommentCard(
                            postID: postID,
                            comment: comment,
                            onReply: {
                                guard auth.username != nil else { auth.isLoginPresented = true; return }
                                replyRoot = comment
                                draft = ""
                                isComposerPresented = true
                            },
                            onError: { operationError = $0 }
                        )
                    }
                    if totalComments > 20 {
                        HStack {
                            Button("上一页") { Task { await loadComments(page: commentPage - 1) } }
                                .disabled(commentPage == 0 || isLoading)
                            Spacer()
                            Text("第 \(commentPage + 1) 页").font(.caption).foregroundStyle(NoveliaStyle.muted)
                            Spacer()
                            Button("下一页") { Task { await loadComments(page: commentPage + 1) } }
                                .disabled(Int64((commentPage + 1) * 20) >= totalComments || isLoading)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: requestedAnchor) { _, anchor in
                guard let anchor else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            .task(id: postID) {
                await load()
                if let initialFragment, post != nil {
                    await Task.yield()
                    proxy.scrollTo(initialFragment, anchor: .top)
                }
            }
            .environment(\.openURL, OpenURLAction { url in handleForumLink(url) })
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openPostInBrowser) {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("在浏览器打开")
            }
        }
        .navigationDestination(isPresented: $isLinkedPostPresented) {
            if let linkedPostRoute {
                ForumPostDetailView(postID: linkedPostRoute.postID, initialFragment: linkedPostRoute.fragment)
            }
        }
        .sheet(isPresented: $isPostEditorPresented) {
            NavigationStack {
                if let post {
                    ForumComposeView(categories: editCategories, editingPost: post) { updated in
                        self.post = updated
                        isPostEditorPresented = false
                    }
                }
            }
        }
        .sheet(isPresented: $isComposerPresented) {
            ForumCommentEditorSheet(
                draft: $draft,
                replyTo: replyRoot?.authorUsername,
                username: auth.username ?? "",
                onCancel: { isComposerPresented = false },
                onSend: { await sendComment() }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .overlay {
            if let message = operationError ?? errorMessage {
                ForumErrorOverlay(
                    message: message,
                    onDismiss: { operationError = nil; errorMessage = nil },
                    onRetry: errorMessage == nil ? nil : { Task { await load() } }
                )
            }
        }
    }

    @MainActor
    private func preparePostEditor() async {
        guard let post, auth.username == post.authorUsername, !isPreparingEdit else { return }
        isPreparingEdit = true
        defer { isPreparingEdit = false }
        do {
            editCategories = try await api.categories()
            guard auth.username == post.authorUsername else { return }
            isPostEditorPresented = true
        } catch { operationError = error.localizedDescription }
    }

    private func openPostInBrowser() {
        guard let url = URL(string: "https://forum.novelia.cc/p/\(postID)") else { return }
        UIApplication.shared.open(url)
    }

    private func handleForumLink(_ url: URL) -> OpenURLAction.Result {
        if let fragment = url.fragment,
           isLocalForumURL(url, postID: postID) || (url.scheme == nil && url.host == nil && url.path.isEmpty) {
            requestedAnchor = fragment.removingPercentEncoding ?? fragment
            return .handled
        }
        guard let destination = forumPostDestination(from: url) else { return .systemAction }
        guard destination.postID != postID else {
            if let fragment = destination.fragment { requestedAnchor = fragment }
            return .handled
        }
        linkedPostRoute = destination
        isLinkedPostPresented = true
        return .handled
    }

    private func beginComment() {
        guard auth.username != nil else { auth.isLoginPresented = true; return }
        replyRoot = nil
        draft = ""
        isComposerPresented = true
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let fetchedPost = api.post(id: postID)
            async let fetchedComments = api.comments(postID: postID, page: 0)
            let (loadedPost, loadedComments) = try await (fetchedPost, fetchedComments)
            post = loadedPost
            comments = loadedComments.items
            totalComments = loadedComments.total
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func loadComments(page requestedPage: Int) async {
        guard requestedPage >= 0 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await api.comments(postID: postID, page: requestedPage)
            comments = result.items
            totalComments = result.total
            commentPage = requestedPage
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func sendComment() async -> String? {
        let content = forumCommentMarkdownForSubmission(draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return "请先输入评论内容。" }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await api.createComment(postID: postID, content: content, rootID: replyRoot?.replyRootID)
            draft = ""
            replyRoot = nil
            await loadComments(page: 0)
            post = try await api.post(id: postID)
            return nil
        } catch { return error.localizedDescription }
    }

    @MainActor
    private func toggleFavorite() async {
        guard let post, !favoriteInProgress else { return }
        favoriteInProgress = true
        defer { favoriteInProgress = false }
        do {
            try await api.setFavorite(postID: postID, isFavorite: !post.favorited)
            self.post = try await api.post(id: postID)
        } catch { operationError = error.localizedDescription }
    }
}

private struct ForumPostRoute: Identifiable {
    let postID: Int64
    let fragment: String?
    var id: String { "\(postID)#\(fragment ?? "")" }
}

private func forumPostDestination(from url: URL) -> ForumPostRoute? {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let host = components?.host?.lowercased()
    let isForumHost = host == "forum.novelia.cc" || host == "www.forum.novelia.cc"
    let isRelativeForumPath = host == nil && url.scheme == nil && url.path.hasPrefix("/")
    guard isForumHost || isRelativeForumPath else { return nil }
    let segments = url.path.split(separator: "/")
    guard segments.count >= 2, segments[0] == "p", let id = Int64(segments[1]) else { return nil }
    return ForumPostRoute(postID: id, fragment: components?.fragment?.removingPercentEncoding ?? components?.fragment)
}

private func isLocalForumURL(_ url: URL, postID: Int64) -> Bool {
    guard let destination = forumPostDestination(from: url) else { return false }
    return destination.postID == postID
}

/// `Text(AttributedString(markdown:))` preserves inline emphasis and links, but
/// SwiftUI's `Text` flattens Markdown block structure. Render blocks separately
/// so paragraphs, headings, lists, and quotes retain the hierarchy shown on web.
struct ForumMarkdownBody: View {
    let markdown: String
    var mode: ForumMarkdownMode = .article
    @Environment(\.openURL) private var parentOpenURL
    @State private var novelRoute: ForumNovelRoute?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parseForumMarkdown(markdown, mode: mode)) { block in
                blockView(block)
                    .id(block.anchor ?? "forum-block-\(block.id)")
            }
        }
        .foregroundStyle(NoveliaStyle.ink)
        .tint(NoveliaStyle.brandGreen)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(mode == .comment ? .system(size: 14) : .system(size: 15))
        .environment(\.openURL, OpenURLAction { url in
            if let route = ForumNovelRoute(url: url) { novelRoute = route; return .handled }
            parentOpenURL(url)
            return .handled
        })
        .background {
            // The body is used inside lazy comment stacks. A local hidden link
            // pushes directly without registering a destination in a lazy child.
            NavigationLink(isActive: Binding(
                get: { novelRoute != nil },
                set: { if !$0 { novelRoute = nil } }
            )) {
                if let route = novelRoute {
                    if route.isCatalogue {
                        DiscoverView()
                    } else if let provider = route.provider {
                        NovelDetailView(novel: Novel(id: "\(provider)/\(route.novelID)", title: "正在加载…", author: "", summary: "", genres: [], chapters: [], accent: .ocean, providerId: provider, novelId: route.novelID))
                    } else {
                        WenkuDetailView(outline: route.outline)
                    }
                }
            } label: { EmptyView() }
            .hidden()
        }
    }

    @ViewBuilder
    private func blockView(_ block: ForumMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            ForumInlineMarkdownText(markdown: block.text, baseSize: mode == .comment ? 14 : 15)
        case let .heading(level):
            ForumInlineMarkdownText(markdown: block.text, baseSize: CGFloat(headingSize(level)), bold: true)
                .font(.system(size: headingSize(level), weight: .bold, design: .rounded))
                .padding(.top, level <= 2 ? 5 : 2)
        case .unorderedItem:
            listRow(marker: "•", text: block.text)
        case let .orderedItem(number):
            listRow(marker: "\(number).", text: block.text)
        case .quote:
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(NoveliaStyle.muted.opacity(0.45)).frame(width: 3)
                ForumInlineMarkdownText(markdown: block.text, baseSize: mode == .comment ? 14 : 15, textColor: NoveliaStyle.muted).foregroundStyle(NoveliaStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 4)
        case .code:
            Text(block.text)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: 8))
        case let .table(rows):
            ForumMarkdownTable(rows: rows, mode: mode)
        case .divider:
            Rectangle().fill(NoveliaStyle.muted.opacity(0.25)).frame(height: 1).padding(.vertical, 5)
        case let .starRating(value):
            ForumStarRating(value: value)
        case let .details(title):
            ForumDetailsBlock(title: title, content: block.text, mode: mode)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).font(.system(size: 15, weight: .semibold)).frame(minWidth: 18, alignment: .trailing)
            ForumInlineMarkdownText(markdown: text, baseSize: mode == .comment ? 14 : 15)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 5)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 22
        case 2: 20
        case 3: 18
        default: 16
        }
    }
}

/// Keep category controls in the normal stack above List instead of a dynamic
/// safe-area inset, so changing feeds cannot leave a stale collapsed inset.
private struct ForumCategoryBar: View {
    let categories: [ForumCategory]
    let selectedCategory: String
    let isVisible: Bool
    let onSelect: (ForumCategory) -> Void

    private var isShown: Bool { isVisible && !categories.isEmpty }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(categories) { category in
                    Button { onSelect(category) } label: {
                        Text(category.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selectedCategory == category.slug ? .white : NoveliaStyle.ink)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selectedCategory == category.slug ? NoveliaStyle.brandGreen : NoveliaStyle.card, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(height: isShown ? 56 : 0)
        .clipped()
        .background(NoveliaStyle.paper)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }
}

/// A bounded text width lets each row grow vertically instead of truncating
/// cells under the horizontal scroll view's unconstrained width proposal.
private struct ForumMarkdownTable: View {
    let rows: [[String]]
    let mode: ForumMarkdownMode

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    ForumTableRowLayout {
                        ForEach(rows[row].indices, id: \.self) { column in
                            ForumInlineMarkdownText(markdown: rows[row][column], baseSize: mode == .comment ? 14 : 15, bold: row == 0)
                                .fontWeight(row == 0 ? .semibold : .regular)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .frame(width: 220, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .background(row == 0 ? NoveliaStyle.paper : NoveliaStyle.card)
                                .overlay(Rectangle().stroke(NoveliaStyle.muted.opacity(0.25)))
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("forum-table-cell-\(row)-\(column)")
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        // Keep the vertical origin at the top when a tall table exceeds its viewport.
        .defaultScrollAnchor(.topLeading)
        .accessibilityIdentifier("forum-markdown-table")
    }
}

/// Measure each row independently so expanded cell backgrounds cannot alter
/// the text origin or borrow height from another row.
private struct ForumTableRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 240, height: nil)) }
        return CGSize(width: CGFloat(subviews.count) * 240, height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * 240, y: bounds.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(width: 240, height: bounds.height))
        }
    }
}

private struct ForumInlineMarkdownText: View {
    let markdown: String
    var baseSize: CGFloat = 15
    var bold = false
    var textColor = NoveliaStyle.ink
    @State private var spoilersRevealed = false

    private var spoilerPattern: NSRegularExpression {
        (try? NSRegularExpression(pattern: "!!!!([\\s\\S]+?)!!!!|!!([\\s\\S]+?)!!"))
            ?? (try! NSRegularExpression(pattern: "a^"))
    }

    private var hasSpoilers: Bool {
        !forumSpoilerMatches(forumSpoilerMarkdown(markdown), pattern: spoilerPattern).isEmpty
    }

    var body: some View {
        if hasSpoilers && !spoilersRevealed {
            Text(renderInlineMarkdown(markdown, spoilersRevealed: false, pattern: spoilerPattern))
                .onTapGesture { spoilersRevealed = true }
        } else if hasSpoilers {
            ForumRevealedSpoilerText(
                text: renderInlineMarkdown(markdown, spoilersRevealed: true, pattern: spoilerPattern),
                baseSize: baseSize, bold: bold, textColor: textColor
            )
        } else {
            Text(renderInlineMarkdown(markdown, spoilersRevealed: true, pattern: spoilerPattern))
        }
    }
}

/// Use TextKit's explicit link interaction after revealing instead of reusing
/// SwiftUI's selectable Text backing view that previously handled reveal taps.
private struct ForumRevealedSpoilerText: UIViewRepresentable {
    let text: AttributedString
    let baseSize: CGFloat
    let bold: Bool
    let textColor: Color
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        view.attributedText = forumSpoilerNativeText(text, baseSize: baseSize, bold: bold, textColor: textColor)
        view.linkTextAttributes = [
            .foregroundColor: UIColor(NoveliaStyle.brandGreen),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL(url) }
        }
    }
}

private func forumSpoilerNativeText(_ text: AttributedString, baseSize: CGFloat, bold: Bool, textColor: Color) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    for run in text.runs {
        var traits: UIFontDescriptor.SymbolicTraits = bold ? [.traitBold] : []
        if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
        if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
        let base = run.inlinePresentationIntent?.contains(.code) == true
            ? UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            : UIFont.systemFont(ofSize: baseSize)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(descriptor: descriptor, size: baseSize))
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(textColor)]
        if let url = run.link { attributes[.link] = url }
        if run.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        result.append(NSAttributedString(string: String(text.characters[run.range]), attributes: attributes))
    }
    return result
}

private func forumSpoilerMarkdown(_ markdown: String) -> String {
    // Keep the entire link inside the reveal span when its label is spoiled.
    guard let links = try? NSRegularExpression(pattern: "\\[((?:!!!!|!!))([^\\]]+?)\\1\\]\\(([^)]+)\\)") else { return markdown }
    let source = markdown as NSString
    let codeRanges = forumInlineCodeRanges(markdown)
    let result = NSMutableString(string: markdown)
    for match in links.matches(in: markdown, range: NSRange(location: 0, length: source.length)).reversed() {
        guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
        let marker = source.substring(with: match.range(at: 1))
        let label = source.substring(with: match.range(at: 2))
        let target = source.substring(with: match.range(at: 3))
        result.replaceCharacters(in: match.range, with: "\(marker)[\(label)](\(target))\(marker)")
    }
    return result as String
}

private func forumInlineCodeRanges(_ markdown: String) -> [NSRange] {
    let code = try? NSRegularExpression(pattern: "(?<!`)(`+)(?!`)[\\s\\S]*?(?<!`)\\1(?!`)")
    return code?.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).map(\.range) ?? []
}

private func forumSpoilerMatches(_ markdown: String, pattern: NSRegularExpression) -> [NSTextCheckingResult] {
    let codeRanges = forumInlineCodeRanges(markdown)
    return pattern.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).filter { match in
        !codeRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
    }
}

private func renderInlineMarkdown(_ markdown: String, spoilersRevealed: Bool, pattern: NSRegularExpression) -> AttributedString {
    let normalized = forumSpoilerMarkdown(markdown)
    let ns = normalized as NSString
    let matches = forumSpoilerMatches(normalized, pattern: pattern)
    var result = AttributedString()
    var cursor = 0
    for match in matches {
        let capturedRange = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
        guard capturedRange.location != NSNotFound else { continue }
        let spoilerRange = capturedRange
        let markerRange = NSRange(location: match.range.location, length: spoilerRange.location - match.range.location)
        if markerRange.location > cursor {
            result += (try? forumInlineAttributes(ns.substring(with: NSRange(location: cursor, length: markerRange.location - cursor))))
                ?? AttributedString(ns.substring(with: NSRange(location: cursor, length: markerRange.location - cursor)))
        }
        var spoiler = (try? forumInlineAttributes(ns.substring(with: spoilerRange))) ?? AttributedString(ns.substring(with: spoilerRange))
        if !spoilersRevealed {
            // Concealed content cannot open invisible links; revealing restores
            // the original Markdown link attributes on the next render.
            spoiler.link = nil
            spoiler.foregroundColor = .clear
            spoiler.backgroundColor = NoveliaStyle.ink.opacity(0.78)
        }
        result += spoiler
        cursor = NSMaxRange(match.range)
    }
    if cursor < ns.length {
        let tail = ns.substring(from: cursor)
        result += (try? forumInlineAttributes(tail)) ?? AttributedString(tail)
    }
    return result
}

private struct ForumStarRating: View {
    let value: Double
    private let green = Color(red: 79 / 255, green: 178 / 255, blue: 51 / 255)
    private var rating: Double { min(5, max(0, (value * 2).rounded() / 2)) }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...5, id: \.self) { index in
                let symbol = Double(index) <= rating ? "star.fill" : (Double(index) - 0.5 <= rating ? "star.leadinghalf.filled" : "star")
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(symbol == "star" ? Color.gray.opacity(0.38) : green)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("评分 \(rating.formatted(.number.precision(.fractionLength(0...1)))) / 5 星")
    }
}

private struct ForumDetailsBlock: View {
    let title: String
    let content: String
    let mode: ForumMarkdownMode
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForumMarkdownBody(markdown: content, mode: mode)
                .padding(.top, 8)
        } label: {
            Text(title.isEmpty ? "点击展开" : title).font(.system(size: 14, weight: .semibold))
        }
        .tint(NoveliaStyle.brandGreen)
        .padding(11)
        .background(NoveliaStyle.paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NoveliaStyle.muted.opacity(0.2), lineWidth: 1))
    }
}

enum ForumMarkdownMode {
    case article
    case comment
}

private func forumCommentMarkdownForSubmission(_ markdown: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "!!!!([\\s\\S]+?)!!!!") else { return markdown }
    let range = NSRange(markdown.startIndex..., in: markdown)
    return regex.stringByReplacingMatches(in: markdown, range: range, withTemplate: "!!$1!!")
}

private struct ForumComposeNotice: View {
    let isPost: Bool
    @Environment(\.openURL) private var parentOpenURL
    @State private var destination: ForumNoticeDestination?

    private var markdown: String {
        if !isPost { return "发言请遵守 [社区守则](https://forum.novelia.cc/rules)。" }
        return """
        - 提问前先阅读 [站务公告](https://forum.novelia.cc/c/announcements) 的新人教程，再搜索 [意见反馈](https://forum.novelia.cc/c/feedback) 中的相同案例，避免重复发帖。
        - 报错请详述问题，并附小说链接或截图。
        - 求书请前往 [求书集中帖](https://forum.novelia.cc/c/novel?q=%E6%B1%82%E4%B9%A6%E9%9B%86%E4%B8%AD%E8%B4%B4)，请勿单独发帖。
        - 碰到此类建政小说时，不要在论坛发帖或群里讨论，请通过 QQ 或 Telegram 私信管理员处理。
        - 发言请遵守 [社区守则](https://forum.novelia.cc/rules)。
        """
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(NoveliaStyle.brandGreen)
            ForumMarkdownBody(markdown: markdown, mode: .article)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(NoveliaStyle.brandGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.openURL, OpenURLAction { url in
            guard let route = ForumNoticeDestination(url: url) else {
                parentOpenURL(url)
                return .handled
            }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            destination = route
            return .handled
        })
        .background {
            NavigationLink(isActive: Binding(
                get: { destination != nil },
                set: { if !$0 { destination = nil } }
            )) {
                if let destination {
                    switch destination {
                    case let .category(slug, query): ForumView(initialCategory: slug, initialQuery: query)
                    case .rules: ForumRulesView()
                    }
                }
            } label: { EmptyView() }
            .hidden()
        }
    }
}

private enum ForumNoticeDestination: Equatable {
    case category(String, String)
    case rules

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "forum.novelia.cc",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        let segments = components.path.split(separator: "/")
        if segments == ["rules"] { self = .rules; return }
        guard segments.count == 2, segments[0] == "c",
              ["announcements", "feedback", "novel"].contains(String(segments[1])) else { return nil }
        self = .category(String(segments[1]), components.queryItems?.first(where: { $0.name == "q" })?.value ?? "")
    }
}

private struct ForumRulesView: View {
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            ForumRulesWebView(onFinish: { isLoading = false }, onError: {
                isLoading = false
                errorMessage = $0
            })
            .id(reloadID)
            if isLoading { ProgressView("正在加载社区守则…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            if let errorMessage {
                ContentUnavailableView {
                    Label("社区守则加载失败", systemImage: "wifi.exclamationmark")
                } description: { Text(errorMessage) } actions: {
                    Button("重试") { self.errorMessage = nil; isLoading = true; reloadID = UUID() }
                }
                .background(NoveliaStyle.paper)
            }
        }
        .navigationTitle("社区守则")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ForumRulesWebView: UIViewRepresentable {
    var onFinish: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://forum.novelia.cc/rules")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ForumRulesWebView
        init(parent: ForumRulesWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.onFinish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.onError(error.localizedDescription) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.onError(error.localizedDescription) }
    }
}

private struct ForumMarkdownHelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let examples: [(String, String)] = [
        ("加粗、斜体与删除线", "**加粗文字**\n*斜体文字*\n~~删除线文字~~"),
        ("链接", "[链接文字](https://n.novelia.cc/)"),
        ("剧透", "!!剧透内容!!"),
        ("标题与引用", "## 二级标题\n> 引用内容"),
        ("列表", "- 第一项\n- 第二项\n\n1. 第一项\n2. 第二项"),
        ("表格", "| 名称 | 说明 |\n| --- | --- |\n| 示例 | 内容 |"),
        ("星级评分", "::: star 4.5"),
        ("折叠内容", "::: details 点击展开\n折叠内容\n:::"),
        ("代码", "`行内代码`\n\n```\n代码块\n```")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选中文字后点击格式按钮，可为选中内容添加标记；没有选中文字时会插入示例。切换到预览查看效果，返回编辑可继续修改。")
                }
                ForEach(examples.indices, id: \.self) { index in
                    Section(examples[index].0) {
                        Text(examples[index].1)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Markdown 语法帮助")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

private struct ForumCommentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: String
    let replyTo: String?
    let username: String
    let onCancel: () -> Void
    let onSend: () async -> String?

    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 12) {
                HStack {
                    if let replyTo {
                        Label("回复 @\(replyTo)", systemImage: "arrowshape.turn.up.left")
                    } else {
                        Label("发表评论", systemImage: "bubble.left")
                    }
                    Spacer()
                    Text("以 \(username) 的身份")
                        .font(.caption)
                        .foregroundStyle(NoveliaStyle.muted)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NoveliaStyle.ink)

                ForumComposeNotice(isPost: false)
                ForumMarkdownEditor(draft: $draft, autoFocus: true)
                    .disabled(isSending)
                Spacer(minLength: 0)
            }
            .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .overlay {
                if let sendError {
                    ForumErrorOverlay(message: sendError, onDismiss: { self.sendError = nil })
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button("取消") { onCancel(); dismiss() }.disabled(isSending)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSending { ProgressView().tint(.white) }
                        else { Label("发送", systemImage: "paperplane.fill") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
            .navigationTitle(replyTo == nil ? "发表评论" : "回复评论")
            .navigationBarTitleDisplayMode(.inline)

        }
    }

    @MainActor
    private func submit() async {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }
        if let error = await onSend() {
            sendError = error
        } else {
            dismiss()
        }
    }
}

private struct ForumMarkdownEditor: View {
    @Binding var draft: String
    var mode: ForumMarkdownMode = .comment
    var minimumHeight: CGFloat = 190
    var autoFocus = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var isPreviewing = false
    @State private var sendError: String?
    @State private var isHelpPresented = false
    @State private var isLinkDialogPresented = false
    @State private var linkLabel = ""
    @State private var linkURL = "https://"
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                Picker("编辑模式", selection: $isPreviewing) {
                    Text("编辑").tag(false)
                    Text("预览").tag(true)
                }
                .pickerStyle(.segmented)

                Group {
                    if isPreviewing {
                        ScrollView {
                            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("预览内容会显示在这里。")
                                    .foregroundStyle(NoveliaStyle.muted)
                                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                            } else {
                                ForumMarkdownBody(markdown: draft, mode: mode)
                                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                            }
                        }
                        .frame(height: minimumHeight)
                        .padding(12)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ZStack(alignment: .topLeading) {
                            ForumMarkdownTextEditor(text: $draft, selection: $selection)
                                .focused($isEditorFocused)
                                .frame(height: minimumHeight)
                            if draft.isEmpty {
                                Text("支持 Markdown，可使用下方工具栏插入格式。")
                                    .font(.system(size: 15))
                                    .foregroundStyle(NoveliaStyle.muted.opacity(0.75))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(8)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                if !isPreviewing { formattingToolbar }
            Button { isHelpPresented = true } label: {
                Label("Markdown 语法帮助", systemImage: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
        .sheet(isPresented: $isHelpPresented) { ForumMarkdownHelpView() }
        .onChange(of: isPreviewing) { _, preview in if preview { isEditorFocused = false } }
        .overlay {
            if let sendError { ForumErrorOverlay(message: sendError, onDismiss: { self.sendError = nil }) }
        }
            .onAppear { isEditorFocused = autoFocus }
            .alert("插入链接", isPresented: $isLinkDialogPresented) {
                TextField("链接文字", text: $linkLabel)
                TextField("https://example.com", text: $linkURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("取消", role: .cancel) {}
                Button("插入") { insertLink() }
            } message: {
                Text("链接将以 [链接文字](https://example.com) 的格式插入。")
            }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    isEditorFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }

    private var formattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                formatButton("粗体", icon: "bold") { wrapSelection(prefix: "**", suffix: "**", placeholder: "粗体文字") }
                formatButton("斜体", icon: "italic") { wrapSelection(prefix: "*", suffix: "*", placeholder: "斜体文字") }
                formatButton("删除线", icon: "strikethrough") { wrapSelection(prefix: "~~", suffix: "~~", placeholder: "删除的文字") }
                formatButton("链接", icon: "link") {
                    let value = selectedText
                    linkLabel = value.isEmpty ? "链接文字" : value
                    linkURL = "https://"
                    isEditorFocused = false
                    isLinkDialogPresented = true
                }
                formatButton("剧透", icon: "eye.slash") { wrapSelection(prefix: "!!", suffix: "!!", placeholder: "剧透内容") }
                Menu {
                    ForEach(1...10, id: \.self) { step in
                        let rating = Double(step) / 2
                        Button("\(rating.formatted(.number.precision(.fractionLength(0...1)))) 星") {
                            insertMarkdownBlock("::: star \(rating.formatted(.number.precision(.fractionLength(0...1))))")
                        }
                    }
                } label: {
                    Label("星级", systemImage: "star.leadinghalf.filled")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(NoveliaStyle.card, in: Capsule())
                }
                .accessibilityLabel("插入星级评分")
                formatButton("折叠", icon: "rectangle.compress.vertical") { insertDetails() }
            }
            .padding(.vertical, 2)
        }
        .tint(NoveliaStyle.brandGreen)
    }

    private var selectedText: String {
        let source = draft as NSString
        guard selection.location != NSNotFound, selection.location + selection.length <= source.length else { return "" }
        return source.substring(with: selection)
    }

    private func formatButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(NoveliaStyle.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let source = draft as NSString
        let safeLocation = selection.location == NSNotFound ? source.length : min(selection.location, source.length)
        let safeLength = min(selection.length, source.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)
        let selected = source.substring(with: range)
        let content = selected.isEmpty ? placeholder : selected
        let replacement = prefix + content + suffix
        draft = source.replacingCharacters(in: range, with: replacement)
        selection = NSRange(location: range.location + (prefix as NSString).length,
                            length: selected.isEmpty ? (content as NSString).length : 0)
        isEditorFocused = true
    }

    private func insertLink() {
        let label = linkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              let components = URLComponents(string: rawURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else {
            sendError = "请输入有效的 HTTP 或 HTTPS 链接和链接文字。"
            return
        }
        insertBlock("[\(label.replacingOccurrences(of: "]", with: "\\]"))](\(rawURL))")
        isLinkDialogPresented = false
    }

    private func insertDetails() {
        let template = "::: details 点击展开\n折叠内容\n:::\n"
        insertMarkdownBlock(template, selecting: "折叠内容")
    }

    private func insertMarkdownBlock(_ block: String, selecting selected: String? = nil) {
        let source = draft as NSString
        let safeLocation = selection.location == NSNotFound ? source.length : min(selection.location, source.length)
        let safeLength = min(selection.length, source.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)
        let prefixSource = source.substring(to: safeLocation)
        let suffixSource = source.substring(from: NSMaxRange(range))
        let prefix = safeLocation == 0 || prefixSource.hasSuffix("\n\n") ? "" : (prefixSource.hasSuffix("\n") ? "\n" : "\n\n")
        let suffix = NSMaxRange(range) == source.length || suffixSource.hasPrefix("\n\n")
            ? "\n"
            : (suffixSource.hasPrefix("\n") ? "\n" : "\n\n")
        let insertion = prefix + block + suffix
        let replacement = source.replacingCharacters(in: range, with: insertion)
        let insertionStart = safeLocation + (prefix as NSString).length
        draft = replacement
        if let selected {
            let searchRange = NSRange(location: insertionStart, length: (block as NSString).length)
            let selectedRange = (replacement as NSString).range(of: selected, options: [], range: searchRange)
            selection = selectedRange.location == NSNotFound
                ? NSRange(location: insertionStart + (block as NSString).length, length: 0)
                : selectedRange
        } else {
            selection = NSRange(location: insertionStart + (block as NSString).length, length: 0)
        }
        isEditorFocused = true
    }

    private func insertBlock(_ value: String, selecting selected: String? = nil) {
        let source = draft as NSString
        let safeLocation = selection.location == NSNotFound ? source.length : min(selection.location, source.length)
        let safeLength = min(selection.length, source.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)
        let replacement = source.replacingCharacters(in: range, with: value)
        draft = replacement
        if let selected {
            let insertionRange = NSRange(location: safeLocation, length: (value as NSString).length)
            let selectedRange = (replacement as NSString).range(of: selected, options: [], range: insertionRange)
            selection = selectedRange.location == NSNotFound
                ? NSRange(location: safeLocation + (value as NSString).length, length: 0)
                : selectedRange
        } else {
            selection = NSRange(location: safeLocation + (value as NSString).length, length: 0)
        }
        isEditorFocused = true
    }

}

private struct ForumMarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, selection: $selection) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.textColor = UIColor.label
        view.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityLabel = "Markdown 正文"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.selection = $selection
        if view.text != text { view.text = text }
        if view.selectedRange != selection { view.selectedRange = selection }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var selection: Binding<NSRange>

        init(text: Binding<String>, selection: Binding<NSRange>) {
            self.text = text
            self.selection = selection
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            selection.wrappedValue = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection.wrappedValue = textView.selectedRange
        }
    }
}

private struct ForumMarkdownBlock: Identifiable {
    enum Kind {
        case paragraph
        case heading(Int)
        case unorderedItem
        case orderedItem(Int)
        case quote
        case code
        case divider
        case table([[String]])
        case starRating(Double)
        case details(String)
    }

    let id: Int
    let kind: Kind
    let text: String
    let anchor: String?
}

private func parseForumMarkdown(_ markdown: String, mode: ForumMarkdownMode = .article) -> [ForumMarkdownBlock] {
    var blocks: [ForumMarkdownBlock] = []
    var paragraph: [String] = []
    var codeLines: [String] = []
    var inCodeFence = false
    var headingAnchorCounts: [String: Int] = [:]

    func append(_ kind: ForumMarkdownBlock.Kind, _ text: String, anchor: String? = nil) {
        blocks.append(ForumMarkdownBlock(id: blocks.count, kind: kind, text: text, anchor: anchor))
    }
    func flushParagraph() {
        let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { append(.paragraph, text) }
        paragraph.removeAll(keepingCapacity: true)
    }

    let lines = markdown.components(separatedBy: .newlines)
    var index = 0
    while index < lines.count {
        let rawLine = lines[index]
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if (line.hasPrefix("```") || line.hasPrefix("~~~")) {
            flushParagraph()
            if inCodeFence {
                append(.code, codeLines.joined(separator: "\n"))
                codeLines.removeAll(keepingCapacity: true)
                inCodeFence = false
            } else {
                inCodeFence = true
            }
            index += 1
            continue
        }
        if inCodeFence {
            codeLines.append(rawLine)
            index += 1
            continue
        }
        if let details = line.firstMatch(of: /^:::\s*details(?:\s+(.*))?$/) {
            flushParagraph()
            let title = String(details.1 ?? "")
            index += 1
            var content: [String] = []
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != ":::" {
                content.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }
            append(.details(title), content.joined(separator: "\n"))
            continue
        }
        if let star = line.firstMatch(of: /^:::\s*star\s+([0-9]+(?:\.[0-9]+)?)\s*$/),
           let value = Double(star.1) {
            flushParagraph()
            append(.starRating(min(5, max(0, value))), "")
            index += 1
            if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == ":::" { index += 1 }
            continue
        }
        if index + 1 < lines.count, line.contains("|"),
           forumTableCells(lines[index + 1]).allSatisfy({ $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }),
           !forumTableCells(lines[index + 1]).isEmpty,
           forumTableCells(rawLine).count == forumTableCells(lines[index + 1]).count {
            flushParagraph()
            let header = forumTableCells(rawLine)
            var rows = [header]
            index += 2
            while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let cells = forumTableCells(lines[index])
                rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
                index += 1
            }
            append(.table(rows), "")
            continue
        }
        if line.isEmpty {
            flushParagraph()
            index += 1
            continue
        }
        if mode == .article, let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
            flushParagraph()
            let title = String(match.2)
            let baseAnchor = forumHeadingSlug(title)
            let duplicateCount = headingAnchorCounts[baseAnchor, default: 0]
            headingAnchorCounts[baseAnchor] = duplicateCount + 1
            let anchor = duplicateCount == 0 ? baseAnchor : "\(baseAnchor)-\(duplicateCount)"
            append(.heading(match.1.count), title, anchor: anchor)
        } else if mode == .article, let match = line.firstMatch(of: /^[-+*]\s+(.+)$/) {
            flushParagraph()
            append(.unorderedItem, String(match.1))
        } else if mode == .article, let match = line.firstMatch(of: /^(\d+)[.)]\s+(.+)$/), let number = Int(match.1) {
            flushParagraph()
            append(.orderedItem(number), String(match.2))
        } else if mode == .article, let match = line.firstMatch(of: /^>\s?(.*)$/) {
            flushParagraph()
            append(.quote, String(match.1))
        } else if mode == .article, isForumMarkdownDivider(line) {
            flushParagraph()
            append(.divider, "")
        } else {
            paragraph.append(line)
        }
        index += 1
    }
    flushParagraph()
    if inCodeFence, !codeLines.isEmpty { append(.code, codeLines.joined(separator: "\n")) }
    return blocks
}

private func isForumMarkdownDivider(_ line: String) -> Bool {
    let compact = line.filter { !$0.isWhitespace }
    guard compact.count >= 3, let marker = compact.first, "-*_".contains(marker) else { return false }
    return compact.allSatisfy { $0 == marker }
}

private func forumHeadingSlug(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: "-")
}

private struct ForumCommentCard: View {
    let postID: Int64
    let comment: ForumComment
    let onReply: () -> Void
    let onError: (String) -> Void
    @State private var extraReplies: [ForumComment] = []
    @State private var isLoadingReplies = false

    private var initialReplies: [ForumComment] { comment.replies?.items ?? [] }
    private var allReplies: [ForumComment] { initialReplies + extraReplies }
    private var api: ForumAPIClient { ForumAPIClient(tokenProvider: { NoveliaForumSessionTokenVault.read() }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(comment.authorUsername).font(.caption.weight(.bold))
                Spacer()
                Text(comment.createdAt.forumDisplayDate).font(.caption2).foregroundStyle(NoveliaStyle.muted)
            }
            ForumMarkdownBody(markdown: comment.content, mode: .comment)
            Button("回复") { onReply() }.font(.caption.weight(.semibold)).tint(NoveliaStyle.brandGreen)
            ForEach(allReplies) { reply in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(NoveliaStyle.brandGreen.opacity(0.4)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(reply.authorUsername).font(.caption2.weight(.bold))
                            Spacer()
                            Text(reply.createdAt.forumDisplayDate).font(.caption2).foregroundStyle(NoveliaStyle.muted)
                        }
                        ForumMarkdownBody(markdown: reply.content, mode: .comment)
                    }
                }
            }
            if let count = comment.replyCount, Int64(allReplies.count) < count {
                Button {
                    Task { await loadMoreReplies() }
                } label: {
                    if isLoadingReplies { ProgressView().controlSize(.small) }
                    else { Text("加载更多回复（剩余 \(count - Int64(allReplies.count)) 条）") }
                }
                .font(.caption.weight(.semibold)).tint(NoveliaStyle.brandGreen).disabled(isLoadingReplies)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }

    @MainActor
    private func loadMoreReplies() async {
        guard !isLoadingReplies else { return }
        isLoadingReplies = true
        defer { isLoadingReplies = false }
        do {
            let result = try await api.replies(postID: postID, rootID: comment.id, page: allReplies.count / 20)
            let known = Set(allReplies.map(\.id))
            extraReplies.append(contentsOf: result.items.filter { !known.contains($0.id) })
        } catch {
            onError(error.localizedDescription)
        }
    }
}

private struct ForumErrorOverlay: View {
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

private struct ForumComposeView: View {
    @EnvironmentObject private var auth: ForumAuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var categories: [ForumCategory]
    @State private var isLoadingCategories = false
    let initialCategorySlug: String
    let editingPost: ForumPost?
    var onSaved: ((ForumPost) -> Void)?

    @State private var selectedCategoryID: Int64?
    @State private var title = ""
    @State private var content = ""
    @State private var selectedTagIDs: Set<Int64> = []
    @State private var isSending = false
    @State private var errorMessage: String?

    private var selectedCategory: ForumCategory? { categories.first { $0.id == selectedCategoryID } }
    private var api: ForumAPIClient { ForumAPIClient(tokenProvider: { NoveliaForumSessionTokenVault.read() }) }

    init(categories: [ForumCategory], initialCategorySlug: String = "novel", editingPost: ForumPost? = nil, onSaved: ((ForumPost) -> Void)? = nil) {
        _categories = State(initialValue: categories)
        self.initialCategorySlug = initialCategorySlug
        self.editingPost = editingPost
        self.onSaved = onSaved
        _selectedCategoryID = State(initialValue: editingPost?.categoryId ?? categories.first(where: { $0.slug == initialCategorySlug })?.id ?? categories.first?.id)
        _title = State(initialValue: editingPost?.title ?? "")
        _content = State(initialValue: editingPost?.content ?? "")
        _selectedTagIDs = State(initialValue: Set(editingPost?.tags.map(\.id) ?? []))
    }

    private var canSubmit: Bool {
        guard let username = auth.username else { return false }
        return editingPost.map { $0.authorUsername == username } ?? true
    }

    var body: some View {
        Form {
            Section { ForumComposeNotice(isPost: true) }
            if auth.username == nil {
                Section {
                    Button("登录 Novelia后发布") { auth.isLoginPresented = true }
                } footer: {
                    Text("登录后会保留当前正在编写的内容。")
                }
            }
            Section("分类") {
                if categories.isEmpty {
                    if isLoadingCategories { ProgressView("正在读取分类…") }
                    else { Button("重新加载分类与标签") { Task { await loadEditorCategories() } } }
                } else {
                    Picker("发布到", selection: $selectedCategoryID) {
                        ForEach(categories) { category in
                            Text(category.title).tag(Optional(category.id))
                        }
                    }
                }
            }
            if let tags = selectedCategory?.tags, !tags.isEmpty {
                Section("标签（最多选择 3 个）") {
                    ForEach(tags.sorted { $0.sortOrder < $1.sortOrder }) { tag in
                        Toggle(tag.name, isOn: Binding(
                            get: { selectedTagIDs.contains(tag.id) },
                            set: { enabled in
                                if enabled, selectedTagIDs.count < 3 { selectedTagIDs.insert(tag.id) }
                                else { selectedTagIDs.remove(tag.id) }
                            }
                        ))
                    }
                }
            }
            Section("标题") {
                TextField("帖子标题（2–100 字）", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("forum-post-title")
            }
            Section("正文") {
                ForumMarkdownEditor(draft: $content, mode: .article, minimumHeight: 240)
            }
            Section {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await publish() }
                } label: {
                    HStack {
                        Spacer()
                        if isSending { ProgressView() } else { Text(editingPost == nil ? "发布帖子" : "保存修改") }
                        Spacer()
                    }
                }
                .disabled(!canSubmit || selectedCategoryID == nil || !validInput || isSending)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await loadEditorCategories() }
        .disabled(isSending)
        .scrollContentBackground(.hidden)
        .background(NoveliaStyle.paper)
        .navigationTitle(editingPost == nil ? "新建帖子" : "编辑帖子")
        .interactiveDismissDisabled(isSending)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedCategoryID) { _, _ in selectedTagIDs.removeAll() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if editingPost != nil { Button("取消") { dismiss() }.disabled(isSending) }
            }
            ToolbarItem(placement: .topBarTrailing) { if isSending { ProgressView() } }
        }
        .overlay {
            if let errorMessage {
                ForumErrorOverlay(message: errorMessage, onDismiss: { self.errorMessage = nil })
            }
        }
    }

    @MainActor
    private func loadEditorCategories() async {
        guard !isLoadingCategories else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }
        do {
            let fetched = try await api.categories()
            categories = fetched
            if selectedCategoryID == nil { selectedCategoryID = fetched.first(where: { $0.slug == initialCategorySlug })?.id ?? fetched.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private var validInput: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2...100).contains(cleanTitle.unicodeScalars.count) && (1...20_000).contains(cleanBody.unicodeScalars.count)
    }

    @MainActor
    private func publish() async {
        guard let selectedCategoryID, canSubmit, validInput, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved: ForumPost
            if let editingPost {
                saved = try await api.updatePost(id: editingPost.id, categoryID: selectedCategoryID,
                    title: cleanTitle, content: content, tagIDs: Array(selectedTagIDs))
            } else {
                saved = try await api.createPost(categoryID: selectedCategoryID,
                    title: cleanTitle, content: content.trimmingCharacters(in: .whitespacesAndNewlines), tagIDs: Array(selectedTagIDs))
            }
            onSaved?(saved)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension String {
    var forumDisplayDate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: self) ?? ISO8601DateFormatter().date(from: self)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? self
    }
}

private func forumTableCells(_ line: String) -> [String] {
    var cells: [String] = []
    var cell = ""
    var escaped = false
    var inCode = false
    for character in line.trimmingCharacters(in: .whitespaces) {
        if escaped { cell.append(character); escaped = false; continue }
        if character == "\\" { escaped = true; cell.append(character); continue }
        if character == "`" { inCode.toggle() }
        if character == "|", !inCode { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
        else { cell.append(character) }
    }
    cells.append(cell.trimmingCharacters(in: .whitespaces))
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
    if trimmed.hasSuffix("|"), cells.last == "" { cells.removeLast() }
    return cells
}

private func forumInlineAttributes(_ input: String) throws -> AttributedString {
    // Normalize a struck link label before splitting strike spans, preserving
    // the complete Markdown link for Foundation's parser.
    let text = input.replacingOccurrences(of: "\\[~~([^\\]]+?)~~\\]\\(([^)]+)\\)", with: "~~[$1]($2)~~", options: .regularExpression)
        .replacingOccurrences(of: "</?(?:del|s|strike)>", with: "~~", options: [.regularExpression, .caseInsensitive])
    guard let expression = try? NSRegularExpression(pattern: "~~([\\s\\S]+?)~~") else {
        return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
    let source = text as NSString
    var result = AttributedString()
    var cursor = 0
    for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        result += try AttributedString(markdown: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        var struck = try AttributedString(markdown: source.substring(with: match.range(at: 1)), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        struck.strikethroughStyle = .single
        result += struck
        cursor = NSMaxRange(match.range)
    }
    result += try AttributedString(markdown: source.substring(from: cursor), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    return result
}

private struct ForumNovelRoute: Hashable {
    let isCatalogue: Bool
    let provider: String?
    let novelID: String
    var outline: WenkuNovelOutline {
        WenkuNovelOutline(id: novelID, title: "正在加载…")
    }
    init?(url: URL) {
        let host = url.host?.lowercased()
        guard host == "n.novelia.cc" || host == "novelia.cc" || host == "www.novelia.cc" || host == "books.fishhawk.top" || (host == nil && url.scheme == nil) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        isCatalogue = parts == ["novel"]
        if isCatalogue { provider = nil; novelID = "" }
        else if parts.count == 3, parts[0] == "novel" { provider = parts[1]; novelID = parts[2] }
        else if parts.count == 2, parts[0] == "wenku" { provider = nil; novelID = parts[1] }
        else { return nil }
    }
}
