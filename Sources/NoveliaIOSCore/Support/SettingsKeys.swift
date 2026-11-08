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
    /// Readium 打开 EPUB 时去掉书内脚本（默认关闭，照常执行）；YueduCoreText 始终不执行书内脚本。
    static let readerEPUBDisablesScripts = "readerEPUBDisablesScripts"
    /// Readium 页面四周何时跟随书籍底色，值为 `ReaderBookBackgroundFollow` 原始值。
    static let readerBookBackgroundFollow = "readerBookBackgroundFollow"
    static let appThemeColor = "appThemeColor"
    static let appThemeCustomHex = "appThemeCustomHex"
    /// 界面底色预设，值为 `AppPaperStyle` 原始值；只影响浅色模式，本机保存不参与同步。
    static let appPaperStyle = "appPaperStyle"
    /// 朗读偏好，只存本机，不参与 WebDAV 同步；`SpeechSettingsStore` 负责读写与旧值兼容。
    enum Speech {
        static let edgeVoiceCatalog = "speech.edgeVoiceCatalog.v1"
        static let volume = "speech.volume.v1"
        static let pitch = "speech.pitch.v1"
        static let edgePrefetchEnabled = "speech.edgePrefetchEnabled.v1"
        static let edgeVoiceIdentifier = "speech.edgeVoice.v1"
        static let edgeConsent = "speech.edgeConsent.v1"
        static let voiceIdentifier = "speech.voice.v1"
        static let rate = "speech.rate.v1"
        static let followsReadingPosition = "speech.follow.v1"
        static let highlightsSpokenText = "speech.highlight.v1"
        /// 本地自动路由或已获同意的云端引擎；保留旧 rawValue。
        static let preferredEngine = "speech.engine.v1"
        /// 定时停止分钟数，0 表示关闭。
        static let sleepTimerMinutes = "speech.sleepTimer.v1"
        /// 上次收听位置（按书），供重启后继续听；键值为前缀加书籍身份。
        static let resumePointPrefix = "speech.resume.v1."
    }

    /// 阅读期间阻止自动锁屏（屏幕常亮）；默认关闭，仅阅读器前台生效。
    static let readerKeepScreenOn = "readerKeepScreenOn"
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
        static let syncStatistics = "webdav.syncStatistics"
        /// 自动同步开关，默认关闭；已有用户保持手动同步。
        static let autoSync = "webdav.autoSync"
        /// 自动同步的 `WebDAVAutoSyncState`（JSON）。
        static let autoSyncState = "webdav.autoSync.state.v1"
        /// 已确认存在的同步目录 `["用户名@地址"]`，见 `WebDAVFolderCache`。
        static let preparedFolders = "webdav.preparedFolders.v1"
        /// 阅读统计同步缓存 `ReadingStatisticsSyncCache`（JSON）。
        static let statisticsCache = "webdav.statistics.cache.v1"
        /// 本机文件的内容哈希缓存 `[文件身份: SHA-256]`，见 `WebDAVFileHash.identity`。
        static let fileHashes = "webdav.fileHashes.v1"
        /// 最近一次内容同步发现不提供 ETag 的服务器地址；用于在设置页提示，换用支持的服务器后清除。
        static let manifestWithoutETag = "webdav.manifestWithoutETag"
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
