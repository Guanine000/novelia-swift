import Foundation
import XCTest
@testable import NoveliaIOSCore

final class SpeechSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SpeechSettingsTest-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    func testEmptyDefaultsUseDocumentedDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SpeechSettingsStore(defaults: defaults).load(), .default)
        XCTAssertNil(SpeechSettingsStore(defaults: defaults).load().voiceIdentifier)
        XCTAssertEqual(SpeechSettingsStore(defaults: defaults).load().preferredEngine, .system)
        XCTAssertEqual(SpeechSettingsStore(defaults: defaults).load().sleepTimerMinutes, 0)
    }

    func testSaveAndLoadRoundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechSettingsStore(defaults: defaults)
        var settings = SpeechSettings.default
        settings.voiceIdentifier = "com.apple.voice.compact.zh-CN.Tingting"
        settings.rate = 0.8
        settings.followsReadingPosition = false
        settings.highlightsSpokenText = false
        settings.preferredEngine = .readium
        settings.sleepTimerMinutes = 45
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.Speech.preferredEngine), "readium")
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.Speech.sleepTimerMinutes), 45)
    }

    func testInvalidStoredValuesFallBackSafely() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("", forKey: SettingsKey.Speech.voiceIdentifier)
        defaults.set(Double.nan, forKey: SettingsKey.Speech.rate)
        defaults.set("not-a-bool", forKey: SettingsKey.Speech.followsReadingPosition)
        defaults.set("cloud-engine-from-the-future", forKey: SettingsKey.Speech.preferredEngine)
        defaults.set("not-a-number", forKey: SettingsKey.Speech.sleepTimerMinutes)
        let loaded = SpeechSettingsStore(defaults: defaults).load()
        XCTAssertNil(loaded.voiceIdentifier)
        XCTAssertEqual(loaded.rate, 0.5)
        XCTAssertTrue(loaded.followsReadingPosition)
        XCTAssertEqual(loaded.preferredEngine, .system)
        XCTAssertEqual(loaded.sleepTimerMinutes, 0)
    }

    func testIndependentSoundControlsPersistAndClamp() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load().volume, 1); XCTAssertEqual(store.load().pitch, 0)
        var value = store.load(); value.volume = 0.35; value.pitch = -0.6
        store.save(value)
        XCTAssertEqual(store.load().volume, 0.35); XCTAssertEqual(store.load().pitch, -0.6)
        defaults.set(Double.nan, forKey: SettingsKey.Speech.volume)
        defaults.set(99, forKey: SettingsKey.Speech.pitch)
        XCTAssertEqual(store.load().volume, 1); XCTAssertEqual(store.load().pitch, 1)
        store.reset(); XCTAssertEqual(store.load().volume, 1); XCTAssertEqual(store.load().pitch, 0)
    }
    func testPrefetchRequiresExplicitOptInAndPersists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechSettingsStore(defaults: defaults)
        XCTAssertFalse(store.load().edgePrefetchEnabled)
        var settings = store.load(); settings.edgePrefetchEnabled = true
        store.save(settings)
        XCTAssertTrue(store.load().edgePrefetchEnabled)
        store.reset(); XCTAssertFalse(store.load().edgePrefetchEnabled)
    }

    func testOutOfRangeValuesAreClampedOnLoadAndSave() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechSettingsStore(defaults: defaults)
        defaults.set(42.0, forKey: SettingsKey.Speech.rate)
        defaults.set(-8.0, forKey: SettingsKey.Speech.sleepTimerMinutes)
        XCTAssertEqual(store.load().rate, 1)
        XCTAssertEqual(store.load().sleepTimerMinutes, 0)

        var settings = SpeechSettings.default
        settings.rate = -3
        settings.sleepTimerMinutes = 37
        store.save(settings)
        XCTAssertEqual(defaults.double(forKey: SettingsKey.Speech.rate), 0)
        // 37 距 30 比 45 更近。
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.Speech.sleepTimerMinutes), 30)
        XCTAssertEqual(store.load().sleepTimerMinutes, 30)
    }

    func testChoosingSystemDefaultRemovesTheVoiceKey() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechSettingsStore(defaults: defaults)
        var settings = SpeechSettings.default
        settings.voiceIdentifier = "voice-a"
        store.save(settings)
        XCTAssertNotNil(defaults.object(forKey: SettingsKey.Speech.voiceIdentifier))
        settings.voiceIdentifier = nil
        store.save(settings)
        XCTAssertNil(defaults.object(forKey: SettingsKey.Speech.voiceIdentifier))
        XCTAssertNil(store.load().voiceIdentifier)
    }

    func testResetRestoresDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechSettingsStore(defaults: defaults)
        var settings = SpeechSettings.default
        settings.rate = 0.15
        settings.sleepTimerMinutes = 90
        store.save(settings)
        store.reset()
        XCTAssertEqual(store.load(), .default)
    }

    func testSleepTimerDeadlineAndRemaining() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(SpeechSleepTimer.deadline(from: now, minutes: 0))
        XCTAssertNil(SpeechSleepTimer.deadline(from: now, minutes: -5))
        XCTAssertEqual(SpeechSleepTimer.deadline(from: now, minutes: 30)?.timeIntervalSince(now), 1800)
        XCTAssertNil(SpeechSleepTimer.remaining(until: nil, at: now))
        XCTAssertEqual(SpeechSleepTimer.remaining(until: now.addingTimeInterval(120), at: now), 120)
        XCTAssertEqual(SpeechSleepTimer.remaining(until: now.addingTimeInterval(-120), at: now), 0)
    }

    func testSleepTimerOptionsAreStableAndTitled() {
        XCTAssertEqual(SpeechSettings.sleepTimerOptions, [0, 15, 30, 45, 60, 90])
        XCTAssertEqual(SpeechSettings.sleepTimerTitle(minutes: 0), "关闭")
        XCTAssertEqual(SpeechSettings.sleepTimerTitle(minutes: 60), "60 分钟")
        XCTAssertEqual(SpeechSettings.normalizedSleepTimer(44), 45)
        XCTAssertEqual(SpeechSettings.normalizedSleepTimer(1000), 90)
    }
}
