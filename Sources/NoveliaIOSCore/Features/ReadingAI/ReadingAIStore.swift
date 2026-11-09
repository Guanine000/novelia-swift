// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// AppServices 持有的唯一 AI 入口。只保存配置，密钥通过注入能力访问；不保存正文或生成历史。
/// 配置变化或删除密钥时取消进行中任务，旧请求不得把迟到结果交给新会话。
@MainActor
final class ReadingAIStore: ObservableObject {
    @Published private(set) var configuration: ReadingAIConfiguration
    @Published private(set) var hasSavedKey = false
    /// 当前请求已收到的正文字数；长时间生成时界面据此显示实时进度，请求结束或取消后归零。
    @Published private(set) var streamedCharacters = 0
    /// 当前请求已收到的正文末尾片段，供"AI 运行记录"实时预览。
    @Published private(set) var streamedPreview = ""
    private let defaults: UserDefaults
    private let keys: any ReadingAIKeyStoring
    private let client: any ReadingAICompleting
    private static let storageKey = "reader.ai.configuration.v1"
    private var revision = UUID()
    private var tasks: [UUID: Task<ReadingAIResponse, Error>] = [:]

    init(defaults: UserDefaults, keys: any ReadingAIKeyStoring, client: any ReadingAICompleting) {
        self.defaults = defaults; self.keys = keys; self.client = client
        let loaded = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(ReadingAIConfiguration.self, from: $0) } ?? .init()
        configuration = (try? loaded.validated()) ?? .init()
        refreshKeyStatus()
    }
    /// 自动阅读提示只在接口、模型和凭据均可用时出现，不因仅打开开关而打扰阅读。
    var isReadyForGeneration: Bool {
        configuration.isEnabled && hasSavedKey && (try? configuration.validated()) != nil
    }
    func refreshKeyStatus() {
        hasSavedKey = (try? configuration.endpoint().absoluteString).flatMap { try? keys.read(scope: $0) }.map { !$0.isEmpty } ?? false
    }
    func save(_ value: ReadingAIConfiguration, newKey: String) throws {
        var value = value
        // 全空且关闭时可保存初始状态；已配置的地址始终校验，不能把密钥藏进 URL 参数。
        if value.isEnabled || !value.baseURL.isEmpty || !value.model.isEmpty { value = try value.validated() }
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard key.utf8.count <= 8_192,
                  !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                throw ReadingAIError.missingKey
            }
        }
        let scope = try? value.endpoint().absoluteString
        if value.isEnabled, key.isEmpty {
            guard let scope, try keys.read(scope: scope) != nil else { throw ReadingAIError.missingKey }
        }
        let encoded = try JSONEncoder().encode(value)
        if !key.isEmpty {
            guard let scope else { throw ReadingAIError.invalidAddress }
            try keys.write(key, scope: scope)
        }
        cancelRunning()
        defaults.set(encoded, forKey: Self.storageKey)
        configuration = value; refreshKeyStatus()
    }
    func deleteCurrentKey() throws {
        let scope = try configuration.endpoint().absoluteString
        try keys.write(nil, scope: scope)
        cancelRunning()
        configuration.isEnabled = false
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.storageKey) }
        refreshKeyStatus()
    }
    private func cancelRunning() {
        revision = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
    func generate(_ request: ReadingAIRequest) async throws -> ReadingAIResponse {
        guard configuration.isEnabled else { throw ReadingAIError.disabled }
        return try await perform(request)
    }
    /// 固定短句测试可在 AI 开关关闭时运行；不读取书籍、历史或当前页面。
    func testConnection() async throws -> ReadingAIResponse {
        let request = configuration.requestsJSON
            ? ReadingAIRequest(instruction: "Reply with exactly this JSON object: {\"status\":\"OK\"}.", input: "Connection test.")
            : .connectionTest
        return try await perform(request)
    }

    private func perform(_ request: ReadingAIRequest) async throws -> ReadingAIResponse {
        try Task.checkCancellation()
        let config = try configuration.validated()
        try request.validate()
        guard let key = try keys.read(scope: config.endpoint().absoluteString), !key.isEmpty else { throw ReadingAIError.missingKey }
        let id = UUID(), snapshot = revision, client = client
        streamedCharacters = 0; streamedPreview = ""
        let task = Task {
            try await client.complete(configuration: config, apiKey: key, request: request) { received, tail in
                // 客户端在后台线程回调，回到主线程只写计数和末尾片段，避免高频刷新拖慢生成。
                Task { @MainActor [weak self] in
                    guard let self, self.revision == snapshot else { return }
                    self.streamedCharacters = max(self.streamedCharacters, received)
                    self.streamedPreview = tail
                }
            }
        }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard revision == snapshot else { throw CancellationError() }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as ReadingAIError { throw error }
        catch { throw ReadingAIError.transport }
    }
}

/// 替代组装专用的实例内凭据；每个 AppServices 创建独立对象，不读写生产 Keychain。
@MainActor
final class MemoryReadingAIKeys: ReadingAIKeyStoring {
    private var values: [String: String] = [:]
    func read(scope: String) throws -> String? { values[scope] }
    func write(_ key: String?, scope: String) throws { values[scope] = key }
}
