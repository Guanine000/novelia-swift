import Foundation

/// 多个页面读写的 UserDefaults 键。这些字符串已经存储在用户设备上，
/// 因此不能更改；`SettingsKeysTests` 会验证它们保持不变。
/// 仅供单个存储使用的键（阅读背景、标签屏蔽、收藏与历史缓存、
/// TXT 规则、EPUB 阅读器样式）仍由对应存储内部管理。
enum SettingsKey {
    static let readerFontSize = "readerFontSize"
    static let readerAppearance = "readerAppearance"
    static let readerMode = "readerMode"
    static let readerTranslationSource = "readerTranslationSource"
    /// 在线小说与 TXT 使用 YueduCoreText 分页代替滚动（默认关闭）。
    static let readerPagedText = "readerPagedText"
    /// EPUB 使用实验性的 Readium（WKWebView）阅读器代替 YueduCoreText。
    static let readerEPUBReadium = "readerEPUBReadium"
    static let appThemeColor = "appThemeColor"
    static let appThemeCustomHex = "appThemeCustomHex"
    /// 底栏页面顺序，以逗号分隔的 `AppTab` 原始值保存。
    static let tabBarOrder = "tabBar.order"
    /// 启动时打开的页面：`AppTab` 原始值，或 `last` 表示上次使用的页面。
    static let tabBarLaunch = "tabBar.launch"
    /// 上次使用的底栏页面，仅在启动页面设为“上次使用”时读取。
    static let tabBarLastSelected = "tabBar.lastSelected"
    /// 导入的 EPUB 阅读器字体，以 `[hash: SyncedImportedFont]` 形式参与 WebDAV 同步。
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
        /// 本机文件的内容哈希缓存 `[文件身份: SHA-256]`，见 `WebDAVFileHash.identity`。
        static let fileHashes = "webdav.fileHashes.v1"
    }
}

/// 在线或已下载网络小说最近阅读的章节，按小说分别保存为
/// `progress.<id>`（章节序号）和 `progressTime.<id>`（最近一次同步合并时间）。
struct ReadingProgressStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func chapterKey(novelID: String) -> String { "progress.\(novelID)" }
    static func timeKey(novelID: String) -> String { "progressTime.\(novelID)" }

    /// 小说从未打开时为 `nil`。
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
