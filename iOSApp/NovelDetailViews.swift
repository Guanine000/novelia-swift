import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct NovelDetailView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var webNovelDownloads: WebNovelDownloadStore
    let novel: Novel
    @State private var displayNovel: Novel
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var cloudLastReadChapterID: String?
    @State private var cloudFolders: [NoveliaCloudFolder] = []
    @State private var showCloudFavoriteOptions = false
    @State private var favoriteError: String?
    @State private var showFavoriteError = false
    @State private var isLoadingFavoriteFolders = false
    @State private var downloadRequest: Novel?
    @AppStorage private var savedChapterIndex: Int

    init(novel: Novel) {
        self.novel = novel
        _displayNovel = State(initialValue: novel)
        _savedChapterIndex = AppStorage(wrappedValue: 0, ReadingProgressStore.chapterKey(novelID: novel.id))
    }

    private var continueChapterIndex: Int {
        if let cloudLastReadChapterID,
           let cloudIndex = displayNovel.chapters.firstIndex(where: { $0.id == cloudLastReadChapterID }) {
            return cloudIndex
        }
        return min(savedChapterIndex, max(0, displayNovel.chapters.count - 1))
    }

    private var availableTranslationSources: [NovelTranslationSource] {
        guard let counts = displayNovel.translationChapterCounts else { return [] }
        return NovelTranslationSource.allCases.filter { (counts[$0] ?? 0) > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(LinearGradient(
                            colors: [NoveliaStyle.accent(for: displayNovel.accent), NoveliaStyle.ink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 190, height: 190)
                        .offset(x: 205, y: -72)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(displayNovel.genres.joined(separator: " · "))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(displayNovel.title)
                            .font(.system(size: 29, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if let originalTitle = displayNovel.distinctOriginalTitle {
                            Text("原名：\(originalTitle)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            Label(displayNovel.author, systemImage: "person")
                            if let totalCharacters = displayNovel.totalCharacters, totalCharacters > 0 {
                                Text("· \(totalCharacters.formatted()) 字")
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(22)
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 24))

                if let wenkuId = displayNovel.wenkuId {
                    NavigationLink {
                        WenkuDetailView(outline: WenkuNovelOutline(id: wenkuId, title: "正在加载…"))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "books.vertical").font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("文库版").font(.headline)
                                Text("查看对应的 Novelia 文库作品")
                                    .font(.caption).foregroundStyle(NoveliaStyle.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .padding(14)
                        .background(NoveliaStyle.brandGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("作品简介")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(displayNovel.summary)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(NoveliaStyle.muted)
                }

                if let translationCounts = displayNovel.translationChapterCounts {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("译源进度")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                            ForEach(NovelTranslationSource.allCases) { source in
                                VStack(spacing: 5) {
                                    Text(source.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(NoveliaStyle.ink)
                                    Text("\(translationCounts[source] ?? 0) / \(displayNovel.chapters.count) 章")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 13))
                            }
                        }
                        Text("阅读时可在右上角设置中切换译源。")
                            .font(.system(size: 12))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }

                if !displayNovel.genres.isEmpty {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 8) {
                            Text("标签").font(.system(size: 19, weight: .bold, design: .rounded))
                            Text("点击搜索，长按屏蔽")
                                .font(.system(size: 12))
                                .foregroundStyle(NoveliaStyle.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 6)
                            TagBlockingMenu(tags: displayNovel.genres)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)],
                            alignment: .leading,
                            spacing: 9
                        ) {
                            ForEach(displayNovel.genres, id: \.self) { tag in
                                NavigationLink {
                                    TagSearchResultsView(tag: tag)
                                } label: {
                                    Text(tag)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(blocked.contains(tag) ? NoveliaStyle.muted : NoveliaStyle.accent(for: displayNovel.accent))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(NoveliaStyle.card, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(blocked.contains(tag) ? "解除屏蔽此标签" : "屏蔽此标签", systemImage: "eye.slash") {
                                        if blocked.contains(tag) { blocked.remove(tag) } else { blocked.add(tag) }
                                    }
                                }
                            }
                        }
                    }
                }

                if !displayNovel.chapters.isEmpty {
                    NavigationLink {
                        ReaderView(novel: displayNovel, startingAt: continueChapterIndex)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "book.fill")
                                .font(.system(size: 17, weight: .semibold))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("继续阅读")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text(displayNovel.chapters[continueChapterIndex].title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .opacity(0.85)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .background(NoveliaStyle.brandGreen, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }

                if displayNovel.isRemote && !displayNovel.chapters.isEmpty {
                    let progress = webNovelDownloads.progress[displayNovel.id]
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            downloadRequest = displayNovel
                        } label: {
                            HStack(spacing: 10) {
                                if progress != nil {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: webNovelDownloads.isDownloaded(displayNovel.id) ? "arrow.clockwise" : "arrow.down.to.line")
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(progress == nil
                                         ? (webNovelDownloads.isDownloaded(displayNovel.id) ? "重新下载全书 EPUB" : "下载全书 EPUB")
                                         : "正在下载整本小说…")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                    Text("选择原文、译文或双语 EPUB，下载后可在 App 内阅读")
                                        .font(.system(size: 12, weight: .medium)).opacity(0.82)
                                }
                                Spacer()
                                if let progress {
                                    ProgressView(value: progress.fraction).tint(.white).frame(width: 48)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(NoveliaStyle.accent(for: displayNovel.accent), in: RoundedRectangle(cornerRadius: 15))
                        }
                        .buttonStyle(.plain)
                        .disabled(progress != nil)
                        if let error = webNovelDownloads.errors[displayNovel.id] {
                            Text("下载失败：\(error)")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                }

                if displayNovel.isRemote,
                   let providerId = displayNovel.providerId,
                   let novelId = displayNovel.novelId {
                    NavigationLink {
                        NovelCommentsView(title: displayNovel.title, subjectKey: "web-\(providerId)-\(novelId)")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 17, weight: .semibold))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("评论区")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text("查看或参与 Novelia 网页端讨论")
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(0.82)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(NoveliaStyle.ink)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("章节目录")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(displayNovel.chapters.count) 章")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                }

                if isLoadingDetail {
                    HStack { Spacer(); ProgressView("加载作品信息…"); Spacer() }
                        .padding(.vertical, 16)
                } else if let detailError {
                    ContentUnavailableView {
                        Label("作品信息加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(detailError)
                    } actions: {
                        Button("重试") { Task { await loadDetail() } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                } else if displayNovel.chapters.isEmpty {
                    Text("没有可阅读的章节。")
                        .font(.system(size: 14))
                        .foregroundStyle(NoveliaStyle.muted)
                        .padding(.vertical, 12)
                }

                ForEach(Array(displayNovel.chapters.enumerated()), id: \.element.id) { index, chapter in
                    NavigationLink {
                        ReaderView(novel: displayNovel, startingAt: index)
                    } label: {
                        HStack(spacing: 13) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                                .frame(width: 35, height: 35)
                                .background(NoveliaStyle.brandGreen.opacity(0.09), in: Circle())
                            Text(chapter.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(NoveliaStyle.muted.opacity(0.6))
                        }
                        .padding(13)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(novel.id)|\(auth.username ?? "")") { await loadDetail() }
        .sheet(item: $downloadRequest) { requestedNovel in
            WebNovelDownloadSheet(novel: requestedNovel, availableSources: availableTranslationSources)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favoriteTapped()
                } label: {
                    Image(systemName: isCloudFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(NoveliaStyle.brandGreen)
                }
                .accessibilityLabel(isCloudFavorite ? "取消网页收藏" : "收藏到网页端")
                .disabled(isLoadingDetail || isLoadingFavoriteFolders)
            }
        }
        .confirmationDialog("收藏到网页端", isPresented: $showCloudFavoriteOptions, titleVisibility: .visible) {
            ForEach(cloudFolders) { folder in
                Button(folder.title) {
                    guard let account = auth.username else { return }
                    Task {
                        do {
                            try await favorites.add(displayNovel, to: folder, account: account)
                            displayNovel = displayNovel.settingCloudFavoriteFolder(folder.id)
                        }
                        catch { presentFavoriteError(error) }
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择 Novelia 网页端的收藏夹。")
        }
        .alert("网页收藏同步失败", isPresented: $showFavoriteError) {
            Button("好", role: .cancel) {}
            if auth.username == nil {
                Button("登录") { auth.isLoginPresented = true }
            }
        } message: {
            Text(favoriteError ?? "请稍后重试。")
        }
    }

    @MainActor
    private func loadDetail() async {
        guard novel.isRemote, let providerId = novel.providerId, let novelId = novel.novelId else { return }
        let account = auth.username
        let api = NoveliaAPIClient()
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }
        do {
            let detail = try await api.novelForContinuation(providerId: providerId, novelId: novelId)
            guard !Task.isCancelled, auth.username == account else { return }
            displayNovel = detail.novel
            cloudLastReadChapterID = detail.lastReadChapterID
            favorites.updateStatus(from: detail.novel, account: account)
        } catch {
            guard !Task.isCancelled else { return }
            detailError = error.localizedDescription
        }
    }

    private var isCloudFavorite: Bool {
        favorites.contains(displayNovel) || favorites.folderID(for: displayNovel) != nil
    }

    private func favoriteTapped() {
        guard let account = auth.username else {
            auth.isLoginPresented = true
            return
        }
        if isCloudFavorite {
            Task {
                do {
                    try await favorites.remove(displayNovel, account: account)
                    displayNovel = displayNovel.settingCloudFavoriteFolder(nil)
                }
                catch { presentFavoriteError(error) }
            }
            return
        }
        isLoadingFavoriteFolders = true
        Task {
            defer { isLoadingFavoriteFolders = false }
            do {
                cloudFolders = try await favorites.folders(account: account)
                guard auth.username == account else { return }
                if cloudFolders.isEmpty {
                    throw NoveliaFavoritesUIError.noFolders
                }
                showCloudFavoriteOptions = true
            } catch {
                presentFavoriteError(error)
            }
        }
    }

    private func presentFavoriteError(_ error: Error) {
        favoriteError = error.localizedDescription
        showFavoriteError = true
    }
}

private struct WebNovelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: WebNovelDownloadStore
    let novel: Novel
    let availableSources: [NovelTranslationSource]

    @State private var selectedMode: WebNovelDownloadMode
    @State private var selectedSourceRaw: String
    @State private var isDownloading = false
    @State private var didFinish = false

    init(novel: Novel, availableSources: [NovelTranslationSource]) {
        self.novel = novel
        self.availableSources = availableSources
        _selectedMode = State(initialValue: availableSources.isEmpty ? .original : .translated)
        let preferredSource = UserDefaults.standard.string(forKey: SettingsKey.readerTranslationSource)
        let initialSource = preferredSource.flatMap { value in
            availableSources.first(where: { $0.rawValue == value })?.rawValue
        } ?? availableSources.first?.rawValue ?? "original"
        _selectedSourceRaw = State(initialValue: initialSource)
    }

    private var selectedSource: NovelTranslationSource? {
        NovelTranslationSource(rawValue: selectedSourceRaw)
    }

    private var effectiveSource: NovelTranslationSource? {
        selectedMode == .original ? nil : selectedSource
    }

    private var progress: WebNovelDownloadProgress? { downloads.progress[novel.id] }

    var body: some View {
        NavigationStack {
            Form {
                Section("下载内容") {
                    Text(novel.title).font(.headline)
                    Text("通过 Novelia 官方整本下载接口获取文件，可在“我的下载”中阅读或导出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("语言") {
                    Picker("下载内容", selection: $selectedMode) {
                        ForEach(WebNovelDownloadMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                                .disabled(mode != .original && availableSources.isEmpty)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isDownloading)
                    if selectedMode != .original {
                        Picker("译源", selection: $selectedSourceRaw) {
                            ForEach(availableSources) { source in
                                let count = novel.translationChapterCounts?[source] ?? 0
                                Text("\(source.title)（\(count) 章）").tag(source.rawValue)
                            }
                        }
                        .disabled(isDownloading)
                        Text(selectedMode == .bilingual
                             ? "双语文件会同时包含原文和所选译源的译文。"
                             : "下载文件只包含所选译源的译文。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    Section("下载进度") {
                        ProgressView(value: progress.fraction)
                        Text(progress.completed == progress.total ? "整本小说已下载" : "正在从 Novelia 获取整本小说…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = downloads.errors[novel.id] {
                    Section { Text("下载失败：\(error)").font(.footnote).foregroundStyle(.red) }
                }
                if didFinish {
                    Section { Label("\(selectedMode.title) EPUB 下载完成，可在“我的下载”中阅读或导出", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Section {
                    Button {
                        isDownloading = true
                        Task {
                            await downloads.download(novel, mode: selectedMode,
                                                     translationSource: effectiveSource)
                            isDownloading = false
                            didFinish = downloads.isDownloaded(novel.id) && downloads.errors[novel.id] == nil
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isDownloading { ProgressView() } else { Text("开始下载") }
                            Spacer()
                        }
                    }
                    .disabled(isDownloading || progress != nil || (selectedMode != .original && effectiveSource == nil))
                }
            }
            .navigationTitle("下载全书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
        }
    }
}

struct NovelCommentsView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    let title: String
    let subjectKey: String

    @State private var commentPage: NoveliaCommentPage?
    @State private var page = 1
    @State private var draft = ""
    @State private var replyRoot: NoveliaComment?
    @State private var extraReplies: [Int: NoveliaCommentPage] = [:]
    @State private var loadingReplyIDs: Set<Int> = []
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
                    ContentUnavailableView {
                        Label("评论加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await loadComments() } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                } else if let commentPage, commentPage.items.isEmpty {
                    ContentUnavailableView("还没有评论", systemImage: "text.bubble", description: Text("来发表第一条评论吧。"))
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
                .scrollContentBackground(.hidden)
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 12))
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
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
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
                                    .font(.system(size: 12))
                                    .lineSpacing(3)
                            }
                        }
                        .foregroundStyle(NoveliaStyle.ink)
                    }
                }
                .padding(.leading, 4)
            }
            if comment.replyCount > visibleReplies.count {
                Button {
                    Task { await loadMoreReplies(for: comment, loadedCount: visibleReplies.count) }
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
            let api = NoveliaAPIClient()
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
            let api = NoveliaAPIClient()
            try await api.postNovelComment(subjectKey: subjectKey, content: content, rootID: replyRoot?.id)
            draft = ""
            replyRoot = nil
            await loadComments(page: 1)
        } catch {
            sendError = error.localizedDescription
        }
    }

    @MainActor
    private func loadMoreReplies(for comment: NoveliaComment, loadedCount: Int) async {
        guard loadingReplyIDs.insert(comment.id).inserted else { return }
        defer { loadingReplyIDs.remove(comment.id) }
        do {
            let api = NoveliaAPIClient()
            let nextPage = loadedCount / 20 + 1
            let result = try await api.novelCommentReplies(
                subjectKey: subjectKey,
                rootID: comment.id,
                page: nextPage,
                pageSize: 20
            )
            var existing = extraReplies[comment.id] ?? NoveliaCommentPage(total: result.total, items: [])
            let existingIDs = Set(existing.items.map(\.id))
            existing = NoveliaCommentPage(
                total: result.total,
                items: existing.items + result.items.filter { !existingIDs.contains($0.id) }
            )
            extraReplies[comment.id] = existing
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .numeric, time: .shortened)
    }
}

private enum NoveliaFavoritesUIError: LocalizedError {
    case noFolders

    var errorDescription: String? { "网页账号下没有可用的收藏夹，请先在 Novelia 网页端创建收藏夹。" }
}
