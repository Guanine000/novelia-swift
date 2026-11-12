// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux 把 URLSession 放在这个模块；Apple 仍由 Foundation 提供。
#endif

/// 按配置的请求格式执行单次生成。对话补全、Responses 和 Anthropic Messages 共用同一条传输，
/// 但路径、鉴权头和正文互不混用。没有自动重试、后台预取、Cookie 或正文日志。
/// 独立 Session 拒绝重定向，避免把密钥或正文转交另一个来源。
final class OpenAIReadingClient: ReadingAICompleting, @unchecked Sendable {
    private let sessionConfiguration: URLSessionConfiguration
    /// 复用一个 Session：每次新建都要重新 TLS 握手、重建 HTTP/2 连接，按章发请求时
    /// 每次 200–500ms 会白白累加。取消依靠 Task 取消具体请求，不影响同 Session 的其他请求。
    private let session: URLSession
    /// 正文上限：完整 JSON 响应或流式拼装后的文本都不能超过它。
    private static let maximumResponseBytes = 1_024 * 1_024
    /// 流式原始字节上限：每个 SSE 事件都带 JSON 外壳，逐 token 推送时外壳总量远大于正文，
    /// 这里只用于防止异常服务端无限推送，不能拿正文上限去卡它。
    private static let maximumStreamBytes = 16 * 1_024 * 1_024

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 非流式请求在生成期间不返回任何字节，默认 60 秒的"等待新数据"看门狗会把一段
        // 4096–8192 tokens 的正常生成直接掐断。按常用接口最慢情况留足余量。
        configuration.timeoutIntervalForRequest = 300; configuration.timeoutIntervalForResource = 600
        sessionConfiguration = configuration
        session = URLSession(configuration: configuration, delegate: ReadingAIRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        try await complete(configuration: configuration, apiKey: apiKey, request: request) { _, _ in }
    }

    /// 优先按 SSE 流式接收：模型生成期间持续有字节到达，既不会触发空闲超时，
    /// 也能把"已接收字数"反馈给界面。服务端忽略 stream 而直接返回 JSON 时自动回退。
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse {
        let config = try configuration.validated()
        let httpRequest = try Self.urlRequest(configuration: config, apiKey: apiKey, request: request)
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: httpRequest)
            guard let http = response as? HTTPURLResponse else { throw ReadingAIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw ReadingAIError.http(http.statusCode) }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            // 流式响应的长度未知或按外壳计算，正文大小在拼装后另行校验，不在这里按整体长度拒绝。
            guard contentType.contains("text/event-stream") || response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw ReadingAIError.responseLimit
            }
            if contentType.contains("text/event-stream") {
                return try await Self.decodeStream(bytes, format: config.requestFormat, onProgress: onProgress)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { throw ReadingAIError.responseLimit }
                data.append(byte)
                if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return try Self.decode(data, format: config.requestFormat)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as ReadingAIError { throw error }
        catch { throw ReadingAIError.transport }
    }

    /// 编码与解码独立可测；不把服务端原始错误正文返回界面，避免回显正文或凭据。
    static func urlRequest(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) throws -> URLRequest {
        let config = try configuration.validated()
        try request.validate()
        guard !apiKey.isEmpty, apiKey.utf8.count <= 8_192,
              !apiKey.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ReadingAIError.missingKey
        }
        var result = URLRequest(url: try config.endpoint())
        result.httpMethod = "POST"
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        switch config.requestFormat {
        case .chatCompletions, .responses:
            result.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        case .anthropicMessages:
            // 官方 Messages 用 x-api-key，不用 Authorization。版本头按当前文档固定。
            result.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            result.setValue(ReadingAIConfiguration.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        }
        result.httpBody = try JSONSerialization.data(withJSONObject: body(configuration: config, request: request))
        return result
    }

    /// 只放该格式的官方字段。不能映射的开关在校验阶段已经拒绝，这里再守一层，避免漏发出去。
    private static func body(configuration config: ReadingAIConfiguration, request: ReadingAIRequest) -> [String: Any] {
        switch config.requestFormat {
        case .chatCompletions:
            var body: [String: Any] = ["model": config.model, "stream": true,
                "messages": [["role": "system", "content": request.instruction], ["role": "user", "content": request.input]],
                config.tokenParameter.rawValue: config.maximumOutputTokens]
            if config.requestsJSON { body["response_format"] = ["type": "json_object"] }
            // 只在用户显式选择时发送：不支持的接口会直接拒绝未知参数。
            // DeepSeek 一类把"关闭思考"做成 thinking 开关，而不是 effort 取值。
            if let effort = config.reasoningEffort {
                if effort.sendsThinkingToggle { body["thinking"] = ["type": "disabled"] }
                else { body["reasoning_effort"] = effort.rawValue }
            }
            return body
        case .responses:
            var body: [String: Any] = [
                "model": config.model, "stream": true,
                "instructions": request.instruction, "input": request.input,
                "max_output_tokens": config.maximumOutputTokens,
                // 官方默认 store 为 true，会把本次回复留在服务端。章节正文不能这样保存。
                "store": false
            ]
            if config.requestsJSON { body["text"] = ["format": ["type": "json_object"]] }
            if let effort = config.reasoningEffort {
                // Responses 没有独立 thinking 开关；“关闭思考”对应官方 effort none。
                body["reasoning"] = ["effort": effort == .off ? "none" : effort.rawValue]
            }
            return body
        case .anthropicMessages:
            var body: [String: Any] = [
                "model": config.model, "stream": true, "max_tokens": config.maximumOutputTokens,
                "system": request.instruction,
                "messages": [["role": "user", "content": request.input]]
            ]
            // thinking.type=disabled 在不少当前模型上会 400，校验已禁止“关闭思考”。其余档位用 output_config.effort。
            if let effort = config.reasoningEffort, effort != .off {
                body["output_config"] = ["effort": effort.rawValue]
            }
            return body
        }
    }

    /// 供测试直接喂入 `data:` 负载，不经过网络。传输层仍走 `decodeStream`。
    static func decodeStreamPayloads(_ payloads: [String], format: ReadingAIConfiguration.RequestFormat,
                                     onProgress: @escaping (Int, String) -> Void = { _, _ in }) throws -> ReadingAIResponse {
        let state = streamState(format: format, onProgress: onProgress)
        for payload in payloads { try state.consume(payload) }
        return try state.finish()
    }

    static func decode(_ data: Data, format: ReadingAIConfiguration.RequestFormat = .chatCompletions) throws -> ReadingAIResponse {
        switch format {
        case .chatCompletions: return try decodeChat(data)
        case .responses: return try decodeResponses(data)
        case .anthropicMessages: return try decodeAnthropic(data)
        }
    }

    private static func decodeStream(_ bytes: URLSession.AsyncBytes, format: ReadingAIConfiguration.RequestFormat,
                                     onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse {
        let state = streamState(format: format, onProgress: onProgress)
        try await readPayloads(bytes) { try state.consume($0) }
        return try state.finish()
    }

    private static func streamState(format: ReadingAIConfiguration.RequestFormat,
                                    onProgress: @escaping (Int, String) -> Void) -> any ReadingAIStreamState {
        switch format {
        case .chatCompletions: return ChatStreamState(onProgress: onProgress)
        case .responses: return ResponsesStreamState(onProgress: onProgress)
        case .anthropicMessages: return AnthropicStreamState(onProgress: onProgress)
        }
    }

    /// 只认 `data:` 行。`event:` 行里的类型在 JSON 的 type 字段里也有，不重复解析。
    private static func readPayloads(_ bytes: URLSession.AsyncBytes, consume: @escaping (String) throws -> Void) async throws {
        var bytesRead = 0
        for try await line in bytes.lines {
            bytesRead += line.utf8.count + 1
            guard bytesRead <= maximumStreamBytes else { throw ReadingAIError.responseLimit }
            if bytesRead.isMultiple(of: 65_536) { try Task.checkCancellation() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            try consume(String(payload))
        }
        try Task.checkCancellation()
    }

    fileprivate static func appendText(_ piece: String, to text: inout String, reported: inout Int,
                                   onProgress: (Int, String) -> Void) throws {
        guard !piece.isEmpty else { return }
        text += piece
        guard text.utf8.count <= maximumResponseBytes else { throw ReadingAIError.responseLimit }
        // 高频回调会拖慢界面，按字符数节流；结束时再补一次完整值。
        if text.count - reported >= 120 { reported = text.count; onProgress(reported, text) }
    }

    fileprivate static func nonNegative(_ value: Any?) -> Int? {
        let number: Int?
        switch value {
        case let int as Int: number = int
        case let int as Int64: number = Int(exactly: int)
        case let numberValue as NSNumber: number = numberValue.intValue
        default: number = nil
        }
        guard let number, number >= 0 else { return nil }
        return number
    }

    fileprivate static func jsonObject(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func decodeChat(_ data: Data) throws -> ReadingAIResponse {
        guard data.count <= maximumResponseBytes else { throw ReadingAIError.responseLimit }
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let refusal: String? }
                let message: Message
                let finish_reason: String?
            }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]
            let usage: Usage?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let choice = envelope.choices.first else { throw ReadingAIError.invalidResponse }
        if choice.finish_reason == "length" { throw ReadingAIError.truncated }
        if choice.message.refusal?.isEmpty == false || choice.finish_reason == "content_filter" { throw ReadingAIError.refused }
        guard choice.finish_reason == "stop", let text = choice.message.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingAIError.invalidResponse }
        return .init(text: text, inputTokens: envelope.usage?.prompt_tokens.flatMap { $0 >= 0 ? $0 : nil },
                     outputTokens: envelope.usage?.completion_tokens.flatMap { $0 >= 0 ? $0 : nil })
    }

    /// 非流式 Responses 对象，或流式终止事件里的 `response`。推理条目不算正文，工具调用整段拒绝。
    static func interpretResponses(_ object: [String: Any], fallbackText: String) throws -> ReadingAIResponse {
        let status = object["status"] as? String
        let incompleteReason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
        let output = object["output"] as? [[String: Any]] ?? []
        var texts: [String] = []
        var refusal = false
        var unexpected = false
        for item in output {
            switch item["type"] as? String {
            case "reasoning":
                continue
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "output_text":
                        if let value = part["text"] as? String { texts.append(value) }
                    case "refusal":
                        if let value = part["refusal"] as? String, !value.isEmpty { refusal = true }
                    default:
                        unexpected = true
                    }
                }
            default:
                unexpected = true
            }
        }
        if refusal || incompleteReason == "content_filter" { throw ReadingAIError.refused }
        if incompleteReason == "max_output_tokens" { throw ReadingAIError.truncated }
        if unexpected || status != "completed" { throw ReadingAIError.invalidResponse }
        let extracted = texts.joined()
        let text = extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackText : extracted
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingAIError.invalidResponse }
        let usage = object["usage"] as? [String: Any]
        return .init(text: text, inputTokens: nonNegative(usage?["input_tokens"]), outputTokens: nonNegative(usage?["output_tokens"]))
    }

    private static func decodeResponses(_ data: Data) throws -> ReadingAIResponse {
        guard data.count <= maximumResponseBytes else { throw ReadingAIError.responseLimit }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ReadingAIError.invalidResponse }
        return try interpretResponses(object, fallbackText: "")
    }

    /// 只拼接 `type=text` 的块。思考块不是给回顾和人物卡用的正文。
    static func anthropicVisibleText(_ object: [String: Any]) -> String {
        (object["content"] as? [[String: Any]] ?? []).compactMap { block -> String? in
            guard (block["type"] as? String) == "text", let text = block["text"] as? String else { return nil }
            return text
        }.joined()
    }

    static func interpretAnthropic(text: String, stopReason: String?, inputTokens: Int?, outputTokens: Int?,
                                   requireStopReason: Bool) throws -> ReadingAIResponse {
        switch stopReason {
        case "max_tokens": throw ReadingAIError.truncated
        case "refusal": throw ReadingAIError.refused
        case "end_turn", "stop_sequence":
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingAIError.invalidResponse }
            return .init(text: text, inputTokens: nonNegative(inputTokens), outputTokens: nonNegative(outputTokens))
        case nil where !requireStopReason:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingAIError.invalidResponse }
            return .init(text: text, inputTokens: nonNegative(inputTokens), outputTokens: nonNegative(outputTokens))
        default:
            throw ReadingAIError.invalidResponse
        }
    }

    private static func decodeAnthropic(_ data: Data) throws -> ReadingAIResponse {
        guard data.count <= maximumResponseBytes else { throw ReadingAIError.responseLimit }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ReadingAIError.invalidResponse }
        if (object["type"] as? String) == "error" { throw ReadingAIError.invalidResponse }
        let usage = object["usage"] as? [String: Any]
        return try interpretAnthropic(text: anthropicVisibleText(object), stopReason: object["stop_reason"] as? String,
                                      inputTokens: nonNegative(usage?["input_tokens"]), outputTokens: nonNegative(usage?["output_tokens"]),
                                      requireStopReason: true)
    }
}

private protocol ReadingAIStreamState: AnyObject {
    func consume(_ payload: String) throws
    func finish() throws -> ReadingAIResponse
}

/// 对话补全的流式规则保持原样：只拒绝 length 和 content_filter，其余带正文的结束原因仍交付。
private final class ChatStreamState: ReadingAIStreamState {
    private let onProgress: (Int, String) -> Void
    private var text = ""
    private var finishReason: String?
    private var promptTokens: Int?
    private var completionTokens: Int?
    private var reported = 0

    init(onProgress: @escaping (Int, String) -> Void) { self.onProgress = onProgress }

    func consume(_ payload: String) throws {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]?
            let usage: Usage?
        }
        guard let data = payload.data(using: .utf8), let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return }
        if let content = chunk.choices?.first?.delta?.content {
            try OpenAIReadingClient.appendText(content, to: &text, reported: &reported, onProgress: onProgress)
        }
        if let value = chunk.choices?.first?.finish_reason { finishReason = value }
        if let usage = chunk.usage {
            promptTokens = usage.prompt_tokens
            completionTokens = usage.completion_tokens
        }
    }

    func finish() throws -> ReadingAIResponse {
        onProgress(text.count, text)
        if finishReason == "length" { throw ReadingAIError.truncated }
        if finishReason == "content_filter" { throw ReadingAIError.refused }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingAIError.invalidResponse }
        return .init(text: text, inputTokens: promptTokens.flatMap { $0 >= 0 ? $0 : nil },
                     outputTokens: completionTokens.flatMap { $0 >= 0 ? $0 : nil })
    }
}

private final class ResponsesStreamState: ReadingAIStreamState {
    private let onProgress: (Int, String) -> Void
    private var text = ""
    private var reported = 0
    private var terminal: [String: Any]?
    private var refusalDelta = false

    init(onProgress: @escaping (Int, String) -> Void) { self.onProgress = onProgress }

    func consume(_ payload: String) throws {
        guard let object = OpenAIReadingClient.jsonObject(payload) else { return }
        if (object["type"] as? String) == "error" { throw ReadingAIError.invalidResponse }
        switch object["type"] as? String {
        case "response.output_text.delta":
            if let delta = object["delta"] as? String {
                try OpenAIReadingClient.appendText(delta, to: &text, reported: &reported, onProgress: onProgress)
            }
        case "response.refusal.delta", "response.refusal.done":
            refusalDelta = true
        case "response.completed", "response.incomplete", "response.failed":
            terminal = object["response"] as? [String: Any]
        default:
            break
        }
    }

    func finish() throws -> ReadingAIResponse {
        onProgress(text.count, text)
        if refusalDelta { throw ReadingAIError.refused }
        // 正文片段只能用于预览；缺失终止事件时无法确认截断、拒答或工具调用，不能提交为成功结果。
        guard let terminal else { throw ReadingAIError.invalidResponse }
        return try OpenAIReadingClient.interpretResponses(terminal, fallbackText: text)
    }
}

private final class AnthropicStreamState: ReadingAIStreamState {
    private let onProgress: (Int, String) -> Void
    private var text = ""
    private var reported = 0
    private var stopReason: String?
    private var inputTokens: Int?
    private var outputTokens: Int?

    init(onProgress: @escaping (Int, String) -> Void) { self.onProgress = onProgress }

    func consume(_ payload: String) throws {
        guard let object = OpenAIReadingClient.jsonObject(payload) else { return }
        if (object["type"] as? String) == "error" { throw ReadingAIError.invalidResponse }
        switch object["type"] as? String {
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any]
            // 只收 text_delta。thinking_delta 和工具参数不是结果正文。
            if (delta?["type"] as? String) == "text_delta", let piece = delta?["text"] as? String {
                try OpenAIReadingClient.appendText(piece, to: &text, reported: &reported, onProgress: onProgress)
            }
        case "message_start":
            let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
            if let value = OpenAIReadingClient.nonNegative(usage?["input_tokens"]) { inputTokens = value }
        case "message_delta":
            let delta = object["delta"] as? [String: Any]
            if let reason = delta?["stop_reason"] as? String { stopReason = reason }
            let usage = object["usage"] as? [String: Any]
            if let value = OpenAIReadingClient.nonNegative(usage?["output_tokens"]) { outputTokens = value }
            if let value = OpenAIReadingClient.nonNegative(usage?["input_tokens"]) { inputTokens = value }
        default:
            break
        }
    }

    func finish() throws -> ReadingAIResponse {
        onProgress(text.count, text)
        return try OpenAIReadingClient.interpretAnthropic(text: text, stopReason: stopReason, inputTokens: inputTokens,
                                                          outputTokens: outputTokens, requireStopReason: true)
    }
}

private final class ReadingAIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
