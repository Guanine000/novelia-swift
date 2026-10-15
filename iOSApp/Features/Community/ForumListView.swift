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
                        ContentUnavailableView(store.posts.isEmpty ? "这里还没有帖子" : "本页没有匹配的帖子", systemImage: "bubble.left.and.bubble.right",
                                               description: Text(filtersCurrentPageOnly ? "可翻页查看其他页的帖子。" : "切换分类或调整搜索词。"))
                            .listRowBackground(Color.clear)
                    }

                    if filtersCurrentPageOnly {
                        Label("“我的帖子”和“收藏”不支持服务器搜索，只在本页按标题筛选。", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.muted)
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

                    if store.page > 0 || store.hasNextPage {
                        HStack {
                            Button("上一页") { loadPage(max(0, store.page - 1), using: proxy) }
                                .disabled(store.page == 0 || store.isLoadingPosts)
                            Spacer()
                            Text("第 \(store.page + 1) 页 · 共 \(store.total) 帖")
                                .font(.caption).foregroundStyle(NoveliaStyle.muted)
                            Spacer()
                            Button("下一页") { loadPage(store.page + 1, using: proxy) }
                                .disabled(!store.hasNextPage || store.isLoadingPosts)
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
