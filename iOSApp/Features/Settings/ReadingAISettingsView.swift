// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 页面只编辑配置和发起固定连接测试；不接触网络客户端或读取密钥明文。
@MainActor
struct ReadingAISettingsView: View {
    @ObservedObject var store: ReadingAIStore
    @State private var draft = ReadingAIConfiguration()
    @State private var newKey = ""
    @State private var message: String?
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var testID = UUID()

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 阅读辅助", isOn: $draft.isEnabled)
            } footer: {
                Text("配置 AI 前情回顾等阅读辅助功能的服务。只有主动生成才发送所选正文，启用不会自动上传书籍。")
            }
            Section {
                TextField("API 基础地址（HTTPS）", text: $draft.baseURL)
                    .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                TextField("模型名称", text: $draft.model)
                    .autocapitalization(.none).disableAutocorrection(true)
                SecureField("API 密钥（留空保留当前接口密钥）", text: $newKey)
                    .textContentType(.password).autocapitalization(.none).disableAutocorrection(true)
                if store.hasSavedKey, draft.baseURL == store.configuration.baseURL { Text("已保存当前接口密钥").font(.caption).foregroundStyle(.secondary) }
            } header: { Text("OpenAI 兼容接口") } footer: {
                Text("填写服务商提供的 API 基础地址，例如 https://api.example.com/v1；程序会追加 /chat/completions。更换地址后需为新接口单独保存密钥。密钥仅存本机 Keychain，不参与 WebDAV 同步。")
            }
            Section {
                Picker("输出上限参数", selection: $draft.tokenParameter) {
                    Text("max_completion_tokens").tag(ReadingAIConfiguration.TokenParameter.completion)
                    Text("max_tokens（兼容接口）").tag(ReadingAIConfiguration.TokenParameter.legacy)
                }
                Stepper("输出上限：\(draft.maximumOutputTokens) tokens", value: $draft.maximumOutputTokens, in: 128...8_192, step: 128)
                Toggle("请求 JSON 格式", isOn: $draft.requestsJSON)
                Picker("思考强度", selection: $draft.reasoningEffort) {
                    Text("不发送").tag(ReadingAIConfiguration.ReasoningEffort?.none)
                    ForEach(ReadingAIConfiguration.ReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(ReadingAIConfiguration.ReasoningEffort?.some(effort))
                    }
                }
            } header: { Text("模型兼容参数") } footer: {
                Text("参数需由模型支持，不支持时会直接报错，所以默认不发送。DeepSeek 默认就是高强度思考：选“关闭思考”最快，“低”次之，而“中”在 DeepSeek 会被映射成“高”。o 系列与 Gemini 认 reasoning_effort；OpenAI 官方不认 thinking 开关。调低能明显变快，但人物与情节判断会更粗。JSON 格式只约束返回格式，不能代替剧情与出处校验；单次输入上限为 128 KiB，输出 tokens 仍可能产生费用。")
            }
            Section {
                Button("保存配置") { save() }
                if isTesting {
                    HStack { ProgressView(); Text("正在测试…"); Spacer(); Button("取消") { cancelTest() } }
                } else {
                    Button("测试已保存配置") { test() }
                        .disabled(draft != store.configuration || !newKey.isEmpty)
                }
                if let message { Text(message).font(.footnote).textSelection(.enabled) }
            } footer: {
                Text("连接测试只发送固定英文短句，不发送小说正文，服务商可能收取少量费用。修改配置后请先保存。")
            }
            if store.hasSavedKey {
                Section {
                    Button("删除当前接口密钥并关闭 AI", role: .destructive) {
                        cancelTest()
                        do { try store.deleteCurrentKey(); draft = store.configuration; newKey = ""; message = "已删除当前接口密钥。" }
                        catch { message = ReadingAIError.credentialStorage.localizedDescription }
                    }
                }
            }
        }
        .navigationTitle("AI 阅读辅助")
        .onAppear { draft = store.configuration; store.refreshKeyStatus() }
        .onDisappear { cancelTest(); newKey = "" }
        .onValueChange(of: draft) { _, _ in cancelTest(); message = nil }
        .onValueChange(of: newKey) { _, _ in cancelTest(); message = nil }
    }

    private func save() {
        cancelTest()
        do { try store.save(draft, newKey: newKey); draft = store.configuration; newKey = ""; message = "配置已保存。" }
        catch let error as ReadingAIError { message = error.localizedDescription }
        catch { message = ReadingAIError.credentialStorage.localizedDescription }
    }
    private func cancelTest() {
        testID = UUID(); testTask?.cancel(); testTask = nil; isTesting = false
    }
    private func test() {
        cancelTest(); message = nil; isTesting = true
        let id = testID
        testTask = Task {
            do {
                let result = try await store.testConnection()
                guard !Task.isCancelled, testID == id else { return }
                let plainOK = result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
                let json = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: String]
                let ok = store.configuration.requestsJSON ? json?["status"] == "OK" : plainOK
                message = ok ? "连接成功，模型已返回预期测试结果。" : "接口已返回文本，但未按测试要求回复；请检查模型兼容性。"
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, testID == id else { return }
                message = (error as? ReadingAIError ?? .transport).localizedDescription
            }
            if testID == id { isTesting = false; testTask = nil }
        }
    }
}
