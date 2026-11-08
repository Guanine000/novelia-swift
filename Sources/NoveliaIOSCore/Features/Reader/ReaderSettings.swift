import Combine
import Foundation

/// LocalAppServices 持有并注入各阅读器的共用偏好，使用同一进度接口与偏好存储。
/// 保持设备上已有的存储键、默认开关和已保存的引擎选择不变。
/// EPUB 专属排版选项仍保存在原有样式对象中。
@MainActor
final class ReaderSettings: ObservableObject {
    @Published private(set) var activeBookID: String?
    @Published private(set) var bookPreferences: [String: BookReadingPreferences] = [:]
    @Published var projectionRevision = 0
    let offlineChapters: OnlineChapterOfflineStore
    private static let bookPreferencesKey = "reader.bookPreferences.v1"
    var usesBookPreferences: Bool { activeStylePreferences != nil }
    private var activeStylePreferences: BookReadingPreferences? {
        guard let value = activePreferences, value.styleOverride ?? true else { return nil }
        return value
    }
    var activePreferences: BookReadingPreferences? { activeBookID.flatMap { bookPreferences[$0] } }
    var projection: ReadingTextProjection { activePreferences?.projection ?? .init() }
    var styleStorageKey: String { usesBookPreferences ? "reader.bookStyle.v1." + FileContentHash.sha256(Data((activeBookID ?? "").utf8)) : Self.epubStyleKey }
    func activateBook(_ id: String) { if activeBookID != id { activeBookID = id } }
    func deactivateBook(_ id: String) { if activeBookID == id { activeBookID = nil } }
    func setBookPreferencesEnabled(_ enabled: Bool) {
        guard let id = activeBookID else { return }
        if enabled, !usesBookPreferences {
            let textProjection = projection
            bookPreferences[id] = .init(fontSize: fontSize, appearance: appearanceRaw, paged: pagedTextReading,
                                        layout: defaults.data(forKey: Self.epubStyleKey), styleOverride: true, projection: textProjection)
            if let data = bookPreferences[id]?.layout { defaults.set(data, forKey: styleStorageKey) }
        } else if !enabled {
            bookPreferences[id]?.styleOverride = false
            defaults.removeObject(forKey: "reader.bookStyle.v1." + FileContentHash.sha256(Data(id.utf8)))
        }
        saveBookPreferences(); projectionRevision += 1
    }
    func setProjection(_ value: ReadingTextProjection) {
        guard let id = activeBookID else { return }
        if bookPreferences[id] == nil {
            bookPreferences[id] = .init(fontSize: storedFontSize, appearance: storedAppearance, paged: storedPagedText,
                                        layout: nil, styleOverride: false)
        }
        bookPreferences[id]?.projection = value.normalized
        saveBookPreferences(); projectionRevision += 1
    }
    private func saveBookPreferences() {
        if let data = try? JSONEncoder().encode(bookPreferences) { defaults.set(data, forKey: Self.bookPreferencesKey) }
    }
    static let fontRange: ClosedRange<Double> = 12...36
    static let epubStyleKey = "epubPrototype.readerStyle.v1"
    let positions: any ReadingPositionProviding
    /// EPUB 与本地 TXT 的书签；未注入时只保存在内存。
    let bookmarks: ReaderBookmarkStore
    let webEPUBMaps: WebNovelEPUBMapStore
    let defaults: UserDefaults
    @Published private var storedFontSize: Double
    @Published private var storedAppearance: String
    @Published private var storedPagedText: Bool

    init(defaults: UserDefaults = .standard, positions: (any ReadingPositionProviding)? = nil,
         bookmarks: ReaderBookmarkStore? = nil, offlineDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        offlineChapters = OnlineChapterOfflineStore(directory: offlineDirectory ?? (defaults === UserDefaults.standard ? support.appendingPathComponent("OfflineChapters") : FileManager.default.temporaryDirectory.appendingPathComponent("OfflineChapters-" + UUID().uuidString)))
        self.positions = positions ?? ReadingPositionStore(defaults: defaults)
        self.bookmarks = bookmarks ?? ReaderBookmarkStore()
        self.defaults = defaults
        bookPreferences = defaults.data(forKey: Self.bookPreferencesKey).flatMap { try? JSONDecoder().decode([String: BookReadingPreferences].self, from: $0) } ?? [:]
        self.webEPUBMaps = WebNovelEPUBMapStore(defaults: defaults)
        let epubStyle = defaults.data(forKey: Self.epubStyleKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let previousFont = defaults.object(forKey: SettingsKey.readerFontSize) as? Double
            ?? (epubStyle?["fontSize"] as? Double) ?? 20
        storedFontSize = Self.normalizedFontSize(previousFont)
        storedAppearance = Self.normalizedAppearance(defaults.string(forKey: SettingsKey.readerAppearance) ?? "system")
        storedPagedText = defaults.bool(forKey: SettingsKey.readerPagedText)
    }

    var fontSize: Double {
        get { activeStylePreferences.map { Self.normalizedFontSize($0.fontSize) } ?? storedFontSize }
        set {
            let value = Self.normalizedFontSize(newValue)
            if usesBookPreferences, let id = activeBookID { bookPreferences[id]?.fontSize = value; saveBookPreferences(); return }
            if storedFontSize != value { storedFontSize = value }
            defaults.set(value, forKey: SettingsKey.readerFontSize)
            // 保持旧版应用能够读取 EPUB 样式，并保留未知字段。
            if let data = defaults.data(forKey: Self.epubStyleKey),
               var style = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                style["fontSize"] = value
                if let encoded = try? JSONSerialization.data(withJSONObject: style) {
                    defaults.set(encoded, forKey: Self.epubStyleKey)
                }
            }
        }
    }

    var appearanceRaw: String {
        get { activeStylePreferences.map { Self.normalizedAppearance($0.appearance) } ?? storedAppearance }
        set {
            let value = Self.normalizedAppearance(newValue)
            if usesBookPreferences, let id = activeBookID { bookPreferences[id]?.appearance = value; saveBookPreferences(); return }
            if storedAppearance != value { storedAppearance = value }
            defaults.set(value, forKey: SettingsKey.readerAppearance)
        }
    }

    /// 在线小说与 TXT 使用分页阅读器；默认仍为滚动模式。
    var pagedTextReading: Bool {
        get { activeStylePreferences?.paged ?? storedPagedText }
        set {
            if usesBookPreferences, let id = activeBookID { bookPreferences[id]?.paged = newValue; saveBookPreferences(); return }
            if storedPagedText != newValue { storedPagedText = newValue }
            defaults.set(newValue, forKey: SettingsKey.readerPagedText)
        }
    }

    func isDark(systemIsDark: Bool) -> Bool {
        switch appearanceRaw {
        case "dark": true
        case "light": false
        default: systemIsDark
        }
    }

    func adjustFontSize(by change: Double) { fontSize += change }

    var progress: ReadingProgressStore { ReadingProgressStore(defaults: defaults) }

    /// 共用访问入口，同时分别处理章节序号与 EPUB 偏移量。
    func recordWebPosition(id: String, chapterIndex: Int) {
        positions.recordWeb(id: id, chapterIndex: chapterIndex)
    }

    /// 打开在线小说时所在章节只是恢复：与已保存的章节相同，或从未保存且从第一章开始。
    /// 恢复不写入，避免在同步前打开书时用当前时间盖过其他设备较新的进度；明确选择其他章节才记录。
    func isRestoringWebPosition(id: String, chapterIndex: Int) -> Bool {
        if let saved = positions.all()["web:\(id)"]?.chapterIndex { return saved == chapterIndex }
        return chapterIndex == 0
    }

    /// `chapterOffset` 仅由 YueduCoreText 使用；`chapterProgression` 由两个引擎写入。
    func recordEPUBPosition(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?) {
        positions.recordEPUB(hash: hash, fraction: fraction, spineIndex: spineIndex,
                                       chapterOffset: chapterOffset, chapterProgression: chapterProgression)
    }

    func epubPosition(hash: String) -> SyncedReadingPosition? {
        positions.epubPosition(hash: hash)
    }

    private static func normalizedFontSize(_ value: Double) -> Double {
        value.isFinite ? min(fontRange.upperBound, max(fontRange.lowerBound, value)) : 20
    }

    private static func normalizedAppearance(_ value: String) -> String {
        ["light", "dark", "system"].contains(value) ? value : "system"
    }
}

/// Readium：书籍给页面指定了不透明底色时，阅读器四周（边距、安全区）何时跟随它。
/// 忽略近白时也透明化正文页面、段落及行内底色；彩色底、边框及图片保持书内样式。
enum ReaderBookBackgroundFollow: String, CaseIterable, Identifiable {
    /// 忽略纯白或接近白色的书籍底色（默认）：白底书保留阅读背景，彩色页面仍铺满。
    case ignoreNearWhite
    /// 当前深浅色与横竖屏设有阅读背景图片时不跟随，保留图片。
    case keepBackgroundImage

    static let `default` = ignoreNearWhite
    /// 三个分量都不低于该值（0–1，约 #F0F0F0）视为接近白色，米白纸色也包括在内。
    static let nearWhiteThreshold = 240.0 / 255

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ignoreNearWhite: "忽略白色底色"
        case .keepBackgroundImage: "保留背景图片"
        }
    }

    /// 已保存值无法识别或缺失时使用默认规则。
    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .default
    }

    func follows(red: Double, green: Double, blue: Double, hasBackgroundImage: Bool) -> Bool {
        switch self {
        case .ignoreNearWhite: min(red, green, blue) < Self.nearWhiteThreshold
        case .keepBackgroundImage: !hasBackgroundImage
        }
    }
}
