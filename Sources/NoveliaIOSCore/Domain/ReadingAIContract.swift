// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 阅读辅助的单次文本生成契约；调用方负责先裁剪已读范围并取得用户生成意图。
/// 不持有书库、原文加载器或会话历史，避免基础设施自行读取未来章节。
protocol ReadingAICompleting: Sendable {
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse
    /// 流式版本：`onProgress` 报告已收到的正文字数与完整已接收正文，供界面实时展示。
    /// 不支持流式的实现可以只实现上一个方法，默认退化为一次性返回。
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse
}

extension ReadingAICompleting {
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse {
        let response = try await complete(configuration: configuration, apiKey: apiKey, request: request)
        onProgress(response.text.count, response.text)
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
    /// 单次请求采用的协议。旧配置没有这个字段时仍是对话补全，避免把已保存的接口改去别的路径。
    enum RequestFormat: String, Codable, CaseIterable, Identifiable, Sendable {
        case chatCompletions = "chat_completions"
        case responses
        case anthropicMessages = "anthropic_messages"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chatCompletions: "对话补全（Chat Completions）"
            case .responses: "Responses（OpenAI）"
            case .anthropicMessages: "Anthropic Messages"
            }
        }
        /// 追加到基础地址上的路径。对话补全保持原来的两段，不能改成单个路径组件。
        var pathComponent: String {
            switch self {
            case .chatCompletions: "chat/completions"
            case .responses: "responses"
            case .anthropicMessages: "messages"
            }
        }
        var appendedPath: String { "/" + pathComponent }
        /// 非对话补全格式的输出上限字段是固定的，界面不再让用户另选参数名。
        var fixedOutputField: String? {
            switch self {
            case .chatCompletions: nil
            case .responses: "max_output_tokens"
            case .anthropicMessages: "max_tokens"
            }
        }
        /// Anthropic 只有带 schema 的 json_schema，没有与 json_object 对应的开关。
        var allowsJSONMode: Bool { self != .anthropicMessages }
        var selectableEfforts: [ReasoningEffort] {
            switch self {
            case .chatCompletions, .responses: ReasoningEffort.allCases
            case .anthropicMessages: ReasoningEffort.allCases.filter { $0 != .off }
            }
        }
        func allows(_ effort: ReasoningEffort) -> Bool { selectableEfforts.contains(effort) }
    }
    /// 官方 Messages 文档当前示例使用的版本头。不是密钥，也不做成用户可填项。
    static let anthropicAPIVersion = "2026-10-21"
    /// 基础地址不能已经是某个协议的最终路径，否则会再追加一次。
    static let forbiddenPathSuffixes = ["/chat/completions", "/responses", "/messages"]

    var isEnabled = false
    /// API 基础地址（例如 https://api.example.com/v1），不是聊天网页地址。
    var baseURL = ""
    var model = ""
    /// 人物卡每块要覆盖十余个角色的多条事实，2048 只能容下约 10 条，容易漏人；
    /// 默认按每块 18 条事实留量，按量计费的接口（如 DeepSeek）可再调高到 8192。
    var maximumOutputTokens = 4_096
    var tokenParameter: TokenParameter = .completion
    var requestsJSON = false
    /// 思考强度。为空表示不发送该参数：多数接口不认识它，乱发会被判 400。
    /// 旧配置缺这个键时按空处理。名称以 o 开头的 OpenAI 推理模型（如 o1、o3、o4-mini）
    /// 和 Gemini 使用 reasoning_effort；这不是单独的 thinking 开关。
    var reasoningEffort: ReasoningEffort? = nil
    var requestFormat: RequestFormat = .chatCompletions

    /// 思考强度。`off` 在对话补全里不是 effort 取值，而是兼容接口的 thinking 开关。
    enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, low, medium, high, max
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "关闭思考（最快）"
            case .low: "低"
            case .medium: "中"
            case .high: "高"
            case .max: "最高（最慢）"
            }
        }
        /// 对话补全的“关闭思考”用 thinking 参数，其余用 reasoning_effort。
        var sendsThinkingToggle: Bool { self == .off }
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, baseURL, model, maximumOutputTokens, tokenParameter, requestsJSON, reasoningEffort, requestFormat
    }

    init() {}
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        maximumOutputTokens = try container.decode(Int.self, forKey: .maximumOutputTokens)
        tokenParameter = try container.decode(TokenParameter.self, forKey: .tokenParameter)
        requestsJSON = try container.decode(Bool.self, forKey: .requestsJSON)
        reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        // 缺字段的旧配置继续走对话补全。显式写成未知值时解码失败，不能悄悄改协议。
        requestFormat = try container.decodeIfPresent(RequestFormat.self, forKey: .requestFormat) ?? .chatCompletions
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(maximumOutputTokens, forKey: .maximumOutputTokens)
        try container.encode(tokenParameter, forKey: .tokenParameter)
        try container.encode(requestsJSON, forKey: .requestsJSON)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        // 默认格式不写入，回顾和人物检查点的配置指纹与升级前保持一致。
        if requestFormat != .chatCompletions { try container.encode(requestFormat, forKey: .requestFormat) }
    }

    func endpoint() throws -> URL {
        let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 2_048, var parts = URLComponents(string: input),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ReadingAIError.invalidAddress
        }
        parts.scheme = "https"; parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard !Self.forbiddenPathSuffixes.contains(where: { parts.path.hasSuffix($0) }), let base = parts.url else {
            throw ReadingAIError.invalidAddress
        }
        return base.appendingPathComponent(requestFormat.pathComponent)
    }
    /// 换格式时丢掉该格式不能发送的选项，避免界面还显示一项实际上不会发出去的设置。
    mutating func applyFormatCompatibility() {
        if !requestFormat.allowsJSONMode { requestsJSON = false }
        if let effort = reasoningEffort, !requestFormat.allows(effort) { reasoningEffort = nil }
    }
    func validated() throws -> Self {
        _ = try endpoint()
        var value = self
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.model.isEmpty, value.model.utf8.count <= 200,
              !value.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (128...8_192).contains(maximumOutputTokens) else { throw ReadingAIError.invalidConfiguration }
        if value.requestsJSON, !value.requestFormat.allowsJSONMode { throw ReadingAIError.unsupportedParameter }
        if let effort = value.reasoningEffort, !value.requestFormat.allows(effort) { throw ReadingAIError.unsupportedParameter }
        return value
    }

    /// 设置页地址说明。调用方必须按纯文本显示：字符串字面量进 SwiftUI `Text` 会走 Markdown，示例 URL 会被点开。
    var addressFootnote: String {
        var text = "填写服务商提供的 API 基础地址，例如 https://api.example.com/v1；程序会追加 \(requestFormat.appendedPath)。示例只说明写法。更换地址或请求格式后，需为新的接口地址单独保存密钥。密钥仅存本机 Keychain，不参与 WebDAV 同步。"
        if requestFormat == .anthropicMessages {
            text += "官方 Messages 接口的基础地址一般是 https://api.anthropic.com/v1。"
        }
        return text
    }
    var compatibilityFootnote: String {
        switch requestFormat {
        case .chatCompletions:
            return "参数需由模型支持，不支持时会直接报错，所以默认不发送。DeepSeek 默认就是高强度思考：选“关闭思考”最快，“低”次之，而“中”在 DeepSeek 会被映射成“高”。OpenAI 名称以 o 开头的推理模型（例如 o1、o3、o4-mini）和 Gemini 使用 reasoning_effort。OpenAI 官方的 Chat Completions 不认单独的 thinking 开关；“关闭思考”发送的是部分兼容接口（如 DeepSeek）使用的 thinking 参数。调低能明显变快，但人物与情节判断会更粗。JSON 格式只约束返回格式，不能代替剧情与出处校验；单次输入上限为 128 KiB，输出 tokens 仍可能产生费用。"
        case .responses:
            return "输出上限固定用 max_output_tokens，不发送 max_completion_tokens 或 max_tokens。官方把可见正文和推理 token 一起算进这个上限，推理变长时正文会更早被截断。思考强度对应 reasoning.effort：低、中、高、最高分别发送 low、medium、high、max；“关闭思考”发送 none。有的模型不接受 none，会直接报错。这里没有单独的 thinking 开关。JSON 格式发送 text.format.type 为 json_object 的旧式 JSON 模式；较新模型更推荐自带 schema 的 json_schema，本应用不代填 schema。官方默认可能保存回复，本应用固定发送 store 为 false，避免把章节正文留在服务端。单次输入上限为 128 KiB，输出 tokens 仍可能产生费用。"
        case .anthropicMessages:
            return "输出上限固定用 max_tokens，没有另一套参数名。不少当前模型默认会思考，思考 token 计入 max_tokens，正文可能因此被截断。低、中、高、最高对应 output_config.effort 的 low、medium、high、max；没有 xhigh 这一档。“关闭思考”在不少模型上会返回 400，所以不能选，也不会发送 thinking 字段。JSON 格式需要官方的 json_schema，本应用没有可发送的 schema，因此不能打开；提示词仍可要求 JSON，回顾和人物卡会照常校验。请求使用 x-api-key 和 anthropic-version \(Self.anthropicAPIVersion)，不使用 Bearer。单次输入上限为 128 KiB，输出 tokens 仍可能产生费用。"
        }
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
    case disabled, unavailable, invalidAddress, invalidConfiguration, unsupportedParameter, missingKey, credentialStorage
    case inputLimit, responseLimit, invalidResponse, truncated, refused, transport, http(Int)
    var errorDescription: String? {
        switch self {
        case .disabled: "请先在 AI 阅读辅助设置中启用 AI。"
        case .unavailable: "当前环境未配置 AI 服务。"
        case .invalidAddress: "请输入 HTTPS API 基础地址；不要包含密钥、查询参数，也不要带上 /chat/completions、/responses 或 /messages。"
        case .invalidConfiguration: "请检查模型名称和输出上限（128–8192 tokens）。"
        case .unsupportedParameter: "当前请求格式不支持这项参数。Anthropic Messages 不能打开 JSON 格式，也不能选择“关闭思考”。"
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
