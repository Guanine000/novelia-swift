import SwiftUI

struct WenkuView: View {
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    @EnvironmentObject private var store: WenkuStore
    @State private var query = ""
    /// 嵌入“发现”页时不设置自己的导航标题。
    private let embedded: Bool

    init(initialQuery: String = "", embedded: Bool = false) {
        _query = State(initialValue: initialQuery)
        self.embedded = embedded
    }

    var body: some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle("文库")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(NoveliaStyle.muted)
                TextField("搜索文库作品", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(NoveliaStyle.muted) }
                }
            }
            .padding(12)
            .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 4)
            HStack(spacing: 8) {
                NavigationLink {
                    WenkuFavoritesView()
                        .environmentObject(store)
                        .environmentObject(localLibrary)
                } label: {
                    DiscoverShortcutChip(title: "文库收藏", systemImage: "heart")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            WenkuNovelList(novels: store.novels, loading: store.isLoading, error: store.errorMessage,
                           filtersBlocked: true,
                           pager: .init(page: store.page, pageCount: store.pageCount) { target in
                               Task { await store.goTo(page: target) }
                           },
                           reload: { await store.goTo(page: store.page) })
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .environmentObject(store)
        .task {
            await localLibrary.refreshMissingMetadata()
        }
        .task(id: query) {
            guard !store.hasLoaded(query) else { return }
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            await store.search(query)
        }
    }
}

/// 文库收藏（与网络小说收藏分开保存，并同步到 Novelia 网页端）。
struct WenkuFavoritesView: View {
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var store: WenkuStore

    var body: some View {
        Group {
            if auth.username == nil {
                ContentUnavailableView {
                    Label("登录后同步文库收藏", systemImage: "person.crop.circle.badge.checkmark")
                } description: {
                    Text("文库收藏与网络小说收藏分开保存，并同步到 Novelia 网页端。")
                } actions: {
                    Button("登录 Novelia 账号") { auth.isLoginPresented = true }
                        .buttonStyle(.borderedProminent).tint(NoveliaStyle.brandGreen)
                }
            } else if let error = store.favoriteErrorMessage, store.favorites.isEmpty {
                ContentUnavailableView("无法加载文库收藏", systemImage: "heart", description: Text(error))
            } else if store.favorites.isEmpty {
                ContentUnavailableView("文库收藏为空", systemImage: "books.vertical", description: Text("搜索文库作品后，在详情页添加收藏。"))
            } else {
                WenkuNovelList(novels: store.favorites, loading: false, error: store.favoriteErrorMessage,
                               filtersBlocked: false, pager: nil) { await store.refreshFavorites(account: auth.username) }
            }
        }
        .padding(.top, 8)
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("文库收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.username) { await store.refreshFavorites(account: auth.username) }
    }
}

private struct WenkuNovelList: View {
    struct Pager {
        let page: Int
        let pageCount: Int
        let select: (Int) -> Void
    }

    @EnvironmentObject private var blocked: BlockedTagsStore
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    let novels: [WenkuNovelOutline]
    let loading: Bool
    let error: String?
    /// 搜索结果按标签屏蔽过滤；收藏保持原样。
    let filtersBlocked: Bool
    /// 搜索结果按页浏览；收藏一次加载全部，不分页。
    let pager: Pager?
    let reload: () async -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    if loading && novels.isEmpty {
                        ProgressView("正在搜索文库…").padding(36)
                    } else if let error, novels.isEmpty {
                        ContentUnavailableView {
                            Label("文库请求失败", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { Task { await reload() } }
                                .buttonStyle(.borderedProminent)
                                .tint(NoveliaStyle.brandGreen)
                        }
                    } else if novels.isEmpty {
                        ContentUnavailableView("没有找到作品", systemImage: "books.vertical", description: Text("换个关键词试试。"))
                    }
                    ForEach(novels.filter { !filtersBlocked || !blocked.hides(blocked.wenkuTags[$0.id] ?? []) }) { novel in
                        NavigationLink {
                            WenkuDetailView(outline: novel)
                                .environmentObject(localLibrary)
                        } label: {
                            WenkuNovelRow(novel: novel)
                        }
                        .buttonStyle(.plain)
                    }
                    if let error, !novels.isEmpty {
                        Text(error).font(.footnote).foregroundStyle(.red).padding()
                    }
                    if let pager, pager.pageCount > 1 || pager.page > 1 {
                        PageNavigator(page: pager.page, pageCount: pager.pageCount, isLoading: loading,
                                      onSelect: pager.select)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
            .refreshable { await reload() }
            // 翻页后回到顶部，像网页端一样从新一页的第一部作品开始看。
            .onChange(of: pager?.page) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
        }
    }

    private static let topAnchor = "wenku-list-top"
}

struct WenkuNovelRow: View {
    let novel: WenkuNovelOutline

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: novel.cover.flatMap(URL.init(string:))) {
                RoundedRectangle(cornerRadius: 8).fill(NoveliaStyle.brandGreen.opacity(0.12))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(NoveliaStyle.brandGreen))
            }
            .frame(width: 72, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(novel.displayTitle).font(.system(size: 16, weight: .bold)).foregroundStyle(NoveliaStyle.ink).lineLimit(2)
                if !novel.title.isEmpty && novel.title != novel.displayTitle {
                    Text(novel.title).font(.system(size: 12)).foregroundStyle(NoveliaStyle.muted).lineLimit(1)
                }
                if novel.favored != nil {
                    Label("已收藏", systemImage: "heart.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(NoveliaStyle.brandGreen)
                }
                Spacer(minLength: 0)
                Text("文库小说").font(.system(size: 11)).foregroundStyle(NoveliaStyle.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 8)
        }
        .frame(minHeight: 112)
        .padding(10)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.vertical, 5)
    }
}

struct WenkuDetailView: View {
    @EnvironmentObject private var blocked: BlockedTagsStore
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var store: WenkuStore
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    let outline: WenkuNovelOutline
    @State private var detail: WenkuNovelDetail?
    @State private var error: String?
    @State private var isLoading = true
    @State private var downloadRequest: WenkuDownloadRequest?
    @State private var favoriteError: String?

    @EnvironmentObject private var services: AppServices
    private var api: any WenkuCatalogService { services.api.wenku }

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(detail)
                            .onAppear { blocked.rememberWenku(id: detail.id, tags: detail.keywords) }
                        if !linkedWebNovels(detail.webIds).isEmpty {
                            relatedWebNovelsSection(detail)
                        }
                        if detail.title != detail.displayTitle || latestUpdateText(detail.latestPublishAt) != nil {
                            VStack(alignment: .leading, spacing: 5) {
                                if detail.title != detail.displayTitle {
                                    Text("原名：\(detail.title)")
                                        .font(.caption)
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .lineLimit(2)
                                }
                                if let latestUpdate = latestUpdateText(detail.latestPublishAt) {
                                    Label(latestUpdate, systemImage: "clock")
                                        .font(.caption)
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                            }
                        }
                        if !detail.introduction.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("简介").font(.headline)
                                Text(detail.introduction).font(.system(size: 14)).lineSpacing(5)
                            }
                        }
                        if !detail.keywords.isEmpty {
                            VStack(alignment: .leading, spacing: 11) {
                                HStack(spacing: 8) {
                                    Text("标签").font(.system(size: 19, weight: .bold, design: .rounded))
                                    Spacer(minLength: 6)
                                    TagBlockingMenu(tags: detail.keywords)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)], alignment: .leading, spacing: 9) {
                                    ForEach(detail.keywords, id: \.self) { tag in
                                        Text(tag)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(blocked.contains(tag) ? NoveliaStyle.muted : NoveliaStyle.ink)
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(NoveliaStyle.card, in: Capsule())
                                    }
                                }
                            }
                        }
                        if !detail.volumes.isEmpty {
                            volumeCoverGallery(detail.volumes)
                        }
                        NavigationLink {
                            NovelCommentsView(title: detail.displayTitle, subjectKey: "wenku-\(detail.id)")
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "text.bubble").font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("评论区").font(.headline)
                                    Text("查看或参与 Novelia 文库讨论")
                                        .font(.caption).foregroundStyle(NoveliaStyle.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .padding(14)
                            .background(NoveliaStyle.brandGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        volumesSection(detail)
                    }
                    .padding(18)
                }
            } else if isLoading {
                ProgressView("正在加载文库详情…")
            } else {
                ContentUnavailableView("无法加载作品", systemImage: "wifi.exclamationmark", description: Text(error ?? "请稍后重试。"))
            }
        }
        .navigationTitle(detail?.displayTitle ?? outline.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: outline.id) {
            await loadDetail()
            if auth.username != nil, store.folders.isEmpty {
                await store.refreshFavorites(account: auth.username)
            }
        }
        .sheet(item: $downloadRequest) { request in
            WenkuDownloadSheet(detail: request.detail, volume: request.volume)
                .environmentObject(localLibrary)
        }
        .alert("收藏失败", isPresented: Binding(get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } })) {
            Button("好", role: .cancel) { favoriteError = nil }
        } message: { Text(favoriteError ?? "") }
    }

    private func header(_ detail: WenkuNovelDetail) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: detail.cover.flatMap(URL.init(string:))) {
                RoundedRectangle(cornerRadius: 10).fill(NoveliaStyle.brandGreen.opacity(0.12))
                    .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(NoveliaStyle.brandGreen))
            }
            .frame(width: 112, height: 154).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.displayTitle).font(.system(size: 21, weight: .bold)).foregroundStyle(NoveliaStyle.ink)
                if !detail.authors.isEmpty { metadataSearchLinks(label: "作者", values: detail.authors) }
                if !detail.artists.isEmpty { metadataSearchLinks(label: "画师", values: detail.artists) }
                if !detail.publisher.isNilOrEmpty, let publisher = detail.publisher {
                    metadataSearchLinks(label: "出版社", values: [publisher])
                }
                if !detail.imprint.isNilOrEmpty, let imprint = detail.imprint {
                    metadataSearchValue(label: "文库", value: imprint)
                }
                Text(detail.level).font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4).background(NoveliaStyle.brandGreen.opacity(0.1), in: Capsule())
                Spacer(minLength: 4)
                Button {
                    Task {
                        guard let account = auth.username else { auth.isLoginPresented = true; return }
                        let target = WenkuNovelOutline(
                            id: detail.id,
                            title: detail.title,
                            titleZh: detail.titleZh,
                            cover: detail.cover,
                            favored: detail.favored
                        )
                        do {
                            try await store.toggleFavorite(target, account: account)
                            let folder = store.favorites.first(where: { $0.id == detail.id })?.favored
                            self.detail = withFavorite(detail, folderID: folder)
                            favoriteError = nil
                        }
                        catch { favoriteError = error.localizedDescription }
                    }
                } label: {
                    Label(detail.favored == nil ? "收藏文库" : "取消收藏", systemImage: detail.favored == nil ? "heart" : "heart.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(NoveliaStyle.brandGreen)
            }
        }
        // 根视图全局开启文本选择时，选择手势会吞掉作者/出版社搜索链接文字上的点按。
        .textSelection(.disabled)
    }

    private func latestUpdateText(_ timestamp: Int64?) -> String? {
        guard let timestamp, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return "最新更新：\(date.formatted(date: .numeric, time: .omitted))"
    }

    private func metadataSearchValue(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label)：")
                .font(.caption)
                .foregroundStyle(NoveliaStyle.muted)
            NavigationLink {
                WenkuView(initialQuery: "\"\(value)\"")
            } label: {
                HStack(spacing: 4) {
                    Text(value).lineLimit(2)
                    Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(NoveliaStyle.brandGreen)
            }
            .buttonStyle(.plain)
        }
    }

    private func metadataSearchLinks(label: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(NoveliaStyle.muted)
            ForEach(values.indices, id: \.self) { index in
                let value = values[index]
                NavigationLink {
                    WenkuView(initialQuery: "\"\(value)\"")
                } label: {
                    HStack(spacing: 4) {
                        Text(value).lineLimit(2)
                        Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(NoveliaStyle.brandGreen)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func volumeCoverGallery(_ volumes: [WenkuVolumeMetadata]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(Array(volumes.enumerated()), id: \.offset) { item in
                    let volume = item.element
                    CoverImage(url: URL(string: volume.coverHires ?? volume.cover)) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(NoveliaStyle.brandGreen.opacity(0.1))
                            .overlay {
                                Image(systemName: "book.closed")
                                    .font(.title2)
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                            }
                    }
                    .frame(width: 112, height: 154)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(volume.titleZh ?? volume.title)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func relatedWebNovelsSection(_ detail: WenkuNovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("相关网络小说").font(.headline)
            ForEach(linkedWebNovels(detail.webIds), id: \.self) { linked in
                NavigationLink {
                    NovelDetailView(novel: linked.novel)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "globe.asia.australia").font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(linked.providerTitle).font(.headline)
                            Text(linked.novelId)
                                .font(.caption)
                                .foregroundStyle(NoveliaStyle.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(14)
                    .background(NoveliaStyle.brandGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func linkedWebNovels(_ webIds: [String]) -> [LinkedWebNovel] {
        webIds.compactMap(LinkedWebNovel.init)
    }

    private func volumesSection(_ detail: WenkuNovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("卷与翻译").font(.headline)
                Spacer()
                Text("原文 \(detail.volumeJp.count) 卷 · 译文 \(detail.volumeZh.count) 卷")
                    .font(.caption).foregroundStyle(NoveliaStyle.muted)
            }
            if detail.volumeJp.isEmpty {
                Text("当前没有可下载的原文卷。")
                    .font(.subheadline).foregroundStyle(NoveliaStyle.muted).padding(.vertical, 8)
            }
            ForEach(detail.volumeJp, id: \.volumeId) { volume in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(volume.volumeId).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text("原文章节 (volume.total)").font(.caption).foregroundStyle(NoveliaStyle.muted)
                        }
                        Spacer()
                        Button { downloadRequest = WenkuDownloadRequest(detail: detail, volume: volume) } label: {
                            Label("下载 EPUB", systemImage: "arrow.down.to.line")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered).tint(NoveliaStyle.brandGreen)
                    }
                    HStack(spacing: 7) {
                        ForEach(WenkuTranslator.allCases) { translator in
                            Text("\(translator.title) \(volume.count(for: translator))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(volume.count(for: translator) > 0 ? NoveliaStyle.ink : NoveliaStyle.muted)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Color.black.opacity(volume.count(for: translator) > 0 ? 0.07 : 0.035), in: Capsule())
                        }
                    }
                }
                .padding(12).background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }
        do { detail = try await api.wenkuNovel(id: outline.id); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func withFavorite(_ old: WenkuNovelDetail, folderID: String?) -> WenkuNovelDetail {
        WenkuNovelDetail(id: old.id, title: old.title, titleZh: old.titleZh, cover: old.cover, authors: old.authors, artists: old.artists, keywords: old.keywords, publisher: old.publisher, imprint: old.imprint, latestPublishAt: old.latestPublishAt, level: old.level, introduction: old.introduction, webIds: old.webIds, volumes: old.volumes, glossary: old.glossary, visited: old.visited, favored: folderID, volumeZh: old.volumeZh, volumeJp: old.volumeJp)
    }
}

/// 文库详情页里指向对应「网络小说」详情的跳转目标，服务端返回形如 "syosetu/n8803hp"。
private struct LinkedWebNovel: Hashable {
    let providerId: String
    let novelId: String

    init?(_ raw: String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        providerId = parts[0]
        novelId = parts[1]
    }

    var providerTitle: String { NovelProviderMetadata.name(providerId) }

    /// 占位 Novel：详情页加载后会补齐标题、简介与章节。
    var novel: Novel {
        Novel(
            id: "remote/\(providerId)/\(novelId)",
            title: "正在加载…",
            author: providerTitle,
            summary: "",
            genres: [],
            chapters: [],
            accent: .ocean,
            providerId: providerId,
            novelId: novelId
        )
    }
}

private struct WenkuDownloadRequest: Identifiable {
    let detail: WenkuNovelDetail
    let volume: WenkuVolumeAvailability

    var id: String { "\(detail.id)/\(volume.volumeId)" }
}

private struct WenkuDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    let detail: WenkuNovelDetail
    let volume: WenkuVolumeAvailability
    @State private var mode: WenkuEPUBMode = .translated
    @State private var translator: WenkuTranslator = .sakura
    @State private var hasCustomTranslatorSelection = false
    @State private var translationsMode: WenkuTranslationsMode = .priority
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var finished = false

    @EnvironmentObject private var services: AppServices
    private var api: any NovelDownloadService { services.api.downloads }

    private var availableTranslators: [WenkuTranslator] {
        WenkuTranslator.allCases.filter { volume.count(for: $0) > 0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("卷") { Text(volume.volumeId); Text("有译文的章节：\(volume.total)") }
                Section("下载内容") {
                    Picker("内容", selection: $mode) {
                        ForEach(WenkuEPUBMode.allCases) { option in
                            Text(option.title).tag(option).disabled(option == .original)
                        }
                    }
                    Text("原文单独 EPUB 目前受 Novelia 上游接口限制，暂时不可下载；译文和双语文件可用。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Section("翻译源") {
                    if availableTranslators.isEmpty {
                        Text("此卷暂无可用翻译源，上游目前也未提供原文单独 EPUB 下载接口。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "翻译源",
                            selection: Binding(
                                get: { translator },
                                set: { translator = $0; hasCustomTranslatorSelection = true }
                            )
                        ) {
                            ForEach(availableTranslators) { source in
                                Text("\(source.title)（\(volume.count(for: source)) 段）").tag(source)
                            }
                        }
                    }
                }
                if let errorMessage { Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) } }
                if finished { Section { Label("下载完成，可在“书库”中阅读或导出", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
                Section {
                    Button {
                        Task { await download() }
                    } label: {
                        HStack {
                            Spacer()
                            if isDownloading { ProgressView() } else { Text("下载到本地") }
                            Spacer()
                        }
                    }
                    .disabled(isDownloading || availableTranslators.isEmpty)
                }
            }
            .navigationTitle("下载 EPUB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
            .onAppear {
                if let first = availableTranslators.first { translator = first }
            }
        }
    }

    private func download() async {
        guard mode == .translated || mode == .originalThenTranslation || mode == .translationThenOriginal else { return }
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }
        do {
            let filenameTranslators = hasCustomTranslatorSelection ? [translator] : WenkuTranslator.websiteDefaultPriority
            let filename = mode.websiteDownloadFilename(
                volumeId: volume.volumeId,
                translationsMode: translationsMode,
                translators: filenameTranslators,
                authors: detail.authors
            )
            try await localLibrary.loadIfNeeded()
            let destination = localLibrary.downloadDestination(for: filename)
            try await api.downloadWenkuEPUB(
                to: destination,
                novelId: detail.id,
                volumeId: volume.volumeId,
                mode: mode,
                translator: translator,
                filenameTranslators: filenameTranslators,
                filenameAuthors: detail.authors,
                translationsMode: translationsMode
            )
            try await localLibrary.registerDownloadedFile(at: destination, title: "\(detail.displayTitle) · \(volume.volumeId)")
            finished = true
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
