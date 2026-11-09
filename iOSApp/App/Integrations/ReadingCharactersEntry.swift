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
                ai: services.readingAI, initialBook: current.key)
        } else if let current {
            CharacterSeriesView(workID: current.key, books: [current], store: readerSettings.characters,
                ai: services.readingAI, initialBook: current.key)
        } else {
            Text("暂未找到对应的本地书籍，从书库重新打开本书后即可查看人物卡。").padding()
        }
    }
}
