import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// “发现”页：顶部切换网络小说与文库，分别保留原有的搜索、排行榜与收藏入口。
struct DiscoverHomeView: View {
    @Environment(\.keyboardPageActive) private var keyboardParentActive
    private enum Catalog: String, CaseIterable, Identifiable {
        case webNovel, wenku
        var id: String { rawValue }
        var title: String { self == .webNovel ? "网络小说" : "文库小说" }
    }

    @SceneStorage("discover.catalog") private var catalog = Catalog.webNovel
    @State private var loaded = Set<Catalog>()

    var body: some View {
        VStack(spacing: 0) {
            Picker("发现内容", selection: $catalog) {
                ForEach(Catalog.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: 760)
            // 两个分段首次打开后都保留，切换时不丢失搜索词和已加载的列表。
            ZStack {
                ForEach(Catalog.allCases.filter { loaded.contains($0) || $0 == catalog }) { item in
                    Group {
                        switch item {
                        case .webNovel: DiscoverView(embedded: true)
                        case .wenku: WenkuView(embedded: true)
                        }
                    }
                    .opacity(item == catalog ? 1 : 0)
                    .allowsHitTesting(item == catalog)
                    .accessibilityHidden(item != catalog)
                    .environment(\.keyboardPageActive, keyboardParentActive && item == catalog)
                }
            }
        }
        .onValueChange(of: catalog, initial: true) { _, value in loaded.insert(value) }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// 发现页快捷入口：轻图标徽章 + 标题，视觉上与筛选药丸明确区分。
struct DiscoverShortcutChip: View {
    let title: String
    let systemImage: String
    var tint: Color = NoveliaStyle.brandGreen
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(1)
            if !compact {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: compact ? nil : .infinity, minHeight: 40)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusMedium)
        .contentShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
    }
}

/// 仿网页端的页码条：上一页、首页、当前页附近的页码、末页、下一页；下方可输入页码跳转，点省略号也会弹出输入框。
struct PageNavigator: View {
    let page: Int
    let pageCount: Int
    var isLoading = false
    let onSelect: (Int) -> Void

    @State private var showsJump = false
    @State private var jumpText = ""
    @State private var inlineJumpText = ""
    @FocusState private var inlineJumpFocused: Bool

    private enum Item: Hashable {
        case number(Int)
        case gap(Int)
    }

    /// 例如共 500 页、当前第 7 页时为：1 … 6 7 8 … 500。
    private var items: [Item] {
        guard pageCount > 1 else { return [.number(1)] }
        let window = max(1, page - 1)...min(pageCount, page + 1)
        var numbers = Set(window)
        numbers.formUnion([1, pageCount])
        // 只差一页时直接显示该页，不用省略号。
        if window.lowerBound == 3 { numbers.insert(2) }
        if window.upperBound == pageCount - 2 { numbers.insert(pageCount - 1) }
        var result: [Item] = []
        var previous = 0
        for number in numbers.sorted() {
            if number - previous > 1 { result.append(.gap(number)) }
            result.append(.number(number))
            previous = number
        }
        return result
    }

    var body: some View {
        VStack(spacing: 10) {
            pageButtons
            if pageCount > 1 { jumpRow }
        }
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .alert("跳转到页码", isPresented: $showsJump) {
            TextField("1–\(pageCount)", text: $jumpText)
                .keyboardType(.numberPad)
            Button("跳转") { jump(to: jumpText) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(pageCount) 页")
        }
    }

    /// 输入页码跳转，超出范围时取最近的有效页。
    private var jumpRow: some View {
        let canJump = Int(inlineJumpText.trimmingCharacters(in: .whitespaces)) != nil
        return HStack(spacing: 8) {
            Text("跳至")
            TextField("\(page)", text: $inlineJumpText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .focused($inlineJumpFocused)
                .frame(width: 60, height: 30)
                .noveliaCard(cornerRadius: NoveliaStyle.radiusSmall)
                .onSubmit { submitInlineJump() }
                .accessibilityLabel("页码")
            Text("/ \(pageCount) 页")
            Button("跳转") { submitInlineJump() }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(canJump ? .white : NoveliaStyle.muted.opacity(0.6))
                .background(canJump ? NoveliaStyle.brandGreen : NoveliaStyle.card, in: Capsule())
                .overlay(Capsule().stroke(canJump ? Color.clear : NoveliaStyle.hairline, lineWidth: 0.75))
                .buttonStyle(.plain)
                .disabled(!canJump)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(NoveliaStyle.muted)
        .compatKeyboardJumpToolbar(isPresented: inlineJumpFocused, action: submitInlineJump)
    }

    private var pageButtons: some View {
        HStack(spacing: 6) {
            arrow("chevron.left", label: "上一页", target: page - 1)
            ForEach(items, id: \.self) { item in
                switch item {
                case let .number(number):
                    Button { select(number) } label: {
                        Text("\(number)")
                            .font(.system(size: 14, weight: number == page ? .bold : .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 32, minHeight: 32)
                            .padding(.horizontal, 2)
                            .foregroundStyle(number == page ? Color.white : NoveliaStyle.ink)
                            .background(number == page ? NoveliaStyle.brandGreen : NoveliaStyle.card,
                                        in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
                    }
                    .accessibilityLabel("第 \(number) 页")
                    .accessibilityAddTraits(number == page ? .isSelected : [])
                case .gap:
                    Button {
                        jumpText = ""
                        showsJump = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.muted)
                            .frame(width: 26, height: 32)
                    }
                    .accessibilityLabel("跳转到指定页")
                }
            }
            arrow("chevron.right", label: "下一页", target: page + 1)
        }
        .buttonStyle(.plain)
    }

    private func submitInlineJump() {
        jump(to: inlineJumpText)
        inlineJumpText = ""
        inlineJumpFocused = false
    }

    private func jump(to text: String) {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        select(min(max(1, number), pageCount))
    }

    private func arrow(_ systemImage: String, label: String, target: Int) -> some View {
        let enabled = (1...pageCount).contains(target)
        return Button { select(target) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(enabled ? NoveliaStyle.ink : NoveliaStyle.muted.opacity(0.4))
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func select(_ target: Int) {
        guard target != page, (1...max(1, pageCount)).contains(target) else { return }
        NoveliaHaptics.selection()
        onSelect(target)
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var services: AppServices
    var initialQuery: String = ""
    var showsNavigationBar = false
    var embedded = false
    var body: some View {
        DiscoverContentView(initialQuery: initialQuery, showsNavigationBar: showsNavigationBar,
                            embedded: embedded, api: services.api.catalog, wenku: services.api.wenku)
    }
}

private struct DiscoverContentView: View {
    @Environment(\.browseSelection) private var keyboardSelect
    @Environment(\.browseSelectedID) private var keyboardSelectedID
    @Environment(\.browseReading) private var keyboardRead
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var readingHistory: ReadingHistoryStore
    @FocusState private var searchFocused: Bool
    @StateObject private var searchHistory = SearchHistoryStore(scope: .discoverWeb)
    @EnvironmentObject private var blocked: BlockedTagsStore
    @State private var query = ""
    @State private var filter = NovelCatalogFilter.standard
    @StateObject private var store: DiscoverStore
    @State private var resumingItemID: String?
    @State private var resumedTarget: CloudReadingContinuation?
    @State private var resumeErrorMessage: String?
    private let showsNavigationBar: Bool
    /// 嵌入“发现”页的“网络小说”分段时，不显示自己的大标题，也不改动导航栏。
    private let embedded: Bool

    init(initialQuery: String, showsNavigationBar: Bool, embedded: Bool, api: any NovelCatalogService, wenku: any WenkuCatalogService) {
        _store = StateObject(wrappedValue: DiscoverStore(api: api, wenku: wenku))
        _query = State(initialValue: initialQuery)
        self.showsNavigationBar = showsNavigationBar
        self.embedded = embedded
    }

    /// 切换筛选或搜索词都从第 1 页重新加载；返回详情页时同一组合不会重复请求。
    private var requestKey: String {
        "\(query)|\(filter.kind.rawValue)|\(filter.rating.rawValue)|\(filter.sort.rawValue)"
    }

    private var listTitle: String {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "搜索结果" }
        return filter.sort == .popular ? "热门作品" : "最近更新"
    }

    var body: some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle(showsNavigationBar ? "搜索结果" : "")
                .navigationBarTitleDisplayMode(.inline)
                .compatToolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var content: some View {
        GeometryReader { geometry in
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Color.clear.frame(height: 0).id(Self.topAnchor)
                if !embedded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FIND YOUR NEXT STORY")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .compatTracking(1.4)
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        Text("发现好故事")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(NoveliaStyle.ink)
                    }
                }

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(searchFocused ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                    TextField("搜索书名、作者或题材", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            searchFocused = false
                            searchHistory.record(query)
                        }
                        .font(.system(size: 14))
                        .compatAutocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                        .accessibilityLabel("清空搜索词")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .noveliaCard(cornerRadius: NoveliaStyle.radiusMedium, isSelected: searchFocused)

                if searchFocused && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SearchHistoryStrip(store: searchHistory) { term in
                        query = term
                        searchFocused = false
                        searchHistory.record(term)
                    }
                }

                let recentOnline = recentContinueItems
                if !recentOnline.isEmpty {
                    DiscoverContinueReadingStrip(
                        items: recentOnline,
                        resumingItemID: resumingItemID,
                        errorMessage: resumeErrorMessage,
                        onDismissError: { resumeErrorMessage = nil },
                        onResume: { item in resumeOnline(item) }
                    )
                }

                HStack(spacing: 10) {
                    BrowseListLink { RankingView() } label: {
                        DiscoverShortcutChip(title: "排行榜", systemImage: "flame.fill", tint: Color.orange)
                    }
                    BrowseListLink { CloudFavoritesListView() } label: {
                        DiscoverShortcutChip(title: "收藏", systemImage: "heart.fill", tint: Color.pink)
                    }
                    BrowseListLink { CloudReadingHistoryListView() } label: {
                        DiscoverShortcutChip(title: "历史", systemImage: "clock.arrow.circlepath", tint: Color.blue)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(listTitle)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(NoveliaStyle.ink)
                        Spacer()
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Novelia 在线书源")
                                .font(NoveliaStyle.fontCaption)
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                    }

                    // 与网页端一致的列表筛选：类型、分级和排序；默认组合保持原有“全部/一般向/更新”。
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Menu {
                                Picker("类型", selection: $filter.kind) {
                                    ForEach(NovelCatalogFilter.Kind.allCases, id: \.self) { kind in
                                        Text(kind.title).tag(kind)
                                    }
                                }
                            } label: {
                                DiscoverFilterChip(category: "类型", value: filter.kind.title,
                                                   isDefault: filter.kind == .all)
                            }
                            Menu {
                                Picker("分级", selection: $filter.rating) {
                                    ForEach(NovelCatalogFilter.Rating.allCases, id: \.self) { rating in
                                        Text(rating.title).tag(rating)
                                    }
                                }
                            } label: {
                                DiscoverFilterChip(category: "分级", value: filter.rating.title,
                                                   isDefault: filter.rating == .general)
                            }
                            Menu {
                                Picker("排序", selection: $filter.sort) {
                                    ForEach(NovelCatalogFilter.Sort.allCases, id: \.self) { sort in
                                        Text(sort.title).tag(sort)
                                    }
                                }
                            } label: {
                                DiscoverFilterChip(category: "排序", value: filter.sort.title,
                                                   isDefault: filter.sort == .updated)
                            }
                        }
                    }

                    if filter.rating != .general {
                        Text("“全部”和“R18”分级需要已登录且具备 R18 权限的账号。")
                            .font(NoveliaStyle.fontMicro)
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }
                .padding(.top, 2)

                if let errorMessage = store.errorMessage {
                    CompatUnavailable {
                        Label("暂时无法连接", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await store.goTo(page: store.page) } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                }

                // 列数取自内容区可用宽度；分屏变窄时回到单列，不按设备型号判断。
                let cardWidth = min(1120, max(0, geometry.size.width - 32))
                let cardColumns = dynamicTypeSize.isAccessibilitySize ? 1 : max(1, Int((cardWidth + 14) / 360))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: cardColumns), spacing: 12) {
                    if store.isLoading && store.novels.isEmpty && store.errorMessage == nil {
                        ForEach(0..<4, id: \.self) { _ in
                            NoveliaListSkeletonCard(showsCover: true)
                        }
                    } else {
                        ForEach(store.novels.filter { !blocked.hides($0.genres) }) { novel in
                            BrowseDetailLink(destination: .novel(novel)) {
                                FeaturedNovelCard(novel: novel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("discover-card-\(novel.id)")
                            .id("novel:" + novel.id)
                        }
                    }
                }
                if !store.novels.isEmpty || store.page > 1 {
                    PageNavigator(page: store.page, pageCount: store.pageCount, isLoading: store.isLoading) { target in
                        Task { await store.goTo(page: target) }
                    }
                }
                if !store.wenkuNovels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("文库（中文译本）")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.ink)
                            Spacer()
                            Text("共 \(store.wenkuNovels.count) 部")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                        Text("网络小说书源没有匹配结果，以下是在文库中找到的作品。进入文库详情页可以跳转到对应的网络小说。")
                            .font(NoveliaStyle.fontFootnote)
                            .foregroundStyle(NoveliaStyle.muted)
                        ForEach(store.wenkuNovels) { novel in
                            BrowseDetailLink(destination: .wenku(novel)) {
                                WenkuNovelRow(novel: novel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                if store.novels.isEmpty && store.wenkuNovels.isEmpty && store.errorMessage == nil && !store.isLoading {
                    CompatSearchUnavailable(text: query)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .frame(maxWidth: 1160)
            .frame(maxWidth: .infinity)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .compatScrollDismissesKeyboardInteractively()
        // 翻页后回到顶部，像网页端一样从新一页的第一部作品开始看。
        .onValueChange(of: store.page) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
        .pageKeyboardActions(browseKeyboardActions(
            destinations: store.novels.filter { !blocked.hides($0.genres) }.map(BrowseDestination.novel),
            selectedID: keyboardSelectedID, select: keyboardSelect, read: keyboardRead,
            search: { searchFocused = true },
            scrollTo: { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }))
        }
        }
        .task(id: requestKey) { await store.searchIfNeeded(query: query, filter: filter) }
        .task(id: auth.username) {
            guard let username = auth.username, !username.isEmpty else { return }
            if readingHistory.items.isEmpty && !readingHistory.isLoading {
                await readingHistory.refresh(account: username)
            }
        }
        .compatNavigationDestination(item: $resumedTarget) { target in
            ReaderView(novel: target.novel, startingAt: target.chapterIndex)
        }
    }

    private var recentContinueItems: [NoveliaCloudReadingHistoryItem] {
        guard auth.username != nil else { return [] }
        return Array(readingHistory.items.filter { !blocked.hides($0.novel.genres) }.prefix(5))
    }

    private func resumeOnline(_ item: NoveliaCloudReadingHistoryItem) {
        guard resumingItemID == nil, let username = auth.username, !username.isEmpty else { return }
        NoveliaHaptics.selection()
        resumingItemID = item.id
        resumeErrorMessage = nil
        Task {
            defer { resumingItemID = nil }
            do {
                let continuation = try await readingHistory.continuation(for: item, account: username)
                if let keyboardRead {
                    keyboardRead(.online(continuation.novel, continuation.chapterIndex))
                } else {
                    resumedTarget = continuation
                }
            } catch {
                resumeErrorMessage = error.localizedDescription
            }
        }
    }

    private static let topAnchor = "discover-top"
}

/// 「发现 → 网络小说」顶部的「继续追更」单行横幅：支持单本全宽或最多 5 本横滑，点按 1 步直达在线阅读器。
private struct DiscoverContinueReadingStrip: View {
    let items: [NoveliaCloudReadingHistoryItem]
    let resumingItemID: String?
    let errorMessage: String?
    let onDismissError: () -> Void
    let onResume: (NoveliaCloudReadingHistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.count == 1, let item = items.first {
                bannerCard(item, fullWidth: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { item in
                            bannerCard(item, fullWidth: false)
                        }
                    }
                }
            }
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(NoveliaStyle.warning)
                    Text(errorMessage)
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { onDismissError() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func bannerCard(_ item: NoveliaCloudReadingHistoryItem, fullWidth: Bool) -> some View {
        let isResuming = resumingItemID == item.id
        return Button {
            onResume(item)
        } label: {
            HStack(spacing: 11) {
                BookCover(novel: item.novel, width: 32, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("继续追更")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        if let ts = item.lastReadAt, ts > 0 {
                            Text("· \(Self.relativeTime(ts))")
                                .font(NoveliaStyle.fontMicro)
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                    }
                    Text(item.novel.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Group {
                    if isResuming {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 26)
                    } else {
                        Text("续读")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(NoveliaStyle.brandGreen, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: fullWidth ? .infinity : 272, alignment: .leading)
            .noveliaCard(cornerRadius: NoveliaStyle.radiusMedium)
            .contentShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(resumingItemID != nil)
        .accessibilityLabel("继续追更：\(item.novel.title)")
    }

    private static func relativeTime(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 筛选菜单的收起状态标签：紧凑视觉高度，非默认选项用柔和品牌色底强调。
private struct DiscoverFilterChip: View {
    let category: String
    let value: String
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(category)
                .foregroundStyle(isDefault ? NoveliaStyle.muted : NoveliaStyle.brandGreen.opacity(0.8))
            Text(value)
                .foregroundStyle(isDefault ? NoveliaStyle.ink : NoveliaStyle.brandGreen)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isDefault ? NoveliaStyle.muted : NoveliaStyle.brandGreen)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(isDefault ? NoveliaStyle.card : NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
        .overlay(
            Capsule().stroke(
                isDefault ? NoveliaStyle.hairline : NoveliaStyle.brandGreen.opacity(0.35),
                lineWidth: 0.75
            )
        )
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category)：\(value)")
        .accessibilityAddTraits(.isButton)
    }
}

private extension NovelCatalogFilter.Kind {
    var title: String {
        switch self {
        case .all: return "全部"
        case .ongoing: return "连载中"
        case .completed: return "已完结"
        case .shortStory: return "短篇"
        }
    }
}

private extension NovelCatalogFilter.Rating {
    var title: String {
        switch self {
        case .all: return "全部"
        case .general: return "一般向"
        case .r18: return "R18"
        }
    }
}

private extension NovelCatalogFilter.Sort {
    var title: String {
        switch self {
        case .updated: return "更新"
        case .popular: return "点击"
        case .relevant: return "相关"
        }
    }
}

private struct RankingView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View { RankingContentView(api: services.api.catalog) }
}

private struct RankingContentView: View {
    @EnvironmentObject private var blocked: BlockedTagsStore
    @State private var page = 1
    @StateObject private var store: RankingStore

    init(api: any NovelCatalogService) {
        _store = StateObject(wrappedValue: RankingStore(api: api))
    }

    private var requestKey: String { String(page) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RANKING")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .compatTracking(1.4)
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Text("小说排行榜")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                }
                .id("ranking-top")

                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Text("Novelia 站内点击热度 · 一般向作品")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))

                if store.isLoading && store.novels.isEmpty {
                    HStack { Spacer(); ProgressView("正在加载排行榜…"); Spacer() }
                        .padding(.vertical, 24)
                }

                if let errorMessage = store.errorMessage {
                    CompatUnavailable {
                        Label("排行榜加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await loadCurrentPage() } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                }

                ForEach(Array(store.novels.enumerated()).filter { !blocked.hides($0.element.genres) }, id: \.element.id) { index, novel in
                    BrowseDetailLink(destination: .novel(novel)) {
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", (page - 1) * 20 + index + 1))
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(index < 3 && page == 1 ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                                .frame(width: 34)
                            FeaturedNovelCard(novel: novel)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if store.pageCount > 1 {
                    PageNavigator(page: page, pageCount: store.pageCount, isLoading: store.isLoading) { page = $0 }
                } else if !store.novels.isEmpty {
                    Text("共 \(store.novels.count) 部上榜作品")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if !store.isLoading && store.errorMessage == nil {
                    CompatUnavailable("暂无排行榜作品", systemImage: "chart.bar")
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .onValueChange(of: page) { _, _ in proxy.scrollTo("ranking-top", anchor: .top) }
        }
        .navigationTitle("小说排行榜")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: requestKey) { await store.loadIfNeeded(page: page) }
    }

    private func loadCurrentPage() async {
        await store.load(page: page)
    }
}

struct TagSearchResultsView: View {
    @EnvironmentObject private var services: AppServices
    let tag: String
    var body: some View {
        TagSearchContentView(tag: tag, api: services.api.catalog, wenku: services.api.wenku)
    }
}

private struct TagSearchContentView: View {
    @EnvironmentObject private var blocked: BlockedTagsStore
    let tag: String
    @StateObject private var store: DiscoverStore

    init(tag: String, api: any NovelCatalogService, wenku: any WenkuCatalogService) {
        self.tag = tag
        _store = StateObject(wrappedValue: DiscoverStore(api: api, wenku: wenku))
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("按标签筛选")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Text(tag)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                    Text("精确匹配包含此标签的作品")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .id("tag-search-top")

                if store.isLoading && store.novels.isEmpty {
                    HStack { Spacer(); ProgressView("正在搜索标签…"); Spacer() }
                        .padding(.vertical, 28)
                }

                if let errorMessage = store.errorMessage {
                    CompatUnavailable {
                        Label("标签搜索失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            Task { await store.goTo(page: store.page) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(NoveliaStyle.brandGreen)
                    }
                }

                ForEach(store.novels.filter { !blocked.hides($0.genres) }) { novel in
                    BrowseDetailLink(destination: .novel(novel)) {
                        FeaturedNovelCard(novel: novel)
                    }
                    .buttonStyle(.plain)
                }

                if !store.novels.isEmpty || store.page > 1 {
                    PageNavigator(page: store.page, pageCount: store.pageCount, isLoading: store.isLoading) { target in
                        Task { await store.goTo(page: target) }
                    }
                } else if !store.isLoading && store.errorMessage == nil {
                    CompatSearchUnavailable(text: tag)
                        .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .onValueChange(of: store.page) { _, _ in proxy.scrollTo("tag-search-top", anchor: .top) }
        }
        .navigationTitle("标签搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.searchIfNeeded(query: tag, exactTag: true) }
    }
}
