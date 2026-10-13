import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

/// “发现”页：顶部切换网络小说与文库，分别保留原有的搜索、排行榜与收藏入口。
struct DiscoverHomeView: View {
    private enum Catalog: String, CaseIterable, Identifiable {
        case webNovel, wenku
        var id: String { rawValue }
        var title: String { self == .webNovel ? "网络小说" : "文库" }
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
            .padding(.bottom, 8)
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
                }
            }
        }
        .onChange(of: catalog, initial: true) { _, value in loaded.insert(value) }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 发现页搜索框下方的快捷入口。
struct DiscoverShortcutChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NoveliaStyle.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(NoveliaStyle.card, in: Capsule())
            .overlay(Capsule().stroke(NoveliaStyle.muted.opacity(0.18), lineWidth: 1))
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
        HStack(spacing: 8) {
            Text("跳至")
            TextField("\(page)", text: $inlineJumpText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .focused($inlineJumpFocused)
                .frame(width: 64, height: 32)
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(NoveliaStyle.muted.opacity(0.2), lineWidth: 1))
                .onSubmit { submitInlineJump() }
                .accessibilityLabel("页码")
            Text("/ \(pageCount) 页")
            Button("跳转") { submitInlineJump() }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(NoveliaStyle.brandGreen)
                .disabled(Int(inlineJumpText.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(NoveliaStyle.muted)
        .toolbar {
            // 数字键盘没有回车键，用键盘上方的按钮完成跳转。
            if inlineJumpFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("跳转") { submitInlineJump() }
                }
            }
        }
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
                                        in: RoundedRectangle(cornerRadius: 8))
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
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func select(_ target: Int) {
        guard target != page, (1...max(1, pageCount)).contains(target) else { return }
        onSelect(target)
    }
}

struct DiscoverView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var query = ""
    @StateObject private var store = DiscoverStore()
    private let showsNavigationBar: Bool
    /// 嵌入“发现”页的“网络小说”分段时，不显示自己的大标题，也不改动导航栏。
    private let embedded: Bool

    init(initialQuery: String = "", showsNavigationBar: Bool = false, embedded: Bool = false) {
        _query = State(initialValue: initialQuery)
        self.showsNavigationBar = showsNavigationBar
        self.embedded = embedded
    }

    var body: some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle(showsNavigationBar ? "搜索结果" : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Color.clear.frame(height: 0).id(Self.topAnchor)
                if !embedded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FIND YOUR NEXT STORY")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        Text("发现好故事")
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                            .foregroundStyle(NoveliaStyle.ink)
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(NoveliaStyle.muted)
                    TextField("搜索书名、作者或题材", text: $query)
                        .font(.system(size: 15))
                        .autocorrectionDisabled()
                }
                .padding(14)
                .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 15))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        NavigationLink { RankingView() } label: {
                            DiscoverShortcutChip(title: "排行榜", systemImage: "chart.line.uptrend.xyaxis")
                        }
                        NavigationLink { CloudFavoritesListView() } label: {
                            DiscoverShortcutChip(title: "收藏", systemImage: "heart")
                        }
                        NavigationLink { CloudReadingHistoryListView() } label: {
                            DiscoverShortcutChip(title: "阅读历史", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    .buttonStyle(.plain)
                }

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
                        Button("重试") { Task { await store.goTo(page: store.page) } }
                            .buttonStyle(.borderedProminent)
                            .tint(NoveliaStyle.brandGreen)
                    }
                }

                ForEach(store.novels.filter { !blocked.hides($0.genres) }) { novel in
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        FeaturedNovelCard(novel: novel)
                    }
                    .buttonStyle(.plain)
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
                            .font(.system(size: 12))
                            .foregroundStyle(NoveliaStyle.muted)
                        ForEach(store.wenkuNovels) { novel in
                            NavigationLink {
                                WenkuDetailView(outline: novel)
                            } label: {
                                WenkuNovelRow(novel: novel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                if store.novels.isEmpty && store.wenkuNovels.isEmpty && store.errorMessage == nil && !store.isLoading {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        // 翻页后回到顶部，像网页端一样从新一页的第一部作品开始看。
        .onChange(of: store.page) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
        }
        .task(id: query) { await store.searchIfNeeded(query: query) }
    }

    private static let topAnchor = "discover-top"
}

private struct RankingView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var page = 1
    @StateObject private var store = RankingStore()

    private var requestKey: String { String(page) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RANKING")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
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
                    ContentUnavailableView {
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
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
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
                    ContentUnavailableView("暂无排行榜作品", systemImage: "chart.bar")
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .onChange(of: page) { proxy.scrollTo("ranking-top", anchor: .top) }
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
    @ObservedObject private var blocked = BlockedTagsStore.shared
    let tag: String
    @StateObject private var store = DiscoverStore()

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
                    ContentUnavailableView {
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
                    NavigationLink {
                        NovelDetailView(novel: novel)
                    } label: {
                        FeaturedNovelCard(novel: novel)
                    }
                    .buttonStyle(.plain)
                }

                if !store.novels.isEmpty || store.page > 1 {
                    PageNavigator(page: store.page, pageCount: store.pageCount, isLoading: store.isLoading) { target in
                        Task { await store.goTo(page: target) }
                    }
                } else if !store.isLoading && store.errorMessage == nil {
                    ContentUnavailableView.search(text: tag)
                        .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .onChange(of: store.page) { proxy.scrollTo("tag-search-top", anchor: .top) }
        }
        .navigationTitle("标签搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.searchIfNeeded(query: tag, exactTag: true) }
    }
}
