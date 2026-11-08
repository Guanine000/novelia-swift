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
