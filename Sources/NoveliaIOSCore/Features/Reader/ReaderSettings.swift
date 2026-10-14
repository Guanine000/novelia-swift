import Combine
import Foundation

/// LocalAppServices 持有并注入各阅读器的共用偏好，使用同一进度接口与偏好存储。
/// 保持设备上已有的存储键、默认开关和已保存的引擎选择不变。
/// EPUB 专属排版选项仍保存在原有样式对象中。
@MainActor
final class ReaderSettings: ObservableObject {
    static let fontRange: ClosedRange<Double> = 12...36
    static let epubStyleKey = "epubPrototype.readerStyle.v1"
    let positions: any ReadingPositionProviding
    let defaults: UserDefaults
    @Published private var storedFontSize: Double
    @Published private var storedAppearance: String
    @Published private var storedPagedText: Bool

    init(defaults: UserDefaults = .standard, positions: (any ReadingPositionProviding)? = nil) {
        self.positions = positions ?? ReadingPositionStore(defaults: defaults)
        self.defaults = defaults
        let epubStyle = defaults.data(forKey: Self.epubStyleKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let previousFont = defaults.object(forKey: SettingsKey.readerFontSize) as? Double
            ?? (epubStyle?["fontSize"] as? Double) ?? 20
        storedFontSize = Self.normalizedFontSize(previousFont)
        storedAppearance = Self.normalizedAppearance(defaults.string(forKey: SettingsKey.readerAppearance) ?? "system")
        storedPagedText = defaults.bool(forKey: SettingsKey.readerPagedText)
    }

    var fontSize: Double {
        get { storedFontSize }
        set {
            let value = Self.normalizedFontSize(newValue)
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
        get { storedAppearance }
        set {
            let value = Self.normalizedAppearance(newValue)
            if storedAppearance != value { storedAppearance = value }
            defaults.set(value, forKey: SettingsKey.readerAppearance)
        }
    }

    /// 在线小说与 TXT 使用分页阅读器；默认仍为滚动模式。
    var pagedTextReading: Bool {
        get { storedPagedText }
        set {
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
