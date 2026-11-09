// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 只执行显式单次 Chat Completions 请求；没有自动重试、后台预取、Cookie 或正文日志。
/// 独立 Session 拒绝重定向，避免把密钥或正文转交另一个来源。
final class OpenAIReadingClient: ReadingAICompleting, @unchecked Sendable {
    private let sessionConfiguration: URLSessionConfiguration
    private static let maximumResponseBytes = 1_024 * 1_024

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 非流式请求在生成期间不返回任何字节，默认 60 秒的"等待新数据"看门狗会把一段
        // 4096–8192 tokens 的正常生成直接掐断。按常用接口最慢情况留足余量。
        configuration.timeoutIntervalForRequest = 300; configuration.timeoutIntervalForResource = 600
        sessionConfiguration = configuration
    }

    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        try await complete(configuration: configuration, apiKey: apiKey, request: request) { _ in }
    }

    /// 优先按 SSE 流式接收：模型生成期间持续有字节到达，既不会触发空闲超时，
    /// 也能把"已接收字数"反馈给界面。服务端忽略 stream 而直接返回 JSON 时自动回退。
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onCharacters: @escaping @Sendable (Int) -> Void) async throws -> ReadingAIResponse {
        let request = try Self.urlRequest(configuration: configuration, apiKey: apiKey, request: request)
        let session = URLSession(configuration: sessionConfiguration, delegate: ReadingAIRedirectGuard(), delegateQueue: nil)
        // 任务独占 Session，提前拒绝、超限和取消均关闭底层连接，不留下继续接收的请求。
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReadingAIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw ReadingAIError.http(http.statusCode) }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw ReadingAIError.responseLimit }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/event-stream") {
                return try await Self.decodeStream(bytes, onCharacters: onCharacters)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { throw ReadingAIError.responseLimit }
                data.append(byte)
                if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return try Self.decode(data)
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
        var body: [String: Any] = ["model": config.model, "stream": true,
            "messages": [["role": "system", "content": request.instruction], ["role": "user", "content": request.input]],
            config.tokenParameter.rawValue: config.maximumOutputTokens]
        if config.requestsJSON { body["response_format"] = ["type": "json_object"] }
        var result = URLRequest(url: try config.endpoint())
        result.httpMethod = "POST"; result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        result.httpBody = try JSONSerialization.data(withJSONObject: body)
        return result
    }

    /// 解析 `text/event-stream`：逐行读 `data: {...}`，累加 delta.content。
    /// 服务端只在最后一块给出 finish_reason，所以把停止／截断／过滤的判断放在流结束之后；
    /// 中途解析失败的单个事件直接跳过，不让一段脏数据作废整次生成。
    static func decodeStream(_ bytes: URLSession.AsyncBytes,
                             onCharacters: @Sendable (Int) -> Void) async throws -> ReadingAIResponse {
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
        var text = "", finish: String?, usage: Chunk.Usage?, reported = 0, bytesRead = 0
        for try await line in bytes.lines {
            bytesRead += line.utf8.count + 1
            guard bytesRead <= maximumResponseBytes else { throw ReadingAIError.responseLimit }
            if bytesRead.isMultiple(of: 4_096) { try Task.checkCancellation() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8), let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
            if let content = chunk.choices?.first?.delta?.content, !content.isEmpty {
                text += content
                guard text.utf8.count <= maximumResponseBytes else { throw ReadingAIError.responseLimit }
                // 高频回调会拖慢界面，按字符数节流；最后再补一次完整值。
                if text.count - reported >= 120 { reported = text.count; onCharacters(reported) }
            }
            if let value = chunk.choices?.first?.finish_reason { finish = value }
            if let value = chunk.usage { usage = value }
        }
        try Task.checkCancellation()
        onCharacters(text.count)
        if finish == "length" { throw ReadingAIError.truncated }
        if finish == "content_filter" { throw ReadingAIError.refused }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingAIError.invalidResponse }
        return .init(text: text, inputTokens: usage?.prompt_tokens.flatMap { $0 >= 0 ? $0 : nil },
                     outputTokens: usage?.completion_tokens.flatMap { $0 >= 0 ? $0 : nil })
    }

    static func decode(_ data: Data) throws -> ReadingAIResponse {        guard data.count <= maximumResponseBytes else { throw ReadingAIError.responseLimit }
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
}

private final class ReadingAIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
