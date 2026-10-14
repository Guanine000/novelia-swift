import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct FeaturedNovelCard: View {
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
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 19))
    }
}

struct NovelRow: View {
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
                Text(metadata(for: novel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.85))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NoveliaStyle.muted.opacity(0.5))
        }
        .padding(11)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: 17))
    }

    private func metadata(for novel: Novel) -> String {
        let detail: String
        if let totalCharacters = novel.totalCharacters, totalCharacters > 0 {
            detail = "\(totalCharacters.formatted()) 字"
        } else if !novel.chapters.isEmpty {
            detail = "\(novel.chapters.count) 章"
        } else {
            detail = novel.genres.first ?? "小说"
        }
        if let genre = novel.genres.first, detail != genre {
            return "\(detail)  ·  \(genre)"
        }
        return detail
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
