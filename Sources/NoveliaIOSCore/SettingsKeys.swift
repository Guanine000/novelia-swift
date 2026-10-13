import Foundation

/// UserDefaults keys read or written from more than one screen. The strings are already
/// stored on users' devices, so they must never change; `SettingsKeysTests` pins them.
/// Keys private to a single store (reading backgrounds, tag blocking, favourites and history
/// caches, TXT rules, EPUB reader style) stay inside that store.
enum SettingsKey {
    static let readerFontSize = "readerFontSize"
    static let readerAppearance = "readerAppearance"
    static let readerMode = "readerMode"
    static let readerTranslationSource = "readerTranslationSource"
    /// Online novels and TXT use YueduCoreText pages instead of scrolling (default off).
    static let readerPagedText = "readerPagedText"
    /// EPUB uses the experimental Readium (WKWebView) reader instead of YueduCoreText.
    static let readerEPUBReadium = "readerEPUBReadium"
    static let appThemeColor = "appThemeColor"
    static let appThemeCustomHex = "appThemeCustomHex"
    /// Imported EPUB reader fonts as `[hash: SyncedImportedFont]` for WebDAV sync.
    static let importedFontSync = "readerFonts.sync.v1"

    static func bookmarks(novelID: String) -> String { "bookmarks.\(novelID)" }

    enum WebDAV {
        static let enabled = "webdav.enabled"
        static let address = "webdav.address"
        static let username = "webdav.username"
        static let syncBooks = "webdav.syncBooks"
        static let syncTags = "webdav.syncTags"
        static let syncBackgrounds = "webdav.syncBackgrounds"
        static let syncFonts = "webdav.syncFonts"
    }
}

/// Last chapter read in an online or downloaded web novel, stored per novel as
/// `progress.<id>` (chapter index) and `progressTime.<id>` (time of the last sync merge).
struct ReadingProgressStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func chapterKey(novelID: String) -> String { "progress.\(novelID)" }
    static func timeKey(novelID: String) -> String { "progressTime.\(novelID)" }

    /// `nil` when the novel has never been opened.
    func chapterIndex(novelID: String) -> Int? {
        defaults.object(forKey: Self.chapterKey(novelID: novelID)) == nil
            ? nil : defaults.integer(forKey: Self.chapterKey(novelID: novelID))
    }

    func updatedAt(novelID: String) -> Date? {
        defaults.object(forKey: Self.timeKey(novelID: novelID)) as? Date
    }

    func save(chapterIndex: Int, updatedAt: Date, novelID: String) {
        defaults.set(chapterIndex, forKey: Self.chapterKey(novelID: novelID))
        defaults.set(updatedAt, forKey: Self.timeKey(novelID: novelID))
    }
}
