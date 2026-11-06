import AVFoundation
import Foundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit

// MARK: - 朗读播放控制器

/// 阅读界面与朗读面板的唯一状态源。持有当前引擎，引擎可替换：目前是 Readium 官方 TTS，
/// 以后可以是系统 TTS 或云端合成；界面只依赖 Domain 的 `SpeechPlaybackContract`。
/// 每本书由阅读器模型持有独立实例，不使用全局 shared。
@MainActor
final class SpeechPlaybackController: ObservableObject {
    @Published private(set) var state: SpeechPlaybackState = .idle {
        didSet { session.playbackStateDidChange(state) }
    }
    @Published var settings = SpeechSettingsStore().load() {
        didSet {
            let value = settings.clamped()
            engine?.update(settings: value)
            store.save(value)
            session.update(sleepTimerMinutes: value.sleepTimerMinutes)
        }
    }

    /// 后台／锁屏会话，由控制器按书持有；朗读面板直接观察它显示定时剩余时间。
    let session = SpeechRemoteSession()
    /// 锁屏显示的书名，由阅读器入口设置。
    var bookTitle = "Novelia 朗读"

    private let store = SpeechSettingsStore()
    @Published private(set) var showsQuickControls = false
    @Published private(set) var engineKind: SpeechEngineKind?
    private var engine: (any SpeechEngine)?
    private var startTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastAnchor = SpeechAnchor(chapterIndex: 0, progression: 0,
                                          chapterUTF16Length: 0, startIndexHint: nil)

    init() {
        session.onTogglePlayback = { [weak self] in self?.toggleFromRemote() }
        session.onPause = { [weak self] in self?.pause() }
        session.onPlay = { [weak self] in self?.play() }
        session.onResume = { [weak self] in self?.resume() }
        session.onStop = { [weak self] in self?.stop() }
        session.onSkipForward = { [weak self] in self?.skipForward() }
        session.onSkipBackward = { [weak self] in self?.skipBackward() }
        session.update(sleepTimerMinutes: settings.sleepTimerMinutes)
    }

    func reloadSettings() { settings = store.load() }
    var selectedVoiceIdentifier: String? { engine?.kind == .edge ? settings.edgeVoiceIdentifier : settings.voiceIdentifier }
    func selectVoice(_ identifier: String) {
        if engine?.kind == .edge { settings.edgeVoiceIdentifier = identifier }
        else { settings.voiceIdentifier = identifier.isEmpty ? nil : identifier }
    }
    var isCloud: Bool { engineKind == .edge }
    var engineTitle: String { isCloud ? "Edge 在线朗读" : (engineKind == .readium ? "本地 · Readium" : "本地 · 系统朗读") }
    var edgeConsentGranted: Bool { store.edgeConsentGranted }
    func changeEngine(to kind: SpeechEngineKind, grantConsent: Bool = false) {
        stop()
        if grantConsent { store.setEdgeConsent(true) }
        settings.preferredEngine = kind
    }
    var skipBackwardLabel: String { isCloud && !capabilities.contains(.sentenceNavigation) ? "上一段" : "上一句" }
    var skipForwardLabel: String { isCloud && !capabilities.contains(.sentenceNavigation) ? "下一段" : "下一句" }

    var isAvailable: Bool { engine != nil }
    var capabilities: SpeechCapabilities { engine?.capabilities ?? [] }
    var availableVoices: [SpeechVoiceOption] { engine?.availableVoices ?? [] }

    /// 正在朗读或已暂停时，重新打开面板不应重建引擎而打断后台播放。
    var isActive: Bool {
        switch state {
        case .playing, .paused, .preparing: return true
        default: return false
        }
    }

    /// 导航器重建时换引擎；旧引擎先停止，避免继续驱动已失效的页面。
    func attach(_ newEngine: (any SpeechEngine)?) {
        stop()
        engine = newEngine
        engineKind = newEngine?.kind
        state = newEngine?.state ?? .idle
        newEngine?.update(settings: settings.clamped())
    }

    func start(from anchor: SpeechAnchor, readiumLocator: Locator? = nil) {
        guard let engine else { return }
        // 主线程回调直接落状态，不再额外排队；代次阻止已替换引擎的迟到事件。
        stop()
        let generation = self.generation
        engine.onStateChange = { [weak self] newState in
            guard let self, self.generation == generation else { return }
            self.state = newState
        }
        (engine as? ReadiumSpeechEngine)?.startingLocator = readiumLocator
        showsQuickControls = true
        lastAnchor = anchor
        session.activate(title: bookTitle)
        state = .preparing
        startTask = Task { [weak self] in
            guard !Task.isCancelled, self?.generation == generation else { return }
            await engine.start(from: anchor)
            if self?.generation == generation { self?.startTask = nil }
        }
    }

    /// 锁屏“播放”是幂等命令：暂停则恢复，结束/失败则重新起播，准备与播放中不重启。
    func play() {
        switch state {
        case .playing, .preparing: break
        case .paused: resume()
        case .failed: retry()
        case .idle, .finished: start(from: lastAnchor)
        }
    }

    func retry() {
        showsQuickControls = true
        session.activate(title: bookTitle)
        if engine?.retry() != true { start(from: lastAnchor) }
    }
    func skipChapter(_ delta: Int) {
        guard isActive else { return }
        engine?.skipChapter(delta)
    }
    /// 选区解析可能读取章节；停止/换引擎会取消同一控制器拥有的解析任务。
    func startSelection(resolve: @escaping () async -> (SpeechAnchor, Locator?)?) {
        stop()
        let generation = self.generation
        showsQuickControls = true; state = .preparing
        startTask = Task { [weak self] in
            let result = await resolve()
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            guard let result else { self.state = .failed("无法定位当前可见正文，请选择句子起播。"); self.startTask = nil; return }
            self.startTask = nil
            self.start(from: result.0, readiumLocator: result.1)
        }
    }
    func toggleHighlightedSpeech() {
        switch state { case .playing: pause(); case .paused: resume(); default: break }
    }
    func pause() { engine?.pause() }
    func resume() { engine?.resume() }
    func skipBackward() {
        guard state.utterance != nil else { return }
        engine?.skipBackward()
    }
    func skipForward() {
        guard state.utterance != nil else { return }
        engine?.skipForward()
    }

    func stop() {
        generation = UUID()
        startTask?.cancel()
        startTask = nil
        showsQuickControls = false
        engine?.onStateChange = nil
        engine?.stop()
        state = .idle
        session.deactivate()
    }

    /// 锁屏「播放／暂停」在停止后也能从上次起播位置重新开始。
    private func toggleFromRemote() {
        switch state {
        case .playing: pause()
        default: play()
        }
    }
}

// MARK: - Readium 官方 TTS 引擎

/// 把 swift-toolkit 的 `PublicationSpeechSynthesizer` 适配到统一的 `SpeechEngine` 契约。
/// 只有带 `ContentService` 的 publication 能创建；真实 EPUB 与已注册内容服务的
/// `ReadiumTextPublication`（在线/TXT）均使用同一套官方 TTS。
/// 音频会话由 Readium 内部管理（.playback / .spokenAudio / .longFormAudio），这里不重复激活。
@MainActor
final class ReadiumSpeechEngine: SpeechEngine, PublicationSpeechSynthesizerDelegate {
    let kind: SpeechEngineKind = .readium
    /// 官方合成器不暴露语速配置，因此不声明 `.rateControl`；后台与锁屏控制由
    /// `SpeechRemoteSession` 在两个引擎之外统一提供，故这里可以声明 `.backgroundAudio`。
    var capabilities: SpeechCapabilities {
        var value: SpeechCapabilities = [.voiceSelection, .wordLevelProgress, .readingFollow, .offline, .backgroundAudio]
        if chapterLocator != nil { value.insert(.chapterNavigation) }
        return value
    }

    var availableVoices: [SpeechVoiceOption] {
        synthesizer.availableVoices.map {
            SpeechVoiceOption(identifier: $0.identifier, name: $0.name,
                              language: String(describing: $0.language))
        }
    }

    private(set) var state: SpeechPlaybackState = .idle {
        didSet { observer?(state) }
    }
    private var observer: ((SpeechPlaybackState) -> Void)?
    var onStateChange: ((SpeechPlaybackState) -> Void)? {
        get { observer }
        set { observer = newValue }
    }

    private var synthesizer: PublicationSpeechSynthesizer
    private let publication: Publication
    private let onFollow: (() -> Void)?
    private weak var navigator: EPUBNavigatorViewController?
    var startingLocator: Locator?
    private let decorationGroup = "tts"
    private var settings = SpeechSettings.default
    private var lastFollowDate = Date.distantPast
    private var generation = UUID()
    private var isRunning = false
    private let chapterLocator: ((Int) async -> Locator?)?
    private var chapterTask: Task<Void, Never>?

    init?(publication: Publication, navigator: EPUBNavigatorViewController, onFollow: (() -> Void)? = nil,
          chapterLocator: ((Int) async -> Locator?)? = nil) {
        self.chapterLocator = chapterLocator
        self.onFollow = onFollow
        guard PublicationSpeechSynthesizer.canSpeak(publication: publication),
              let synthesizer = PublicationSpeechSynthesizer(publication: publication) else { return nil }
        self.synthesizer = synthesizer
        self.publication = publication
        self.navigator = navigator
        synthesizer.delegate = self
    }

    func start(from anchor: SpeechAnchor) async {
        guard let navigator else {
            state = .failed("阅读器尚未就绪")
            return
        }
        guard !Task.isCancelled else { return }
        stop()
        let generation = self.generation
        state = .preparing
        let selected = startingLocator
        startingLocator = nil
        let locator: Locator?
        if let selected { locator = selected }
        else { locator = await navigator.firstVisibleElementLocator() }
        guard self.generation == generation, !Task.isCancelled else { return }
        // 上游状态通知异步投递，重新起播使用独立合成器并核对身份，隔离旧会话事件。
        guard let synthesizer = PublicationSpeechSynthesizer(publication: publication) else {
            state = .failed("无法创建朗读引擎")
            return
        }
        self.synthesizer = synthesizer
        synthesizer.delegate = self
        synthesizer.config.voiceIdentifier = settings.voiceIdentifier
        isRunning = true
        synthesizer.start(from: locator)
    }

    func pause() {
        if chapterTask != nil {
            chapterTask?.cancel(); chapterTask = nil; state = .idle
        }
        synthesizer.pause()
        if let utterance = state.utterance { state = .paused(utterance) }
    }
    func resume() { synthesizer.resume() }
    func skipChapter(_ delta: Int) {
        guard let chapterLocator, let navigator else { return }
        let observer = self.observer
        self.observer = nil; stop(); self.observer = observer
        let generation = self.generation
        state = .preparing
        chapterTask = Task { [weak self] in
            let target = await chapterLocator(delta)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            guard let target else { self.chapterTask = nil; self.state = .finished; return }
            self.onFollow?()
            _ = await navigator.go(to: target)
            guard !Task.isCancelled, self.generation == generation else { return }
            self.chapterTask = nil
            guard let synthesizer = PublicationSpeechSynthesizer(publication: self.publication) else {
                self.state = .failed("无法创建朗读引擎"); return
            }
            self.synthesizer = synthesizer
            synthesizer.delegate = self
            synthesizer.config.voiceIdentifier = self.settings.voiceIdentifier
            self.isRunning = true
            synthesizer.start(from: target)
        }
    }
    func skipBackward() { synthesizer.previous() }
    func skipForward() { synthesizer.next() }

    func stop() {
        generation = UUID()
        chapterTask?.cancel(); chapterTask = nil
        isRunning = false
        synthesizer.delegate = nil
        synthesizer.stop()
        navigator?.apply(decorations: [], in: decorationGroup)
        state = .idle
    }

    func update(settings: SpeechSettings) {
        self.settings = settings.clamped()
        // 配置在下一句生效，这是官方合成器的既定行为。
        synthesizer.config.voiceIdentifier = self.settings.voiceIdentifier
        if !self.settings.highlightsSpokenText {
            navigator?.apply(decorations: [], in: decorationGroup)
        }
    }

    // MARK: PublicationSpeechSynthesizerDelegate

    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer,
                                      stateDidChange newState: PublicationSpeechSynthesizer.State) {
        guard synthesizer === self.synthesizer, isRunning else { return }
        switch newState {
        case .stopped:
            isRunning = false
            navigator?.apply(decorations: [], in: decorationGroup)
            state = .finished
        case let .paused(utterance):
            state = .paused(Self.map(utterance))
        case let .playing(utterance, range: range):
            state = .playing(Self.map(utterance))
            applyDecoration(for: utterance)
            if settings.followsReadingPosition, let range { follow(range) }
        }
    }

    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer,
                                      utterance: PublicationSpeechSynthesizer.Utterance,
                                      didFailWithError error: PublicationSpeechSynthesizer.Error) {
        guard synthesizer === self.synthesizer, isRunning else { return }
        state = .failed("朗读失败，请重试")
    }

    private static func map(_ utterance: PublicationSpeechSynthesizer.Utterance) -> SpeechUtterance {
        // Readium 用 Locator + Decoration 高亮，不依赖句内字符范围；整句范围供界面显示当前朗读内容。
        SpeechUtterance(text: utterance.text, chapterIndex: 0, utf16Offset: nil,
                        wordRange: 0..<max(1, utterance.text.utf16.count))
    }

    private func applyDecoration(for utterance: PublicationSpeechSynthesizer.Utterance) {
        guard settings.highlightsSpokenText, let navigator else { return }
        let decoration = Decoration(id: "tts-current", locator: utterance.locator,
                                    style: .init(id: "novelia-speech"))
        navigator.apply(decorations: [decoration], in: decorationGroup)
    }

    /// 逐词回调频率很高，直接按每个 range 跳页会拖慢 WebView；限制为约每 0.8 秒一次。
    private func follow(_ range: Locator) {
        let now = Date()
        guard now.timeIntervalSince(lastFollowDate) >= 0.8, let navigator else { return }
        lastFollowDate = now
        let generation = self.generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation, self.isRunning, self.state.isPlaying,
                  self.settings.followsReadingPosition else { return }
            self.onFollow?()
            _ = await navigator.go(to: range)
        }
    }
}

// MARK: - 朗读面板

/// 与引擎无关的播放控件：能力位决定显示哪些设置，云端引擎接入后无需改动本视图。
struct SpeechControlView: View {
    @ObservedObject var controller: SpeechPlaybackController
    @ObservedObject var session: SpeechRemoteSession
    let anchor: SpeechAnchor
    var title = "Novelia 朗读"
    var onEngineChange: (() -> Void)? = nil
    var onStart: (() -> Void)? = nil
    @State private var showsEdgeConsent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 24) {
                        Button { controller.skipBackward() } label: {
                            Image(systemName: "backward.fill")
                        }
                        .accessibilityLabel(controller.skipBackwardLabel)
                        .disabled(controller.state.utterance == nil)
                        Button { toggle() } label: {
                            Image(systemName: controller.state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.largeTitle)
                        }
                        .accessibilityLabel(controller.state.isPlaying ? "暂停朗读" : "播放朗读")
                        .disabled(controller.state == .preparing || !controller.isAvailable)
                        Button { controller.skipForward() } label: {
                            Image(systemName: "forward.fill")
                        }
                        .accessibilityLabel(controller.skipForwardLabel)
                        .disabled(controller.state.utterance == nil)
                        Button { controller.stop() } label: {
                            Image(systemName: "stop.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderless)
                    if controller.capabilities.contains(.chapterNavigation) {
                        HStack {
                            Button("上一章") { controller.skipChapter(-1) }
                            Spacer()
                            Button("下一章") { controller.skipChapter(1) }
                        }.buttonStyle(.borderless).disabled(!controller.isActive)
                    }
                    Text(statusText).font(.footnote).foregroundStyle(.secondary)
                }

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
                        Text("切换会停止当前播放；点按播放，从当前阅读位置继续。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if controller.isCloud {
                    Section("Edge 在线朗读") {
                        Toggle("提前准备下一段", isOn: $controller.settings.edgePrefetchEnabled)
                        Text("开启后会提前发送同章下一分段正文给微软，减少段间等待。上一句／下一句按时间轴跳转；无时间轴时按段切换。音频只在本次会话内缓存，停止后清除。")
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
                                          isCloud: controller.isCloud, rate: controller.settings.rate, volume: controller.settings.volume, pitch: controller.settings.pitch,
                                          beforePreview: { controller.stop() })
                            .id(controller.engineKind)
                    }
                }

                if controller.capabilities.contains(.rateControl) {
                    Section("语速") {
                        Slider(value: $controller.settings.rate, in: 0...1, step: 0.05)
                        Text(controller.isCloud ? "0.5 为 Edge 默认语速，从下一段起生效。" : "0.5 为系统默认语速，从下一句起生效。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if controller.capabilities.contains(.volumeControl) || controller.capabilities.contains(.pitchControl) {
                    Section("声音") { SpeechSoundControls(settings: $controller.settings, cloud: controller.isCloud) }
                } else if controller.engineKind == .readium {
                    Text("Readium 本地朗读接口暂不支持独立音量和音高；系统朗读与 Edge 支持。")
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
                        Text("锁屏与耳机可播放／暂停、切换朗读片段；来电等音频中断会自动暂停，拔掉耳机也会暂停。离开阅读器仍会停止朗读。")
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
            .navigationTitle("朗读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 关闭面板只收起界面，朗读继续；后台与锁屏控制因此才有意义。
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("停止朗读") {
                        controller.stop()
                        dismiss()
                    }
                    .disabled(controller.state == .idle)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
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
        case .preparing: return "正在准备…"
        case let .playing(utterance): return "正在朗读：\(utterance.text)"
        case .paused: return "已暂停"
        case .finished: return "朗读结束"
        case let .failed(message): return message
        }
    }
}

/// 正文上的小型控件不占顶栏；展开设置仍使用宿主面板，不持有第二套播放器。
struct ReaderSpeechQuickControls: View {
    @ObservedObject var controller: SpeechPlaybackController
    let openPanel: () -> Void
    @State private var expanded = false
    var body: some View {
        if controller.showsQuickControls {
            VStack(alignment: .trailing, spacing: 8) {
                if expanded {
                    HStack(spacing: 16) {
                        Button { controller.skipBackward() } label: { Image(systemName: "backward.fill") }
                            .accessibilityLabel(controller.skipBackwardLabel)
                        Button { controller.skipForward() } label: { Image(systemName: "forward.fill") }
                            .accessibilityLabel(controller.skipForwardLabel)
                        Button(action: openPanel) { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("朗读设置")
                        Button { controller.stop() } label: { Image(systemName: "stop.fill") }.accessibilityLabel("停止朗读")
                    }.padding(14).background(.regularMaterial, in: Capsule())
                }
                HStack(spacing: 12) {
                    Button {
                        if controller.state.isPlaying { controller.pause() } else { controller.play() }
                    } label: { Image(systemName: controller.state.isPlaying ? "pause.fill" : "play.fill").frame(width: 36, height: 36) }
                    .accessibilityLabel(controller.state.isPlaying ? "快捷暂停朗读" : "快捷继续朗读")
                    .disabled(controller.state == .preparing)
                    Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "ellipsis").frame(width: 32, height: 36) }
                        .accessibilityLabel("朗读快捷操作")
                }.padding(6).background(.regularMaterial, in: Capsule())
            }.buttonStyle(.borderless)
        }
    }
}

/// 音色按语言组织；试听固定短句，不上传书籍正文，离开音色页面即停止。
struct SpeechVoicePicker: View {
    let voices: [SpeechVoiceOption]
    @Binding var selection: String
    let isCloud: Bool
    let rate: Double
    var volume: Double = 1
    var pitch: Double = 0
    var beforePreview: () -> Void = {}
    @EnvironmentObject private var services: AppServices
    @StateObject private var preview = SpeechVoicePreview()
    @State private var dynamicVoices: [SpeechVoiceOption] = SpeechSettingsStore().edgeVoices
    @State private var showsCatalog = false
    private var displayedVoices: [SpeechVoiceOption] {
        var values = isCloud ? dynamicVoices : voices
        if isCloud, !selection.isEmpty, !values.contains(where: { $0.identifier == selection }) {
            values.append(.init(identifier: selection, name: selection, language: String(selection.prefix(5))))
        }
        return values
    }
    private var languages: [String] { Set(displayedVoices.map(\.language)).sorted() }
    var body: some View {
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
        if isCloud {
            Button("更多 Edge 音色") { preview.stop(); showsCatalog = true }
                .sheet(isPresented: $showsCatalog, onDismiss: { dynamicVoices = SpeechSettingsStore().edgeVoices }) {
                    SpeechVoiceCatalog(selection: $selection, voices: $dynamicVoices)
                }
        }
        Button(preview.isPreparing ? "正在准备试听…" : "试听当前音色") {
            beforePreview()
            preview.play(cloud: isCloud, voice: selection,
                         language: displayedVoices.first(where: { $0.identifier == selection })?.language ?? "zh-CN",
                         rate: rate, volume: volume, pitch: pitch, service: services.speech)
        }.disabled(preview.isPreparing)
        if preview.isActive { Button("停止试听") { preview.stop() } }
        if let message = preview.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        Text("试听使用固定短句，会停止当前朗读。中文和日文使用对应短句，其他音色使用英文测试句。")
            .font(.caption).foregroundStyle(.secondary)
            .onDisappear { preview.stop() }
    }
}

@MainActor
private final class SpeechVoicePreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isPreparing = false
    @Published private(set) var isActive = false
    @Published private(set) var message: String?
    private var worker: Task<Void, Never>?
    private var revision = UUID()
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    override init() { super.init(); synthesizer.delegate = self }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }; self?.stop()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.utterance === utterance else { return }; self?.stop()
        }
    }
    func stop() {
        revision = UUID(); worker?.cancel(); worker = nil
        player?.delegate = nil; player?.stop(); player = nil; utterance = nil; synthesizer.stopSpeaking(at: .immediate)
        isPreparing = false; isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func play(cloud: Bool, voice: String, language: String, rate: Double, volume: Double, pitch: Double, service: any SpeechEngineSelecting) {
        stop(); message = nil
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
                if cloud {
                    guard self.player?.play() == true else { throw SpeechPreviewFailure.unavailable }
                } else {
                    let utterance = AVSpeechUtterance(string: text)
                    utterance.voice = voice.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voice)
                    utterance.rate = Float(rate)
                    utterance.volume = Float(volume)
                    utterance.pitchMultiplier = Float(pow(2, pitch))
                    self.utterance = utterance
                    self.synthesizer.speak(utterance)
                }
                self.isPreparing = false; self.isActive = true
            } catch {
                guard self.revision == revision, !Task.isCancelled else { return }
                self.stop(); self.message = (error as? LocalizedError)?.errorDescription ?? "试听失败，请重试。"
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
            Text("音高：" + (abs(settings.pitch) < 0.01 ? "默认" : (settings.pitch < 0 ? "偏低" : "偏高")))
            Slider(value: $settings.pitch, in: -1...1, step: 0.05).accessibilityLabel("朗读音高")
            Button("恢复声音默认值") { settings.volume = 1; settings.pitch = 0 }
        }
        Text(cloud ? "音量立即生效；音高从下一段起生效，不改变语速。" : "系统朗读从下一句起生效；Readium 官方接口暂不提供这两项配置。")
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
