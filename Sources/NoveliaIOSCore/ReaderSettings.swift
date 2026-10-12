import Combine
import Foundation

/// Shared preferences without changing the keys already stored on devices.
/// EPUB-specific layout options remain in its existing style object.
@MainActor
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()
    static let fontRange: ClosedRange<Double> = 12...36
    static let epubStyleKey = "epubPrototype.readerStyle.v1"
    let defaults: UserDefaults
    @Published private var storedFontSize: Double
    @Published private var storedAppearance: String
    @Published private var storedPagedText: Bool

    init(defaults: UserDefaults = .standard) {
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
            // Keep the old EPUB style readable by older versions and preserve unknown fields.
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

    /// Online novels and TXT use the paged reader; scrolling remains the default.
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

    private static func normalizedFontSize(_ value: Double) -> Double {
        value.isFinite ? min(fontRange.upperBound, max(fontRange.lowerBound, value)) : 20
    }

    private static func normalizedAppearance(_ value: String) -> String {
        ["light", "dark", "system"].contains(value) ? value : "system"
    }
}
