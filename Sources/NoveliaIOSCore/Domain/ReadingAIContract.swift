// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 阅读辅助的单次文本生成契约；调用方负责先裁剪已读范围并取得用户生成意图。
/// 不持有书库、原文加载器或会话历史，避免基础设施自行读取未来章节。
protocol ReadingAICompleting: Sendable {
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse
    /// 流式版本：`onProgress` 报告已收到的正文字数与末尾片段，供界面实时展示。
    /// 不支持流式的实现可以只实现上一个方法，默认退化为一次性返回。
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse
}

extension ReadingAICompleting {
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse {
        let response = try await complete(configuration: configuration, apiKey: apiKey, request: request)
        onProgress(response.text.count, String(response.text.suffix(200)))
        return response
    }
}

/// 由 App 注入的安全凭据能力。生产使用 Keychain，替代组装使用独立内存。
@MainActor
protocol ReadingAIKeyStoring: AnyObject {
    func read(scope: String) throws -> String?
    func write(_ key: String?, scope: String) throws
}

struct ReadingAIConfiguration: Codable, Equatable, Sendable {
    enum TokenParameter: String, Codable, CaseIterable, Identifiable, Sendable {
        case completion = "max_completion_tokens", legacy = "max_tokens"
        var id: String { rawValue }
    }
    var isEnabled = false
    /// API 基础地址（例如 https://api.example.com/v1），不是聊天网页地址。
    var baseURL = ""
    var model = ""
    /// 人物卡每块要覆盖十余个角色的多条事实，2048 只能容下约 10 条，容易漏人；
    /// 默认按每块 18 条事实留量，按量计费的接口（如 DeepSeek）可再调高到 8192。
    var maximumOutputTokens = 4_096
    var tokenParameter: TokenParameter = .completion
    var requestsJSON = false

    func endpoint() throws -> URL {
        let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 2_048, var parts = URLComponents(string: input),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ReadingAIError.invalidAddress
        }
        parts.scheme = "https"; parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard !parts.path.hasSuffix("/chat/completions"), let base = parts.url else { throw ReadingAIError.invalidAddress }
        return base.appendingPathComponent("chat/completions")
    }
    func validated() throws -> Self {
        _ = try endpoint()
        var value = self
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.model.isEmpty, value.model.utf8.count <= 200,
              !value.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (128...8_192).contains(maximumOutputTokens) else { throw ReadingAIError.invalidConfiguration }
        return value
    }
}

struct ReadingAIRequest: Equatable, Sendable {
    let instruction: String
    let input: String
    /// 正文预算是 UTF-8 字节数，不冒充模型 token 数；超限必须由业务分章/分块，不能静默截断。
    static let maximumInputBytes = 128 * 1_024
    func validate() throws {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instruction.utf8.count + input.utf8.count <= Self.maximumInputBytes else { throw ReadingAIError.inputLimit }
    }
    static let connectionTest = Self(instruction: "Reply with exactly OK. Do not add anything else.", input: "Connection test.")
}
struct ReadingAIResponse: Equatable, Sendable {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
}

enum ReadingAIError: LocalizedError, Equatable {
    case disabled, unavailable, invalidAddress, invalidConfiguration, missingKey, credentialStorage
    case inputLimit, responseLimit, invalidResponse, truncated, refused, transport, http(Int)
    var errorDescription: String? {
        switch self {
        case .disabled: "请先在 AI 阅读辅助设置中启用 AI。"
        case .unavailable: "当前环境未配置 AI 服务。"
        case .invalidAddress: "请输入 HTTPS API 基础地址；不要包含密钥、查询参数或 /chat/completions。"
        case .invalidConfiguration: "请检查模型名称和输出上限（128–8192 tokens）。"
        case .missingKey: "请先保存当前接口的 API 密钥。"
        case .credentialStorage: "无法访问安全密钥存储，请解锁设备后重试。"
        case .inputLimit: "输入为空或超过 128 KiB，请缩小章节范围后重试。"
        case .responseLimit: "AI 返回内容超过 1 MiB，已中止接收。"
        case .invalidResponse: "接口未返回有效的文本结果，请检查模型及兼容参数。"
        case .truncated: "结果因输出上限被截断，请缩小范围或提高输出上限后重试。"
        case .refused: "模型未提供可用结果，请调整输入后重试。"
        case .transport: "AI 连接失败，请检查网络和接口配置后重试。"
        case .http(let status):
            switch status {
            case 401, 403: "AI 接口鉴权失败（\(status)），请检查密钥和模型权限。"
            case 429: "AI 接口额度不足或请求过于频繁（429），请稍后重试。"
            case 300..<400: "AI 接口发生重定向，已停止请求；请填写最终 API 基础地址。"
            default: "AI 接口请求失败（\(status)），请检查配置后重试。"
            }
        }
    }
}

struct UnavailableReadingAIClient: ReadingAICompleting {
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        throw ReadingAIError.unavailable
    }
}
