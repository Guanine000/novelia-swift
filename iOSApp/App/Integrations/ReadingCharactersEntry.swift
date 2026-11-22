// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 书内查询到系列人物页的导航适配；只使用明确系列归属，不按相似书名猜作品。
@MainActor
struct ReadingCharactersEntry: View {
    let libraryBook: String?
    let source: LocalRecapSource
    let query: String
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var web: WebNovelDownloadStore
    @EnvironmentObject private var wenku: WenkuLocalLibraryStore
    @EnvironmentObject private var cloud: CloudBookStore
    private var books: [LibraryBook] { state.books(web: web, wenku: wenku, cloud: cloud) }
    private var current: LibraryBook? {
        if let libraryBook { return books.first { $0.key == libraryBook } }
        let hash = source.bookKey.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        let matches = books.filter { state.hashByBook[$0.key] == hash }
        return matches.count == 1 ? matches[0] : nil
    }
    var body: some View {
        if let current, let series = state.series.seriesID(forBook: current.key) {
            let keys = state.series.bookKeys(inSeries: series)
            CharacterSeriesView(workID: series, books: books.filter { keys.contains($0.key) }, store: readerSettings.characters, ai: services.readingAI, initialBook: current.key,
                readingBoundary: source.currentChapter, readingIdentity: source.identity, initialQuery: query)
        } else {
            Text("请先在书库将本书加入明确的系列，再查询跨卷人物。也可从系列页的“AI 人物词条”打开。").padding()
        }
    }
}

/// 书内阅读菜单“查看角色卡”的导航适配：系列书沿用系列归属；未入系列的书以书键作作品键，
/// 移入系列时人物卡数据自动迁移（见 CharacterLexiconStore.migrateWork）。
@MainActor
struct ReadingCharacterCardsEntry: View {
    let libraryBookKey: String?
    /// 浏览模式：从阅读菜单“查看人物卡”进入，隐藏卷序确认、生成、校准菜单，详情仍可编辑。
    var readOnly = false
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var web: WebNovelDownloadStore
    @EnvironmentObject private var wenku: WenkuLocalLibraryStore
    @EnvironmentObject private var cloud: CloudBookStore

    var body: some View {
        let books = state.books(web: web, wenku: wenku, cloud: cloud)
        let current = libraryBookKey.flatMap { key in books.first { $0.key == key } }
        if let current, let series = state.series.seriesID(forBook: current.key) {
            let keys = state.series.bookKeys(inSeries: series)
            CharacterSeriesView(workID: series, books: books.filter { keys.contains($0.key) }, store: readerSettings.characters,
                ai: services.readingAI, initialBook: current.key, readOnly: readOnly)
        } else if let current {
            CharacterSeriesView(workID: current.key, books: [current], store: readerSettings.characters,
                ai: services.readingAI, initialBook: current.key, readOnly: readOnly)
        } else {
            Text("暂未找到对应的本地书籍，从书库重新打开本书后即可查看人物卡。").padding()
        }
    }
}

/// 书内阅读菜单「世界观词条」的导航适配：系列书沿用系列 ID，单书使用书键。
@MainActor
struct ReadingWorldviewEntry: View {
    let libraryBookKey: String?
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var web: WebNovelDownloadStore
    @EnvironmentObject private var wenku: WenkuLocalLibraryStore
    @EnvironmentObject private var cloud: CloudBookStore

    var body: some View {
        let books = state.books(web: web, wenku: wenku, cloud: cloud)
        let current = libraryBookKey.flatMap { key in books.first { $0.key == key } }
        if let current, let series = state.series.seriesID(forBook: current.key) {
            let keys = state.series.bookKeys(inSeries: series)
            WorldviewLexiconView(
                workID: series,
                workTitle: state.series.series[series]?.name ?? current.title,
                books: books.filter { keys.contains($0.key) },
                initialBookKey: current.key,
                store: readerSettings.worldview,
                ai: services.readingAI
            )
        } else if let current {
            WorldviewLexiconView(
                workID: current.key,
                workTitle: current.title,
                books: [current],
                initialBookKey: current.key,
                store: readerSettings.worldview,
                ai: services.readingAI
            )
        } else {
            Text("暂未找到对应的本地书籍，从书库重新打开本书后即可查看世界观词条。").padding()
        }
    }
}

/// 书内阅读菜单「回顾上一卷」的导航适配：按已确认卷序或自然书名找到上一卷并复用全书梗概管线。
@MainActor
struct ReadingPreviousVolumeEntry: View {
    let libraryBookKey: String?
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var web: WebNovelDownloadStore
    @EnvironmentObject private var wenku: WenkuLocalLibraryStore
    @EnvironmentObject private var cloud: CloudBookStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let books = state.books(web: web, wenku: wenku, cloud: cloud)
        if let libraryBookKey,
           let current = books.first(where: { $0.key == libraryBookKey }),
           let series = state.series.seriesID(forBook: current.key) {
            let keys = state.series.bookKeys(inSeries: series)
            let members = books.filter { keys.contains($0.key) }
            let confirmed = readerSettings.characters.order(work: series)
            if let prevKey = LibrarySeriesVolumeResolver.previousBookKey(
                for: current.key,
                confirmedOrder: confirmed,
                members: members.map { .init(key: $0.key, title: $0.title) }
            ), let previous = members.first(where: { $0.key == prevKey }) {
                PreviousVolumeRecapSheet(
                    previousBook: previous,
                    currentBookTitle: current.title,
                    store: readerSettings.recaps,
                    ai: services.readingAI
                )
            } else {
                CompatNavigationStack {
                    Text("《\(current.title)》已经是当前系列的第一卷，没有上一卷可回顾。")
                        .padding()
                        .navigationTitle("回顾上一卷")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回阅读") { dismiss() } } }
                }
            }
        } else {
            CompatNavigationStack {
                Text("请先在书库把多卷轻小说加入同一个系列，再使用一键「回顾上一卷」。")
                    .padding()
                    .navigationTitle("回顾上一卷")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回阅读") { dismiss() } } }
            }
        }
    }
}
