// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NoveliaIOSCore

final class ReadingAIInfrastructureTests: XCTestCase {
    private func config(_ address: String = "https://ai.example.com/v1/") -> ReadingAIConfiguration {
        var value = ReadingAIConfiguration()
        value.isEnabled = true; value.baseURL = address; value.model = "test-model"
        return value
    }
    func testEndpointNormalizesAndRejectsCredentialBearingAddresses() throws {
        XCTAssertEqual(try config().endpoint().absoluteString, "https://ai.example.com/v1/chat/completions")
        for address in ["http://ai.example.com/v1", "https://user:key@ai.example.com/v1", "https://ai.example.com/v1?key=secret",
                        "https://ai.example.com/v1#secret", "https://ai.example.com/v1/chat/completions", "", "file:///v1"] {
            XCTAssertThrowsError(try config(address).endpoint(), address)
        }
        var value = config(); value.maximumOutputTokens = 0
        XCTAssertThrowsError(try value.validated())
    }
    func testRequestUsesOnlyExplicitInputAndSelectedCompatibilityParameter() throws {
        var config = self.config(); config.tokenParameter = .legacy; config.requestsJSON = true
        let request = try OpenAIReadingClient.urlRequest(configuration: config, apiKey: "isolated-test-key",
            request: .init(instruction: "Return JSON.", input: "已读章节，仅此文本。"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer isolated-test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Return JSON."], ["role": "user", "content": "已读章节，仅此文本。"]])
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("isolated-test-key"))
    }
    func testOversizeInputAndHeaderInjectionRejectedBeforeTransport() {
        XCTAssertThrowsError(try OpenAIReadingClient.urlRequest(configuration: config(), apiKey: "test\r\nInjected: header", request: .connectionTest))
        let huge = ReadingAIRequest(instruction: "Summarize.", input: String(repeating: "中", count: ReadingAIRequest.maximumInputBytes / 3 + 1))
        XCTAssertThrowsError(try OpenAIReadingClient.urlRequest(configuration: config(), apiKey: "test", request: huge)) {
            XCTAssertEqual($0 as? ReadingAIError, .inputLimit)
        }
    }
    func testTruncationRefusalAndToolResultsAreNeverAcceptedAsSummary() throws {
        func body(reason: String, content: String = "text", refusal: String? = nil) throws -> Data {
            var message = ["content": content]
            if let refusal { message["refusal"] = refusal }
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": reason]]])
        }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(body(reason: "length"))) { XCTAssertEqual($0 as? ReadingAIError, .truncated) }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(body(reason: "stop", refusal: "No"))) { XCTAssertEqual($0 as? ReadingAIError, .refused) }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(body(reason: "tool_calls")))
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data("{\"choices\":[]}".utf8)))
        XCTAssertThrowsError(try OpenAIReadingClient.decode(body(reason: "stop", content: "  ")))
        let valid = Data("{\"choices\":[{\"message\":{\"content\":\"结果\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":4}}".utf8)
        XCTAssertEqual(try OpenAIReadingClient.decode(valid), .init(text: "结果", inputTokens: 20, outputTokens: 4))
    }

    func testStreamingResponseIsAssembledAndReportsReceivedCharacters() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingAITestURLProtocol.self]
        let client = OpenAIReadingClient(configuration: configuration)
        final class Box: @unchecked Sendable { var counts: [Int] = [] }
        let box = Box()
        let response = try await client.complete(configuration: config("https://stream.example/v1"), apiKey: "fake",
                                                 request: .connectionTest) { box.counts.append($0) }
        XCTAssertEqual(response.text, "OK")
        // 流式只按字符数节流回调，最后补一次完整值。
        XCTAssertEqual(box.counts.last, 2)
    }

    func testStreamingShellBytesDoNotCountAgainstTheTextLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingAITestURLProtocol.self]
        let client = OpenAIReadingClient(configuration: configuration)
        // 原始事件流约 1.3 MiB，拼装后的正文只有 5200 字，必须成功而不是报“超过 1 MiB”。
        let response = try await client.complete(configuration: config("https://bigstream.example/v1"), apiKey: "fake",
                                                 request: .connectionTest)
        XCTAssertEqual(response.text.count, 5_200)
    }

    func testTransportAcceptsOnlyBoundedSuccessfulTextResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingAITestURLProtocol.self]
        let client = OpenAIReadingClient(configuration: configuration)
        let success = try await client.complete(configuration: config("https://success.example/v1"), apiKey: "fake", request: .connectionTest)
        XCTAssertEqual(success.text, "OK")
        for (host, expected) in [("auth", ReadingAIError.http(401)), ("redirect", .http(307)),
                                 ("oversize", .responseLimit), ("broken", .invalidResponse)] {
            do {
                _ = try await client.complete(configuration: config("https://\(host).example/v1"), apiKey: "fake", request: .connectionTest)
                XCTFail("不应接受失败或超限返回")
            } catch {
                XCTAssertEqual(error as? ReadingAIError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private-server-body"))
            }
        }
    }

    @MainActor
    func testDisabledServiceDoesNotCallClientAndFixedTestDoesNotReadBooks() async throws {
        let suite = "ReadingAITest-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = RecordingReadingAI(), keys = MemoryReadingAIKeys()
        let store = ReadingAIStore(defaults: defaults, keys: keys, client: client)
        do { _ = try await store.generate(.init(instruction: "instruction", input: "正文")); XCTFail() }
        catch { XCTAssertEqual(error as? ReadingAIError, .disabled) }
        var value = config(); value.isEnabled = false
        try store.save(value, newKey: "secret-test-key")
        _ = try await store.testConnection()
        let requests = await client.requests
        XCTAssertEqual(requests, [.connectionTest])
        let data = try XCTUnwrap(defaults.data(forKey: "reader.ai.configuration.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-test-key"))
        let reopened = ReadingAIStore(defaults: defaults, keys: keys, client: client)
        XCTAssertTrue(reopened.hasSavedKey)
        XCTAssertEqual(reopened.configuration, value)
        try reopened.deleteCurrentKey()
        XCTAssertFalse(reopened.hasSavedKey)
        XCTAssertFalse(reopened.configuration.isEnabled)
    }
    @MainActor
    func testChangingEndpointCannotReusePreviousProvidersKey() throws {
        let suite = "ReadingAIScope-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: RecordingReadingAI())
        try store.save(config(), newKey: "first-key")
        XCTAssertThrowsError(try store.save(config("https://other.example.com/v1"), newKey: "")) {
            XCTAssertEqual($0 as? ReadingAIError, .missingKey)
        }
        XCTAssertEqual(store.configuration.baseURL, config().baseURL)
    }
    @MainActor
    func testDisablingConfigurationCancelsInFlightGeneration() async throws {
        let suite = "ReadingAICancel-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = WaitingReadingAI()
        let store = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        try store.save(config(), newKey: "test-key")
        let task = Task { try await store.generate(.connectionTest) }
        for _ in 0..<1_000 {
            let ready = await client.started
            if ready { break }
            await Task.yield()
        }
        let started = await client.started
        XCTAssertTrue(started)
        var disabled = config(); disabled.isEnabled = false
        try store.save(disabled, newKey: "")
        do { _ = try await task.value; XCTFail("旧任务不应返回可展示结果") } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor
    func testCorruptConfigurationDoesNotEnableAI() throws {
        let suite = "ReadingAICorrupt-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("bad-data".utf8), forKey: "reader.ai.configuration.v1")
        let store = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: RecordingReadingAI())
        XCTAssertFalse(store.configuration.isEnabled)
        XCTAssertFalse(store.hasSavedKey)
        var invalid = config(); invalid.maximumOutputTokens = -1
        defaults.set(try JSONEncoder().encode(invalid), forKey: "reader.ai.configuration.v1")
        let repaired = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: RecordingReadingAI())
        XCTAssertFalse(repaired.configuration.isEnabled)
        XCTAssertEqual(repaired.configuration.maximumOutputTokens, 4_096)
    }
    @MainActor
    func testAutomaticRecapRequiresConfiguredAPIModelAndReadableSavedKey() throws {
        let suite = "RecapReadiness-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = MemoryReadingAIKeys(), client = RecordingReadingAI()
        let initial = ReadingAIStore(defaults: defaults, keys: keys, client: client)
        XCTAssertFalse(initial.isReadyForGeneration)
        let configuration = config()
        defaults.set(try JSONEncoder().encode(configuration), forKey: "reader.ai.configuration.v1")
        let missing = ReadingAIStore(defaults: defaults, keys: keys, client: client)
        XCTAssertFalse(missing.isReadyForGeneration)
        try missing.save(configuration, newKey: "isolated-test-key")
        XCTAssertTrue(missing.isReadyForGeneration)
        try keys.write(nil, scope: configuration.endpoint().absoluteString)
        missing.refreshKeyStatus()
        XCTAssertFalse(missing.isReadyForGeneration)
        try keys.write("", scope: configuration.endpoint().absoluteString)
        missing.refreshKeyStatus()
        XCTAssertFalse(missing.isReadyForGeneration)
        var disabled = configuration; disabled.isEnabled = false
        try missing.save(disabled, newKey: "isolated-test-key")
        XCTAssertFalse(missing.isReadyForGeneration)
    }

}

private actor RecordingReadingAI: ReadingAICompleting {
    var requests = [ReadingAIRequest]()
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        requests.append(request)
        return .init(text: "OK", inputTokens: 1, outputTokens: 1)
    }
}
private actor WaitingReadingAI: ReadingAICompleting {
    var started = false
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        started = true
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return .init(text: "late", inputTokens: nil, outputTokens: nil)
    }
}

/// 所有请求均由内存响应接管；任何测试失败都不会退回真实网络。
private final class ReadingAITestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        let code = host == "auth.example" ? 401 : (host == "redirect.example" ? 307 : 200)
        var headers = ["Content-Type": "application/json", "Location": "https://never-follow.example/v1/chat/completions"]
        if host == "oversize.example" { headers["Content-Length"] = "2097152" }
        if host == "stream.example" { headers["Content-Type"] = "text/event-stream" }
        if host == "bigstream.example" { headers["Content-Type"] = "text/event-stream" }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let valid = "{\"choices\":[{\"message\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}"
        let stream = """
        data: {"choices":[{"delta":{"content":"O"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"K"},"finish_reason":"stop"}]}

        data: [DONE]


        """
        // 每个 token 一个事件，JSON 外壳总量远超正文：正文上限不能按原始字节数判定。
        let padding = String(repeating: "a", count: 200)
        let big = String(repeating: "data: {\"id\":\"\(padding)\",\"choices\":[{\"delta\":{\"content\":\"x\"},\"finish_reason\":null}]}\n\n", count: 5_200)
            + "data: [DONE]\n\n"
        let text = host == "success.example" ? valid
            : (host == "stream.example" ? stream : (host == "bigstream.example" ? big : "private-server-body"))
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
