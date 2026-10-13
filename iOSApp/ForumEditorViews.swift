import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

private struct ForumComposeNotice: View {
    let isPost: Bool
    @Environment(\.openURL) private var parentOpenURL
    @Environment(\.forumLinkActions) private var linkActions

    private var markdown: String {
        if !isPost { return "发言请遵守 [社区守则](https://forum.novelia.cc/rules)。" }
        return """
        - 提问前先阅读 [站务公告](https://forum.novelia.cc/c/announcements) 的新人教程，再搜索 [意见反馈](https://forum.novelia.cc/c/feedback) 中的相同案例，避免重复发帖。
        - 报错请详述问题，并附小说链接或截图。
        - 求书请前往 [求书集中帖](https://forum.novelia.cc/c/novel?q=%E6%B1%82%E4%B9%A6%E9%9B%86%E4%B8%AD%E8%B4%B4)，请勿单独发帖。
        - 碰到此类建政小说时，不要在论坛发帖或群里讨论，请通过 QQ 或 Telegram 私信管理员处理。
        - 发言请遵守 [社区守则](https://forum.novelia.cc/rules)。
        """
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(NoveliaStyle.brandGreen)
            ForumMarkdownBody(markdown: markdown, mode: .article)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(NoveliaStyle.brandGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.openURL, OpenURLAction { url in
            guard let route = ForumNoticeDestination(url: url), let linkActions else {
                parentOpenURL(url)
                return .handled
            }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            linkActions.openNotice(route)
            return .handled
        })
    }
}

/// 在应用内打开论坛 Markdown 中点击的链接。Markdown 也用于
/// 惰性列表和表单，而 SwiftUI 在其中忽略导航目标，因此每个展示页面
/// 都通过此修饰器在根视图统一声明一次导航目标。
struct ForumLinkActions {
    var openNovel: (ForumNovelRoute) -> Void
    var openNotice: (ForumNoticeDestination) -> Void
}

private struct ForumLinkActionsKey: EnvironmentKey {
    static let defaultValue: ForumLinkActions? = nil
}

extension EnvironmentValues {
    var forumLinkActions: ForumLinkActions? {
        get { self[ForumLinkActionsKey.self] }
        set { self[ForumLinkActionsKey.self] = newValue }
    }
}

private struct ForumInAppLinkDestinations: ViewModifier {
    @State private var novelRoute: ForumNovelRoute?
    @State private var notice: ForumNoticeDestination?

    func body(content: Content) -> some View {
        content
            .environment(\.forumLinkActions, ForumLinkActions(openNovel: { novelRoute = $0 }, openNotice: { notice = $0 }))
            .navigationDestination(item: $novelRoute) { route in ForumNovelRouteView(route: route) }
            .navigationDestination(item: $notice) { destination in
                switch destination {
                case let .category(slug, query): ForumView(initialCategory: slug, initialQuery: query)
                case .rules: ForumRulesView()
                }
            }
    }
}

extension View {
    func forumInAppLinkDestinations() -> some View { modifier(ForumInAppLinkDestinations()) }
}

private struct ForumRulesView: View {
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            ForumRulesWebView(onFinish: { isLoading = false }, onError: {
                isLoading = false
                errorMessage = $0
            })
            .id(reloadID)
            if isLoading { ProgressView("正在加载社区守则…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            if let errorMessage {
                ContentUnavailableView {
                    Label("社区守则加载失败", systemImage: "wifi.exclamationmark")
                } description: { Text(errorMessage) } actions: {
                    Button("重试") { self.errorMessage = nil; isLoading = true; reloadID = UUID() }
                }
                .background(NoveliaStyle.paper)
            }
        }
        .navigationTitle("社区守则")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ForumRulesWebView: UIViewRepresentable {
    var onFinish: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://forum.novelia.cc/rules")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ForumRulesWebView
        init(parent: ForumRulesWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.onFinish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.onError(error.localizedDescription) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.onError(error.localizedDescription) }
    }
}

private struct ForumMarkdownHelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let examples: [(String, String)] = [
        ("加粗、斜体与删除线", "**加粗文字**\n*斜体文字*\n~~删除线文字~~"),
        ("链接", "[链接文字](https://n.novelia.cc/)"),
        ("剧透", "!!剧透内容!!"),
        ("标题与引用", "## 二级标题\n> 引用内容"),
        ("列表", "- 第一项\n- 第二项\n\n1. 第一项\n2. 第二项"),
        ("表格", "| 名称 | 说明 |\n| --- | --- |\n| 示例 | 内容 |"),
        ("星级评分", "::: star 4.5"),
        ("折叠内容", "::: details 点击展开\n折叠内容\n:::"),
        ("代码", "`行内代码`\n\n```\n代码块\n```")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选中文字后点击格式按钮，可为选中内容添加标记；没有选中文字时会插入示例。切换到预览查看效果，返回编辑可继续修改。")
                }
                ForEach(examples.indices, id: \.self) { index in
                    Section(examples[index].0) {
                        Text(examples[index].1)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Markdown 语法帮助")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

struct ForumCommentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: String
    let replyTo: String?
    let isEditing: Bool
    let username: String
    let onCancel: () -> Void
    let onSend: () async -> String?

    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 12) {
                HStack {
                    if let replyTo {
                        Label("回复 @\(replyTo)", systemImage: "arrowshape.turn.up.left")
                    } else if isEditing {
                        Label("编辑评论", systemImage: "square.and.pencil")
                    } else {
                        Label("发表评论", systemImage: "bubble.left")
                    }
                    Spacer()
                    Text("以 \(username) 的身份")
                        .font(.caption)
                        .foregroundStyle(NoveliaStyle.muted)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NoveliaStyle.ink)

                ForumComposeNotice(isPost: false)
                ForumMarkdownEditor(draft: $draft, autoFocus: true)
                    .disabled(isSending)
                Spacer(minLength: 0)
            }
            .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .overlay {
                if let sendError {
                    ForumErrorOverlay(message: sendError, onDismiss: { self.sendError = nil })
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button("取消") { onCancel(); dismiss() }.disabled(isSending)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSending { ProgressView().tint(.white) }
                        else { Label(isEditing ? "保存" : "发送", systemImage: isEditing ? "checkmark" : "paperplane.fill") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NoveliaStyle.brandGreen)
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
            .navigationTitle(isEditing ? "编辑评论" : (replyTo == nil ? "发表评论" : "回复评论"))
            .forumInAppLinkDestinations()
            .navigationBarTitleDisplayMode(.inline)

        }
    }

    @MainActor
    private func submit() async {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }
        if let error = await onSend() {
            sendError = error
        } else {
            dismiss()
        }
    }
}

private struct ForumMarkdownEditor: View {
    @Binding var draft: String
    var mode: ForumMarkdownMode = .comment
    var minimumHeight: CGFloat = 190
    var autoFocus = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var isPreviewing = false
    @State private var sendError: String?
    @State private var isHelpPresented = false
    @State private var isLinkDialogPresented = false
    @State private var linkLabel = ""
    @State private var linkURL = "https://"
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                Picker("编辑模式", selection: $isPreviewing) {
                    Text("编辑").tag(false)
                    Text("预览").tag(true)
                }
                .pickerStyle(.segmented)

                Group {
                    if isPreviewing {
                        ScrollView {
                            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("预览内容会显示在这里。")
                                    .foregroundStyle(NoveliaStyle.muted)
                                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                            } else {
                                ForumMarkdownBody(markdown: draft, mode: mode)
                                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                            }
                        }
                        .frame(height: minimumHeight)
                        .padding(12)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ZStack(alignment: .topLeading) {
                            ForumMarkdownTextEditor(text: $draft, selection: $selection)
                                .focused($isEditorFocused)
                                .frame(height: minimumHeight)
                            if draft.isEmpty {
                                Text("支持 Markdown，可使用下方工具栏插入格式。")
                                    .font(.system(size: 15))
                                    .foregroundStyle(NoveliaStyle.muted.opacity(0.75))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(8)
                        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                if !isPreviewing { formattingToolbar }
            Button { isHelpPresented = true } label: {
                Label("Markdown 语法帮助", systemImage: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
        .sheet(isPresented: $isHelpPresented) { ForumMarkdownHelpView() }
        .onChange(of: isPreviewing) { _, preview in if preview { isEditorFocused = false } }
        .overlay {
            if let sendError { ForumErrorOverlay(message: sendError, onDismiss: { self.sendError = nil }) }
        }
            .onAppear { isEditorFocused = autoFocus }
            .alert("插入链接", isPresented: $isLinkDialogPresented) {
                TextField("链接文字", text: $linkLabel)
                TextField("https://example.com", text: $linkURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("取消", role: .cancel) {}
                Button("插入") { insertLink() }
            } message: {
                Text("链接将以 [链接文字](https://example.com) 的格式插入。")
            }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    isEditorFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }

    private var formattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                formatButton("粗体", icon: "bold") { wrapSelection(prefix: "**", suffix: "**", placeholder: "粗体文字") }
                formatButton("斜体", icon: "italic") { wrapSelection(prefix: "*", suffix: "*", placeholder: "斜体文字") }
                formatButton("删除线", icon: "strikethrough") { wrapSelection(prefix: "~~", suffix: "~~", placeholder: "删除的文字") }
                formatButton("链接", icon: "link") {
                    let value = selectedText
                    linkLabel = value.isEmpty ? "链接文字" : value
                    linkURL = "https://"
                    isEditorFocused = false
                    isLinkDialogPresented = true
                }
                formatButton("剧透", icon: "eye.slash") { wrapSelection(prefix: "!!", suffix: "!!", placeholder: "剧透内容") }
                Menu {
                    ForEach(1...10, id: \.self) { step in
                        let rating = Double(step) / 2
                        Button("\(rating.formatted(.number.precision(.fractionLength(0...1)))) 星") {
                            insertMarkdownBlock("::: star \(rating.formatted(.number.precision(.fractionLength(0...1))))")
                        }
                    }
                } label: {
                    Label("星级", systemImage: "star.leadinghalf.filled")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(NoveliaStyle.card, in: Capsule())
                }
                .accessibilityLabel("插入星级评分")
                formatButton("折叠", icon: "rectangle.compress.vertical") { insertDetails() }
            }
            .padding(.vertical, 2)
        }
        .tint(NoveliaStyle.brandGreen)
    }

    private var selectedText: String {
        let source = draft as NSString
        guard selection.location != NSNotFound, selection.location + selection.length <= source.length else { return "" }
        return source.substring(with: selection)
    }

    private func formatButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(NoveliaStyle.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let source = draft as NSString
        let safeLocation = selection.location == NSNotFound ? source.length : min(selection.location, source.length)
        let safeLength = min(selection.length, source.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)
        let selected = source.substring(with: range)
        let content = selected.isEmpty ? placeholder : selected
        let replacement = prefix + content + suffix
        draft = source.replacingCharacters(in: range, with: replacement)
        selection = NSRange(location: range.location + (prefix as NSString).length,
                            length: selected.isEmpty ? (content as NSString).length : 0)
        isEditorFocused = true
    }

    private func insertLink() {
        let label = linkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              let components = URLComponents(string: rawURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else {
            sendError = "请输入有效的 HTTP 或 HTTPS 链接和链接文字。"
            return
        }
        insertBlock("[\(label.replacingOccurrences(of: "]", with: "\\]"))](\(rawURL))")
        isLinkDialogPresented = false
    }

    private func insertDetails() {
        let template = "::: details 点击展开\n折叠内容\n:::\n"
        insertMarkdownBlock(template, selecting: "折叠内容")
    }

    private func insertMarkdownBlock(_ block: String, selecting selected: String? = nil) {
        let source = draft as NSString
        let safeLocation = selection.location == NSNotFound ? source.length : min(selection.location, source.length)
        let safeLength = min(selection.length, source.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)
        let prefixSource = source.substring(to: safeLocation)
        let suffixSource = source.substring(from: NSMaxRange(range))
        let prefix = safeLocation == 0 || prefixSource.hasSuffix("\n\n") ? "" : (prefixSource.hasSuffix("\n") ? "\n" : "\n\n")
        let suffix = NSMaxRange(range) == source.length || suffixSource.hasPrefix("\n\n")
            ? "\n"
            : (suffixSource.hasPrefix("\n") ? "\n" : "\n\n")
        let insertion = prefix + block + suffix
        let replacement = source.replacingCharacters(in: range, with: insertion)
        let insertionStart = safeLocation + (prefix as NSString).length
        draft = replacement
        if let selected {
            let searchRange = NSRange(location: insertionStart, length: (block as NSString).length)
            let selectedRange = (replacement as NSString).range(of: selected, options: [], range: searchRange)
            selection = selectedRange.location == NSNotFound
                ? NSRange(location: insertionStart + (block as NSString).length, length: 0)
                : selectedRange
        } else {
            selection = NSRange(location: insertionStart + (block as NSString).length, length: 0)
        }
        isEditorFocused = true
    }

    private func insertBlock(_ value: String, selecting selected: String? = nil) {
        let source = draft as NSString
        let safeLocation = selection.location == NSNotFound ? source.length : min(selection.location, source.length)
        let safeLength = min(selection.length, source.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)
        let replacement = source.replacingCharacters(in: range, with: value)
        draft = replacement
        if let selected {
            let insertionRange = NSRange(location: safeLocation, length: (value as NSString).length)
            let selectedRange = (replacement as NSString).range(of: selected, options: [], range: insertionRange)
            selection = selectedRange.location == NSNotFound
                ? NSRange(location: safeLocation + (value as NSString).length, length: 0)
                : selectedRange
        } else {
            selection = NSRange(location: safeLocation + (value as NSString).length, length: 0)
        }
        isEditorFocused = true
    }

}

private struct ForumMarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, selection: $selection) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.textColor = UIColor.label
        view.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityLabel = "Markdown 正文"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.selection = $selection
        if view.text != text { view.text = text }
        if view.selectedRange != selection { view.selectedRange = selection }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var selection: Binding<NSRange>

        init(text: Binding<String>, selection: Binding<NSRange>) {
            self.text = text
            self.selection = selection
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            selection.wrappedValue = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection.wrappedValue = textView.selectedRange
        }
    }
}

struct ForumComposeView: View {
    @EnvironmentObject private var auth: ForumAuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var categories: [ForumCategory]
    @State private var isLoadingCategories = false
    let initialCategorySlug: String
    let editingPost: ForumPost?
    var onSaved: ((ForumPost) -> Void)?

    @State private var selectedCategoryID: Int64?
    @State private var title = ""
    @State private var content = ""
    @State private var selectedTagIDs: Set<Int64> = []
    @State private var isSending = false
    @State private var errorMessage: String?

    private var selectedCategory: ForumCategory? { categories.first { $0.id == selectedCategoryID } }
    private var api: ForumAPIClient { ForumAPIClient(tokenProvider: { NoveliaForumSessionTokenVault.read() }) }

    init(categories: [ForumCategory], initialCategorySlug: String = "novel", editingPost: ForumPost? = nil, onSaved: ((ForumPost) -> Void)? = nil) {
        _categories = State(initialValue: categories)
        self.initialCategorySlug = initialCategorySlug
        self.editingPost = editingPost
        self.onSaved = onSaved
        _selectedCategoryID = State(initialValue: editingPost?.categoryId ?? categories.first(where: { $0.slug == initialCategorySlug })?.id ?? categories.first?.id)
        _title = State(initialValue: editingPost?.title ?? "")
        _content = State(initialValue: editingPost?.content ?? "")
        _selectedTagIDs = State(initialValue: Set(editingPost?.tags.map(\.id) ?? []))
    }

    private var canSubmit: Bool {
        guard let username = auth.username else { return false }
        return editingPost.map { $0.authorUsername == username } ?? true
    }

    var body: some View {
        Form {
            Section { ForumComposeNotice(isPost: true) }
            if auth.username == nil {
                Section {
                    Button("登录 Novelia后发布") { auth.isLoginPresented = true }
                } footer: {
                    Text("登录后会保留当前正在编写的内容。")
                }
            }
            Section("分类") {
                if categories.isEmpty {
                    if isLoadingCategories { ProgressView("正在读取分类…") }
                    else { Button("重新加载分类与标签") { Task { await loadEditorCategories() } } }
                } else {
                    Picker("发布到", selection: $selectedCategoryID) {
                        ForEach(categories) { category in
                            Text(category.title).tag(Optional(category.id))
                        }
                    }
                }
            }
            if let tags = selectedCategory?.tags, !tags.isEmpty {
                Section("标签（最多选择 3 个）") {
                    ForEach(tags.sorted { $0.sortOrder < $1.sortOrder }) { tag in
                        Toggle(tag.name, isOn: Binding(
                            get: { selectedTagIDs.contains(tag.id) },
                            set: { enabled in
                                if enabled, selectedTagIDs.count < 3 { selectedTagIDs.insert(tag.id) }
                                else { selectedTagIDs.remove(tag.id) }
                            }
                        ))
                    }
                }
            }
            Section("标题") {
                TextField("帖子标题（2–100 字）", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("forum-post-title")
            }
            Section("正文") {
                ForumMarkdownEditor(draft: $content, mode: .article, minimumHeight: 240)
            }
            Section {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await publish() }
                } label: {
                    HStack {
                        Spacer()
                        if isSending { ProgressView() } else { Text(editingPost == nil ? "发布帖子" : "保存修改") }
                        Spacer()
                    }
                }
                .disabled(!canSubmit || selectedCategoryID == nil || !validInput || isSending)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await loadEditorCategories() }
        .disabled(isSending)
        .scrollContentBackground(.hidden)
        .background(NoveliaStyle.paper)
        .navigationTitle(editingPost == nil ? "新建帖子" : "编辑帖子")
        .forumInAppLinkDestinations()
        .interactiveDismissDisabled(isSending)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedCategoryID) { _, _ in selectedTagIDs.removeAll() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if editingPost != nil { Button("取消") { dismiss() }.disabled(isSending) }
            }
            ToolbarItem(placement: .topBarTrailing) { if isSending { ProgressView() } }
        }
        .overlay {
            if let errorMessage {
                ForumErrorOverlay(message: errorMessage, onDismiss: { self.errorMessage = nil })
            }
        }
    }

    @MainActor
    private func loadEditorCategories() async {
        guard !isLoadingCategories else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }
        do {
            let fetched = try await api.categories()
            categories = fetched
            if selectedCategoryID == nil { selectedCategoryID = fetched.first(where: { $0.slug == initialCategorySlug })?.id ?? fetched.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private var validInput: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2...100).contains(cleanTitle.unicodeScalars.count) && (1...20_000).contains(cleanBody.unicodeScalars.count)
    }

    @MainActor
    private func publish() async {
        guard let selectedCategoryID, canSubmit, validInput, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved: ForumPost
            if let editingPost {
                saved = try await api.updatePost(id: editingPost.id, categoryID: selectedCategoryID,
                    title: cleanTitle, content: content, tagIDs: Array(selectedTagIDs))
            } else {
                saved = try await api.createPost(categoryID: selectedCategoryID,
                    title: cleanTitle, content: content.trimmingCharacters(in: .whitespacesAndNewlines), tagIDs: Array(selectedTagIDs))
            }
            onSaved?(saved)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
