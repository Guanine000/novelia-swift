import Foundation
import XCTest
@testable import NoveliaIOSCore

final class EdgeSpeechTests: XCTestCase {
    func testV2TokenMatchesPinnedUpstreamVectors() {
        let key = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        let vectors: [(Double, String)] = [
            (0, "52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6"),
            (1_700_000_000, "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2"),
            (1_793_797_200, "1AB471C7F8C1FEC0-694D37DA31B90D02355743059544761171A3E09129E4211C4CFE78B93D624EA4")
        ]
        for (time, expected) in vectors {
            XCTAssertEqual(EdgeSpeechToken.value(at: Date(timeIntervalSince1970: time), clientToken: key), expected)
        }
    }
    func testBinaryFramesValidateBoundsPathAndType() throws {
        func frame(_ headers: String, _ payload: Data) -> Data {
            let text = Data(headers.utf8), length = text.count
            return Data([UInt8(length >> 8), UInt8(length & 255)]) + text + payload
        }
        let audio = Data([0xFF,0xFB,0x01])
        XCTAssertEqual(try EdgeSpeechClient.audioPayload(frame("Path:audio\r\nContent-Type:audio/mpeg\r\n", audio)), audio)
        XCTAssertTrue(try EdgeSpeechClient.audioPayload(frame("Path:audio\r\n", Data())).isEmpty)
        XCTAssertThrowsError(try EdgeSpeechClient.audioPayload(Data([0,255,1])))
        XCTAssertThrowsError(try EdgeSpeechClient.audioPayload(frame("Path:audio.metadata\r\n", audio)))
        XCTAssertThrowsError(try EdgeSpeechClient.audioPayload(frame("Path:audio\r\nContent-Type:text/html\r\n", audio)))
    }
    func testSSMLEscapesTextAndVoiceAndClampsRates() {
        let text = "<script> & ' \" \u{0}"
        let request = EdgeSpeechClient.ssml(text: text, voice: "zh-CN-XiaoxiaoNeural", rate: 0.5, at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(request.contains("Path:ssml\r\n\r\n"))
        XCTAssertTrue(request.contains("rate='+0%'"))
        XCTAssertTrue(request.contains("&lt;script&gt; &amp; &apos; &quot;"))
        XCTAssertFalse(request.contains("\u{0}"))
        XCTAssertTrue(request.contains("Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)"))
        XCTAssertTrue(EdgeSpeechClient.ssml(text: "一", voice: "v", rate: -20, at: Date()).contains("rate='-50%'"))
        XCTAssertTrue(EdgeSpeechClient.ssml(text: "一", voice: "v", rate: 20, at: Date()).contains("rate='+100%'"))
    }
    func testCloudChunksBoundEscapedPayloadAndPreserveSourceRanges() {
        let text = String(repeating: "😀<&很多文字。\n", count: 500)
        let chunks = CloudSpeechText.chunks(in: text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { CloudSpeechText.escapedUTF8Count($0.text) <= CloudSpeechText.maximumEscapedUTF8 })
        XCTAssertEqual(chunks[0].sourceRange.lowerBound, 0)
        XCTAssertEqual(chunks.last?.sourceRange.upperBound, text.utf16.count - 1)
        XCTAssertEqual(CloudSpeechText.startIndex(in: chunks, length: text.utf16.count, progression: 1), chunks.count - 1)
        XCTAssertTrue(CloudSpeechText.chunks(in: " \n ").isEmpty)
    }
    func testStartingPageForcesAChunkBoundaryWithoutLosingEarlierText() {
        let text = String(repeating: "这一句有十个字符。", count: 100)
        let chunks = CloudSpeechText.chunks(in: text, startingAt: 0.5)
        let target = SpeechText.segments(in: text)[50].utf16Offset
        let index = CloudSpeechText.startIndex(in: chunks, length: text.utf16.count, progression: 0.5)
        XCTAssertEqual(chunks[index].sourceRange.lowerBound, target)
        XCTAssertEqual(chunks.first?.sourceRange.lowerBound, 0)
        XCTAssertEqual(chunks.last?.sourceRange.upperBound, text.utf16.count)
    }

    func testDynamicCatalogFiltersMalformedVoicesAndSupportsRegionalNames() throws {
        let json = #"[{"ShortName":"en-US-AriaNeural","LocalName":"Aria","Locale":"en-US"},{"ShortName":"en-US-AriaNeural","LocalName":"duplicate","Locale":"en-US"},{"ShortName":"<bad>","Locale":"en-US"}]"#
        let values = try EdgeSpeechClient.voiceOptions(Data(json.utf8))
        XCTAssertEqual(values, [.init(identifier: "en-US-AriaNeural", name: "Aria", language: "en-US")])
        XCTAssertThrowsError(try EdgeSpeechClient.voiceOptions(Data("[]".utf8)))
        XCTAssertFalse(EdgeSpeechVoices.validIdentifier("en-USNeural"))
        XCTAssertFalse(EdgeSpeechVoices.validIdentifier("en-US-Voice<xml>Neural"))
        XCTAssertTrue(EdgeSpeechVoices.validIdentifier("zh-CN-liaoning-XiaobeiNeural"))
        let request = EdgeSpeechClient.ssml(text: "你好。", voice: "zh-CN-liaoning-XiaobeiNeural", rate: 0.5, at: Date())
        XCTAssertTrue(request.contains("(zh-CN-liaoning, XiaobeiNeural)"))
    }
    func testVoiceCatalogCachesPublicMetadataAndPreservesDynamicSelection() throws {
        let name = "VoiceCatalog-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SpeechSettingsStore(defaults: defaults)
        let voice = SpeechVoiceOption(identifier: "en-US-AriaNeural", name: "Aria", language: "en-US")
        store.saveEdgeVoices([voice,voice])
        XCTAssertEqual(store.edgeVoices.count, EdgeSpeechVoices.all.count + 1)
        var settings = SpeechSettings.default; settings.edgeVoiceIdentifier = voice.identifier
        store.save(settings)
        XCTAssertEqual(store.load().edgeVoiceIdentifier, voice.identifier)
        defaults.set(Data("broken".utf8), forKey: SettingsKey.Speech.edgeVoiceCatalog)
        XCTAssertEqual(store.edgeVoices, EdgeSpeechVoices.all)
        XCTAssertEqual(store.load().edgeVoiceIdentifier, voice.identifier)
    }
    func testPitchUsesBoundedHzWithoutChangingRate() {
        let high = EdgeSpeechClient.ssml(text: "测试。", voice: "zh-CN-XiaoxiaoNeural", rate: 0.5, at: Date(), pitch: 1)
        XCTAssertTrue(high.contains("pitch='+50Hz' rate='+0%'"))
        XCTAssertTrue(EdgeSpeechClient.ssml(text: "测试。", voice: "zh-CN-XiaoxiaoNeural", rate: 0.5, at: Date(), pitch: -99).contains("pitch='-50Hz'"))
    }
    func testRetryClassificationDoesNotRetryRejectedOrMalformedRequests() {
        XCTAssertTrue(EdgeSpeechClient.Failure.timedOut.shouldRetry)
        XCTAssertTrue(EdgeSpeechClient.Failure.unavailable.shouldRetry)
        XCTAssertFalse(EdgeSpeechClient.Failure.rejected.shouldRetry)
        XCTAssertFalse(EdgeSpeechClient.Failure.invalidVoice.shouldRetry)
        XCTAssertFalse(EdgeSpeechClient.Failure.malformedFrame.shouldRetry)
    }
    func testSentenceMetadataAndSourceMapping() throws {
        let json = #"{"Metadata":[{"Type":"SentenceBoundary","Data":{"Offset":12000000,"Duration":8000000,"text":{"Text":"甲 &amp; 乙。"}}},{"Type":"WordBoundary","Data":{}},{"Type":"SentenceBoundary","Data":{"Offset":-1}}]}"#
        let boundaries = EdgeSpeechClient.sentenceBoundaries(Data(json.utf8))
        XCTAssertEqual(boundaries, [.init(time: 1.2, duration: 0.8, text: "甲 & 乙。")])
        XCTAssertTrue(EdgeSpeechClient.sentenceBoundaries(Data("bad".utf8)).isEmpty)
        let text = "  甲   乙。\n第二句。"
        let chunk = try XCTUnwrap(CloudSpeechText.chunks(in: text).first)
        let ranges = SpeechText.sourceRanges(of: ["甲 乙。", "第二句。"], in: chunk.text)
        XCTAssertEqual(chunk.sourceRange(for: try XCTUnwrap(ranges[0])), 2..<8)
        XCTAssertEqual(chunk.sourceRange(for: try XCTUnwrap(ranges[1])), 9..<13)
        XCTAssertNil(chunk.sourceRange(for: -1..<2))
        var cache = SpeechAudioMemoryCache()
        cache.putAudio(.init(data: Data([1]), boundaries: boundaries), for: "one")
        XCTAssertEqual(cache.getAudio("one")?.boundaries, boundaries)
    }

    func testCacheEvictsLeastRecentlyUsedAndStopCanClearAll() {
        var cache = SpeechAudioMemoryCache(maximumBytes: 6)
        cache.put(Data([1,2,3]), for: "a"); cache.put(Data([4,5,6]), for: "b")
        XCTAssertNotNil(cache.get("a"))
        cache.put(Data([7,8,9]), for: "c")
        XCTAssertNil(cache.get("b")); XCTAssertEqual(cache.byteCount, 6)
        cache.put(Data(repeating: 0, count: 7), for: "huge")
        XCTAssertNil(cache.get("huge"))
        cache.removeAll(); XCTAssertEqual(cache.byteCount, 0); XCTAssertNil(cache.get("a"))
    }
    func testEdgeIsOffUntilExplicitConsentAndLocalVoiceIsPreserved() throws {
        let name = "EdgeConsent-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SpeechSettingsStore(defaults: defaults)
        var value = SpeechSettings.default
        value.preferredEngine = .edge; value.voiceIdentifier = "local-saved"; value.edgeVoiceIdentifier = "zh-CN-YunxiNeural"
        store.save(value)
        XCTAssertEqual(store.load().preferredEngine, .system)
        store.setEdgeConsent(true)
        XCTAssertEqual(store.load().preferredEngine, .edge)
        XCTAssertEqual(store.load().voiceIdentifier, "local-saved")
        XCTAssertEqual(store.load().edgeVoiceIdentifier, "zh-CN-YunxiNeural")
        store.reset(); XCTAssertFalse(store.edgeConsentGranted); XCTAssertEqual(store.load(), .default)
    }
}
