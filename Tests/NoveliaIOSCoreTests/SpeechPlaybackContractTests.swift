import Foundation
import XCTest
@testable import NoveliaIOSCore

@MainActor
private final class StubSpeechEngine: SpeechEngine {
    let kind: SpeechEngineKind = .system
    let capabilities: SpeechCapabilities = [.voiceSelection, .rateControl, .offline]
    let availableVoices: [SpeechVoiceOption] = [
        SpeechVoiceOption(identifier: "voice-a", name: "甲", language: "zh")
    ]
    private(set) var state: SpeechPlaybackState = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((SpeechPlaybackState) -> Void)?
    var startedAnchor: SpeechAnchor?
    var appliedSettings: SpeechSettings?

    func start(from anchor: SpeechAnchor) async {
        startedAnchor = anchor
        state = .preparing
    }
    func pause() {
        if let utterance = state.utterance { state = .paused(utterance) }
    }
    func resume() {
        if let utterance = state.utterance { state = .playing(utterance) }
    }
    func stop() { state = .idle }
    func skipBackward() {}
    func skipForward() {}
    func update(settings: SpeechSettings) { appliedSettings = settings }
}

final class SpeechPlaybackContractTests: XCTestCase {
    func testResumePointDecodesLegacyRecordsAndPreservesPreciseOffsets() throws {
        let oldJSON = #"{"bookKey":"epub:old","chapterIndex":2,"progression":0.4,"engine":"system","updatedAt":0}"#
        let old = try JSONDecoder().decode(SpeechResumePoint.self, from: Data(oldJSON.utf8))
        XCTAssertNil(old.sourceUTF16Offset)
        XCTAssertNil(old.locatorJSON)
        XCTAssertEqual(old.anchor.chapterIndex, 2)
        XCTAssertEqual(old.anchor.progression, 0.4)
        let suite = "ResumeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechResumeStore(defaults: defaults)
        let point = SpeechResumePoint(bookKey: "epub:new", chapterIndex: 3, progression: 0.6,
                                      engine: "readium", sourceUTF16Offset: 123,
                                      locatorJSON: #"{"href":"chapter4.xhtml"}"#)
        store.save(point)
        XCTAssertEqual(store.load(bookKey: "epub:new"), point)
        XCTAssertEqual(store.load(bookKey: "epub:new")?.anchor.sourceUTF16Offset, 123)
        XCTAssertNil(store.load(bookKey: "epub:other"))
        defaults.set(Data("broken".utf8), forKey: SettingsKey.Speech.resumePointPrefix + "epub:broken")
        XCTAssertNil(store.load(bookKey: "epub:broken"))
    }

    func testCapabilitiesDriveHighlightFallbackForCloudEngines() {
        let utterance = SpeechUtterance(text: "甲", chapterIndex: 0, utf16Offset: 0, wordRange: 3..<5)
        XCTAssertEqual(utterance.highlightRange(for: [.wordLevelProgress, .offline]), 3..<5)
        XCTAssertNil(utterance.highlightRange(for: [.offline]), "no word-level progress means no read-along highlight")
        XCTAssertTrue(SpeechCapabilities.voiceSelection.union(.rateControl).contains(.rateControl))
    }

    func testSettingsClampInvalidRatesWithoutChangingOtherValues() {
        var settings = SpeechSettings.default
        XCTAssertEqual(settings.rate, 0.5)
        settings.rate = 3
        XCTAssertEqual(settings.clamped().rate, 1)
        settings.rate = -1
        XCTAssertEqual(settings.clamped().rate, 0)
        settings.rate = .nan
        XCTAssertEqual(settings.clamped().rate, 0.5)
        settings.voiceIdentifier = "saved-voice"
        XCTAssertEqual(settings.clamped().voiceIdentifier, "saved-voice")
    }

    func testStatesExposeUtteranceAndPlayingFlag() {
        let utterance = SpeechUtterance(text: "句", chapterIndex: 1, utf16Offset: 4, wordRange: nil)
        XCTAssertTrue(SpeechPlaybackState.playing(utterance).isPlaying)
        XCTAssertFalse(SpeechPlaybackState.paused(utterance).isPlaying)
        XCTAssertEqual(SpeechPlaybackState.paused(utterance).utterance, utterance)
        XCTAssertNil(SpeechPlaybackState.idle.utterance)
        XCTAssertNil(SpeechPlaybackState.failed("engine").utterance)
        XCTAssertEqual(SpeechPlaybackState.finished, .finished)
    }

    func testAnchorUsesTheSameProgressionRulesAsSpeechText() {
        let text = "第一句。第二句。第三句。第四句。"
        let segments = SpeechText.segments(in: text)
        let anchor = SpeechAnchor(chapterIndex: 0, progression: 0.5,
                                  chapterUTF16Length: text.utf16.count, startIndexHint: nil)
        XCTAssertEqual(anchor.startIndex(in: segments), 2)
    }

    @MainActor
    func testEngineContractIsObservableAndSettingsAreApplied() async {
        let engine = StubSpeechEngine()
        var observed: [SpeechPlaybackState] = []
        engine.onStateChange = { observed.append($0) }
        let anchor = SpeechAnchor(chapterIndex: 2, progression: 0.25,
                                  chapterUTF16Length: 32, startIndexHint: 1)
        await engine.start(from: anchor)
        XCTAssertEqual(engine.startedAnchor, anchor)
        XCTAssertEqual(observed, [.preparing])
        engine.update(settings: .default.clamped())
        XCTAssertEqual(engine.appliedSettings, .default)
        engine.stop()
        XCTAssertEqual(observed, [.preparing, .idle])
    }
}
