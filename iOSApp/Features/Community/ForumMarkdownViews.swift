import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

/// `Text(AttributedString(markdown:))` 保留行内强调和链接，
/// 但 SwiftUI 的 `Text` 会将 Markdown 块结构展平，也不会绘制远程图片。
/// 分别渲染各块，使段落、标题、列表、引用、表格和图片保留层级。
struct ForumMarkdownBody: View {
    @EnvironmentObject private var services: AppServices
    let markdown: String
    var mode: ForumMarkdownMode = .article
    @Environment(\.openURL) private var parentOpenURL
    @Environment(\.forumLinkActions) private var linkActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ForumMarkdownCache.shared.blocks(markdown, mode: mode)) { block in
                blockView(block)
                    .id(block.anchor ?? "forum-block-\(block.id)")
            }
        }
        .foregroundStyle(NoveliaStyle.ink)
        .tint(NoveliaStyle.brandGreen)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(mode == .comment ? .system(size: 15) : .system(size: 16))
        .lineSpacing(4)
        .environment(\.openURL, OpenURLAction { url in
            if let route = ForumNovelRoute(url: url, configuration: services.configuration), let linkActions {
                linkActions.openNovel(route)
                return .handled
            }
            parentOpenURL(url)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: ForumMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            inlineText(block.text, baseSize: mode == .comment ? 15 : 16)
        case let .heading(level):
            inlineText(block.text, baseSize: headingSize(level), bold: true)
                .font(.system(size: headingSize(level), weight: .bold))
                .padding(.top, level <= 2 ? 5 : 2)
        case .unorderedItem:
            listRow(marker: "•", text: block.text)
        case let .orderedItem(number):
            listRow(marker: "\(number).", text: block.text)
        case .quote:
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(NoveliaStyle.muted.opacity(0.45)).frame(width: 3)
                inlineText(block.text, baseSize: mode == .comment ? 15 : 16, textColor: NoveliaStyle.muted).foregroundStyle(NoveliaStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 4)
        case .code:
            Text(block.text)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
        case let .table(rows):
            ForumMarkdownTable(rows: rows, mode: mode, imageBaseURL: services.configuration.forumOrigin)
        case .divider:
            Rectangle().fill(NoveliaStyle.muted.opacity(0.25)).frame(height: 1).padding(.vertical, 5)
        case let .starRating(value):
            ForumStarRating(value: value)
        case let .details(title):
            ForumDetailsBlock(title: title, content: block.text, mode: mode)
        }
    }

    private func inlineText(_ markdown: String, baseSize: CGFloat, bold: Bool = false, textColor: Color = NoveliaStyle.ink, imageMaxHeight: CGFloat = 640) -> some View {
        ForumMarkdownInlineContent(
            markdown: markdown,
            baseSize: baseSize,
            bold: bold,
            textColor: textColor,
            imageMaxHeight: imageMaxHeight,
            imageBaseURL: services.configuration.forumOrigin
        )
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).font(.system(size: 15, weight: .semibold)).frame(minWidth: 18, alignment: .trailing)
            inlineText(text, baseSize: mode == .comment ? 15 : 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 5)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 22
        case 2: 20
        case 3: 18
        default: 16
        }
    }
}

/// 限制文本宽度，让每行可以向下增长，避免水平滚动视图
/// 提供无限宽度时单元格被截断。
private struct ForumMarkdownTable: View {
    let rows: [[String]]
    let mode: ForumMarkdownMode
    var imageBaseURL: URL = APIConfiguration.production.forumOrigin

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    ForumTableRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            ForumMarkdownInlineContent(
                                markdown: rows[row][column],
                                baseSize: mode == .comment ? 15 : 16,
                                bold: row == 0,
                                imageMaxHeight: 480,
                                imageBaseURL: imageBaseURL
                            )
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .frame(width: 220, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .background(row == 0 ? NoveliaStyle.paper : NoveliaStyle.card)
                                .overlay(Rectangle().stroke(NoveliaStyle.muted.opacity(0.25)))
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("forum-table-cell-\(row)-\(column)")
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        // 高表格超出可视区域时，保持内容的纵向起点在顶部。iOS 17 以下滚动视图默认即从顶部开始。
        .forumDefaultScrollAnchorTop()
        .accessibilityIdentifier("forum-markdown-table")
    }
}

/// 独立测量每一行，避免扩展后的单元格背景
/// 改变文字起点或占用其他行的高度。iOS 16 及以上使用 Layout；更早系统按顶对齐排列，
/// 同行较矮单元格的背景不会拉到最高单元格。
private struct ForumTableRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16, *) {
            ForumTableRowLayout { content() }
        } else {
            HStack(alignment: .top, spacing: 0) { content() }
        }
    }
}

@available(iOS 16, *)
private struct ForumTableRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 240, height: nil)) }
        return CGSize(width: CGFloat(subviews.count) * 240, height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * 240, y: bounds.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(width: 240, height: bounds.height))
        }
    }
}

private extension View {
    @ViewBuilder
    func forumDefaultScrollAnchorTop() -> some View {
        if #available(iOS 17, *) {
            self.defaultScrollAnchor(.topLeading)
        } else {
            self
        }
    }
}

private struct ForumInlineMarkdownText: View {
    let markdown: String
    var baseSize: CGFloat = 15
    var bold = false
    var textColor = NoveliaStyle.ink
    /// 同一段里还有图片时，由外层持有揭示状态，揭示后才能把剧透中的图片拆出来。
    var externalSpoilersRevealed: Binding<Bool>? = nil
    @State private var localSpoilersRevealed = false

    private var hasSpoilers: Bool { ForumMarkdownCache.shared.hasSpoilers(markdown) }
    private var spoilersRevealed: Bool { externalSpoilersRevealed?.wrappedValue ?? localSpoilersRevealed }

    var body: some View {
        if hasSpoilers && !spoilersRevealed {
            Text(ForumMarkdownCache.shared.inline(markdown, spoilersRevealed: false, conceal: concealForumSpoiler))
                .fontWeight(bold ? .semibold : .regular)
                .onTapGesture {
                    if let externalSpoilersRevealed {
                        externalSpoilersRevealed.wrappedValue = true
                    } else {
                        localSpoilersRevealed = true
                    }
                }
        } else if hasSpoilers {
            ForumRevealedSpoilerText(
                text: ForumMarkdownCache.shared.inline(markdown, spoilersRevealed: true),
                baseSize: baseSize, bold: bold, textColor: textColor
            )
        } else {
            Text(ForumMarkdownCache.shared.inline(markdown, spoilersRevealed: true))
                .fontWeight(bold ? .semibold : .regular)
        }
    }
}

/// 揭示后使用 TextKit 显式处理链接交互，避免复用
/// 之前处理揭示点击的 SwiftUI 可选择 Text 底层视图。
private struct ForumRevealedSpoilerText: UIViewRepresentable {
    let text: AttributedString
    let baseSize: CGFloat
    let bold: Bool
    let textColor: Color
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeUIView(context: Context) -> UITextView {
        let view: UITextView
        if #available(iOS 16, *) {
            view = UITextView()
        } else {
            view = ForumSizingTextView()
        }
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        view.attributedText = forumSpoilerNativeText(text, baseSize: baseSize, bold: bold, textColor: textColor)
        view.linkTextAttributes = [
            .foregroundColor: UIColor(NoveliaStyle.brandGreen),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    @available(iOS 16, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }

        @available(iOS 17, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL(url) }
        }

        func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            if #available(iOS 17, *) { return true }
            openURL(url)
            return false
        }
    }
}

/// iOS 15 没有 `UIViewRepresentable.sizeThatFits`。只在该系统使用，按自身宽度回报高度。
private final class ForumSizingTextView: UITextView {
    private var measuredWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 1 ? bounds.width : measuredWidth
        guard width > 1 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let height = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - measuredWidth) > 0.5 else { return }
        measuredWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

private func forumSpoilerNativeText(_ text: AttributedString, baseSize: CGFloat, bold: Bool, textColor: Color) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    for run in text.runs {
        var traits: UIFontDescriptor.SymbolicTraits = bold ? [.traitBold] : []
        if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
        if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
        let base = run.inlinePresentationIntent?.contains(.code) == true
            ? UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            : UIFont.systemFont(ofSize: baseSize)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(descriptor: descriptor, size: baseSize))
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(textColor)]
        if let url = run.link { attributes[.link] = url }
        if run.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        result.append(NSAttributedString(string: String(text.characters[run.range]), attributes: attributes))
    }
    return result
}

private func concealForumSpoiler(_ spoiler: inout AttributedString) {
    spoiler.foregroundColor = .clear
    spoiler.backgroundColor = NoveliaStyle.ink.opacity(0.78)
}

/// 没有图片时仍走原来的 `Text`，避免改变剧透、链接和表格文字的布局。
/// 有图片时把剧透状态抬到这一层：未揭示时图片留在原文里，点按后再拆出来加载。
private struct ForumMarkdownInlineContent: View {
    let markdown: String
    var baseSize: CGFloat = 15
    var bold = false
    var textColor = NoveliaStyle.ink
    var imageMaxHeight: CGFloat = 640
    var imageBaseURL: URL = APIConfiguration.production.forumOrigin
    @State private var spoilersRevealed = false

    var body: some View {
        if let segments = segmentsForDisplay() {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        ForumInlineMarkdownText(
                            markdown: text,
                            baseSize: baseSize,
                            bold: bold,
                            textColor: textColor,
                            externalSpoilersRevealed: $spoilersRevealed
                        )
                    case .image(let image):
                        ForumRemoteMarkdownImage(image: image, baseURL: imageBaseURL, maxHeight: imageMaxHeight)
                    }
                }
            }
        } else {
            ForumInlineMarkdownText(markdown: markdown, baseSize: baseSize, bold: bold, textColor: textColor)
        }
    }

    private func segmentsForDisplay() -> [ForumInlineSegment]? {
        let cache = ForumMarkdownCache.shared
        let revealedSegments = cache.inlineSegments(markdown, spoilersRevealed: true)
        guard revealedSegments.contains(where: \.isImage) else { return nil }
        let revealed = spoilersRevealed || !cache.hasSpoilers(markdown)
        let segments = cache.inlineSegments(markdown, spoilersRevealed: revealed)
        return segments.isEmpty ? nil : segments
    }
}

/// 按 Markdown 图片地址直接下载，不经过论坛 API。内存缓存避免表格滚动时重新占位。
private final class ForumMarkdownImageLoader: @unchecked Sendable {
    static let shared = ForumMarkdownImageLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private final class Inflight {
        let task: Task<UIImage?, Never>
        init(_ task: Task<UIImage?, Never>) { self.task = task }
    }

    private let lock = NSLock()
    private var inFlight: [URL: Inflight] = [:]
    private let maxBytes = 20 * 1024 * 1024
    private let maxPixel: CGFloat = 1600

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
        session = URLSession(configuration: configuration)
        memory.countLimit = 80
        memory.totalCostLimit = 48 * 1024 * 1024
    }

    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        let flight = existingOrCreate(url)
        let image = await flight.task.value
        lock.lock()
        if inFlight[url] === flight { inFlight[url] = nil }
        lock.unlock()
        return image
    }

    private func existingOrCreate(_ url: URL) -> Inflight {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[url] { return existing }
        let task = Task.detached(priority: .userInitiated) { [self] in
            await self.load(url)
        }
        let flight = Inflight(task)
        inFlight[url] = flight
        return flight
    }

    private func load(_ url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !data.isEmpty, data.count <= maxBytes,
                  let image = forumDisplayImage(data, maxPixel: maxPixel) else { return nil }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
            memory.setObject(image, forKey: url as NSURL, cost: cost)
            return image
        } catch {
            return nil
        }
    }
}

private func forumDisplayImage(_ data: Data, maxPixel: CGFloat) -> UIImage? {
    guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
    let pixelWidth = image.size.width * image.scale
    let pixelHeight = image.size.height * image.scale
    let longest = max(pixelWidth, pixelHeight)
    guard longest > maxPixel else { return image }
    let ratio = maxPixel / longest
    let size = CGSize(width: max(1, floor(pixelWidth * ratio)), height: max(1, floor(pixelHeight * ratio)))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
}

private struct ForumImageWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// 高度按可用宽度和像素宽高比计算，并设上限。加载和失败都保留最小高度，
/// 避免远程图尚未返回时表格行被压成 0，或按原始像素把整行撑得过高。
private struct ForumRemoteMarkdownImage: View {
    let image: ForumMarkdownImage
    let baseURL: URL
    var maxHeight: CGFloat
    @State private var loaded: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @Environment(\.openURL) private var openURL

    private var resolvedURL: URL? {
        forumMarkdownImageURL(image.destination, relativeTo: baseURL)
    }

    private var linkURL: URL? {
        image.link.flatMap(forumMarkdownActionURL)
    }

    private var accessibilityName: String {
        let alt = image.alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.isEmpty ? "图片" : alt
    }

    var body: some View {
        imageBody
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.disabled)
            .task(id: "\(resolvedURL?.absoluteString ?? "invalid")#\(attempt)") {
                await load(resolvedURL)
            }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let displayed = loaded ?? resolvedURL.flatMap({ ForumMarkdownImageLoader.shared.cachedImage(for: $0) }) {
            ForumFittedRemoteImage(image: displayed, maxHeight: maxHeight)
                .modifier(ForumImageLinkTap(url: linkURL, openURL: openURL))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityName)
                .accessibilityAddTraits(linkURL == nil ? .isImage : .isImage.union(.isButton))
                .accessibilityIdentifier("forum-markdown-image")
        } else if resolvedURL == nil || failed {
            failure(canRetry: resolvedURL != nil)
                .accessibilityIdentifier("forum-markdown-image-failed")
        } else {
            loading
                .accessibilityLabel("正在加载图片")
                .accessibilityIdentifier("forum-markdown-image-loading")
        }
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("正在加载图片")
                .font(.system(size: 12))
                .foregroundStyle(NoveliaStyle.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: 6))
    }

    private func failure(canRetry: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 22))
            Text(accessibilityName == "图片" ? "图片无法加载" : accessibilityName)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
            if accessibilityName != "图片" {
                Text("图片无法加载")
                    .font(.system(size: 12))
            }
            if canRetry {
                Button("重试") {
                    failed = false
                    loaded = nil
                    attempt += 1
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NoveliaStyle.brandGreen)
            }
        }
        .foregroundStyle(NoveliaStyle.muted)
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.horizontal, 8)
        .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: 6))
    }

    private func load(_ url: URL?) async {
        let generation = attempt
        guard let url else { return }
        if let cached = ForumMarkdownImageLoader.shared.cachedImage(for: url) {
            guard generation == attempt else { return }
            loaded = cached
            failed = false
            return
        }
        guard let downloaded = await ForumMarkdownImageLoader.shared.image(for: url) else {
            guard generation == attempt, !Task.isCancelled else { return }
            loaded = nil
            failed = true
            return
        }
        guard generation == attempt, !Task.isCancelled else { return }
        loaded = downloaded
        failed = false
    }
}

private struct ForumImageLinkTap: ViewModifier {
    let url: URL?
    let openURL: OpenURLAction

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.contentShape(Rectangle()).onTapGesture { openURL(url) }
        } else {
            content
        }
    }
}

private struct ForumFittedRemoteImage: View {
    let image: UIImage
    var maxHeight: CGFloat
    @State private var width: CGFloat = 0

    private var displayHeight: CGFloat {
        let aspect = max(image.size.width, 1) / max(image.size.height, 1)
        guard width > 1 else { return min(120, maxHeight) }
        return min(maxHeight, max(1, width / aspect))
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: displayHeight)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ForumImageWidthPreference.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(ForumImageWidthPreference.self) { newWidth in
                guard newWidth > 1, abs(newWidth - width) > 0.5 else { return }
                width = newWidth
            }
    }
}

private struct ForumStarRating: View {
    let value: Double
    private let green = Color(red: 79 / 255, green: 178 / 255, blue: 51 / 255)
    private var rating: Double { min(5, max(0, (value * 2).rounded() / 2)) }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...5, id: \.self) { index in
                let symbol = Double(index) <= rating ? "star.fill" : (Double(index) - 0.5 <= rating ? "star.leadinghalf.filled" : "star")
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(symbol == "star" ? Color.gray.opacity(0.38) : green)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("评分 \(rating.formatted(.number.precision(.fractionLength(0...1)))) / 5 星")
    }
}

private struct ForumDetailsBlock: View {
    let title: String
    let content: String
    let mode: ForumMarkdownMode
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForumMarkdownBody(markdown: content, mode: mode)
                .padding(.top, 8)
        } label: {
            Text(title.isEmpty ? "点击展开" : title).font(.system(size: 14, weight: .semibold))
        }
        .tint(NoveliaStyle.brandGreen)
        .padding(11)
        .background(NoveliaStyle.paper.opacity(0.65), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall).stroke(NoveliaStyle.muted.opacity(0.2), lineWidth: 1))
    }
}

/// 在论坛 Markdown 中点击小说或文库链接后打开的应用内页面。
struct ForumNovelRouteView: View {
    let route: ForumNovelRoute

    var body: some View {
        if route.isCatalogue {
            DiscoverView()
        } else if let provider = route.provider {
            NovelDetailView(novel: Novel(id: "\(provider)/\(route.novelID)", title: "正在加载…", author: "", summary: "", genres: [], chapters: [], accent: .ocean, providerId: provider, novelId: route.novelID))
        } else {
            WenkuDetailView(outline: route.outline)
        }
    }
}
