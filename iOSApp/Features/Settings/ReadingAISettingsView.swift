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
                Picker("请求格式", selection: requestFormat) {
                    ForEach(ReadingAIConfiguration.RequestFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                TextField("API 基础地址（HTTPS）", text: $draft.baseURL)
                    .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                TextField("模型名称", text: $draft.model)
                    .autocapitalization(.none).disableAutocorrection(true)
                SecureField("API 密钥（留空保留当前接口密钥）", text: $newKey)
                    .textContentType(.password).autocapitalization(.none).disableAutocorrection(true)
                if showsSavedKey { Text("已保存当前接口密钥").font(.caption).foregroundStyle(.secondary) }
            } header: { Text("模型接口") } footer: {
                // 字面量 `Text("…https://…")` 走 LocalizedStringKey 的 Markdown，裸 URL 会变成可点开的链接。
                // 示例地址只是占位，必须按纯文本显示。
                Text(verbatim: draft.addressFootnote)
            }
            Section {
                if draft.requestFormat == .chatCompletions {
                    Picker("输出上限参数", selection: $draft.tokenParameter) {
                        Text("max_completion_tokens").tag(ReadingAIConfiguration.TokenParameter.completion)
                        Text("max_tokens（兼容接口）").tag(ReadingAIConfiguration.TokenParameter.legacy)
                    }
                } else if let field = draft.requestFormat.fixedOutputField {
                    HStack {
                        Text("输出上限参数")
                        Spacer()
                        Text(field).foregroundStyle(.secondary)
                    }
                }
                Stepper("输出上限：\(draft.maximumOutputTokens) tokens", value: $draft.maximumOutputTokens, in: 128...8_192, step: 128)
                Toggle("请求 JSON 格式", isOn: $draft.requestsJSON)
                    .disabled(!draft.requestFormat.allowsJSONMode)
                Picker("思考强度", selection: $draft.reasoningEffort) {
                    Text("不发送").tag(ReadingAIConfiguration.ReasoningEffort?.none)
                    ForEach(draft.requestFormat.selectableEfforts) { effort in
                        Text(effort.title).tag(ReadingAIConfiguration.ReasoningEffort?.some(effort))
                    }
                }
            } header: { Text("模型兼容参数") } footer: {
                Text(verbatim: draft.compatibilityFootnote)
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

    /// 换格式时立刻清掉该格式不能发送的选项，避免保存时才报错。
    private var requestFormat: Binding<ReadingAIConfiguration.RequestFormat> {
        Binding(get: { draft.requestFormat }, set: { newValue in
            var copy = draft
            copy.requestFormat = newValue
            copy.applyFormatCompatibility()
            draft = copy
        })
    }
    /// 密钥按最终接口地址隔离。只改模型名称仍是同一个接口；改地址或请求格式则不是。
    private var showsSavedKey: Bool {
        guard store.hasSavedKey,
              let draftEndpoint = try? draft.endpoint().absoluteString,
              let savedEndpoint = try? store.configuration.endpoint().absoluteString else { return false }
        return draftEndpoint == savedEndpoint
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
