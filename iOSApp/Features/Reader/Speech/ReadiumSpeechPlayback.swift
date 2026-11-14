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
        didSet {
            if let utterance = state.utterance {
                currentSentence = utterance.text
                lastAnchor = playbackAnchor(for: utterance)
                hasPlaybackPosition = true
                recordResumePoint(force: !state.isPlaying)
            }
            session.playbackStateDidChange(state)
        }
    }
    @Published var settings = SpeechSettingsStore().load() {
        didSet {
            let value = settings.clamped()
            applyEngineSettings()
            store.save(value)
            session.update(sleepTimerMinutes: value.sleepTimerMinutes)
        }
    }

    /// 后台／锁屏会话，由控制器按书持有；朗读面板直接观察它显示定时剩余时间。
    private(set) var session = SpeechRemoteSession()
    /// 锁屏显示的书名，由阅读器入口设置。
    var bookTitle = "Novelia 朗读"
    var chapterTitleProvider: ((Int) -> String?)?
    @Published private(set) var currentSentence = ""
    var chapterTitle: String { chapterTitleProvider?(lastAnchor.chapterIndex) ?? "第 \(lastAnchor.chapterIndex + 1) 章" }
    var chapterProgression: Double { lastAnchor.progression }
    var preparationMessage: String { engine?.preparationMessage ?? "正在定位朗读位置…" }
    /// 书籍身份（进度键），由阅读器入口设置；用于按书记住收听位置。
    var bookRoute: SpeechBookRoute?
    var currentSpokenLocator: Locator? { pendingPausedStart?.locator ?? (engine as? ReadiumSpeechEngine)?.currentSpokenLocator }
    var currentPlaybackAnchor: SpeechAnchor { lastAnchor }

    private func playbackAnchor(for utterance: SpeechUtterance) -> SpeechAnchor {
        let length = utterance.chapterUTF16Length ?? 0
        let offset = utterance.utf16Offset
        let progression = utterance.chapterProgression
            ?? (length > 0 && offset != nil ? (Double(offset!) + 0.1) / Double(length) : lastAnchor.progression)
        return SpeechAnchor(chapterIndex: utterance.chapterIndex, progression: min(1, max(0, progression)),
                            chapterUTF16Length: length, startIndexHint: nil, sourceUTF16Offset: offset)
    }
    var bookKey: String?
    /// 「回到正在朗读的段落」：由宿主阅读器注入，滚动/分页各自实现定位。
    var onJumpToSpoken: (() -> Void)?
    /// 上次收听位置（打开面板时读取，供「继续上次」）。
    @Published private(set) var savedResume: SpeechResumePoint?

    private let store = SpeechSettingsStore()
    /// 宿主将真实续听点承接到书籍进度；不依赖页面跟随，沿用续听写盘节流。
    var onProgressSave: ((SpeechResumePoint) -> Void)?
    private let resumeStore: SpeechResumeStore
    private var hasPlaybackPosition = false
    private var lastResumeSave = Date.distantPast
    private var lastResumeChapter = -1
    @Published private(set) var showsQuickControls = false
    @Published private(set) var engineKind: SpeechEngineKind?
    private var engine: (any SpeechEngine)?
    private var startTask: Task<Void, Never>?
    private var generation = UUID()
    private struct Transfer {
        var anchor: SpeechAnchor
        let locator: Locator?
        let wantsPlayback: Bool
        var followSuspended: Bool = false
    }
    private var pendingTransfer: Transfer?
    private var pendingPausedStart: Transfer?
    private enum DeferredNavigation { case sentence(Int), chapter(Int) }
    private var pendingNavigation: DeferredNavigation?
    private var wantsPlayback = false
    private var previewCancellation: (() -> Void)?
    private var previewRecovery: (id: UUID, transfer: Transfer, retainedPlayback: Bool)?

    private func transferSnapshot() -> Transfer {
        var anchor = lastAnchor
        anchor.resumeText = currentSentence.isEmpty ? nil : currentSentence
        return Transfer(anchor: anchor, locator: currentSpokenLocator,
                        wantsPlayback: state.isPlaying || state == .preparing || (state.isFailure && wantsPlayback),
                        followSuspended: followSuspended)
    }
    /// 试听只暂停原会话；准备阶段则取消旧加载并在试听完成后按锚点恢复。
    func beginVoicePreview(cancel: (() -> Void)? = nil) -> UUID? {
        guard isActive else { return nil }
        if let recovery = previewRecovery { return recovery.id }
        let transfer = transferSnapshot()
        let retained = state.utterance != nil
        if retained { engine?.pause() } else { stop() }
        let id = UUID()
        previewRecovery = (id, transfer, retained)
        previewCancellation = cancel
        return id
    }
    func finishVoicePreview(_ id: UUID, restore: Bool) {
        guard let recovery = previewRecovery, recovery.id == id else { return }
        previewRecovery = nil
        previewCancellation = nil
        guard restore, recovery.transfer.wantsPlayback else { return }
        if recovery.retainedPlayback { wantsPlayback = true; engine?.resume() }
        else {
            start(from: recovery.transfer.anchor, readiumLocator: recovery.transfer.locator)
            suspendFollow(recovery.transfer.followSuspended)
        }
    }
    func ownsVoicePreview(_ id: UUID) -> Bool { previewRecovery?.id == id }
    func cancelVoicePreviewRecovery() {
        let cancel = previewCancellation
        previewRecovery = nil; previewCancellation = nil
        cancel?()
    }
    private var lastAnchor = SpeechAnchor(chapterIndex: 0, progression: 0,
                                          chapterUTF16Length: 0, startIndexHint: nil)

    init(resumeStore: SpeechResumeStore = SpeechResumeStore()) {
        self.resumeStore = resumeStore
        bindRemoteSession()
    }

    private func bindRemoteSession() {
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

    /// 打开面板或进入书籍时读取该书上次的收听位置。
    func refreshSavedResume() {
        savedResume = bookKey.flatMap { resumeStore.load(bookKey: $0) }
    }

    /// 当前会话的实时收听位置（不落盘）：迷你条「回到书内」用它定位，
    /// 避免写盘节流期间返回旧的落盘位置。
    var currentResumePoint: SpeechResumePoint? {
        guard let bookKey, !bookKey.isEmpty else { return nil }
        return SpeechResumePoint(bookKey: bookKey, chapterIndex: lastAnchor.chapterIndex,
                                 progression: lastAnchor.progression,
                                 engine: (engineKind ?? .system).rawValue,
                                 sourceUTF16Offset: lastAnchor.sourceUTF16Offset,
                                 locatorJSON: try? currentSpokenLocator?.jsonString())
    }

    /// 播放时节流写盘；暂停、停止、退出或切后台时补存当前句，重复事件不重复编码。
    private func recordResumePoint(force: Bool = false) {
        guard hasPlaybackPosition else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastResumeSave)
        let chapterChanged = lastAnchor.chapterIndex != lastResumeChapter
        guard force || (chapterChanged ? elapsed >= 5 : elapsed >= 60) else { return }
        guard let point = currentResumePoint else { return }
        if let saved = savedResume, saved.bookKey == point.bookKey,
           saved.chapterIndex == point.chapterIndex, saved.progression == point.progression,
           saved.sourceUTF16Offset == point.sourceUTF16Offset, saved.locatorJSON == point.locatorJSON,
           saved.engine == point.engine { return }
        lastResumeSave = now
        lastResumeChapter = point.chapterIndex
        resumeStore.save(point)
        savedResume = point
        onProgressSave?(point)
    }
    func flushResumePoint() { recordResumePoint(force: true) }

    /// 手动翻页时只挂起跟读，不打断播放：用户翻到别处继续看，朗读仍在进行。
    @Published private(set) var followSuspended = false
    func suspendFollow(_ suspended: Bool) {
        guard followSuspended != suspended else { return }
        followSuspended = suspended
        applyEngineSettings()
    }

    func returnToSpoken() { onJumpToSpoken?() }
    func resumeFollowing() {
        guard settings.followsReadingPosition else { return }
        suspendFollow(false)
        onJumpToSpoken?()
    }

    /// 引擎拿到的设置：挂起跟读期间临时关闭自动翻页，不改动已保存的偏好。
    private func applyEngineSettings() {
        var value = settings.clamped()
        if followSuspended { value.followsReadingPosition = false }
        engine?.update(settings: value)
    }

    var selectedVoiceIdentifier: String? {
        switch engine?.kind {
        case .edge: settings.edgeVoiceIdentifier
        default: settings.voiceIdentifier
        }
    }
    func selectVoice(_ identifier: String) {
        switch engine?.kind {
        case .edge: settings.edgeVoiceIdentifier = identifier
        default: settings.voiceIdentifier = identifier.isEmpty ? nil : identifier
        }
    }
    var isCloud: Bool { engineKind == .edge }
    var engineTitle: String {
        switch engineKind {
        case .edge: "Edge 在线朗读"
        case .readium: "本地 · Readium"
        case .system: "本地 · 系统朗读"
        case nil: "Novelia 朗读"
        }
    }
    var edgeConsentGranted: Bool { store.edgeConsentGranted }
    func changeEngine(to kind: SpeechEngineKind, grantConsent: Bool = false) {
        let transfer = showsQuickControls && state != .idle ? transferSnapshot() : nil
        stop()
        pendingTransfer = transfer
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
        let transfer = pendingTransfer
        stop()
        engine = newEngine
        engineKind = newEngine?.kind
        state = newEngine?.state ?? .idle
        applyEngineSettings()
        if let transfer, newEngine != nil {
            start(from: transfer.anchor, readiumLocator: engineKind == .readium ? transfer.locator : nil,
                  initiallyPaused: !transfer.wantsPlayback)
            suspendFollow(transfer.followSuspended)
        }
    }

    func start(from anchor: SpeechAnchor, readiumLocator: Locator? = nil, initiallyPaused: Bool = false) {
        guard let engine else { return }
        if initiallyPaused {
            stop()
            lastAnchor = anchor
            pendingPausedStart = Transfer(anchor: anchor, locator: readiumLocator, wantsPlayback: false, followSuspended: followSuspended)
            showsQuickControls = true
            session.activate(title: bookTitle)
            state = .paused(SpeechUtterance(text: currentSentence, chapterIndex: anchor.chapterIndex,
                                           utf16Offset: anchor.sourceUTF16Offset, wordRange: nil,
                                           chapterUTF16Length: anchor.chapterUTF16Length, chapterProgression: anchor.progression))
            return
        }
        // 新一次起播恢复正常跟读：手动翻页挂起的只是当次会话。
        if followSuspended { followSuspended = false; applyEngineSettings() }
        // 主线程回调直接落状态，不再额外排队；代次阻止已替换引擎的迟到事件。
        stop()
        wantsPlayback = !initiallyPaused
        let generation = self.generation
        observe(engine, generation: generation)
        (engine as? ReadiumSpeechEngine)?.startingLocator = readiumLocator
        showsQuickControls = true
        lastAnchor = anchor
        hasPlaybackPosition = false
        session.activate(title: bookTitle)
        state = .preparing
        startTask = Task { [weak self] in
            guard !Task.isCancelled, self?.generation == generation else { return }
            await engine.start(from: anchor)
            if self?.generation == generation { self?.startTask = nil }
        }
    }

    private func observe(_ engine: any SpeechEngine, generation: UUID) {
        engine.onStateChange = { [weak self, weak engine] newState in
            guard let self, let engine, self.generation == generation else { return }
            if newState.utterance == nil { self.flushResumePoint() }
            self.state = newState
            if newState.isPlaying, let navigation = self.pendingNavigation {
                self.pendingNavigation = nil
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.generation == generation else { return }
                    switch navigation {
                    case .sentence(let delta): if delta > 0 { engine.skipForward() } else { engine.skipBackward() }
                    case .chapter(let delta): engine.skipChapter(delta)
                    }
                }
            }
        }
    }

    /// 同书返回只移交正在运行的音频对象，不停止、重新合成或 seek。
    /// 正文与高亮回调改绑新宿主，远程会话一并保留以维持定时截止时间。
    func adoptLivePlayback(from previous: SpeechPlaybackController) -> Bool {
        guard previous !== self, !isActive, previous.isActive, previous.state.utterance != nil,
              bookKey == previous.bookKey, let live = previous.engine,
              let replacement = engine, live.kind == replacement.kind else { return false }
        if let system = live as? SystemSpeechEngine, let next = replacement as? SystemSpeechEngine {
            system.rebindReadingContext(to: next)
        } else if let cloud = live as? EdgeSpeechEngine, let next = replacement as? EdgeSpeechEngine {
            cloud.rebindReadingContext(to: next)
        } else if let readium = live as? ReadiumSpeechEngine, let next = replacement as? ReadiumSpeechEngine {
            readium.rebindReadingContext(to: next)
        } else { return false }
        previous.flushResumePoint()
        previous.generation = UUID()
        live.onStateChange = nil
        engine = live
        engineKind = previous.engineKind
        startTask = previous.startTask; previous.startTask = nil
        pendingPausedStart = previous.pendingPausedStart; previous.pendingPausedStart = nil
        pendingNavigation = previous.pendingNavigation; previous.pendingNavigation = nil
        wantsPlayback = previous.wantsPlayback
        lastAnchor = previous.lastAnchor
        hasPlaybackPosition = previous.hasPlaybackPosition
        followSuspended = previous.followSuspended
        currentSentence = previous.currentSentence
        session = previous.session
        previous.session = SpeechRemoteSession()
        bindRemoteSession()
        previous.bindRemoteSession()
        previous.engine = nil
        previous.showsQuickControls = false
        previous.state = .idle
        previous.hasPlaybackPosition = false
        previous.wantsPlayback = false
        observe(live, generation: generation)
        showsQuickControls = true
        session.activate(title: bookTitle)
        state = live.state
        applyEngineSettings()
        return true
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
        cancelVoicePreviewRecovery()
        if resumeDeferred(.chapter(delta)) { return }
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
    func playOrPause() { if state.isPlaying { pause() } else { play() } }
    func toggleHighlightedSpeech() {
        switch state { case .playing: pause(); case .paused: resume(); default: break }
    }
    func pause() { cancelVoicePreviewRecovery(); wantsPlayback = false; engine?.pause() }
    func resume() {
        cancelVoicePreviewRecovery(); wantsPlayback = true
        if let transfer = pendingPausedStart {
            start(from: transfer.anchor, readiumLocator: transfer.locator)
            suspendFollow(transfer.followSuspended)
        } else { engine?.resume() }
    }
    private func resumeDeferred(_ navigation: DeferredNavigation) -> Bool {
        guard let transfer = pendingPausedStart else { return false }
        start(from: transfer.anchor, readiumLocator: transfer.locator)
        suspendFollow(transfer.followSuspended)
        pendingNavigation = navigation
        return true
    }
    func skipBackward() {
        cancelVoicePreviewRecovery()
        if resumeDeferred(.sentence(-1)) { return }
        guard state.utterance != nil else { return }
        engine?.skipBackward()
    }
    func skipForward() {
        cancelVoicePreviewRecovery()
        if resumeDeferred(.sentence(1)) { return }
        guard state.utterance != nil else { return }
        engine?.skipForward()
    }

    func stop() {
        cancelVoicePreviewRecovery()
        pendingTransfer = nil
        pendingPausedStart = nil
        pendingNavigation = nil
        wantsPlayback = false
        flushResumePoint()
        generation = UUID()
        startTask?.cancel()
        startTask = nil
        showsQuickControls = false
        engine?.onStateChange = nil
        engine?.stop()
        state = .idle
        hasPlaybackPosition = false
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
    #if DEBUG
    /// 独立验证界面核对同书返回没有重新起播；不进入 Release。
    private(set) static var validationStartCount = 0
    #endif
    let kind: SpeechEngineKind = .readium
    let preparationMessage = "正在定位朗读句…"
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
    private var onFollow: (() -> Void)?
    private weak var navigator: EPUBNavigatorViewController?
    var startingLocator: Locator?
    /// 当前朗读句的定位，供宿主「回到正在朗读的段落」使用。
    var onSpokenLocator: ((Locator) -> Void)?
    private let decorationGroup = "tts"
    private var settings = SpeechSettings.default
    private(set) var currentSpokenLocator: Locator?
    private var currentUtterance: PublicationSpeechSynthesizer.Utterance?
    private var currentRange: Locator?
    private var needsContextNavigation = false
    private var lastFollowDate = Date.distantPast
    private var generation = UUID()
    private var isRunning = false
    private var chapterLocator: ((Int) async -> Locator?)?
    private var anchorForLocator: ((Locator) -> SpeechAnchor?)?
    private var locatorForAnchor: ((SpeechAnchor) async -> Locator?)?
    private var startingAnchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil)
    private var chapterTask: Task<Void, Never>?

    init?(publication: Publication, navigator: EPUBNavigatorViewController, onFollow: (() -> Void)? = nil,
          chapterLocator: ((Int) async -> Locator?)? = nil,
          anchorForLocator: ((Locator) -> SpeechAnchor?)? = nil,
          locatorForAnchor: ((SpeechAnchor) async -> Locator?)? = nil) {
        self.locatorForAnchor = locatorForAnchor
        self.anchorForLocator = anchorForLocator
        self.chapterLocator = chapterLocator
        self.onFollow = onFollow
        guard PublicationSpeechSynthesizer.canSpeak(publication: publication),
              let synthesizer = PublicationSpeechSynthesizer(publication: publication) else { return nil }
        self.synthesizer = synthesizer
        self.publication = publication
        self.navigator = navigator
        synthesizer.delegate = self
    }

    /// 保留原 PublicationSpeechSynthesizer 的句内进度，只更换显示与导航宿主。
    func rebindReadingContext(to replacement: ReadiumSpeechEngine) {
        generation = UUID() // 取消尚未执行的旧页面跟读跳转，不触碰合成器。
        navigator?.apply(decorations: [], in: decorationGroup)
        navigator = replacement.navigator
        onFollow = replacement.onFollow
        chapterLocator = replacement.chapterLocator
        anchorForLocator = replacement.anchorForLocator
        locatorForAnchor = replacement.locatorForAnchor
        onSpokenLocator = replacement.onSpokenLocator
        needsContextNavigation = true
        lastFollowDate = .distantPast
    }

    func start(from anchor: SpeechAnchor) async {
        guard let navigator else {
            state = .failed("阅读器尚未就绪")
            return
        }
        guard !Task.isCancelled else { return }
        #if DEBUG
        Self.validationStartCount += 1
        #endif
        stop()
        let generation = self.generation
        state = .preparing
        startingAnchor = anchor
        let selected = startingLocator
        startingLocator = nil
        let locator: Locator?
        if let selected { locator = selected }
        else if anchor.resumeText != nil, let locatorForAnchor { locator = await locatorForAnchor(anchor) }
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
    func resume() { try? AVAudioSession.sharedInstance().setActive(true); synthesizer.resume() }
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
        currentUtterance = nil
        currentRange = nil
        needsContextNavigation = false
        navigator?.apply(decorations: [], in: decorationGroup)
        state = .idle
    }

    func update(settings: SpeechSettings) {
        self.settings = settings.clamped()
        // 配置在下一句生效，这是官方合成器的既定行为。
        synthesizer.config.voiceIdentifier = self.settings.voiceIdentifier
        if !self.settings.highlightsSpokenText {
            navigator?.apply(decorations: [], in: decorationGroup)
        } else if let currentUtterance { applyDecoration(for: currentUtterance) }
        if let currentSpokenLocator { onSpokenLocator?(currentSpokenLocator) }
        if needsContextNavigation, let target = currentRange ?? currentSpokenLocator, let navigator {
            needsContextNavigation = false
            let generation = self.generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.isRunning else { return }
                self.onFollow?()
                _ = await navigator.go(to: target)
            }
        }
    }

    // MARK: PublicationSpeechSynthesizerDelegate

    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer,
                                      stateDidChange newState: PublicationSpeechSynthesizer.State) {
        guard synthesizer === self.synthesizer, isRunning else { return }
        switch newState {
        case .stopped:
            isRunning = false
            currentUtterance = nil
            currentRange = nil
            needsContextNavigation = false
            navigator?.apply(decorations: [], in: decorationGroup)
            state = .finished
        case let .paused(utterance):
            currentUtterance = utterance
            currentSpokenLocator = utterance.locator
            state = .paused(map(utterance))
        case let .playing(utterance, range: range):
            currentUtterance = utterance
            currentRange = range
            currentSpokenLocator = utterance.locator
            onSpokenLocator?(utterance.locator)
            state = .playing(map(utterance))
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

    private func map(_ utterance: PublicationSpeechSynthesizer.Utterance) -> SpeechUtterance {
        let anchor = anchorForLocator?(utterance.locator) ?? startingAnchor
        return SpeechUtterance(text: utterance.text, chapterIndex: anchor.chapterIndex, utf16Offset: nil,
                               wordRange: 0..<max(1, utterance.text.utf16.count),
                               chapterProgression: anchor.progression)
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

private extension SpeechPlaybackState {
    var isFailure: Bool { if case .failed = self { return true }; return false }
}
