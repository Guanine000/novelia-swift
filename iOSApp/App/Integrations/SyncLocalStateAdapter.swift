import Foundation
import UIKit

extension WebNovelDownloadStore: SyncBookLibrary {}
extension WenkuLocalLibraryStore: SyncBookLibrary {}

/// Composition bridge between local features and the protocol-based sync engine.
@MainActor
struct AppWebDAVSyncLocalState: WebDAVSyncLocalState {
    let blocked: BlockedTagsStore
    let backgrounds: ReaderBackgroundStore
    let positions: any ReadingPositionSynchronizing
    let library: any LibrarySeriesManaging
    var readingPositions: [String: SyncedReadingPosition] { positions.all() }
    func mergeReadingPositions(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {
        positions.merge(remote, webBooks: webBooks)
    }
    var librarySeries: LibrarySeriesState { library.series }
    func applyLibrarySeries(_ series: LibrarySeriesState) { library.applySynced(series) }
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

