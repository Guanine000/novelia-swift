import AVFoundation
import Foundation
import SwiftUI
import UIKit

// MARK: - 朗读面板

/// 与引擎无关的播放控件：能力位决定显示哪些设置，云端引擎接入后无需改动本视图。
struct SpeechControlView: View {
    @ObservedObject var controller: SpeechPlaybackController
    @ObservedObject var session: SpeechRemoteSession
    let anchor: SpeechAnchor
    var title = "Novelia 朗读"
    var onEngineChange: (() -> Void)? = nil
    var onStart: (() -> Void)? = nil
    /// 从上次收听位置继续：由宿主阅读器负责跳章并起播。
    var onResumeSaved: ((SpeechResumePoint) -> Void)? = nil
    var onReturnToBook: (() -> Void)? = nil
    var settingsOnly = false
    @State private var showsSettings = false
    @State private var showsEdgeConsent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if settingsOnly { settingsContent }
                else { playerContent }
            }
            .navigationTitle(settingsOnly ? "朗读设置" : "听书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settingsOnly ? "完成" : "关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !settingsOnly {
                        Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("朗读设置")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showsSettings) {
            SpeechControlView(controller: controller, session: session, anchor: anchor,
                              title: title, onEngineChange: onEngineChange, onStart: onStart,
                              onResumeSaved: onResumeSaved, onReturnToBook: onReturnToBook, settingsOnly: true)
        }
        .alert("启用 Edge 在线朗读？", isPresented: $showsEdgeConsent) {
            Button("取消", role: .cancel) {}
            Button("同意并启用") {
                controller.changeEngine(to: .edge, grantConsent: true)
                onEngineChange?()
            }
        } message: {
            Text("朗读时会把当前分段正文发送给微软服务。需要联网，音频只在本次会话内缓存，停止后清除。是否同意并启用？")
        }

    }

    private var playerContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed.fill")
                        .font(.title2).foregroundStyle(NoveliaStyle.brandGreen)
                        .frame(width: 52, height: 64)
                        .background(NoveliaStyle.brandGreen.opacity(0.1), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline).lineLimit(2)
                        Text(controller.chapterTitle).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("tts-current-chapter")
                        Text(controller.engineTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.currentSentence.isEmpty ? "从当前阅读位置开始，或继续上次收听。" : controller.currentSentence)
                        .font(.body).lineLimit(5).frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                        .accessibilityIdentifier("tts-current-sentence")
                    Text(statusText).font(.footnote).foregroundStyle(.secondary)
                    ProgressView(value: controller.chapterProgression)
                        .accessibilityLabel("本章朗读位置")
                        .accessibilityValue("\(Int(controller.chapterProgression * 100))%")
                    Text("本章文字位置 \(Int(controller.chapterProgression * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding().background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
                HStack(spacing: 28) {
                    Button { controller.skipBackward() } label: { Image(systemName: "backward.fill").font(.title2).frame(width: 48, height: 48) }
                        .accessibilityLabel(controller.skipBackwardLabel).disabled(controller.state.utterance == nil)
                    Button { toggle() } label: {
                        Group {
                            if controller.state == .preparing { ProgressView().tint(.white) }
                            else { Image(systemName: controller.state.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle) }
                        }
                        .frame(width: 72, height: 72).foregroundStyle(.white)
                        .background(NoveliaStyle.brandGreen, in: Circle())
                    }
                    .accessibilityLabel(controller.state.isPlaying ? "暂停朗读" : "播放朗读")
                    .disabled(controller.state == .preparing || !controller.isAvailable)
                    Button { controller.skipForward() } label: { Image(systemName: "forward.fill").font(.title2).frame(width: 48, height: 48) }
                        .accessibilityLabel(controller.skipForwardLabel).disabled(controller.state.utterance == nil)
                }
                .buttonStyle(.plain)
                if controller.capabilities.contains(.chapterNavigation) {
                    HStack {
                        Button("上一章") { controller.skipChapter(-1) }.frame(minHeight: 44)
                        Spacer()
                        Button("下一章") { controller.skipChapter(1) }.frame(minHeight: 44)
                    }.disabled(!controller.isActive)
                }
                SpeechFollowStatus(controller: controller)
                if case .failed = controller.state {
                    VStack(spacing: 8) {
                        Button("重试本段") { controller.retry() }.frame(minHeight: 44)
                        if controller.isCloud, let onEngineChange {
                            Button("切回本地继续") { controller.changeEngine(to: .system); onEngineChange() }.frame(minHeight: 44)
                        } else if let onReturnToBook {
                            Button("回到书内调整引擎") { dismiss(); onReturnToBook() }.frame(minHeight: 44)
                        }
                    }
                }
                if controller.state == .preparing {
                    Button("取消准备") { controller.stop() }.frame(minHeight: 44)
                }
                if let saved = controller.savedResume, let resume = onResumeSaved {
                    Button("继续上次收听（第 \(saved.chapterIndex + 1) 章）") { resume(saved) }
                        .frame(minHeight: 44).disabled(controller.isActive)
                }
                if controller.capabilities.contains(.rateControl) {
                    SpeechRateControls(settings: $controller.settings, engineKind: controller.engineKind)
                }
                Button { showsSettings = true } label: {
                    HStack {
                        Label("定时停止", systemImage: "moon.zzz")
                        Spacer()
                        Text(session.remaining.map { "剩余 " + durationText($0) }
                             ?? SpeechSettings.sleepTimerTitle(minutes: controller.settings.sleepTimerMinutes))
                    }.frame(minHeight: 44)
                }
                if controller.state != .idle {
                    Button("停止朗读", role: .destructive) { controller.stop() }.frame(minHeight: 44)
                }
            }.padding()
        }.background(NoveliaStyle.paper)
    }

    private var settingsContent: some View {
        Form {
                if let onEngineChange {
                    Section("朗读引擎") {
                        Picker("切换引擎", selection: Binding(
                            get: { controller.isCloud ? SpeechEngineKind.edge : .system },
                            set: { kind in
                                if kind == .edge && !controller.edgeConsentGranted { showsEdgeConsent = true }
                                else { controller.changeEngine(to: kind); onEngineChange() }
                            })) {
                            Text("本地朗读").tag(SpeechEngineKind.system)
                            Text("Edge 在线朗读").tag(SpeechEngineKind.edge)
                        }
                        Text("当前引擎：\(controller.engineTitle)").font(.caption).foregroundStyle(.secondary)
                        Text("切换保留当前收听句；正在播放会接着听，暂停状态仍保持暂停。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if controller.isCloud {
                    Section("Edge 在线朗读") {
                        Toggle("提前准备下一段", isOn: $controller.settings.edgePrefetchEnabled)
                        Text("开启后会提前发送同章下一段正文给微软，减少段间等待。上一句／下一句按时间轴跳转；无时间轴时按段切换。音频只在本次会话内缓存，停止后清除。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if controller.capabilities.contains(.readingFollow) {
                    Section("跟读") {
                        Toggle("高亮当前朗读句", isOn: $controller.settings.highlightsSpokenText)
                        Toggle("自动翻到朗读位置", isOn: $controller.settings.followsReadingPosition)
                    }
                }

                if controller.capabilities.contains(.voiceSelection), !controller.availableVoices.isEmpty {
                    Section(controller.isCloud ? "Edge 音色" : "设备语音") {
                        SpeechVoicePicker(voices: controller.availableVoices,
                                          selection: Binding(get: { controller.selectedVoiceIdentifier ?? "" },
                                                             set: { controller.selectVoice($0) }),
                                          isCloud: controller.isCloud, engineKind: controller.engineKind, rate: controller.settings.rate, volume: controller.settings.volume, pitch: controller.settings.pitch,
                                          previewController: controller)
                            .id(controller.engineKind)
                    }
                }

                if controller.capabilities.contains(.rateControl) {
                    Section("语速") { SpeechRateControls(settings: $controller.settings, engineKind: controller.engineKind) }
                }

                if controller.capabilities.contains(.volumeControl) || controller.capabilities.contains(.pitchControl) {
                    Section("声音") {
                        SpeechSoundControls(settings: $controller.settings, cloud: controller.isCloud)
                    }
                } else if controller.engineKind == .readium {
                    Text("Readium 本地朗读暂不支持独立音量和音高；系统与 Edge 支持这两项。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("定时停止") {
                    Picker("定时停止", selection: $controller.settings.sleepTimerMinutes) {
                        ForEach(SpeechSettings.sleepTimerOptions, id: \.self) { minutes in
                            Text(SpeechSettings.sleepTimerTitle(minutes: minutes)).tag(minutes)
                        }
                    }
                    if let remaining = session.remaining {
                        Text("剩余 \(durationText(remaining))").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("从起播开始按分钟计时，到时自动停止；暂停期间仍继续计时。设置会保存在本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if controller.capabilities.contains(.backgroundAudio) {
                    Section("后台播放") {
                        Text("锁屏与耳机可播放／暂停、切换朗读片段；来电等音频中断会自动暂停，拔掉耳机也会暂停。退出阅读器后可通过迷你条继续听，明确停止或定时到期后结束。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !controller.isAvailable {
                    Section {
                        Text("当前书籍暂不支持朗读，可改用其他阅读引擎。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
        }
    }

    private func toggle() {
        switch controller.state {
        case .playing: controller.pause()
        case .paused: controller.resume()
        case .preparing: break
        case .failed: controller.retry()
        default: if let onStart { onStart() } else { controller.start(from: anchor) }
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var statusText: String {
        switch controller.state {
        case .idle: return "点按播放，从当前页开始朗读；关闭面板后仍可继续收听"
        case .preparing: return controller.preparationMessage
        case .playing: return "正在朗读"
        case .paused: return "已暂停"
        case .finished: return "朗读结束"
        case let .failed(message): return message
        }
    }
}

/// 底部听书条：朗读期间覆盖在阅读区底部，替代悬浮控件；中间文字区点按打开朗读面板。
/// 与引擎无关，经 `ReaderSpeechPresentation` 挂在各阅读器上，不持有第二套播放器。
struct ReaderSpeechBar: View {
    @ObservedObject var controller: SpeechPlaybackController
    let openPanel: () -> Void
    /// 迷你条（阅读器之外）用「回到书内」替代「回到朗读处」：定位需要回到书里才有效。
    var onReturnToBook: (() -> Void)? = nil
    var body: some View {
        if controller.showsQuickControls {
            HStack(spacing: 4) {
                Button(action: openPanel) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.bookTitle).font(NoveliaStyle.fontBody).lineLimit(1)
                        Text(controller.followSuspended && controller.state.isPlaying ? "正在朗读 · 跟读已暂停" : statusLine)
                            .font(NoveliaStyle.fontFootnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("打开听书面板")
                    .accessibilityValue(controller.bookTitle + "，" + statusLine)
                if onReturnToBook == nil {
                    barButton("backward.fill", label: controller.skipBackwardLabel, enabled: controller.state.utterance != nil) { controller.skipBackward() }
                }
                barButton(controller.state.isPlaying ? "pause.fill" : "play.fill",
                          label: controller.state.isPlaying ? "快捷暂停朗读" : "快捷继续朗读",
                          enabled: controller.state != .preparing) { controller.playOrPause() }
                if onReturnToBook == nil {
                    barButton("forward.fill", label: controller.skipForwardLabel, enabled: controller.state.utterance != nil) { controller.skipForward() }
                }
                if let onReturnToBook {
                    barButton("book", label: "回到书内朗读处", action: onReturnToBook)
                } else if controller.onJumpToSpoken != nil {
                    barButton("text.magnifyingglass", label: "回到正在朗读的段落") { controller.returnToSpoken() }
                }
                Menu {
                    Button("打开听书面板", action: openPanel)
                    if controller.capabilities.contains(.chapterNavigation) {
                        Button("上一章") { controller.skipChapter(-1) }
                        Button("下一章") { controller.skipChapter(1) }
                    }
                    if controller.followSuspended, controller.settings.followsReadingPosition {
                        Button("恢复跟读") { controller.resumeFollowing() }
                    }
                    Button("停止朗读", role: .destructive) { controller.stop() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("更多朗读操作")
            }
            .buttonStyle(.borderless).foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
        }
    }
    private func barButton(_ icon: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel(label).disabled(!enabled)
    }

    private var statusLine: String {
        switch controller.state {
        case .idle: return "朗读已停止"
        case .preparing: return controller.preparationMessage
        case .playing(let utterance): return "正在朗读：\(utterance.text.prefix(28))"
        case .paused: return "已暂停"
        case .finished: return "朗读结束"
        case .failed(let message): return message
        }
    }
}

/// 根视图的跨页听书条：阅读器退出后接管的会话在这里显示；点中间文字区打开完整面板。
/// 会话停止（含定时到期）后自动消失；进入阅读器会回收遗留会话，因此阅读中不会出现。
struct SpeechMiniBarHost: View {
    @ObservedObject var store: SpeechHandoffStore
    @State private var showsPanel = false
    var body: some View {
        if let controller = store.session {
            ReaderSpeechBar(controller: controller,
                            openPanel: { showsPanel = true },
                            onReturnToBook: { store.requestOpen() })
                .onReceive(controller.$state) { state in
                    if state == .idle { store.clearIfSame(controller) }
                }
                .sheet(isPresented: $showsPanel) {
                    SpeechControlView(controller: controller, session: controller.session,
                                      anchor: SpeechAnchor(chapterIndex: 0, progression: 0,
                                                           chapterUTF16Length: 0, startIndexHint: nil),
                                      title: controller.bookTitle, onEngineChange: nil,
                                      onStart: { controller.play() }, onReturnToBook: { store.requestOpen() })
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 可选朗读会话也必须直接观察，不能依赖外层设置对象转发内部变化。
struct SpeechObservedContent<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    let content: (Object) -> Content
    var body: some View { content(object) }
}

struct SpeechFollowStatus: View {
    @ObservedObject var controller: SpeechPlaybackController
    var body: some View {
        if controller.isActive, controller.capabilities.contains(.readingFollow) {
            VStack(spacing: 6) {
                if !controller.settings.followsReadingPosition {
                    Text("自动跟读已关闭").font(.footnote).foregroundStyle(.secondary)
                } else if controller.followSuspended {
                    Label(controller.state.isPlaying ? "正在朗读 · 跟读已暂停" : "朗读已暂停 · 跟读已挂起", systemImage: "hand.raised")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("回到正在朗读的段落") { controller.returnToSpoken() }.frame(minHeight: 44)
                        Spacer()
                        Button("恢复跟读") { controller.resumeFollowing() }.frame(minHeight: 44)
                    }
                } else {
                    Label(controller.state.isPlaying ? "跟读中" : "自动跟读已开启", systemImage: "text.alignleft")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("回到正在朗读的段落") { controller.returnToSpoken() }.frame(minHeight: 44)
                }
            }.accessibilityIdentifier("tts-follow-status")
        }
    }
}

struct SpeechRateControls: View {
    @Binding var settings: SpeechSettings
    var engineKind: SpeechEngineKind?
    private let minimumRate = 0.0
    private var rateTitle: String {
        if abs(settings.rate - 0.5) < 0.01 { return "标准语速" }
        return settings.rate < 0.5 ? "较慢 · 第 \(Int((settings.rate * 20).rounded()) + 1) 档" : "较快 · 第 \(Int((settings.rate * 20).rounded()) + 1) 档"
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { settings.rate = max(minimumRate, max(minimumRate, settings.rate) - 0.05) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                    .accessibilityLabel("降低朗读语速").disabled(settings.rate <= minimumRate)
                Spacer()
                Text(rateTitle).font(.subheadline).accessibilityIdentifier("tts-rate-value")
                Spacer()
                Button { settings.rate = min(1, max(minimumRate, settings.rate) + 0.05) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .accessibilityLabel("提高朗读语速").disabled(settings.rate >= 1)
            }
            Slider(value: Binding(get: { max(minimumRate, settings.rate) }, set: { settings.rate = $0 }), in: minimumRate...1, step: 0.05)
                .accessibilityLabel("朗读语速").accessibilityValue(rateTitle)
            HStack {
                Button("慢速") { settings.rate = 0.25 }.frame(minHeight: 44)
                Spacer()
                Button("标准") { settings.rate = 0.5 }.frame(minHeight: 44)
                Spacer()
                Button("快速") { settings.rate = 0.75 }.frame(minHeight: 44)
            }
            Text(engineKind == .edge ? "使用相对速度档位，从下一段起生效。" : "使用设备语音的相对速度，从下一句起生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 音色按语言组织；试听固定短句，不上传书籍正文，离开音色页面即停止。
struct SpeechVoicePicker: View {
    let voices: [SpeechVoiceOption]
    @Binding var selection: String
    let isCloud: Bool
    /// Edge 音色使用本机目录缓存和显式更新入口。
    var engineKind: SpeechEngineKind? = nil
    let rate: Double
    var volume: Double = 1
    var pitch: Double = 0
    var previewController: SpeechPlaybackController? = nil
    var beforePreview: () -> Void = {}
    @State private var previewToken: UUID?
    @EnvironmentObject private var services: AppServices
    @StateObject private var preview = SpeechVoicePreview()
    @State private var dynamicVoices: [SpeechVoiceOption] = SpeechSettingsStore().edgeVoices
    @State private var showsCatalog = false
    private var usesEdgeCatalog: Bool { isCloud }
    private var displayedVoices: [SpeechVoiceOption] {
        var values = usesEdgeCatalog ? dynamicVoices : voices
        if isCloud, !selection.isEmpty, !values.contains(where: { $0.identifier == selection }) {
            values.append(.init(identifier: selection, name: selection, language: String(selection.prefix(5))))
        }
        return values
    }
    private var languages: [String] { Set(displayedVoices.map(\.language)).sorted() }
    var body: some View {
        if let previewController {
            SpeechObservedContent(object: previewController) { _ in controls }
        } else { controls }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
        Picker(isCloud ? "Edge 音色" : "设备语音", selection: $selection) {
            if !isCloud { Text("系统默认").tag("") }
            ForEach(languages, id: \.self) { language in
                Section(language) {
                    ForEach(displayedVoices.filter { $0.language == language }, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                    }
                }
            }
        }
        if usesEdgeCatalog {
            Button("更多 Edge 音色") { preview.stop(); showsCatalog = true }.frame(minHeight: 44)
                .sheet(isPresented: $showsCatalog, onDismiss: { dynamicVoices = SpeechSettingsStore().edgeVoices }) {
                    SpeechVoiceCatalog(selection: $selection, voices: $dynamicVoices)
                }
        }
        Button(preview.isPreparing ? "正在准备试听…" : "试听当前音色") {
            if let token = previewToken, previewController?.ownsVoicePreview(token) != true { previewToken = nil }
            if previewToken == nil {
                previewToken = previewController?.beginVoicePreview(cancel: { [weak preview = preview] in
                    preview?.stop(releaseAudioSession: false)
                })
            }
            beforePreview()
            preview.onFinished = {
                if let token = previewToken { previewController?.finishVoicePreview(token, restore: true) }
                previewToken = nil
            }
            preview.play(cloud: isCloud, voice: selection,
                         language: displayedVoices.first(where: { $0.identifier == selection })?.language ?? "zh-CN",
                         rate: rate, volume: volume, pitch: pitch, service: services.speech)
        }.disabled(preview.isPreparing || previewController?.state == .preparing).frame(minHeight: 44)
        if preview.isActive { Button("结束试听并返回") { preview.complete() }.frame(minHeight: 44) }
        if let message = preview.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        Text("试听使用固定短句，暂停当前书籍；试听结束后恢复原播放状态。离开设置或停止书籍时取消自动恢复。")
            .font(.caption).foregroundStyle(.secondary)
        }
            .onDisappear {
                preview.stop()
                if let token = previewToken { previewController?.finishVoicePreview(token, restore: false) }
                previewToken = nil
            }
    }
}

@MainActor
private final class SpeechVoicePreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isPreparing = false
    @Published private(set) var isActive = false
    @Published private(set) var message: String?
    var onFinished: (() -> Void)?
    private var worker: Task<Void, Never>?
    private var revision = UUID()
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var ownsAudioSession = false
    override init() { super.init(); synthesizer.delegate = self }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }; self?.complete()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.utterance === utterance else { return }; self?.complete()
        }
    }
    func complete() {
        let finished = onFinished
        stop()
        finished?()
    }
    func stop(releaseAudioSession: Bool = true) {
        onFinished = nil
        revision = UUID(); worker?.cancel(); worker = nil
        player?.delegate = nil; player?.stop(); player = nil; utterance = nil; synthesizer.stopSpeaking(at: .immediate)
        isPreparing = false; isActive = false
        if releaseAudioSession, ownsAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        ownsAudioSession = false
    }
    func play(cloud: Bool, voice: String, language: String, rate: Double, volume: Double, pitch: Double, service: any SpeechEngineSelecting) {
        let finished = onFinished
        stop(); message = nil
        onFinished = finished
        let text = language.hasPrefix("ja") ? "こんにちは。これは音声のテストです。" : (language.hasPrefix("zh") ? "你好，这是朗读音色试听。" : "Hello. This is a voice preview.")
        let revision = self.revision
        isPreparing = true
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                if cloud {
                    let audio = try await service.preview(text: text, voice: voice, rate: rate, pitch: pitch)
                    guard self.revision == revision, !Task.isCancelled else { return }
                    self.player = try AVAudioPlayer(data: audio)
                    self.player?.delegate = self
                    self.player?.volume = Float(volume)
                }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
                try session.setActive(true)
                self.ownsAudioSession = true
                if cloud {
                    guard self.player?.play() == true else { throw SpeechPreviewFailure.unavailable }
                } else {
                    let utterance = AVSpeechUtterance(string: text)
                    utterance.voice = voice.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voice)
                    utterance.rate = SystemSpeechEngine.avRate(for: rate)
                    utterance.volume = Float(volume)
                    utterance.pitchMultiplier = Float(pow(2, pitch))
                    self.utterance = utterance
                    self.synthesizer.speak(utterance)
                }
                self.isPreparing = false; self.isActive = true
            } catch {
                guard self.revision == revision, !Task.isCancelled else { return }
                self.complete(); self.message = (error as? LocalizedError)?.errorDescription ?? "试听失败，请重试。"
            }
        }
    }
}

/// 正文只发出朗读意图，宿主负责引擎组装和同一控制器的生命周期。
struct ReaderSpeechActions {
    var toggle: () -> Void = {}
    var start: (SpeechAnchor) -> Void = { _ in }
}
private struct ReaderSpeechActionsKey: EnvironmentKey { static let defaultValue = ReaderSpeechActions() }
extension EnvironmentValues {
    var readerSpeechActions: ReaderSpeechActions {
        get { self[ReaderSpeechActionsKey.self] }
        set { self[ReaderSpeechActionsKey.self] = newValue }
    }
}
struct SpeechSentenceMenu: View {
    let text: String
    let baseOffset: Int
    let chapter: Int
    @Environment(\.readerSpeechActions) private var actions
    var body: some View {
        Menu("从此句朗读") {
            ForEach(Array(SpeechText.segments(in: text).enumerated()), id: \.offset) { _, segment in
                Button(String(segment.text.prefix(70))) {
                    actions.start(SpeechAnchor(chapterIndex: chapter, progression: 0, chapterUTF16Length: 0,
                                               startIndexHint: nil, sourceUTF16Offset: baseOffset + segment.utf16Offset))
                }
            }
        }
    }
}

private struct SpeechChapterIndexKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var speechChapterIndex: Int {
        get { self[SpeechChapterIndexKey.self] }
        set { self[SpeechChapterIndexKey.self] = newValue }
    }
}

struct SpeechSoundControls: View {
    @Binding var settings: SpeechSettings
    let cloud: Bool
    var body: some View {
        VStack(alignment: .leading) {
            Text("朗读音量 \(Int(settings.volume * 100))%")
            Slider(value: $settings.volume, in: 0...1, step: 0.05).accessibilityLabel("朗读音量")
            Group {
                Text("音高：" + (abs(settings.pitch) < 0.01 ? "默认" : (settings.pitch < 0 ? "偏低" : "偏高")))
                Slider(value: $settings.pitch, in: -1...1, step: 0.05).accessibilityLabel("朗读音高")
            }
            Button("恢复声音默认值") { settings.volume = 1; settings.pitch = 0 }.frame(minHeight: 44)
        }
        Text(cloud ? "音量立即生效；音高从下一段起生效，不改变语速。"
                   : "系统朗读从下一句起生效；Readium 官方接口暂不提供这两项配置。")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// 只有用户点“更新”才联网，失败保留缓存与内置目录，音色选择不发送正文。
private struct SpeechVoiceCatalog: View {
    @Binding var selection: String
    @Binding var voices: [SpeechVoiceOption]
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var loading = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    private var filtered: [SpeechVoiceOption] {
        voices.filter { query.isEmpty || "\($0.name) \($0.language) \($0.identifier)".localizedCaseInsensitiveContains(query) }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }
    var body: some View {
        NavigationView {
            List {
                Section {
                    Button(loading ? "正在更新音色…" : "从 Edge 更新音色") {
                        guard !loading else { return }
                        loading = true; message = nil
                        task = Task {
                            do {
                                let result = try await services.speech.refreshVoices()
                                guard !Task.isCancelled else { return }
                                voices = result; loading = false
                            } catch {
                                guard !Task.isCancelled else { return }
                                loading = false; message = "音色更新失败，仍可使用已有列表。"
                            }
                        }
                    }.disabled(loading)
                    Text("更新只获取公开音色目录，不发送书籍正文。当前共 \(voices.count) 个音色；列表保存在本机，离线仍可选择，在线朗读仍需联网。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(filtered, id: \.identifier) { voice in
                    Button {
                        selection = voice.identifier; dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(voice.name)
                                Text("\(voice.language) · \(voice.identifier)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection == voice.identifier { Image(systemName: "checkmark") }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索音色、语言或名称")
            .navigationTitle("Edge 音色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.navigationViewStyle(StackNavigationViewStyle())
        .onDisappear { task?.cancel() }
    }
}
