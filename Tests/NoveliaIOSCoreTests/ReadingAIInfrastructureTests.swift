// SPDX-License-Identifier: GPL-3.0-only
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NoveliaIOSCore

final class ReadingAIInfrastructureTests: XCTestCase {
    @MainActor
    func testConversationRetainsCompletedReplyWithoutPersistingIt() async throws {
        let suite = "ReadingAIConversation-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = MemoryReadingAIKeys()
        let store = ReadingAIStore(defaults: defaults, keys: keys, client: RecordingReadingAI())
        try store.save(config(), newKey: "test-key")
        _ = try await ReadingAIStore.$conversationID.withValue("conversation-one") { try await store.generate(.connectionTest) }
        XCTAssertTrue(store.requestProgress.isEmpty)
        XCTAssertEqual(store.completedReplies.first?.preview, "OK")
        XCTAssertEqual(store.completedReplies.first?.conversationID, "conversation-one")
        let reopened = ReadingAIStore(defaults: defaults, keys: keys, client: RecordingReadingAI())
        XCTAssertTrue(reopened.completedReplies.isEmpty)
    }

    @MainActor
    func testConcurrentProgressIsIsolatedAndLateCallbacksAreIgnored() async throws {
        let suite = "ReadingAIProgress-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ControlledProgressAI()
        let store = ReadingAIStore(defaults: defaults, keys: MemoryReadingAIKeys(), client: client)
        try store.save(config(), newKey: "test-key")
        let first = Task { try await store.generate(.init(instruction: "first", input: "test")) }
        let second = Task { try await store.generate(.init(instruction: "second", input: "test")) }
        for _ in 0..<1000 {
            if await client.count == 2 { break }
            await Task.yield()
        }
        await client.emit()
        for _ in 0..<1000 {
            if store.streamedCharacters == 30 { break }
            await Task.yield()
        }
        XCTAssertEqual(Set(store.requestProgress.values.map(\.characters)), Set([10, 20]))
        XCTAssertEqual(store.streamedCharacters, 30)
        first.cancel(); second.cancel()
        _ = await first.result; _ = await second.result
        XCTAssertTrue(store.requestProgress.isEmpty)
        await client.emit()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(store.requestProgress.isEmpty)
    }

    private func config(_ address: String = "https://ai.example.com/v1/") -> ReadingAIConfiguration {
        var value = ReadingAIConfiguration()
        value.isEnabled = true; value.baseURL = address; value.model = "test-model"
        return value
    }
    func testEndpointNormalizesAndRejectsCredentialBearingAddresses() throws {
        XCTAssertEqual(try config().endpoint().absoluteString, "https://ai.example.com/v1/chat/completions")
        for address in ["http://ai.example.com/v1", "https://user:key@ai.example.com/v1", "https://ai.example.com/v1?key=secret",
                        "https://ai.example.com/v1#secret", "https://ai.example.com/v1/chat/completions",
                        "https://ai.example.com/v1/responses", "https://ai.example.com/v1/messages", "", "file:///v1"] {
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
        XCTAssertNil(body["store"]); XCTAssertNil(body["instructions"]); XCTAssertNil(body["max_output_tokens"])
        XCTAssertNil(body["output_config"]); XCTAssertNil(body["system"])
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
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
        final class Box: @unchecked Sendable { var counts: [Int] = []; var tails: [String] = [] }
        let box = Box()
        let response = try await client.complete(configuration: config("https://stream.example/v1"), apiKey: "fake",
                                                 request: .connectionTest) { count, tail in
            box.counts.append(count); box.tails.append(tail)
        }
        XCTAssertEqual(response.text, "OK")
        // 流式只按字符数节流回调，最后补一次完整值。
        XCTAssertEqual(box.counts.last, 2)
        XCTAssertEqual(box.tails.last, "OK")
    }

    func testStreamingShellBytesDoNotCountAgainstTheTextLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingAITestURLProtocol.self]
        let client = OpenAIReadingClient(configuration: configuration)
        // 原始事件流约 1.3 MiB，拼装后的正文只有 5200 字，必须成功而不是报“超过 1 MiB”。
        final class ReplyBox: @unchecked Sendable { var text = "" }
        let box = ReplyBox()
        let response = try await client.complete(configuration: config("https://bigstream.example/v1"), apiKey: "fake",
                                                 request: .connectionTest) { _, text in box.text = text }
        XCTAssertEqual(response.text.count, 5_200)
        XCTAssertEqual(box.text, response.text, "对话必须收到完整回复，而非仅末尾片段")
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
        if host.hasPrefix("responses-") || host.hasPrefix("anthropic-") {
            let responses = host.hasPrefix("responses-")
            let pathOK = request.url?.path.hasSuffix(responses ? "/responses" : "/messages") == true
            let authOK = responses
                ? request.value(forHTTPHeaderField: "Authorization") == "Bearer fake" && request.value(forHTTPHeaderField: "x-api-key") == nil
                : request.value(forHTTPHeaderField: "x-api-key") == "fake"
                    && request.value(forHTTPHeaderField: "Authorization") == nil
                    && request.value(forHTTPHeaderField: "anthropic-version") == ReadingAIConfiguration.anthropicAPIVersion
            guard pathOK, authOK else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
        }
        let code = host == "auth.example" ? 401 : (host == "redirect.example" ? 307 : 200)
        var headers = ["Content-Type": "application/json", "Location": "https://never-follow.example/v1/chat/completions"]
        if host == "oversize.example" { headers["Content-Length"] = "2097152" }
        if host == "stream.example" || host == "bigstream.example" || host.hasSuffix("-stream.example") {
            headers["Content-Type"] = "text/event-stream"
        }
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
        let responsesStream = """
        data: {"type":"response.output_text.delta","delta":"O"}

        data: {"type":"response.reasoning_summary_text.delta","delta":"hidden"}

        data: {"type":"response.output_text.delta","delta":"K"}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":3,"output_tokens":1}}}


        """
        let anthropicStream = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

        data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret"}}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"O"}}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"K"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

        data: {"type":"message_stop"}


        """
        let text = host == "success.example" ? valid
            : (host == "stream.example" ? stream : (host == "bigstream.example" ? big
                : (host == "responses-stream.example" ? responsesStream
                    : (host == "anthropic-stream.example" ? anthropicStream
                        : (host == "responses-json.example"
                            ? "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}],\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}"
                            : (host == "anthropic-json.example"
                                ? "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hidden\"},{\"type\":\"text\",\"text\":\"OK\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}"
                                : "private-server-body"))))))
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ControlledProgressAI: ReadingAICompleting {
    private var callbacks: [String: @Sendable (Int, String) -> Void] = [:]
    var count: Int { callbacks.count }
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        try await complete(configuration: configuration, apiKey: apiKey, request: request, onProgress: { _, _ in })
    }
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse {
        callbacks[request.instruction] = onProgress
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return .init(text: "done", inputTokens: nil, outputTokens: nil)
    }
    func emit() { callbacks["first"]?(10, "first"); callbacks["second"]?(20, "second") }
}

final class ReasoningEffortRequestTests: XCTestCase {
    func testThinkingOffUsesTheThinkingToggleInsteadOfEffort() throws {
        var config = ReadingAIConfiguration()
        config.isEnabled = true; config.baseURL = "https://ai.example.com/v1"; config.model = "test-model"
        config.reasoningEffort = .off
        let request = try OpenAIReadingClient.urlRequest(configuration: config, apiKey: "k", request: .connectionTest)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(body["reasoning_effort"])
    }
    func testEffortLevelsAreSentAsReasoningEffort() throws {
        for effort in [ReadingAIConfiguration.ReasoningEffort.low, .medium, .high, .max] {
            var config = ReadingAIConfiguration()
            config.isEnabled = true; config.baseURL = "https://ai.example.com/v1"; config.model = "test-model"
            config.reasoningEffort = effort
            let request = try OpenAIReadingClient.urlRequest(configuration: config, apiKey: "k", request: .connectionTest)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["reasoning_effort"] as? String, effort.rawValue)
            XCTAssertNil(body["thinking"])
        }
    }
    func testNoSelectionSendsNeitherParameter() throws {
        var config = ReadingAIConfiguration()
        config.isEnabled = true; config.baseURL = "https://ai.example.com/v1"; config.model = "test-model"
        config.reasoningEffort = nil
        let request = try OpenAIReadingClient.urlRequest(configuration: config, apiKey: "k", request: .connectionTest)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["reasoning_effort"]); XCTAssertNil(body["thinking"])
    }
}

final class ReadingAIFormatTests: XCTestCase {
    private func config(_ address: String = "https://ai.example.com/v1/") -> ReadingAIConfiguration {
        var value = ReadingAIConfiguration()
        value.isEnabled = true; value.baseURL = address; value.model = "test-model"
        return value
    }
    private func decodedBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testEachFormatAppendsItsOwnPathAndStillRejectsUnsafeAddresses() throws {
        var responses = config(); responses.requestFormat = .responses
        XCTAssertEqual(try responses.endpoint().absoluteString, "https://ai.example.com/v1/responses")
        var anthropic = config("https://API.Example.com/v1/"); anthropic.requestFormat = .anthropicMessages
        XCTAssertEqual(try anthropic.endpoint().absoluteString, "https://api.example.com/v1/messages")
        for format in ReadingAIConfiguration.RequestFormat.allCases {
            for address in ["http://ai.example.com/v1", "https://user:secret@ai.example.com/v1",
                            "https://ai.example.com/v1?token=secret", "https://ai.example.com/v1/chat/completions",
                            "https://ai.example.com/v1/responses", "https://ai.example.com/v1/messages"] {
                var value = config(address); value.requestFormat = format
                XCTAssertThrowsError(try value.endpoint(), "\(format.rawValue) \(address)")
            }
        }
    }

    func testAddressFootnoteIsPlainTextAndNamesTheSelectedPath() throws {
        for format in ReadingAIConfiguration.RequestFormat.allCases {
            var value = config(); value.requestFormat = format
            let footnote = value.addressFootnote
            XCTAssertTrue(footnote.contains("https://api.example.com/v1"), footnote)
            XCTAssertTrue(footnote.contains(format.appendedPath), footnote)
            XCTAssertFalse(footnote.contains("]("))
            XCTAssertFalse(AttributedString(footnote).runs.contains { $0.link != nil })
        }
        let chat = config().compatibilityFootnote
        XCTAssertTrue(chat.contains("o1")); XCTAssertTrue(chat.contains("o3")); XCTAssertTrue(chat.contains("o4-mini"))
        XCTAssertTrue(chat.contains("reasoning_effort"))
        XCTAssertTrue(chat.contains("不认单独的 thinking 开关"))
        XCTAssertFalse(chat.contains("o 系列"))
        var responses = config(); responses.requestFormat = .responses
        XCTAssertTrue(responses.compatibilityFootnote.contains("max_output_tokens"))
        XCTAssertTrue(responses.compatibilityFootnote.contains("store"))
        XCTAssertTrue(responses.compatibilityFootnote.contains("json_object"))
        var anthropic = config(); anthropic.requestFormat = .anthropicMessages
        XCTAssertTrue(anthropic.compatibilityFootnote.contains("x-api-key"))
        XCTAssertTrue(anthropic.compatibilityFootnote.contains(ReadingAIConfiguration.anthropicAPIVersion))
        XCTAssertTrue(anthropic.compatibilityFootnote.contains("json_schema"))
        XCTAssertFalse(anthropic.requestFormat.allowsJSONMode)
        XCTAssertFalse(anthropic.requestFormat.selectableEfforts.contains(.off))
    }

    func testLegacyConfigurationWithoutRequestFormatStaysOnChatCompletions() throws {
        let original = Data("""
        {"isEnabled":true,"baseURL":"https://ai.example.com/v1","model":"test-model","maximumOutputTokens":4096,"tokenParameter":"max_completion_tokens","requestsJSON":false}
        """.utf8)
        let value = try JSONDecoder().decode(ReadingAIConfiguration.self, from: original)
        XCTAssertEqual(value.requestFormat, .chatCompletions)
        XCTAssertNil(value.reasoningEffort)
        XCTAssertEqual(try value.endpoint().absoluteString, "https://ai.example.com/v1/chat/completions")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertNil(encoded["requestFormat"])
        XCTAssertEqual(Set(encoded.keys), ["baseURL", "isEnabled", "maximumOutputTokens", "model", "requestsJSON", "tokenParameter"])
        var changed = value; changed.requestFormat = .responses
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
        XCTAssertEqual(saved["requestFormat"] as? String, "responses")
    }

    func testResponsesRequestUsesOfficialFieldsAndDoesNotStoreTheReply() throws {
        var config = self.config(); config.requestFormat = .responses; config.requestsJSON = true; config.reasoningEffort = .off
        let request = try OpenAIReadingClient.urlRequest(configuration: config, apiKey: "isolated-test-key", request: .connectionTest)
        XCTAssertEqual(request.url?.absoluteString, "https://ai.example.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer isolated-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try decodedBody(request)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4_096)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, ReadingAIRequest.connectionTest.instruction)
        XCTAssertEqual(body["input"] as? String, ReadingAIRequest.connectionTest.input)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        let format = (body["text"] as? [String: Any])?["format"] as? [String: String]
        XCTAssertEqual(format?["type"], "json_object")
        for absent in ["messages", "max_tokens", "max_completion_tokens", "thinking", "reasoning_effort", "response_format", "temperature"] {
            XCTAssertNil(body[absent], absent)
        }
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("isolated-test-key"))
        for effort in [ReadingAIConfiguration.ReasoningEffort.low, .medium, .high, .max] {
            var level = self.config(); level.requestFormat = .responses; level.reasoningEffort = effort
            let encoded = try decodedBody(OpenAIReadingClient.urlRequest(configuration: level, apiKey: "k", request: .connectionTest))
            XCTAssertEqual((encoded["reasoning"] as? [String: String])?["effort"], effort.rawValue)
            XCTAssertNil(encoded["thinking"])
        }
    }

    func testAnthropicRequestUsesRequiredHeadersAndOmitsUnmappedFields() throws {
        var config = self.config(); config.requestFormat = .anthropicMessages; config.reasoningEffort = .high
        let request = try OpenAIReadingClient.urlRequest(configuration: config, apiKey: "isolated-test-key", request: .connectionTest)
        XCTAssertEqual(request.url?.absoluteString, "https://ai.example.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "isolated-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), ReadingAIConfiguration.anthropicAPIVersion)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try decodedBody(request)
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(body["system"] as? String, ReadingAIRequest.connectionTest.instruction)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": ReadingAIRequest.connectionTest.input]])
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "high")
        for absent in ["thinking", "response_format", "temperature", "max_completion_tokens", "max_output_tokens", "reasoning_effort", "store", "instructions"] {
            XCTAssertNil(body[absent], absent)
        }
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("isolated-test-key"))
        var plain = self.config(); plain.requestFormat = .anthropicMessages
        XCTAssertNil(try decodedBody(OpenAIReadingClient.urlRequest(configuration: plain, apiKey: "k", request: .connectionTest))["output_config"])
    }

    func testAnthropicRejectsJSONModeAndDisabledThinkingBeforeTransport() {
        var json = config(); json.requestFormat = .anthropicMessages; json.requestsJSON = true
        XCTAssertThrowsError(try OpenAIReadingClient.urlRequest(configuration: json, apiKey: "k", request: .connectionTest)) {
            XCTAssertEqual($0 as? ReadingAIError, .unsupportedParameter)
        }
        var off = config(); off.requestFormat = .anthropicMessages; off.reasoningEffort = .off
        XCTAssertThrowsError(try off.validated()) { XCTAssertEqual($0 as? ReadingAIError, .unsupportedParameter) }
        off.requestsJSON = true
        off.applyFormatCompatibility()
        XCTAssertFalse(off.requestsJSON)
        XCTAssertNil(off.reasoningEffort)
        XCTAssertNoThrow(try off.validated())
    }

    func testResponsesAndAnthropicParsersKeepVisibleTextAndRejectBadStops() throws {
        let completed = Data("""
        {"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"结果"}]}],"usage":{"input_tokens":8,"output_tokens":2}}
        """.utf8)
        XCTAssertEqual(try OpenAIReadingClient.decode(completed, format: .responses), .init(text: "结果", inputTokens: 8, outputTokens: 2))
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data("""
        {"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"部分"}]}]}
        """.utf8), format: .responses)) { XCTAssertEqual($0 as? ReadingAIError, .truncated) }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data("""
        {"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[{"type":"message","content":[{"type":"output_text","text":"部分"}]}]}
        """.utf8), format: .responses)) { XCTAssertEqual($0 as? ReadingAIError, .refused) }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data("""
        {"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}
        """.utf8), format: .responses)) { XCTAssertEqual($0 as? ReadingAIError, .refused) }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data("""
        {"status":"completed","output":[{"type":"function_call"},{"type":"message","content":[{"type":"output_text","text":"旁白"}]}]}
        """.utf8), format: .responses)) { XCTAssertEqual($0 as? ReadingAIError, .invalidResponse) }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data(#"{"status":"failed","output":[]}"#.utf8), format: .responses)) {
            XCTAssertEqual($0 as? ReadingAIError, .invalidResponse)
        }

        var counts: [Int] = []
        let streamed = try OpenAIReadingClient.decodeStreamPayloads([
            #"{"type":"response.output_text.delta","delta":"结"}"#,
            #"{"type":"response.reasoning_summary_text.delta","delta":"不要显示"}"#,
            #"{"type":"response.output_text.delta","delta":"果"}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"结果"}]}],"usage":{"input_tokens":8,"output_tokens":2}}}"#
        ], format: .responses) { count, text in counts.append(count); XCTAssertFalse(text.contains("不要显示")) }
        XCTAssertEqual(streamed, .init(text: "结果", inputTokens: 8, outputTokens: 2))
        XCTAssertEqual(counts.last, 2)
        XCTAssertThrowsError(try OpenAIReadingClient.decodeStreamPayloads([
            #"{"type":"response.output_text.delta","delta":"no"}"#,
            #"{"type":"response.refusal.delta","delta":"no"}"#
        ], format: .responses)) { XCTAssertEqual($0 as? ReadingAIError, .refused) }
        XCTAssertThrowsError(try OpenAIReadingClient.decodeStreamPayloads([
            #"{"type":"error","error":{"message":"secret prompt"}}"#
        ], format: .responses)) {
            XCTAssertEqual($0 as? ReadingAIError, .invalidResponse)
            XCTAssertFalse($0.localizedDescription.contains("secret"))
        }
        XCTAssertThrowsError(try OpenAIReadingClient.decodeStreamPayloads([
            #"{"type":"response.output_text.delta","delta":"部分"}"#,
            #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"部分"}]}]}}"#
        ], format: .responses)) { XCTAssertEqual($0 as? ReadingAIError, .truncated) }

        let message = Data("""
        {"type":"message","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"结果"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":1}}
        """.utf8)
        XCTAssertEqual(try OpenAIReadingClient.decode(message, format: .anthropicMessages), .init(text: "结果", inputTokens: 4, outputTokens: 1))
        XCTAssertEqual(try OpenAIReadingClient.decode(Data(#"{"content":[{"type":"text","text":"停"}],"stop_reason":"stop_sequence"}"#.utf8), format: .anthropicMessages).text, "停")
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data(#"{"content":[{"type":"text","text":"部分"}],"stop_reason":"max_tokens"}"#.utf8), format: .anthropicMessages)) {
            XCTAssertEqual($0 as? ReadingAIError, .truncated)
        }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data(#"{"content":[{"type":"text","text":"不"}],"stop_reason":"refusal"}"#.utf8), format: .anthropicMessages)) {
            XCTAssertEqual($0 as? ReadingAIError, .refused)
        }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data(#"{"content":[{"type":"tool_use","name":"lookup"},{"type":"text","text":"旁白"}],"stop_reason":"tool_use"}"#.utf8), format: .anthropicMessages)) {
            XCTAssertEqual($0 as? ReadingAIError, .invalidResponse)
        }
        XCTAssertThrowsError(try OpenAIReadingClient.decode(Data(#"{"content":[{"type":"text","text":"未完"}],"stop_reason":"pause_turn"}"#.utf8), format: .anthropicMessages)) {
            XCTAssertEqual($0 as? ReadingAIError, .invalidResponse)
        }
        let anthropic = try OpenAIReadingClient.decodeStreamPayloads([
            #"{"type":"message_start","message":{"usage":{"input_tokens":4}}}"#,
            #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hidden"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"结"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"果"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
            #"{"type":"ping"}"#
        ], format: .anthropicMessages)
        XCTAssertEqual(anthropic, .init(text: "结果", inputTokens: 4, outputTokens: 1))
        XCTAssertThrowsError(try OpenAIReadingClient.decodeStreamPayloads([
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"部分"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":9}}"#
        ], format: .anthropicMessages)) { XCTAssertEqual($0 as? ReadingAIError, .truncated) }
        XCTAssertThrowsError(try OpenAIReadingClient.decodeStreamPayloads([
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        ], format: .anthropicMessages)) { XCTAssertEqual($0 as? ReadingAIError, .invalidResponse) }
        XCTAssertEqual(try OpenAIReadingClient.decodeStreamPayloads([
            #"{"choices":[{"delta":{"content":"OK"},"finish_reason":"tool_calls"}]}"#
        ], format: .chatCompletions).text, "OK")
    }

    func testClientParsesStreamingAndJSONForResponsesAndAnthropic() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingAITestURLProtocol.self]
        let client = OpenAIReadingClient(configuration: configuration)
        var responses = config("https://responses-stream.example/v1"); responses.requestFormat = .responses
        let streamed = try await client.complete(configuration: responses, apiKey: "fake", request: .connectionTest)
        XCTAssertEqual(streamed, .init(text: "OK", inputTokens: 3, outputTokens: 1))
        var responsesJSON = config("https://responses-json.example/v1"); responsesJSON.requestFormat = .responses
        let json = try await client.complete(configuration: responsesJSON, apiKey: "fake", request: .connectionTest)
        XCTAssertEqual(json, .init(text: "OK", inputTokens: 2, outputTokens: 1))
        var anthropic = config("https://anthropic-stream.example/v1"); anthropic.requestFormat = .anthropicMessages
        let anthropicStream = try await client.complete(configuration: anthropic, apiKey: "fake", request: .connectionTest)
        XCTAssertEqual(anthropicStream, .init(text: "OK", inputTokens: 5, outputTokens: 2))
        var anthropicJSON = config("https://anthropic-json.example/v1"); anthropicJSON.requestFormat = .anthropicMessages
        let anthropicBody = try await client.complete(configuration: anthropicJSON, apiKey: "fake", request: .connectionTest)
        XCTAssertEqual(anthropicBody, .init(text: "OK", inputTokens: 2, outputTokens: 1))
    }

    @MainActor
    func testChangingFormatCannotReuseThePreviousEndpointKey() throws {
        let suite = "ReadingAIFormatScope-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = MemoryReadingAIKeys()
        let store = ReadingAIStore(defaults: defaults, keys: keys, client: UnavailableReadingAIClient())
        try store.save(config(), newKey: "first-key")
        var responses = config(); responses.requestFormat = .responses
        XCTAssertThrowsError(try store.save(responses, newKey: "")) { XCTAssertEqual($0 as? ReadingAIError, .missingKey) }
        XCTAssertEqual(store.configuration.requestFormat, .chatCompletions)
        try store.save(responses, newKey: "second-key")
        XCTAssertEqual(store.configuration.requestFormat, .responses)
        XCTAssertTrue(store.hasSavedKey)
        let reopened = ReadingAIStore(defaults: defaults, keys: keys, client: UnavailableReadingAIClient())
        XCTAssertEqual(reopened.configuration.requestFormat, .responses)
        XCTAssertEqual(try reopened.configuration.endpoint().absoluteString, "https://ai.example.com/v1/responses")
        XCTAssertTrue(reopened.hasSavedKey)
    }
}
