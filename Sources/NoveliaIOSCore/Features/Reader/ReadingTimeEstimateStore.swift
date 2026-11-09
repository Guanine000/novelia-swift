// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

struct ReadingTimePreferences: Codable, Equatable {
    var isEnabled = false
    var learnsSpeed = false
    var usesManualSpeed = false
    var manualSpeed: Double = 400
    var language: ReadingSpeedLanguage = .automatic
}

/// ReaderSettings 拥有的本地设置和速率摘要；不依赖阅读统计开关，也不进入 WebDAV。
@MainActor
final class ReadingTimeEstimateStore: ObservableObject {
    @Published var preferences: ReadingTimePreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.preferenceKey) }
        }
    }
    @Published private(set) var profileRevision = 0
    @Published private(set) var resetRevision = 0
    private let defaults: UserDefaults
    private var profiles: [String: ReadingSpeedProfile]
    private static let preferenceKey = "reader.remainingTime.preferences.v1"
    private static let profilesKey = "reader.remainingTime.profiles.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        var preferences = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(ReadingTimePreferences.self, from: $0) } ?? .init()
        if !preferences.manualSpeed.isFinite { preferences.manualSpeed = 400 }
        preferences.manualSpeed = min(3_000, max(25, preferences.manualSpeed))
        self.preferences = preferences
        profiles = (defaults.data(forKey: Self.profilesKey)
            .flatMap { try? JSONDecoder().decode([String: ReadingSpeedProfile].self, from: $0) } ?? [:])
            .filter { $0.key.count <= 200 && $0.value.isValid }
        if profiles.count > 128 { profiles = [:] }
    }

    func language(detected: ReadingSpeedLanguage) -> ReadingSpeedLanguage {
        preferences.language == .automatic ? detected : preferences.language
    }
    private func key(book: String?, language: ReadingSpeedLanguage, mode: String) -> String {
        (book.map { FileContentHash.sha256(Data($0.utf8)) } ?? "global") + "|" + language.rawValue + "|" + mode
    }
    func speed(book: String, language: ReadingSpeedLanguage, mode: String) -> Double? {
        if preferences.usesManualSpeed { return preferences.manualSpeed }
        return profiles[key(book: book, language: language, mode: mode)]?.speed
            ?? profiles[key(book: nil, language: language, mode: mode)]?.speed
    }
    func record(_ speed: Double, book: String, language: ReadingSpeedLanguage, mode: String) {
        guard preferences.isEnabled, preferences.learnsSpeed, !preferences.usesManualSpeed else { return }
        for book in [Optional(book), nil] {
            let key = key(book: book, language: language, mode: mode)
            // 限制长期保存数量；全局档位继续学习，新书超过上限时不再新增单书档位。
            guard profiles[key] != nil || profiles.count < 128 else { continue }
            var profile = profiles[key] ?? .init(); profile.add(speed); profiles[key] = profile
        }
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
        profileRevision += 1
    }
    func clearLearning() {
        profiles.removeAll(); defaults.removeObject(forKey: Self.profilesKey); profileRevision += 1; resetRevision += 1
    }
}
