import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

/// `Text(AttributedString(markdown:))` preserves inline emphasis and links, but
/// SwiftUI's `Text` flattens Markdown block structure. Render blocks separately
/// so paragraphs, headings, lists, and quotes retain the hierarchy shown on web.
struct ForumMarkdownBody: View {
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
        .font(mode == .comment ? .system(size: 14) : .system(size: 15))
        .environment(\.openURL, OpenURLAction { url in
            if let route = ForumNovelRoute(url: url), let linkActions {
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
            ForumInlineMarkdownText(markdown: block.text, baseSize: mode == .comment ? 14 : 15)
        case let .heading(level):
            ForumInlineMarkdownText(markdown: block.text, baseSize: CGFloat(headingSize(level)), bold: true)
                .font(.system(size: headingSize(level), weight: .bold, design: .rounded))
                .padding(.top, level <= 2 ? 5 : 2)
        case .unorderedItem:
            listRow(marker: "•", text: block.text)
        case let .orderedItem(number):
            listRow(marker: "\(number).", text: block.text)
        case .quote:
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(NoveliaStyle.muted.opacity(0.45)).frame(width: 3)
                ForumInlineMarkdownText(markdown: block.text, baseSize: mode == .comment ? 14 : 15, textColor: NoveliaStyle.muted).foregroundStyle(NoveliaStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 4)
        case .code:
            Text(block.text)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: 8))
        case let .table(rows):
            ForumMarkdownTable(rows: rows, mode: mode)
        case .divider:
            Rectangle().fill(NoveliaStyle.muted.opacity(0.25)).frame(height: 1).padding(.vertical, 5)
        case let .starRating(value):
            ForumStarRating(value: value)
        case let .details(title):
            ForumDetailsBlock(title: title, content: block.text, mode: mode)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).font(.system(size: 15, weight: .semibold)).frame(minWidth: 18, alignment: .trailing)
            ForumInlineMarkdownText(markdown: text, baseSize: mode == .comment ? 14 : 15)
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

/// A bounded text width lets each row grow vertically instead of truncating
/// cells under the horizontal scroll view's unconstrained width proposal.
private struct ForumMarkdownTable: View {
    let rows: [[String]]
    let mode: ForumMarkdownMode

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    ForumTableRowLayout {
                        ForEach(rows[row].indices, id: \.self) { column in
                            ForumInlineMarkdownText(markdown: rows[row][column], baseSize: mode == .comment ? 14 : 15, bold: row == 0)
                                .fontWeight(row == 0 ? .semibold : .regular)
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
        // Keep the vertical origin at the top when a tall table exceeds its viewport.
        .defaultScrollAnchor(.topLeading)
        .accessibilityIdentifier("forum-markdown-table")
    }
}

/// Measure each row independently so expanded cell backgrounds cannot alter
/// the text origin or borrow height from another row.
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

private struct ForumInlineMarkdownText: View {
    let markdown: String
    var baseSize: CGFloat = 15
    var bold = false
    var textColor = NoveliaStyle.ink
    @State private var spoilersRevealed = false

    private var hasSpoilers: Bool { ForumMarkdownCache.shared.hasSpoilers(markdown) }

    var body: some View {
        if hasSpoilers && !spoilersRevealed {
            Text(ForumMarkdownCache.shared.inline(markdown, spoilersRevealed: false, conceal: concealForumSpoiler))
                .onTapGesture { spoilersRevealed = true }
        } else if hasSpoilers {
            ForumRevealedSpoilerText(
                text: ForumMarkdownCache.shared.inline(markdown, spoilersRevealed: true),
                baseSize: baseSize, bold: bold, textColor: textColor
            )
        } else {
            Text(ForumMarkdownCache.shared.inline(markdown, spoilersRevealed: true))
        }
    }
}

/// Use TextKit's explicit link interaction after revealing instead of reusing
/// SwiftUI's selectable Text backing view that previously handled reveal taps.
private struct ForumRevealedSpoilerText: UIViewRepresentable {
    let text: AttributedString
    let baseSize: CGFloat
    let bold: Bool
    let textColor: Color
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL(url) }
        }
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
        .background(NoveliaStyle.paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NoveliaStyle.muted.opacity(0.2), lineWidth: 1))
    }
}

/// The in-app page for a novel or wenku link tapped in forum Markdown.
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
