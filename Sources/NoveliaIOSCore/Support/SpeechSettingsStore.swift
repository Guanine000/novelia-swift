import Foundation

/// 朗读偏好的本机持久化。键名已经写入设备后不可更改，见 `SettingsKeysTests`。
/// 只存本机，不参与 WebDAV 同步；云端引擎的凭据与音频缓存不属于这里。
/// 读取一律先取默认值再覆盖：缺键、类型错误、无法识别的枚举与越界数值都要安全回落，
/// 让旧版本存档和用户在设置中手工写入的异常值都不会让合成器报错。
struct SpeechSettingsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SpeechSettings {
        let base = SpeechSettings.default
        let storedVoice = defaults.string(forKey: SettingsKey.Speech.voiceIdentifier)
        let voiceIdentifier = (storedVoice?.isEmpty ?? true) ? nil : storedVoice
        let rate = storedNumber(SettingsKey.Speech.rate)?.doubleValue ?? base.rate
        let follows = storedBool(SettingsKey.Speech.followsReadingPosition,
                                 fallback: base.followsReadingPosition)
        let highlights = storedBool(SettingsKey.Speech.highlightsSpokenText,
                                    fallback: base.highlightsSpokenText)
        var engine = defaults.string(forKey: SettingsKey.Speech.preferredEngine)
            .flatMap(SpeechEngineKind.init(rawValue:)) ?? base.preferredEngine
        if engine == .edge && !edgeConsentGranted { engine = .system }
        let minutes = storedNumber(SettingsKey.Speech.sleepTimerMinutes)?.intValue
            ?? base.sleepTimerMinutes
        var settings = SpeechSettings(voiceIdentifier: voiceIdentifier, rate: rate,
                              followsReadingPosition: follows, highlightsSpokenText: highlights,
                              preferredEngine: engine, sleepTimerMinutes: minutes).clamped()
        if let voice = defaults.string(forKey: SettingsKey.Speech.edgeVoiceIdentifier),
           EdgeSpeechVoices.validIdentifier(voice) { settings.edgeVoiceIdentifier = voice }
        settings.edgePrefetchEnabled = storedBool(SettingsKey.Speech.edgePrefetchEnabled, fallback: false)
        settings.volume = storedNumber(SettingsKey.Speech.volume)?.doubleValue ?? 1
        settings.pitch = storedNumber(SettingsKey.Speech.pitch)?.doubleValue ?? 0
        return settings.clamped()
    }

    func save(_ settings: SpeechSettings) {
        let value = settings.clamped()
        if let voice = value.voiceIdentifier, !voice.isEmpty {
            defaults.set(voice, forKey: SettingsKey.Speech.voiceIdentifier)
        } else {
            // 选择「系统默认」时删掉键，回到与从未设置过一致的状态。
            defaults.removeObject(forKey: SettingsKey.Speech.voiceIdentifier)
        }
        defaults.set(value.volume, forKey: SettingsKey.Speech.volume)
        defaults.set(value.pitch, forKey: SettingsKey.Speech.pitch)
        defaults.set(value.edgePrefetchEnabled, forKey: SettingsKey.Speech.edgePrefetchEnabled)
        defaults.set(value.edgeVoiceIdentifier, forKey: SettingsKey.Speech.edgeVoiceIdentifier)
        defaults.set(value.rate, forKey: SettingsKey.Speech.rate)
        defaults.set(value.followsReadingPosition, forKey: SettingsKey.Speech.followsReadingPosition)
        defaults.set(value.highlightsSpokenText, forKey: SettingsKey.Speech.highlightsSpokenText)
        defaults.set(value.preferredEngine.rawValue, forKey: SettingsKey.Speech.preferredEngine)
        defaults.set(value.sleepTimerMinutes, forKey: SettingsKey.Speech.sleepTimerMinutes)
    }

    /// 目录仅包含公开音色元数据；坏缓存回到内置列表，不联网，不参与同步。
    var edgeVoices: [SpeechVoiceOption] {
        let cached: [SpeechVoiceOption]
        if let data = defaults.data(forKey: SettingsKey.Speech.edgeVoiceCatalog), data.count <= 2 * 1_024 * 1_024 {
            cached = (try? JSONDecoder().decode([SpeechVoiceOption].self, from: data)) ?? []
        } else { cached = [] }
        return EdgeSpeechVoices.sanitized(EdgeSpeechVoices.all + cached)
    }
    func saveEdgeVoices(_ voices: [SpeechVoiceOption]) {
        let values = EdgeSpeechVoices.sanitized(voices)
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values), data.count <= 2 * 1_024 * 1_024 else { return }
        defaults.set(data, forKey: SettingsKey.Speech.edgeVoiceCatalog)
    }
    var edgeConsentGranted: Bool { defaults.bool(forKey: SettingsKey.Speech.edgeConsent) }
    func setEdgeConsent(_ granted: Bool) { defaults.set(granted, forKey: SettingsKey.Speech.edgeConsent) }
    func reset() { setEdgeConsent(false); save(.default) }

    private func storedNumber(_ key: String) -> NSNumber? {
        defaults.object(forKey: key) as? NSNumber
    }

    private func storedBool(_ key: String, fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? fallback
    }
}

/// 定时停止的纯计算：界面与锁屏只读这里的规则，实际计时由 App 层的 `SpeechRemoteSession` 驱动。
enum SpeechSleepTimer {
    static func deadline(from now: Date, minutes: Int) -> Date? {
        let normalized = SpeechSettings.normalizedSleepTimer(minutes)
        guard normalized > 0 else { return nil }
        return now.addingTimeInterval(Double(normalized) * 60)
    }

    static func remaining(until deadline: Date?, at now: Date) -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }
}
