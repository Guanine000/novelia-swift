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
