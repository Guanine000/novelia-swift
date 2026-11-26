import SwiftUI

struct MeCardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NoveliaStyle.muted)
                .padding(.horizontal, 6)
            VStack(spacing: 0) {
                content
            }
            .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
        }
    }
}

struct MeIconBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct MeRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(NoveliaStyle.hairline)
            .frame(height: 0.75)
            .padding(.leading, 54)
    }
}

struct MeNavigationRow: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueHighlighted: Bool = false
    let systemImage: String
    let iconTint: Color
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            MeIconBadge(systemImage: systemImage, tint: iconTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NoveliaStyle.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: valueHighlighted ? .semibold : .regular))
                    .foregroundStyle(valueHighlighted ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct MeQuickTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var highlightsSubtitle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MeIconBadge(systemImage: systemImage, tint: tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.45))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(NoveliaStyle.fontFootnote)
                    .foregroundStyle(highlightsSubtitle ? tint : NoveliaStyle.muted)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
        .contentShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
    }
}

struct MeToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let iconTint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            MeIconBadge(systemImage: systemImage, tint: iconTint)
                .padding(.top, subtitle == nil ? 0 : 1)
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(NoveliaStyle.fontCaption)
                            .foregroundStyle(NoveliaStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(NoveliaStyle.brandGreen)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct MeSectionFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NoveliaStyle.fontCaption)
            .foregroundStyle(NoveliaStyle.muted)
            .padding(.horizontal, 8)
            .padding(.top, -8)
    }
}
