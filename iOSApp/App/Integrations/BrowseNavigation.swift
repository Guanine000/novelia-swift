import SwiftUI
import UIKit

/// 浏览选择只保存页面目标；账号、书库、进度等实例仍由 AppServices 和 RootView 持有。
enum BrowseDestination: Identifiable {
    case library(LibraryBook)
    case novel(Novel)
    case wenku(WenkuNovelOutline)

    var id: String {
        switch self {
        case .library(let book): "library:" + book.key
        case .novel(let novel): "novel:" + novel.id
        case .wenku(let novel): "wenku:" + novel.id
        }
    }
}

/// iPad 浏览器发起完整窗口阅读；手机没有此环境动作，继续沿用原有导航链接。
enum BrowseReadingDestination: Identifiable {
    case library(LibraryBook)
    case online(Novel, Int)
    var id: String {
        switch self {
        case .library(let book): "library:" + book.key
        case .online(let novel, let chapter): "online:\(novel.id):\(chapter)"
        }
    }
}

/// 每次关闭阅读都产生一次定位请求，确保最近阅读排序变化后仍能找到刚才的书。
struct BrowseReadingReturn: Equatable {
    let id = UUID()
    let bookKey: String
}
private struct BrowseReadingReturnKey: EnvironmentKey {
    static let defaultValue: BrowseReadingReturn? = nil
}
private struct BrowseSelectionKey: EnvironmentKey {
    static let defaultValue: ((BrowseDestination) -> Void)? = nil
}
private struct BrowseSelectedIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
private struct BrowseReadingKey: EnvironmentKey {
    static let defaultValue: ((BrowseReadingDestination) -> Void)? = nil
}
extension EnvironmentValues {
    var browseReadingReturn: BrowseReadingReturn? {
        get { self[BrowseReadingReturnKey.self] }
        set { self[BrowseReadingReturnKey.self] = newValue }
    }
    var browseSelection: ((BrowseDestination) -> Void)? {
        get { self[BrowseSelectionKey.self] }
        set { self[BrowseSelectionKey.self] = newValue }
    }
    var browseSelectedID: String? {
        get { self[BrowseSelectedIDKey.self] }
        set { self[BrowseSelectedIDKey.self] = newValue }
    }
    var browseReading: ((BrowseReadingDestination) -> Void)? {
        get { self[BrowseReadingKey.self] }
        set { self[BrowseReadingKey.self] = newValue }
    }
}

/// 侧栏中的二级列表留在同一列，并显式传递选择动作；系统导航目标不能继承右列的空动作。
struct BrowseListLink<Destination: View, Label: View>: View {
    @Environment(\.browseSelection) private var select
    @Environment(\.browseSelectedID) private var selectedID
    let destination: () -> Destination
    let label: () -> Label
    var body: some View {
        NavigationLink {
            destination()
                .environment(\.browseSelection, select)
                .environment(\.browseSelectedID, selectedID)
        } label: { label() }
        .isDetailLink(false)
    }
}

/// 列表中的详情入口：分栏列表提交选择，其余页面仍可在所在导航栈内继续查看详情。
struct BrowseDetailLink<Label: View>: View {
    @Environment(\.browseSelection) private var select
    @Environment(\.browseSelectedID) private var selectedID
    let destination: BrowseDestination
    let label: () -> Label
    var body: some View {
        Group {
            if let select {
                Button { select(destination) } label: { label() }
            } else {
                NavigationLink { BrowseDetailContent(destination: destination) } label: { label() }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge)
            .stroke(selectedID == destination.id ? NoveliaStyle.brandGreen : .clear, lineWidth: 2)
            .allowsHitTesting(false))
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selectedID == destination.id ? .isSelected : [])
    }
}

struct BrowseReadingLink<Label: View>: View {
    @Environment(\.browseReading) private var present
    let destination: BrowseReadingDestination
    let label: () -> Label
    var body: some View {
        if let present {
            Button { present(destination) } label: { label() }
        } else {
            NavigationLink { BrowseReadingContent(destination: destination) } label: { label() }
        }
    }
}

private struct BrowseReadingContent: View {
    let destination: BrowseReadingDestination
    var body: some View {
        switch destination {
        case .library(let book): LibraryReaderDestination(book: book)
        case .online(let novel, let chapter): ReaderView(novel: novel, startingAt: chapter)
        }
    }
}

/// 滚动阅读原本依赖压栈后的系统返回键；全窗口展示时由覆盖层提供明确的关闭动作。
private struct BrowseReadingPresentation: View {
    @Environment(\.dismiss) private var dismiss
    let destination: BrowseReadingDestination
    var body: some View {
        CompatNavigationStack {
            BrowseReadingContent(destination: destination)
                .environment(\.readerCloseAction, { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .compatTopBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("返回")
                    }
                }
        }
    }
}

private struct BrowseDetailContent: View {
    let destination: BrowseDestination
    var body: some View {
        switch destination {
        case .library(let book): LibraryBookDetailView(book: book, embedded: true)
        case .novel(let novel): NovelDetailView(novel: novel)
        case .wenku(let novel): WenkuDetailView(outline: novel)
        }
    }
}

/// 每个标签持有自己的选择和阅读展示；尺寸变化只交给系统分栏容器处理，不切换视图树。
struct BrowseNavigationRoot<Master: View>: View {
    @EnvironmentObject private var libraryState: LibraryStateStore
    @State private var selection: BrowseDestination?
    @State private var reading: BrowseReadingDestination?
    @State private var readingBookKey: String?
    @State private var readingReturn: BrowseReadingReturn?
    let master: () -> Master

    var body: some View {
        Group {
            if #available(iOS 17, *) {
                ModernBrowseSplit(selection: $selection, master: master)
            } else {
                LegacyBrowseSplit(selection: $selection, master: master)
            }
        }
        .environment(\.browseReading, { destination in
            if case .library(let book) = destination {
                libraryState.markOpened(book)
                readingBookKey = book.key
            } else { readingBookKey = nil }
            reading = destination
        })
        .environment(\.browseReadingReturn, readingReturn)
        .environment(\.keyboardPageActive, reading == nil)
        .fullScreenCover(item: $reading, onDismiss: {
            libraryState.reloadPositions()
            if let readingBookKey { readingReturn = BrowseReadingReturn(bookKey: readingBookKey) }
        }) { destination in
            BrowseReadingPresentation(destination: destination)
                .environment(\.browseSelection, nil)
                .environment(\.browseReading, nil)
                .environment(\.keyboardPageActive, true)
        }
    }
}

@available(iOS 17, *)
private struct ModernBrowseSplit<Master: View>: View {
    @Binding var selection: BrowseDestination?
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    let master: () -> Master

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
            CompatNavigationStack { master() }
                .environment(\.browseSelection, { selection = $0; compactColumn = .detail })
                .environment(\.browseSelectedID, selection?.id)
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 440)
        } detail: {
            CompatNavigationStack { BrowseSelectedDetail(selection: selection) }
                .id(selection?.id)
                .environment(\.browseSelection, nil)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// iOS 15/16 使用系统双列 NavigationView，隐藏链接同时承担窄窗口的压栈和返回。
private struct LegacyBrowseSplit<Master: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var selection: BrowseDestination?
    @State private var showsDetail = false
    let master: () -> Master

    var body: some View {
        NavigationView {
            master()
                .environment(\.browseSelection, { selection = $0; showsDetail = true })
                .environment(\.browseSelectedID, selection?.id)
                .background {
                    NavigationLink(isActive: $showsDetail) {
                        BrowseSelectedDetail(selection: selection)
                            .id(selection?.id)
                            .environment(\.browseSelection, nil)
                    } label: { EmptyView() }
                    .hidden()
                }
            BrowseSelectedDetail(selection: nil)
        }
        .navigationViewStyle(.columns)
        .onValueChange(of: horizontalSizeClass) { _, value in
            if value == .regular, selection != nil { showsDetail = true }
        }
    }
}

private struct BrowseSelectedDetail: View {
    let selection: BrowseDestination?
    var body: some View {
        if let selection {
            BrowseDetailContent(destination: selection)
        } else {
            CompatUnavailable("选择一本书", systemImage: "book", description: Text("从左侧列表选择书籍，查看详情或开始阅读。"))
                .navigationTitle("书籍详情")
        }
    }
}

/// 键盘按当前实际筛选、排序后的数组移动选择；不维护第二份书库顺序。
func browseKeyboardActions(destinations: [BrowseDestination], selectedID: String?,
                           select: ((BrowseDestination) -> Void)?,
                           read: ((BrowseReadingDestination) -> Void)?,
                           search: @escaping () -> Void,
                           scrollTo: @escaping (String) -> Void) -> [PageKeyAction] {
    var actions: [PageKeyAction] = [.command("f", "搜索书籍", action: search)]
    guard let select, !destinations.isEmpty else { return actions }
    func move(_ delta: Int) {
        let old = destinations.firstIndex { $0.id == selectedID }
        let index = old.map { min(destinations.count - 1, max(0, $0 + delta)) } ?? (delta > 0 ? 0 : destinations.count - 1)
        let destination = destinations[index]
        select(destination); scrollTo(destination.id)
    }
    actions += [
        .init(input: UIKeyCommand.inputDownArrow, title: "选择下一本", perform: { _ in move(1) }),
        .init(input: UIKeyCommand.inputUpArrow, title: "选择上一本", perform: { _ in move(-1) }),
        .init(input: "\r", title: "查看所选书籍", perform: { _ in
            if let destination = destinations.first(where: { $0.id == selectedID }) ?? destinations.first { select(destination) }
        })
    ]
    if let read {
        actions.append(.command("\r", "阅读所选书籍") {
            guard let destination = destinations.first(where: { $0.id == selectedID }) else { return }
            switch destination {
            case .library(let book): if !book.isCloudOnly { read(.library(book)) }
            case .novel(let novel): if !novel.chapters.isEmpty { read(.online(novel, 0)) }
            case .wenku: break
            }
        })
    }
    return actions
}
