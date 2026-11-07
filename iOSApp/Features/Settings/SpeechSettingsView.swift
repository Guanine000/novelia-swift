import AVFoundation
import SwiftUI

/// 「我的 → 阅读体验 → 朗读」：编辑本机朗读默认偏好。
/// 与朗读面板共用 `SpeechSettingsStore`，不另建第二套状态；改动在下次打开阅读器或
/// 下一次朗读句子时生效，正在播放的句子不中途改变。
struct SpeechSettingsView: View {
    private let store: SpeechSettingsStore
    /// 第三方 API 密钥只存 Keychain；其余配置仍走同一偏好存储。
    private let keyStore = KeychainSpeechAPIKeyStore()
    @State private var settings: SpeechSettings
    @State private var showsEdgeConsent = false
    // 第三方配置用独立草稿：提交时才收敛保存，避免输入中途被 URL 归一化清空。
    @State private var endpointDraft: String
    @State private var modelDraft: String
    @State private var voiceDraft: String
    @State private var keyDraft: String

    init() {
        let store = SpeechSettingsStore()
        self.store = store
        let loaded = store.load()
        _settings = State(initialValue: loaded)
        _endpointDraft = State(initialValue: loaded.openAIBaseURL)
        _modelDraft = State(initialValue: loaded.openAIModel)
        _voiceDraft = State(initialValue: loaded.openAIVoice)
        _keyDraft = State(initialValue: KeychainSpeechAPIKeyStore().readKey() ?? "")
    }

    private var voices: [SpeechVoiceOption] {
        if settings.preferredEngine == .edge { return store.edgeVoices }
        if settings.preferredEngine == .openai { return OpenAISpeechVoices.options(selected: settings.openAIVoice) }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.contains(".eloquence.") && !$0.identifier.contains(".novelty.") }
            .map { SpeechVoiceOption(identifier: $0.identifier, name: $0.name, language: $0.language) }
    }

    var body: some View {
        Form {
            Section("朗读引擎") {
                Picker("朗读引擎", selection: engineSelection) {
                    Text("本地朗读（自动）").tag(SpeechEngineKind.system)
                    Text("Edge 在线朗读").tag(SpeechEngineKind.edge)
                    Text("第三方 API").tag(SpeechEngineKind.openai)
                }
                Text("默认使用本地朗读。切换在下次打开阅读器或非播放状态下重开朗读面板时生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.preferredEngine == .edge {
                    Text("当前分段正文将发送给微软合成语音。此消费端服务可能变化或不可用，可切回本地朗读。音频仅在当前会话内缓存，停止后清除；不写入文件、不参与同步。Edge 根据服务返回的句子时间轴跟读，不提供逐词定位。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.preferredEngine == .openai {
                    Text("朗读正文分段发送给你自备的 OpenAI 兼容服务合成语音，无句子时间轴，按分段跳转；密钥与地址由你自行管理，音频仅在当前会话内缓存，停止后清除。未填写地址或密钥时自动回落本地朗读。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("语音") {
                SpeechVoicePicker(voices: voices, selection: voiceSelection,
                                  isCloud: settings.preferredEngine == .edge || settings.preferredEngine == .openai,
                                  engineKind: settings.preferredEngine, rate: settings.rate, volume: settings.volume, pitch: settings.pitch)
                    .id(settings.preferredEngine)
                Text(settings.preferredEngine == .edge ? "Edge 使用在线自然语音；音色和语速从下一段起生效。"
                     : settings.preferredEngine == .openai ? "第三方服务使用其模型音色；音色和语速从下一段起生效。"
                     : "本地引擎使用设备上的系统语音，从下一句起生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.preferredEngine == .openai {
                Section("第三方 API") {
                    TextField("服务地址（https://…/v1）", text: $endpointDraft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveThirdParty)
                    TextField("模型（如 tts-1）", text: $modelDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveThirdParty)
                    TextField("音色（如 alloy；预设 alloy/echo/fable/onyx/nova/shimmer）", text: $voiceDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveThirdParty)
                    SecureField("API 密钥", text: $keyDraft)
                        .onSubmit(saveThirdParty)
                    Button("保存第三方配置") { saveThirdParty() }
                    Text("地址需为 HTTPS 且以 /v1 之类接口根结尾，请求发往「地址 + /audio/speech」。密钥保存在本机 Keychain，不参与同步、不写入日志；正文分段会发送给该服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("语速") {
                Slider(value: binding(\.rate), in: 0...1, step: 0.05)
                Text(settings.preferredEngine == .edge ? "0.5 为 Edge 默认语速，从下一段起生效。" : "0.5 为系统默认语速。系统 TTS 支持；Readium 官方合成器暂不提供语速接口。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("声音") {
                SpeechSoundControls(settings: Binding(get: { settings }, set: { settings = $0; save() }),
                                    cloud: settings.preferredEngine == .edge)
            }
            Section("跟读") {
                    Toggle("高亮当前朗读句", isOn: binding(\.highlightsSpokenText))
                    Toggle("自动翻到朗读位置", isOn: binding(\.followsReadingPosition))
                    Text("本地与 Edge 均已接通当前句高亮和跟读；手动翻页或拖动正文会暂停朗读。")
                        .font(.caption).foregroundStyle(.secondary)
            }
            if settings.preferredEngine == .edge || settings.preferredEngine == .openai {
                Section("连续播放") {
                    Toggle("提前准备下一段", isOn: binding(\.edgePrefetchEnabled))
                    Text(settings.preferredEngine == .edge
                         ? "开启后会提前发送同章下一分段正文给微软，减少段间等待。默认关闭，停止时清除缓存。"
                         : "开启后会提前请求同章下一段音频，减少段间等待。默认关闭，停止时清除缓存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("定时停止") {
                Picker("定时停止", selection: binding(\.sleepTimerMinutes)) {
                    ForEach(SpeechSettings.sleepTimerOptions, id: \.self) { minutes in
                        Text(SpeechSettings.sleepTimerTitle(minutes: minutes)).tag(minutes)
                    }
                }
                Text("从每次起播开始计时，到时自动停止；暂停期间仍继续计时。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("后台播放") {
                Text("已开启后台音频。锁屏与耳机可播放／暂停、切换朗读片段；来电等音频中断或拔掉耳机时自动暂停。退出阅读器后仍在底部迷你条继续播放，点按可停止；Readium 官方引擎绑定阅读页面，离开即停止。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("以上朗读设置只保存在本机，不参与 WebDAV 同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("恢复默认设置") {
                    settings = .default
                    store.reset()
                }
            }
        }
        .alert("启用 Edge 在线朗读？", isPresented: $showsEdgeConsent) {
            Button("取消", role: .cancel) {}
            Button("同意并启用") {
                store.setEdgeConsent(true)
                settings.preferredEngine = .edge
                save()
            }
        } message: {
            Text("朗读时会把当前分段正文发送给微软服务。语音需要联网，音频只在本次会话内缓存，停止后清除。是否同意并启用？")
        }
        .navigationTitle("朗读")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var engineSelection: Binding<SpeechEngineKind> {
        Binding(get: { settings.preferredEngine == .edge || settings.preferredEngine == .openai ? settings.preferredEngine : .system },
                set: { value in
            if value == .edge && !store.edgeConsentGranted { showsEdgeConsent = true }
            else {
                if settings.preferredEngine == .openai && value != .openai { saveThirdParty() }
                settings.preferredEngine = value; save()
            }
        })
    }

    private var voiceSelection: Binding<String> {
        Binding(
            get: {
                switch settings.preferredEngine {
                case .edge: settings.edgeVoiceIdentifier
                case .openai: settings.openAIVoice
                default: settings.voiceIdentifier ?? ""
                }
            },
            set: { newValue in
                switch settings.preferredEngine {
                case .edge: settings.edgeVoiceIdentifier = newValue
                case .openai: settings.openAIVoice = newValue
                default: settings.voiceIdentifier = newValue.isEmpty ? nil : newValue
                }
                save()
            }
        )
    }

    /// 提交第三方配置：先保存地址/模型/音色与密钥，再核对是否已可直接使用。
    private func saveThirdParty() {
        settings.openAIBaseURL = endpointDraft
        settings.openAIModel = modelDraft
        settings.openAIVoice = voiceDraft
        save()
        keyStore.writeKey(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : keyDraft)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SpeechSettings, T>) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                save()
            }
        )
    }

    private func save() {
        let value = settings.clamped()
        settings = value
        store.save(value)
    }
}
