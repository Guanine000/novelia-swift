import Foundation
import XCTest
@testable import NoveliaIOSCore

/// 已存储在设备上的设置通过这些精确字符串查找；修改任一名称
/// 都会无提示地重置所有现有用户的对应设置。
final class SettingsKeysTests: XCTestCase {
    func testPersistedKeysAreUnchanged() {
        XCTAssertEqual(SettingsKey.readerFontSize, "readerFontSize")
        XCTAssertEqual(SettingsKey.readerAppearance, "readerAppearance")
        XCTAssertEqual(SettingsKey.readerMode, "readerMode")
        XCTAssertEqual(SettingsKey.readerTranslationSource, "readerTranslationSource")
        XCTAssertEqual(SettingsKey.readerPagedText, "readerPagedText")
        XCTAssertEqual(SettingsKey.appThemeColor, "appThemeColor")
        XCTAssertEqual(SettingsKey.appThemeCustomHex, "appThemeCustomHex")
        XCTAssertEqual(SettingsKey.importedFontSync, "readerFonts.sync.v1")
        XCTAssertEqual(SettingsKey.bookmarks(novelID: "syosetu/n1"), "bookmarks.syosetu/n1")
        XCTAssertEqual([SettingsKey.WebDAV.enabled, SettingsKey.WebDAV.address, SettingsKey.WebDAV.username,
                        SettingsKey.WebDAV.syncBooks, SettingsKey.WebDAV.syncTags, SettingsKey.WebDAV.syncBackgrounds,
                        SettingsKey.WebDAV.syncFonts],
                       ["webdav.enabled", "webdav.address", "webdav.username", "webdav.syncBooks", "webdav.syncTags",
                        "webdav.syncBackgrounds", "webdav.syncFonts"])
        XCTAssertEqual(ReadingProgressStore.chapterKey(novelID: "syosetu/n1"), "progress.syosetu/n1")
        XCTAssertEqual(ReadingProgressStore.timeKey(novelID: "syosetu/n1"), "progressTime.syosetu/n1")
    }

    func testReadingProgressStore() {
        let suite = "ReadingProgressTest-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingProgressStore(defaults: defaults)
        XCTAssertNil(store.chapterIndex(novelID: "a"), "unread novel has no progress")
        XCTAssertNil(store.updatedAt(novelID: "a"))
        defaults.set(0, forKey: "progress.a")
        XCTAssertEqual(store.chapterIndex(novelID: "a"), 0, "chapter 0 is real progress, not absence")
        let date = Date(timeIntervalSince1970: 1_000)
        store.save(chapterIndex: 7, updatedAt: date, novelID: "a")
        XCTAssertEqual(store.chapterIndex(novelID: "a"), 7)
        XCTAssertEqual(store.updatedAt(novelID: "a"), date)
        XCTAssertEqual(defaults.integer(forKey: "progress.a"), 7, "same storage as @AppStorage in the reader")
    }
}
