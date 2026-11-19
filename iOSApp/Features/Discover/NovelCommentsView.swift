import SwiftUI
import UIKit

struct NovelCommentsView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var auth: AccountAuthStore
    let title: String
    let subjectKey: String

    @State private var commentPage: NoveliaCommentPage?
    @State private var page = 1
    @State private var draft = ""
    @State private var replyRoot: NoveliaComment?
    @State private var extraReplies: [Int: NoveliaCommentPage] = [:]
    @State private var loadingReplyIDs: Set<Int> = []
    @State private var replyPaging: [Int: ReplyPaging] = [:]
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
                    CompatUnavailable {
                        Label("评论加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await loadComments() } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                } else if let commentPage, commentPage.items.isEmpty {
                    CompatUnavailable("还没有评论", systemImage: "text.bubble", description: Text("来发表第一条评论吧。"))
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
        .forumInAppLinkDestinations()
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
                .compatScrollContentBackgroundHidden()
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
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
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge))
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
                                    .font(NoveliaStyle.fontFootnote)
                                    .lineSpacing(3)
                            }
                        }
                        .foregroundStyle(NoveliaStyle.ink)
                    }
                }
                .padding(.leading, 4)
            }
            if comment.replyCount > visibleReplies.count, replyPaging[comment.id]?.isExhausted != true {
                Button {
                    Task { await loadMoreReplies(for: comment, shown: visibleReplies) }
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
            let api = services.api.bookComments
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
            let api = services.api.bookComments
            try await api.postNovelComment(subjectKey: subjectKey, content: content, rootID: replyRoot?.id)
            draft = ""
            replyRoot = nil
            await loadComments(page: 1)
        } catch {
            sendError = error.localizedDescription
        }
    }

    @MainActor
    /// `shown` 为已显示的回复（预览加已加载）；新页与它们按 ID 去重，避免预览回复重复出现。
    private func loadMoreReplies(for comment: NoveliaComment, shown: [NoveliaComment]) async {
        guard loadingReplyIDs.insert(comment.id).inserted else { return }
        defer { loadingReplyIDs.remove(comment.id) }
        do {
            let api = services.api.bookComments
            var paging = replyPaging[comment.id] ?? ReplyPaging()
            let result = try await api.novelCommentReplies(
                subjectKey: subjectKey,
                rootID: comment.id,
                page: paging.nextPage + 1,
                pageSize: 20
            )
            let added = paging.accept(result.items, shown: shown, pageSize: 20)
            replyPaging[comment.id] = paging
            let existing = extraReplies[comment.id]?.items ?? []
            extraReplies[comment.id] = NoveliaCommentPage(total: result.total, items: existing + added)
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .numeric, time: .shortened)
    }
}

enum NoveliaFavoritesUIError: LocalizedError {
    case noFolders

    var errorDescription: String? { "网页账号下没有可用的收藏夹，请先在 Novelia 网页端创建收藏夹。" }
}
