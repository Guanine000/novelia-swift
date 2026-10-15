import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

struct ForumPostDetailView: View {
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
    @State private var editingComment: ForumComment?
    @State private var editedCommentContents: [Int64: String] = [:]
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

    @EnvironmentObject private var services: AppServices
    private var api: any ForumService { services.api.forum }

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
                            username: auth.username,
                            editedContents: editedCommentContents,
                            content: editedCommentContents[comment.id] ?? comment.content,
                            onReply: {
                                guard auth.username != nil else { auth.isLoginPresented = true; return }
                                editingComment = nil
                                replyRoot = comment
                                draft = ""
                                isComposerPresented = true
                            },
                            onEdit: { beginCommentEdit($0) },
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
        .forumInAppLinkDestinations()
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
                isEditing: editingComment != nil,
                username: auth.username ?? "",
                onCancel: { cancelCommentEditor() },
                onSend: {
                    if editingComment == nil { return await sendComment() }
                    return await saveCommentEdit()
                }
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
        let url = services.configuration.forumURL(path: "p/\(postID)")
        UIApplication.shared.open(url)
    }

    private func handleForumLink(_ url: URL) -> OpenURLAction.Result {
        if let fragment = url.fragment,
           isLocalForumURL(url, postID: postID, configuration: services.configuration) || (url.scheme == nil && url.host == nil && url.path.isEmpty) {
            requestedAnchor = fragment.removingPercentEncoding ?? fragment
            return .handled
        }
        guard let destination = forumPostDestination(from: url, configuration: services.configuration) else { return .systemAction }
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
        editingComment = nil
        draft = ""
        isComposerPresented = true
    }

    private func beginCommentEdit(_ comment: ForumComment) {
        guard auth.username == comment.authorUsername else { return }
        replyRoot = nil
        editingComment = comment
        draft = editedCommentContents[comment.id] ?? comment.content
        isComposerPresented = true
    }

    private func cancelCommentEditor() {
        isComposerPresented = false
        editingComment = nil
        replyRoot = nil
        draft = ""
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let fetchedPost = api.post(id: postID)
            async let fetchedComments = api.comments(postID: postID, page: 0, pageSize: 20)
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
            let result = try await api.comments(postID: postID, page: requestedPage, pageSize: 20)
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
        } catch { return error.localizedDescription }
        // 评论已发出：之后的刷新失败不算发送失败，否则用户可能重新发送而产生重复评论。
        draft = ""
        replyRoot = nil
        await loadComments(page: 0)
        if let refreshed = try? await api.post(id: postID) { post = refreshed }
        return nil
    }

    @MainActor
    private func saveCommentEdit() async -> String? {
        guard let editingComment, auth.username == editingComment.authorUsername else { return "只能编辑自己发表的评论。" }
        let content = forumCommentMarkdownForSubmission(draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return "请先输入评论内容。" }
        isSending = true
        defer { isSending = false }
        do {
            let updated = try await api.updateComment(postID: postID, commentID: editingComment.id, content: content)
            editedCommentContents[updated.id] = updated.content
            self.editingComment = nil
            draft = ""
            await loadComments(page: commentPage)
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

private struct ForumCommentCard: View {
    let postID: Int64
    let comment: ForumComment
    let username: String?
    let editedContents: [Int64: String]
    let content: String
    let onReply: () -> Void
    let onEdit: (ForumComment) -> Void
    let onError: (String) -> Void
    @State private var extraReplies: [ForumComment] = []
    @State private var replyPaging = ReplyPaging()
    @State private var isLoadingReplies = false

    private var initialReplies: [ForumComment] { comment.replies?.items ?? [] }
    private var allReplies: [ForumComment] { initialReplies + extraReplies }
    @EnvironmentObject private var services: AppServices
    private var api: any ForumService { services.api.forum }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(comment.authorUsername).font(.caption.weight(.bold))
                Spacer()
                Text(comment.createdAt.forumDisplayDate).font(.caption2).foregroundStyle(NoveliaStyle.muted)
            }
            ForumMarkdownBody(markdown: content, mode: .comment)
            HStack(spacing: 16) {
                Button("回复") { onReply() }
                if username == comment.authorUsername {
                    Button("编辑") { onEdit(comment) }
                }
            }
            .font(.caption.weight(.semibold)).tint(NoveliaStyle.brandGreen)
            ForEach(allReplies) { reply in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(NoveliaStyle.brandGreen.opacity(0.4)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(reply.authorUsername).font(.caption2.weight(.bold))
                            Spacer()
                            Text(reply.createdAt.forumDisplayDate).font(.caption2).foregroundStyle(NoveliaStyle.muted)
                        }
                        ForumMarkdownBody(markdown: editedContents[reply.id] ?? reply.content, mode: .comment)
                        if username == reply.authorUsername {
                            Button("编辑") { onEdit(reply) }
                                .font(.caption.weight(.semibold)).tint(NoveliaStyle.brandGreen)
                        }
                    }
                }
            }
            if let count = comment.replyCount, Int64(allReplies.count) < count, !replyPaging.isExhausted {
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
            let result = try await api.replies(postID: postID, rootID: comment.id, page: replyPaging.nextPage, pageSize: 20)
            extraReplies.append(contentsOf: replyPaging.accept(result.items, shown: allReplies, pageSize: 20))
        } catch {
            onError(error.localizedDescription)
        }
    }
}

extension String {
    @MainActor var forumDisplayDate: String {
        let date = ForumDateParsing.fractional.date(from: self) ?? ForumDateParsing.plain.date(from: self)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? self
    }
}

/// 列表每行都会解析日期；解析器只建一次，仅在主线程（界面）使用。
@MainActor
private enum ForumDateParsing {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let plain = ISO8601DateFormatter()
}
