import SwiftUI

struct ShelfView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YOUR PERSONAL LIBRARY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(NoveliaStyle.coral)
                    Text("我的书架")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                    Text("收藏的作品会保存在这台设备上。")
                        .font(.system(size: 15))
                        .foregroundStyle(NoveliaStyle.muted)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("已收藏")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        Spacer()
                        Text("\(favorites.novels.count) 本")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    if auth.username == nil {
                        ContentUnavailableView {
                            Label("登录后同步网页收藏", systemImage: "person.crop.circle.badge.checkmark")
                        } description: {
                            Text("此处会显示你在 Novelia 网页端收藏的作品。")
                        } actions: {
                            Button("登录 Novelia 账号") { auth.isLoginPresented = true }
                                .buttonStyle(.borderedProminent)
                                .tint(NoveliaStyle.coral)
                        }
                        .padding(.vertical, 22)
                    } else if favorites.isLoading && favorites.novels.isEmpty {
                        HStack { Spacer(); ProgressView("正在同步网页收藏…"); Spacer() }
                            .padding(.vertical, 28)
                    } else if favorites.novels.isEmpty {
                        ContentUnavailableView {
                            Label("网页收藏夹为空", systemImage: "heart")
                        } description: {
                            Text("在作品详情中收藏后，这里会与网页端保持同步。")
                        }
                        .padding(.vertical, 22)
                    } else {
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
                    }
                    if let error = favorites.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                        Button("重新同步") { Task { await favorites.refresh(account: auth.username) } }
                            .tint(NoveliaStyle.coral)
                    } else if auth.username != nil {
                        Button("刷新网页收藏") { Task { await favorites.refresh(account: auth.username) } }
                            .font(.system(size: 13, weight: .medium))
                            .tint(NoveliaStyle.coral)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: auth.username) { await favorites.refresh(account: auth.username) }
    }
}

struct DiscoverView: View {
    @State private var query = ""
    @StateObject private var store = DiscoverStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FIND YOUR NEXT STORY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(NoveliaStyle.coral)
                    Text("发现好故事")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(NoveliaStyle.muted)
                    TextField("搜索书名、作者或题材", text: $query)
                        .font(.system(size: 15))
                        .autocorrectionDisabled()
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 15))

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
                            .tint(NoveliaStyle.coral)
                    }
                }

                ForEach(store.novels) { novel in
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        FeaturedNovelCard(novel: novel)
                    }
                    .buttonStyle(.plain)
                }
                if store.novels.isEmpty && store.errorMessage == nil && !store.isLoading {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) { await store.search(query: query) }
    }
}

struct NovelDetailView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    let novel: Novel
    @State private var displayNovel: Novel
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var cloudFolders: [NoveliaCloudFolder] = []
    @State private var showCloudFavoriteOptions = false
    @State private var favoriteError: String?
    @State private var showFavoriteError = false
    @State private var isLoadingFavoriteFolders = false
    @AppStorage private var savedChapterIndex: Int

    init(novel: Novel) {
        self.novel = novel
        _displayNovel = State(initialValue: novel)
        _savedChapterIndex = AppStorage(wrappedValue: 0, "progress.\(novel.id)")
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
                        Text("著 · \(displayNovel.author)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(22)
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 9) {
                    Text("作品简介")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(displayNovel.summary)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(NoveliaStyle.muted)
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
                            .tint(NoveliaStyle.coral)
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
                                .foregroundStyle(NoveliaStyle.coral)
                                .frame(width: 35, height: 35)
                                .background(NoveliaStyle.coral.opacity(0.09), in: Circle())
                            Text(chapter.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(NoveliaStyle.muted.opacity(0.6))
                        }
                        .padding(13)
                        .background(.white, in: RoundedRectangle(cornerRadius: 15))
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favoriteTapped()
                } label: {
                    Image(systemName: isCloudFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(NoveliaStyle.coral)
                }
                .accessibilityLabel(isCloudFavorite ? "取消网页收藏" : "收藏到网页端")
                .disabled(isLoadingDetail || isLoadingFavoriteFolders)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ReaderView(novel: displayNovel, startingAt: min(savedChapterIndex, max(0, displayNovel.chapters.count - 1)))
                } label: {
                    Image(systemName: "book.fill")
                        .foregroundStyle(NoveliaStyle.coral)
                }
                .accessibilityLabel("继续阅读")
                .disabled(displayNovel.chapters.isEmpty)
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
        let token = NoveliaSessionTokenVault.read()
        let api = NoveliaAPIClient(tokenProvider: { token })
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }
        do {
            let loaded = try await api.novel(providerId: providerId, novelId: novelId)
            guard !Task.isCancelled, auth.username == account else { return }
            displayNovel = loaded
            favorites.updateStatus(from: loaded, account: account)
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

private enum NoveliaFavoritesUIError: LocalizedError {
    case noFolders

    var errorDescription: String? { "网页账号下没有可用的收藏夹，请先在 Novelia 网页端创建收藏夹。" }
}

private struct ContinueReadingCard: View {
    let novel: Novel
    @AppStorage private var savedChapterIndex: Int

    init(novel: Novel) {
        self.novel = novel
        _savedChapterIndex = AppStorage(wrappedValue: 0, "progress.\(novel.id)")
    }

    var body: some View {
        HStack(spacing: 16) {
            BookCover(novel: novel, width: 82, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                Text("接着上次")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(NoveliaStyle.coral)
                Text(novel.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                Text(novel.chapters[min(savedChapterIndex, novel.chapters.count - 1)].title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(NoveliaStyle.muted)
                HStack(spacing: 6) {
                    Text("继续阅读")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NoveliaStyle.coral)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 21))
        .overlay(alignment: .trailing) {
            Image(systemName: "sparkle")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(NoveliaStyle.coral.opacity(0.7))
                .padding(15)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct FeaturedNovelCard: View {
    let novel: Novel

    var body: some View {
        HStack(spacing: 15) {
            BookCover(novel: novel, width: 82, height: 112)
            VStack(alignment: .leading, spacing: 7) {
                Text(novel.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                Text(novel.author)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted)
                Text(novel.summary)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .lineSpacing(3)
                    .foregroundStyle(NoveliaStyle.muted)
                Text(novel.genres.joined(separator: "  ·  "))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.accent(for: novel.accent))
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(.white, in: RoundedRectangle(cornerRadius: 19))
    }
}

private struct NovelRow: View {
    let novel: Novel

    var body: some View {
        HStack(spacing: 13) {
            BookCover(novel: novel, width: 61, height: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(novel.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(NoveliaStyle.ink)
                Text(novel.author)
                    .font(.system(size: 12))
                    .foregroundStyle(NoveliaStyle.muted)
                Text("\(novel.chapters.count) 章  ·  \(novel.genres.first ?? "小说")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.5))
        }
        .padding(11)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
    }
}

struct BookCover: View {
    let novel: Novel
    var width: CGFloat = 74
    var height: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [NoveliaStyle.accent(for: novel.accent), NoveliaStyle.ink.opacity(0.95)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: width * 0.8)
                .offset(x: width * 0.42, y: -height * 0.48)
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: novel.accent == .ocean ? "water.waves" : "moon.stars.fill")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
                Text(novel.title)
                    .font(.system(size: max(9, width * 0.16), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
            }
            .padding(width * 0.12)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("\(novel.title) 封面")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @AppStorage("readerFontSize") private var fontSize = 20.0
    @AppStorage("readerMode") private var modeRaw = ReaderMode.bilingual.rawValue

    private var selectedMode: ReaderMode {
        ReaderMode(rawValue: modeRaw) ?? .bilingual
    }

    var body: some View {
        Form {
            Section("Novelia 账号") {
                if let username = auth.username {
                    LabeledContent("已登录", value: username)
                    Button("退出登录", role: .destructive) { auth.logout() }
                } else {
                    Text("登录后可使用需要账号的服务。密码由 Novelia 认证网页处理，App 只保存会话令牌。")
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                    Button {
                        auth.errorMessage = nil
                        auth.isLoginPresented = true
                    } label: {
                        Label("登录 / 注册", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .tint(NoveliaStyle.coral)
                }
            }
            Section("阅读体验") {
                Picker("显示语言", selection: $modeRaw) {
                    ForEach(ReaderMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("正文字号")
                        Spacer()
                        Text("\(Int(fontSize)) pt")
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    Slider(value: $fontSize, in: 16...30, step: 1)
                        .tint(NoveliaStyle.coral)
                }
            }
            Section("关于此移植") {
                LabeledContent("平台", value: "iOS 17+")
                LabeledContent("版本", value: "独立 MVP")
                Text("发现、在线阅读和网页收藏已连接 Novelia API，账号登录使用官方统一认证页。云端书架文件夹管理、下载队列与 ECH 传输尚未接入。")
                    .font(.system(size: 13))
                    .foregroundStyle(NoveliaStyle.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NoveliaStyle.paper)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
    }
}
