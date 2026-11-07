// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// 第三方 API 的端点在请求时读取：用户改设置后无需重建客户端。密钥经注入的存储读取，不进偏好文件。
struct OpenAISpeechEndpoint: Sendable, Equatable {
    let baseURL: URL
    let apiKey: String
    let model: String

    init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
    }
}

protocol OpenAIEndpointProviding: Sendable {
    /// 未配置（缺地址或密钥）时返回 nil，消费端据此报告"未配置"而不是发起请求。
    func currentEndpoint() -> OpenAISpeechEndpoint?
}

/// 闭包适配器：App 组装用设置存储与 Keychain 拼出当前端点，测试注入固定端点。
struct ClosureOpenAIEndpointProvider: OpenAIEndpointProviding {
    let provide: @Sendable () -> OpenAISpeechEndpoint?
    init(provide: @escaping @Sendable () -> OpenAISpeechEndpoint?) { self.provide = provide }
    func currentEndpoint() -> OpenAISpeechEndpoint? { provide() }
}

/// OpenAI 兼容 `/audio/speech` 客户端：整段返回音频、无句子时间轴，引擎按分段顺序播放。
/// 独立会话：不携带小说/论坛凭据或 Cookie，不使用磁盘缓存；失败向上传递，不静默换服务上传正文。
actor OpenAICompatibleSpeechClient: CloudSpeechSynthesizing {
    enum Failure: LocalizedError, CloudSpeechRetryableError, Equatable {
        var shouldRetry: Bool {
            switch self { case .timedOut, .unavailable: return true; default: return false }
        }
        case notConfigured, invalidEndpoint, invalidKey, invalidVoice, invalidText, tooLarge
        case rejected(status: Int), noAudio, timedOut, unavailable

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未配置第三方 API 服务地址或密钥。"
            case .invalidEndpoint: return "第三方 API 服务地址无效，请检查设置中的地址。"
            case .invalidKey: return "第三方 API 密钥无效或没有权限，请检查设置。"
            case .invalidVoice: return "此音色在该服务上不可用，请更换音色。"
            case .invalidText: return "这段正文无法交给该服务合成。"
            case .tooLarge: return "分段正文超出服务限制，请反馈该问题。"
            case .noAudio: return "服务未返回有效音频，请重试或改用本地朗读。"
            case .timedOut: return "第三方 API 合成超时，请重试或改用本地朗读。"
            case .unavailable: return "暂时无法连接第三方 API 服务，请检查网络或稍后重试。"
            case .rejected(let status): return "第三方 API 拒绝了朗读请求（HTTP \(status)），请检查服务状态。"
            }
        }
    }

    /// OpenAI 兼容接口的单次输入上限（字符）。
    static let maximumInputCharacters = 4_096
    private let endpointProvider: any OpenAIEndpointProviding
    private let session: URLSession

    init(endpointProvider: any OpenAIEndpointProviding, session: URLSession? = nil) {
        self.endpointProvider = endpointProvider
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: config)
        }
    }

    func voices() async throws -> [SpeechVoiceOption] { OpenAISpeechVoices.presets }

    func audio(text: String, voice: String, rate: Double) async throws -> Data {
        guard let endpoint = endpointProvider.currentEndpoint() else { throw Failure.notConfigured }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.invalidText }
        guard trimmed.count <= Self.maximumInputCharacters else { throw Failure.tooLarge }
        guard OpenAISpeechVoices.isValidVoice(voice) else { throw Failure.invalidVoice }
        // iOS 15 兼容：不用 URL.appending(path:)；补齐尾斜杠后按相对地址解析，避免丢掉 /v1 路径段。
        var base = endpoint.baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        guard let requestURL = URL(string: "audio/speech", relativeTo: URL(string: base)),
              requestURL.scheme?.lowercased() == "https" else {
            throw Failure.invalidEndpoint
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        // 语速 0–1 归一化映射到 0.5–2.0 倍，0.5 为该服务的默认速度；上限收敛到接口允许范围。
        let speed = min(2.0, max(0.25, rate * 2))
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": endpoint.model, "input": trimmed, "voice": voice,
            "response_format": "mp3", "speed": speed,
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw (error as NSError).code == NSURLErrorTimedOut ? Failure.timedOut : Failure.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        switch http.statusCode {
        case 200:
            guard !data.isEmpty else { throw Failure.noAudio }
            return data
        case 401, 403: throw Failure.invalidKey
        case 404: throw Failure.invalidEndpoint
        case 429: throw Failure.rejected(status: 429)
        case 400: throw Failure.invalidVoice
        default: throw http.statusCode >= 500 ? Failure.unavailable : Failure.rejected(status: http.statusCode)
        }
    }
}

/// 用户自备 API 密钥的 Keychain 存储：本设备可读（ThisDeviceOnly），不参与备份同步语义之外的定义。
/// 键值变更与删除都走 SecItemUpdate/SecItemDelete，不落偏好文件，也不写日志。
struct KeychainSpeechAPIKeyStore: SpeechAPIKeyStoring {
    let service: String
    init(service: String = "cc.novelia.speech.apiKey") { self.service = service }

    func readKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func writeKey(_ value: String?) {
        let trimmed = value.flatMap { Data($0.utf8) }
        guard let data = trimmed, !data.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "openai"]
    }
}
