import SwiftUI

struct WenkuView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    @StateObject private var store = WenkuStore()
    @State private var section = WenkuSection.search
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("文库", selection: $section) {
                ForEach(WenkuSection.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Group {
                switch section {
                case .search: searchContent
                case .favorites: favoritesContent
                case .downloaded: downloadedContent
                }
            }
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("文库")
        .navigationBarTitleDisplayMode(.inline)
        .environmentObject(store)
        .task(id: auth.username) {
            await store.refreshFavorites(account: auth.username)
        }
        .task {
            await localLibrary.refreshMissingMetadata()
        }
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            await store.search(query)
        }
    }

    private var searchContent: some View {
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
            .padding(.bottom, 8)
            novelList(store.novels, loading: store.isLoading, error: store.errorMessage, loadMore: store.loadMore)
        }
    }

    private var favoritesContent: some View {
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
                novelList(store.favorites, loading: false, error: store.favoriteErrorMessage) { await store.refreshFavorites(account: auth.username) }
            }
        }
    }

    private var downloadedContent: some View {
        MyDownloadsView(initialTab: .wenku)
    }

    @ViewBuilder
    private func novelList(
        _ novels: [WenkuNovelOutline],
        loading: Bool,
        error: String?,
        loadMore: @escaping () async -> Void
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if loading && novels.isEmpty {
                    ProgressView("正在搜索文库…").padding(36)
                } else if let error, novels.isEmpty {
                    ContentUnavailableView("文库请求失败", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if novels.isEmpty {
                    ContentUnavailableView("没有找到作品", systemImage: "books.vertical", description: Text("换个关键词试试。"))
                }
                ForEach(Array(novels.enumerated()).filter { section != .search || !blocked.hides(blocked.wenkuTags[$0.element.id] ?? []) }, id: \.element.id) { index, novel in
                    NavigationLink {
                        WenkuDetailView(outline: novel)
                            .environmentObject(localLibrary)
                    } label: {
                        WenkuNovelRow(novel: novel)
                    }
                    .buttonStyle(.plain)
                    .task {
                        if index >= novels.count - 4 { await loadMore() }
                    }
                }
                if section == .search, !blocked.tags.isEmpty, !novels.isEmpty {
                    Button("加载更多作品") { Task { await loadMore() } }
                        .disabled(loading).padding()
                }
                if loading && !novels.isEmpty { ProgressView().padding() }
                if let error, !novels.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(.red).padding()
                    Button("重试加载") { Task { await loadMore() } }.padding(.bottom, 12)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .refreshable { await loadMore() }
    }
}

private enum WenkuSection: String, CaseIterable, Identifiable {
    case search, favorites, downloaded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .search: "搜索"
        case .favorites: "收藏"
        case .downloaded: "下载列表"
        }
    }
}

private struct WenkuNovelRow: View {
    let novel: WenkuNovelOutline

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: novel.cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
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
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var store: WenkuStore
    @EnvironmentObject private var localLibrary: WenkuLocalLibraryStore
    let outline: WenkuNovelOutline
    @State private var detail: WenkuNovelDetail?
    @State private var error: String?
    @State private var isLoading = true
    @State private var downloadRequest: WenkuDownloadRequest?
    @State private var favoriteError: String?

    private let api = NoveliaAPIClient()

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(detail)
                            .onAppear { blocked.rememberWenku(id: detail.id, tags: detail.keywords) }
                        if !detail.introduction.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("简介").font(.headline)
                                Text(detail.introduction).font(.system(size: 14)).lineSpacing(5)
                            }
                        }
                        if !detail.keywords.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("标签").font(.headline)
                                ForEach(detail.keywords, id: \.self) { tag in
                                    Button(blocked.contains(tag) ? "解除屏蔽：\(tag)" : "屏蔽：\(tag)") {
                                        if blocked.contains(tag) { blocked.remove(tag) } else { blocked.add(tag) }
                                    }
                                }
                                NavigationLink("管理屏蔽标签") { BlockedTagsView() }
                            }
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
        .task(id: outline.id) { await loadDetail() }
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
            AsyncImage(url: detail.cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10).fill(NoveliaStyle.brandGreen.opacity(0.12))
                    .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(NoveliaStyle.brandGreen))
            }
            .frame(width: 112, height: 154).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.displayTitle).font(.system(size: 21, weight: .bold)).foregroundStyle(NoveliaStyle.ink)
                if detail.title != detail.displayTitle { Text(detail.title).font(.system(size: 13)).foregroundStyle(NoveliaStyle.muted) }
                if !detail.authors.isEmpty { Label(detail.authors.joined(separator: "、"), systemImage: "person").font(.caption).foregroundStyle(NoveliaStyle.muted) }
                if !detail.publisher.isNilOrEmpty { Text([detail.publisher, detail.imprint].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(NoveliaStyle.muted) }
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

    private let api = NoveliaAPIClient()

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
                if finished { Section { Label("下载完成，可在“我的 → 我的下载”中导出", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
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
