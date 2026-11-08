import AVFoundation
import SwiftUI

/// 「我的 → 阅读体验 → 朗读」：编辑本机朗读默认偏好。
/// 与朗读面板共用 `SpeechSettingsStore`，不另建第二套状态；改动在下次打开阅读器或
/// 下一次朗读句子时生效，正在播放的句子不中途改变。
struct SpeechSettingsView: View {
    @Environment(\.speechHandoff) private var speechHandoff
    private let store: SpeechSettingsStore
    @State private var settings: SpeechSettings
    @State private var showsEdgeConsent = false

    init() {
        let store = SpeechSettingsStore()
        self.store = store
        let loaded = store.load()
        _settings = State(initialValue: loaded)
    }

    private var voices: [SpeechVoiceOption] {
        if settings.preferredEngine == .edge { return store.edgeVoices }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.contains(".eloquence.") && !$0.identifier.contains(".novelty.") }
            .map { SpeechVoiceOption(identifier: $0.identifier, name: $0.name, language: $0.language) }
    }

    private func voicePicker(controller: SpeechPlaybackController?) -> some View {
        SpeechVoicePicker(voices: voices, selection: voiceSelection,
                          isCloud: settings.preferredEngine == .edge,
                          engineKind: settings.preferredEngine, rate: settings.rate, volume: settings.volume, pitch: settings.pitch,
                          previewController: controller)
            .id(settings.preferredEngine)
    }

    var body: some View {
        Form {
            Section("朗读引擎") {
                Picker("朗读引擎", selection: engineSelection) {
                    Text("本地朗读（自动）").tag(SpeechEngineKind.system)
                    Text("Edge 在线朗读").tag(SpeechEngineKind.edge)
                }
                Text("默认使用本地朗读。切换在下次打开阅读器或非播放状态下重开朗读面板时生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.preferredEngine == .edge {
                    Text("当前分段正文将发送给微软合成语音。此消费端服务可能变化或不可用，可切回本地朗读。音频仅在当前会话内缓存，停止后清除；不写入文件、不参与同步。Edge 根据服务返回的句子时间轴跟读，不提供逐词定位。")
                        .font(.caption).foregroundStyle(.secondary)
                }

            }
            Section("语音") {
                if let speechHandoff {
                    SpeechObservedContent(object: speechHandoff) { store in voicePicker(controller: store.session) }
                } else { voicePicker(controller: nil) }
                Text(settings.preferredEngine == .edge ? "Edge 使用在线自然语音；音色和语速从下一段起生效。"
                     : "本地引擎使用设备上的系统语音，从下一句起生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("语速") {
                SpeechRateControls(settings: Binding(get: { settings }, set: { settings = $0; save() }), engineKind: settings.preferredEngine)
                if settings.preferredEngine == .system { Text("Readium 本地朗读暂不提供语速接口。").font(.caption).foregroundStyle(.secondary) }
            }

            Section("声音") {
                SpeechSoundControls(settings: Binding(get: { settings }, set: { settings = $0; save() }),
                                    cloud: settings.preferredEngine == .edge)
            }
            Section("跟读") {
                    Toggle("高亮当前朗读句", isOn: binding(\.highlightsSpokenText))
                    Toggle("自动翻到朗读位置", isOn: binding(\.followsReadingPosition))
                    Text("本地与 Edge 均已接通当前句高亮和跟读；手动翻页或拖动正文只挂起跟读，朗读继续。")
                        .font(.caption).foregroundStyle(.secondary)
            }
            if settings.preferredEngine == .edge {
                Section("连续播放") {
                    Toggle("提前准备下一段", isOn: binding(\.edgePrefetchEnabled))
                    Text("开启后会提前发送同章下一分段正文给微软，减少段间等待。默认关闭，停止时清除缓存。")
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
                Text("已开启后台音频。锁屏与耳机可播放／暂停、切换朗读片段；来电等音频中断或拔掉耳机时自动暂停。退出阅读器后，各引擎均可通过底部迷你条继续播放，在更多操作中停止。")
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
        Binding(get: { settings.preferredEngine == .edge ? settings.preferredEngine : .system },
                set: { value in
            if value == .edge && !store.edgeConsentGranted { showsEdgeConsent = true }
            else {
                settings.preferredEngine = value; save()
            }
        })
    }

    private var voiceSelection: Binding<String> {
        Binding(
            get: {
                switch settings.preferredEngine {
                case .edge: settings.edgeVoiceIdentifier
                default: settings.voiceIdentifier ?? ""
                }
            },
            set: { newValue in
                switch settings.preferredEngine {
                case .edge: settings.edgeVoiceIdentifier = newValue
                default: settings.voiceIdentifier = newValue.isEmpty ? nil : newValue
                }
                save()
            }
        )
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
