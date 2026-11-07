import Foundation

/// 上次收听位置：按书保存，供 App 重启或重新进入书籍后「继续听」。
/// 只记到章级加章内比例，不依赖具体引擎的 Locator；各阅读器用自己的跳转接口落位。
/// 与朗读偏好一样只存本机，不参与 WebDAV 同步。
struct SpeechResumePoint: Codable, Equatable, Sendable {
    var bookKey: String
    var chapterIndex: Int
    /// 章内比例（0…1），与阅读进度、书签同一口径。
    var progression: Double
    var engine: String
    var updatedAt: Date

    init(bookKey: String, chapterIndex: Int, progression: Double, engine: String, updatedAt: Date = Date()) {
        self.bookKey = bookKey
        self.chapterIndex = chapterIndex
        self.progression = min(max(progression.isFinite ? progression : 0, 0), 1)
        self.engine = engine
        self.updatedAt = updatedAt
    }
}

/// 无状态读写器：键按书分隔，缺键或损坏数据都当作没有记录，不影响朗读启动。
struct SpeechResumeStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ bookKey: String) -> String {
        SettingsKey.Speech.resumePointPrefix + bookKey
    }

    func load(bookKey: String) -> SpeechResumePoint? {
        guard !bookKey.isEmpty, let data = defaults.data(forKey: key(bookKey)) else { return nil }
        guard let point = try? JSONDecoder().decode(SpeechResumePoint.self, from: data),
              point.bookKey == bookKey else { return nil }
        return point
    }

    func save(_ point: SpeechResumePoint) {
        guard !point.bookKey.isEmpty,
              let data = try? JSONEncoder().encode(point),
              data.count <= 4 * 1_024 else { return }
        defaults.set(data, forKey: key(point.bookKey))
    }

    func clear(bookKey: String) {
        guard !bookKey.isEmpty else { return }
        defaults.removeObject(forKey: key(bookKey))
    }
}
