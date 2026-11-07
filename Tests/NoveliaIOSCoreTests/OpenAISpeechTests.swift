import Foundation
import XCTest
@testable import NoveliaIOSCore

/// 可控 URLProtocol：记录最近请求，按注册的回放返回状态码与响应体。
final class SpeechURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlerBox: ((URLRequest) -> (Int, Data))?

    static func setHandler(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handlerBox = handler
    }

    private static var latestRequestBox: URLRequest?
    private static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        latestRequestBox = request
    }
    static var latestRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return latestRequestBox
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlerBox = nil; latestRequestBox = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.record(request)
        let (status, data): (Int, Data) = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            return Self.handlerBox?(request) ?? (200, Data([0xFF, 0xFB]))
        }()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenAISpeechTests: XCTestCase {
    private func makeClient(_ handler: @escaping (URLRequest) -> (Int, Data),
                            endpoint: OpenAISpeechEndpoint? = OpenAISpeechEndpoint(
                                baseURL: URL(string: "https://api.example.com/v1")!,
                                apiKey: "sk-test", model: "tts-1-hd")) -> OpenAICompatibleSpeechClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechURLProtocol.self]
        let session = URLSession(configuration: config)
        SpeechURLProtocol.setHandler(handler)
        return OpenAICompatibleSpeechClient(endpointProvider: ClosureOpenAIEndpointProvider { endpoint },
                                            session: session)
    }

    override func tearDown() {
        SpeechURLProtocol.reset()
        super.tearDown()
    }

    func testRequestSendsBearerEndpointModelVoiceFormatAndSpeedMapping() async throws {
        let client = makeClient { _ in (200, Data([1, 2, 3])) }
        func lastBody() throws -> [String: Any] {
            let request = try XCTUnwrap(SpeechURLProtocol.latestRequest)
            // URLProtocol 会把 httpBody 转成 bodyStream，需排空读取。
            let stream = try XCTUnwrap(request.httpBodyStream ?? { if let data = request.httpBody { return InputStream(data: data) }; return nil }())
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let audio = try await client.audio(text: "  你好。 ", voice: "alloy", rate: 0.75)
        XCTAssertEqual(audio, Data([1, 2, 3]))
        XCTAssertEqual(SpeechURLProtocol.latestRequest?.url?.absoluteString, "https://api.example.com/v1/audio/speech")
        XCTAssertEqual(SpeechURLProtocol.latestRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(SpeechURLProtocol.latestRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let first = try lastBody()
        XCTAssertEqual(first["model"] as? String, "tts-1-hd")
        XCTAssertEqual(first["input"] as? String, "你好。")
        XCTAssertEqual(first["voice"] as? String, "alloy")
        XCTAssertEqual(first["response_format"] as? String, "mp3")
        XCTAssertEqual(try XCTUnwrap(first["speed"] as? Double), 1.5, accuracy: 0.001)
        SpeechURLProtocol.reset()
        _ = try await client.audio(text: "中", voice: "nova", rate: 0.5)
        XCTAssertEqual(try XCTUnwrap(try lastBody()["speed"] as? Double), 1.0, accuracy: 0.001)
        SpeechURLProtocol.reset()
        _ = try await client.audio(text: "慢", voice: "nova", rate: 0)
        XCTAssertEqual(try XCTUnwrap(try lastBody()["speed"] as? Double), 0.25, accuracy: 0.001)
        SpeechURLProtocol.reset()
        _ = try await client.audio(text: "快", voice: "nova", rate: 1)
        XCTAssertEqual(try XCTUnwrap(try lastBody()["speed"] as? Double), 2.0, accuracy: 0.001)
    }

    func testUnconfiguredAndRejectedInputsFailBeforeSending() async throws {
        let unconfigured = makeClient({ _ in (200, Data([1])) }, endpoint: nil)
        await XCTAssertThrowsErrorAsync(try await unconfigured.audio(text: "一", voice: "alloy", rate: 0.5)) { error in
            XCTAssertEqual(error as? OpenAICompatibleSpeechClient.Failure, .notConfigured)
        }
        XCTAssertNil(SpeechURLProtocol.latestRequest)
        SpeechURLProtocol.reset()
        let configured = makeClient({ _ in (200, Data([1])) })
        await XCTAssertThrowsErrorAsync(try await configured.audio(text: "一", voice: "", rate: 0.5)) { error in
            XCTAssertEqual(error as? OpenAICompatibleSpeechClient.Failure, .invalidVoice)
        }
        SpeechURLProtocol.reset()
        let long = String(repeating: "一", count: OpenAICompatibleSpeechClient.maximumInputCharacters + 1)
        await XCTAssertThrowsErrorAsync(try await configured.audio(text: long, voice: "alloy", rate: 0.5)) { error in
            XCTAssertEqual(error as? OpenAICompatibleSpeechClient.Failure, .tooLarge)
        }
        XCTAssertNil(SpeechURLProtocol.latestRequest, "音色非法或正文超限时不应发起请求")
    }

    func testHTTPStatusMapping() async throws {
        let cases: [(Int, Data, OpenAICompatibleSpeechClient.Failure)] = [
            (401, Data(), .invalidKey),
            (403, Data(), .invalidKey),
            (404, Data(), .invalidEndpoint),
            (429, Data(), .rejected(status: 429)),
            (400, Data(), .invalidVoice),
            (500, Data(), .unavailable),
            (503, Data(), .unavailable),
            (200, Data(), .noAudio),
        ]
        for (status, data, expected) in cases {
            let client = makeClient { _ in (status, data) }
            await XCTAssertThrowsErrorAsync(try await client.audio(text: "一", voice: "alloy", rate: 0.5)) { error in
                XCTAssertEqual(error as? OpenAICompatibleSpeechClient.Failure, expected, "status \(status)")
            }
            SpeechURLProtocol.reset()
        }

    }

    func testSettingsClampsEndpointFieldsAndStoreRoundTrips() {
        var settings = SpeechSettings.default
        settings.openAIBaseURL = " http://api.example.com/v1 "
        XCTAssertNotEqual(SpeechSettings.normalizedEndpoint(settings.openAIBaseURL), settings.openAIBaseURL)
        settings.openAIBaseURL = "https://api.example.com/v1"
        settings.openAIModel = "  tts-1  "
        settings.openAIVoice = "我的自定义音色"
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.openAIBaseURL, "https://api.example.com/v1")
        XCTAssertEqual(clamped.openAIModel, "tts-1")
        XCTAssertEqual(clamped.openAIVoice, "我的自定义音色")
        // 非 HTTPS 地址直接视为未配置；超长字段回落默认值。
        XCTAssertEqual(SpeechSettings.default.clamped().openAIBaseURL, "")
        XCTAssertEqual(SpeechSettings.normalizedEndpoint("https://"), "")
        XCTAssertEqual(SpeechSettings.normalizedField(String(repeating: "x", count: 200), fallback: "tts-1"), "tts-1")
        XCTAssertEqual(SpeechSettings.normalizedField("  ", fallback: "tts-1"), "tts-1")

        let defaults = UserDefaults(suiteName: "openai-speech-tests")!
        defaults.removePersistentDomain(forName: "openai-speech-tests")
        let store = SpeechSettingsStore(defaults: defaults)
        var saved = SpeechSettings.default
        saved.preferredEngine = .openai
        saved.openAIBaseURL = "https://api.example.com/v1"
        saved.openAIModel = "tts-1-hd"
        saved.openAIVoice = "onyx"
        store.save(saved)
        let loaded = store.load()
        XCTAssertEqual(loaded.preferredEngine, .openai)
        XCTAssertEqual(loaded.openAIBaseURL, "https://api.example.com/v1")
        XCTAssertEqual(loaded.openAIModel, "tts-1-hd")
        XCTAssertEqual(loaded.openAIVoice, "onyx")
        // 非法 rawValue 与缺失键仍安全回落；未识别引擎不会停留在云端。
        defaults.set("unknown-engine", forKey: SettingsKey.Speech.preferredEngine)
        XCTAssertEqual(store.load().preferredEngine, .system)
    }

    func testOpenAIVoiceOptionsKeepCustomSelectionVisible() {
        XCTAssertTrue(OpenAISpeechVoices.presets.contains { $0.identifier == "alloy" })
        let options = OpenAISpeechVoices.options(selected: "my-voice")
        XCTAssertTrue(options.contains { $0.identifier == "my-voice" && $0.language == "自定义" })
        XCTAssertEqual(OpenAISpeechVoices.options(selected: "alloy").count, OpenAISpeechVoices.presets.count)
        XCTAssertTrue(OpenAISpeechVoices.isValidVoice("alloy"))
        XCTAssertFalse(OpenAISpeechVoices.isValidVoice(""))
        XCTAssertFalse(OpenAISpeechVoices.isValidVoice(String(repeating: "v", count: 129)))
    }
}

/// XCTest 的异步抛错断言包装；失败时给出实际错误便于排查。
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ errorHandler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("Expected error but call succeeded", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
