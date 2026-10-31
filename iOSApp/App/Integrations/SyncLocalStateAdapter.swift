import Foundation
import SwiftUI
import UIKit

extension WebNovelDownloadStore: SyncBookLibrary {
    func prepareForSync() async throws { try await loadIfNeeded() }
    func removeFromSync(_ book: DownloadedWebNovel) async throws { try await removeForMove(book) }
}
extension WenkuLocalLibraryStore: SyncBookLibrary {
    func prepareForSync() async throws { try await loadIfNeeded() }
    func removeFromSync(_ book: LocalWenkuEPUB) async throws { try await removeForMove(book) }
}

/// 把 App 前后台和本机书库、系列、标签的变化转交给 WebDAV 自动同步。
/// 书库 Store 由 RootView 持有，这里在根视图出现时交给同步 Store；是否执行由 Store 按策略决定。
/// 阅读位置不逐次监听，改动由进入背景时的推送带上。
struct WebDAVAutoSyncTriggers: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let sync: WebDAVSyncStore
    let web: WebNovelDownloadStore
    let wenku: WenkuLocalLibraryStore
    let library: LibraryStateStore
    let blockedTags: BlockedTagsStore
    let identityMaps: WebNovelEPUBMapStore
    let bookmarks: ReaderBookmarkStore

    func body(content: Content) -> some View {
        content
            .task {
                do { try await web.loadIfNeeded() } catch { /* Store 保留错误供界面重试。 */ }
                do { try await wenku.loadIfNeeded() } catch { /* 仍尝试读取另一个书库。 */ }
                // 两个库都尝试读取，单库损坏不能使另一个库一直显示加载中。
                sync.startAutomaticSync(web: web, wenku: wenku)
            }
            .onChange(of: scenePhase) { _, phase in sync.scenePhaseDidChange(phase) }
            .onReceive(web.$books.dropFirst()) { _ in sync.localStateDidChange() }
            .onReceive(wenku.$books.dropFirst()) { _ in sync.localStateDidChange() }
            .onReceive(library.objectWillChange) { sync.localStateDidChange() }
            .onReceive(blockedTags.objectWillChange) { sync.localStateDidChange() }
            .onReceive(identityMaps.$maps.dropFirst()) { _ in sync.localStateDidChange() }
            .onReceive(bookmarks.$records.dropFirst()) { _ in sync.localStateDidChange() }
    }
}

/// App 组装给 WebDAVSyncStore 的本地状态适配，连接实际背景、标签、进度和书库系列。
/// 同步引擎只看接口；此处引用 App 正在使用的实例，不另建存储或改变其数据格式。
@MainActor
struct AppWebDAVSyncLocalState: WebDAVSyncLocalState {
    let blocked: BlockedTagsStore
    let backgrounds: ReaderBackgroundStore
    let positions: any ReadingPositionSynchronizing
    let library: any LibrarySeriesManaging
    let identityMaps: WebNovelEPUBMapStore
    let bookmarkStore: ReaderBookmarkStore
    var webEPUBMaps: [String: WebNovelEPUBMap] { identityMaps.maps }
    func applyWebEPUBMaps(_ maps: [String: WebNovelEPUBMap]) throws { try identityMaps.merge(maps) }
    var readingPositions: [String: SyncedReadingPosition] { positions.all() }
    func mergeReadingPositions(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {
        positions.merge(remote, webBooks: webBooks)
    }
    var librarySeries: LibrarySeriesState { library.series }
    func applyLibrarySeries(_ series: LibrarySeriesState) { library.applySynced(series) }
    var bookmarks: [String: ReaderBookmark] { bookmarkStore.records }
    func applyBookmarks(_ bookmarks: [String: ReaderBookmark]) throws { try bookmarkStore.applySynced(bookmarks) }
    var blockedTags: [String: SyncedBlockedTag] { blocked.syncStates }
    func applyBlockedTags(_ tags: [String: SyncedBlockedTag]) { blocked.applySynced(tags) }
    func background(dark: Bool) throws -> SyncedReaderBackground { try backgrounds.syncSnapshot(dark: dark) }
    func backgroundImageURL(dark: Bool, landscape: Bool) -> URL {
        backgrounds.imageURL(dark: dark, landscape: landscape)
    }
    func isValidBackgroundImage(_ file: URL) -> Bool { UIImage(contentsOfFile: file.path) != nil }
    func applyBackground(_ value: SyncedReaderBackground, dark: Bool, files: [String: URL]) throws {
        try backgrounds.applySync(value, dark: dark, files: files)
    }
    func fonts() throws -> [String: SyncedImportedFont] { try EPUBLocalFonts.syncSnapshot() }
    func fontFiles() throws -> [String: URL] { try EPUBLocalFonts.syncFiles() }
    func applyFonts(_ records: [String: SyncedImportedFont], files: [String: URL]) throws {
        try EPUBLocalFonts.applySync(records, files: files)
    }
}

