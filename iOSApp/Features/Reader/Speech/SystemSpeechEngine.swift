import AVFoundation
import Foundation
import SwiftUI
import struct ReadiumShared.Locator

// MARK: - 系统语音合成引擎

/// 用 `AVSpeechSynthesizer` 逐句朗读章节纯文本，覆盖 Readium 官方 TTS 之外的链路。
/// 文本由阅读器按需提供，切句与起播定位复用 Core 的 `SpeechText`；读完一章自动取下一章。
/// 合成器的 delegate 事件由独立桥接对象接回主线程，避免把 @MainActor 类型直接暴露给非隔离回调。
@MainActor
final class SystemSpeechEngine: SpeechEngine {
    let kind: SpeechEngineKind = .system
    let preparationMessage = "正在加载朗读章节…"
    /// 系统合成器支持语音、语速与逐词回调；backgroundAudio 由两份 Info.plist 的 audio 模式
    /// 与 `SpeechRemoteSession` 提供，两个引擎都声明该能力。
    var capabilities: SpeechCapabilities {
        var value: SpeechCapabilities = [.voiceSelection, .rateControl, .wordLevelProgress, .offline, .backgroundAudio, .chapterNavigation, .volumeControl, .pitchControl]
        if onReadingPosition != nil { value.insert(.readingFollow) }
        return value
    }

    var availableVoices: [SpeechVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.contains(".eloquence.") && !$0.identifier.contains(".novelty.") }
            .map { SpeechVoiceOption(identifier: $0.identifier, name: $0.name, language: $0.language) }
    }

    private(set) var state: SpeechPlaybackState = .idle {
        didSet { observer?(state) }
    }
    private var observer: ((SpeechPlaybackState) -> Void)?
    var onStateChange: ((SpeechPlaybackState) -> Void)? {
        get { observer }
        set { observer = newValue }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let bridge = SystemSynthesizerDelegate()
    let chapterCount: Int
    private(set) var chapterText: (Int) async throws -> String
    private var segments: [SpeechText.Segment] = []
    private var chapterIndex = 0
    private var segmentIndex = 0
    private var settings = SpeechSettings.default
    private var isPaused = false
    private var ownsAudioSession = false
    // 停止/重新起播使旧加载和旧 utterance 失效；取消请求不保证提供方立即返回。
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var activeUtterance: AVSpeechUtterance?
    private var chapterUTF16Length = 0
    private var readingPosition: SpeechReadingPosition?
    private(set) var onReadingPosition: ((SpeechReadingPosition?, SpeechSettings) -> Void)?

    init(chapterCount: Int,
         onReadingPosition: ((SpeechReadingPosition?, SpeechSettings) -> Void)? = nil,
         chapterText: @escaping (Int) async throws -> String) {
        self.onReadingPosition = onReadingPosition
        self.chapterCount = chapterCount
        self.chapterText = chapterText
        synthesizer.delegate = bridge
        bridge.onFinish = { [weak self] utterance in
            Task { @MainActor in self?.handleFinish(utterance) }
        }
        bridge.onRange = { [weak self] utterance, range in
            Task { @MainActor in self?.handleRange(range, utterance: utterance) }
        }
    }

    /// 保留合成器的句内进度，只替换新阅读页的数据和定位回调。
    func rebindReadingContext(to replacement: SystemSpeechEngine) {
        chapterText = replacement.chapterText
        onReadingPosition = replacement.onReadingPosition
    }

    func start(from anchor: SpeechAnchor) async {
        guard !Task.isCancelled else { return }
        stop()
        let generation = self.generation
        state = .preparing
        activateSession()
        await load(chapter: anchor.chapterIndex, progression: anchor.progression, generation: generation, sourceOffset: anchor.sourceUTF16Offset, exactVisibleStart: anchor.startsAtVisibleOffset, resumeText: anchor.resumeText)
    }

    func pause() {
        guard state.isPlaying else { return }
        isPaused = true
        synthesizer.pauseSpeaking(at: .word)
        if let current = state.utterance { state = .paused(current) }
    }

    func resume() {
        guard case .paused = state else { return }
        isPaused = false
        activateSession()
        synthesizer.continueSpeaking()
        if let current = state.utterance { state = .playing(current) }
    }

    func stop() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        activeUtterance = nil
        readingPosition = nil
        onReadingPosition?(nil, settings)
        isPaused = false
        synthesizer.stopSpeaking(at: .immediate)
        segments = []
        deactivateSession()
        state = .idle
    }

    func skipChapter(_ delta: Int) {
        let target = min(max(0, chapterCount - 1), max(0, chapterIndex + delta))
        let observer = self.observer
        self.observer = nil; stop(); self.observer = observer
        state = .preparing
        let generation = self.generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            self.activateSession()
            await self.load(chapter: target, progression: 0, generation: generation)
        }
    }
    func skipBackward() {
        guard state.utterance != nil else { return }
        activeUtterance = nil
        isPaused = false
        synthesizer.stopSpeaking(at: .immediate)
        segmentIndex = max(0, segmentIndex - 1)
        speakCurrent()
    }

    func skipForward() {
        guard state.utterance != nil else { return }
        activeUtterance = nil
        isPaused = false
        synthesizer.stopSpeaking(at: .immediate)
        segmentIndex += 1
        speakCurrent()
    }

    func update(settings: SpeechSettings) {
        // 语音与语速在下一句生效，正在播放的句子不中途改变。
        self.settings = settings.clamped()
        onReadingPosition?(readingPosition, self.settings)
    }

    // MARK: 队列

    private func load(chapter index: Int, progression: Double, generation: UUID, sourceOffset: Int? = nil, exactVisibleStart: Bool = false, resumeText: String? = nil) async {
        guard self.generation == generation, !Task.isCancelled else { return }
        state = .preparing
        guard index >= 0, index < chapterCount else {
            readingPosition = nil
            onReadingPosition?(nil, settings)
            deactivateSession()
            state = .finished
            return
        }
        do {
            let text = try await chapterText(index)
            guard self.generation == generation, !Task.isCancelled else { return }
            let sourceOffset = sourceOffset ?? resumeText.flatMap { SpeechText.selectedOffset($0, in: text, near: progression) }
            // 长章节切句放到后台，避免阻塞主线程。
            let parts = await Task.detached(priority: .userInitiated) {
                SpeechText.splitAtVisibleOffset(SpeechText.segments(in: text), offset: exactVisibleStart ? sourceOffset : nil)
            }.value
            guard self.generation == generation, !Task.isCancelled else { return }
            segments = parts
            chapterUTF16Length = text.utf16.count
            chapterIndex = index
            let computed = SpeechAnchor(chapterIndex: index, progression: progression,
                                        chapterUTF16Length: text.utf16.count, startIndexHint: nil, sourceUTF16Offset: sourceOffset)
            let resolved = computed.resolvedProgression(length: text.utf16.count)
            segmentIndex = SpeechText.startIndex(in: parts, chapterUTF16Length: text.utf16.count, progression: resolved)
            isPaused = false
            speakCurrent()
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            readingPosition = nil
            onReadingPosition?(nil, settings)
            deactivateSession()
            state = .failed("无法读取章节正文")
        }
    }

    private func speakCurrent() {
        guard segments.indices.contains(segmentIndex) else {
            // 空章节或读完一章都继续取下一章；超出章节数时 load 会置为 finished。
            let nextChapter = chapterIndex + 1
            let generation = self.generation
            state = .preparing
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                await self?.load(chapter: nextChapter, progression: 0, generation: generation)
            }
            return
        }
        let segment = segments[segmentIndex]
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.volume = Float(settings.volume)
        utterance.pitchMultiplier = Float(pow(2, settings.pitch))
        utterance.rate = Self.avRate(for: settings.rate)
        if let identifier = settings.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        }
        state = .playing(SpeechUtterance(text: segment.text, chapterIndex: chapterIndex,
                                         utf16Offset: segment.utf16Offset, wordRange: nil,
                                         chapterUTF16Length: chapterUTF16Length))
        activeUtterance = utterance
        reportReadingPosition(spokenOffset: 0)
        synthesizer.speak(utterance)
    }

    private func handleFinish(_ utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance, !isPaused else { return }
        activeUtterance = nil
        segmentIndex += 1
        speakCurrent()
    }

    private func handleRange(_ range: NSRange, utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance, case let .playing(current) = state else { return }
        reportReadingPosition(spokenOffset: range.location)
        let length = current.text.utf16.count
        let start = min(max(range.location, 0), max(0, length - 1))
        let end = min(length, start + max(1, range.length))
        state = .playing(SpeechUtterance(text: current.text, chapterIndex: chapterIndex,
                                         utf16Offset: current.utf16Offset,
                                         wordRange: start..<max(start + 1, end),
                                         chapterUTF16Length: chapterUTF16Length))
    }

    private func reportReadingPosition(spokenOffset: Int) {
        guard segments.indices.contains(segmentIndex) else { return }
        let segment = segments[segmentIndex]
        let position = SpeechReadingPosition(chapterIndex: chapterIndex, sentenceRange: segment.sourceRange,
                                             currentOffset: segment.sourceOffset(forSpokenOffset: spokenOffset),
                                             chapterUTF16Length: chapterUTF16Length)
        readingPosition = position
        onReadingPosition?(position, settings)
    }

    /// 归一化 0–1：0.5 对应系统默认语速，两端分别对应最小／最大语速。
    static func avRate(for normalized: Double) -> Float {
        let value = min(max(normalized, 0), 1)
        let lower = Double(AVSpeechUtteranceMinimumSpeechRate)
        let upper = Double(AVSpeechUtteranceMaximumSpeechRate)
        let middle = Double(AVSpeechUtteranceDefaultSpeechRate)
        return Float(value <= 0.5
                     ? lower + (middle - lower) * (value / 0.5)
                     : middle + (upper - middle) * ((value - 0.5) / 0.5))
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        do { try session.setActive(true); ownsAudioSession = true } catch {}
    }

    private func deactivateSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 只负责把 AVSpeechSynthesizerDelegate 的非隔离回调转发到主线程，不持有朗读状态。
private final class SystemSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: ((AVSpeechUtterance) -> Void)?
    var onRange: ((AVSpeechUtterance, NSRange) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        onRange?(utterance, characterRange)
    }
}

// MARK: - 各阅读器共用的朗读入口

/// 面板挂在阅读器宿主上，菜单关闭或顶栏隐藏都不会销毁正在展示的面板。
struct ReaderSpeechPresentation: ViewModifier {
    @EnvironmentObject private var services: AppServices
    @Environment(\.speechHandoff) private var speechHandoff
    @Environment(\.speechBookRoute) private var bookRoute
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: SpeechPlaybackController
    @Binding var isPresented: Bool
    let anchor: () -> SpeechAnchor
    let title: String
    /// 书籍身份与「回到朗读处」由宿主提供；不提供时功能按钮自动隐藏。
    var bookKey: String? = nil
    var isReady: Bool = true
    var chapterTitle: ((Int) -> String?)? = nil
    var jumpToSpoken: (() -> Void)? = nil
    var onResumeSaved: ((SpeechResumePoint) -> Void)? = nil
    /// 必须排在带默认值的参数之后、并以尾闭包传入。
    let makeEngine: @MainActor () -> (any SpeechEngine)?

    func body(content: Content) -> some View {
        content.environment(\.readerSpeechActions, ReaderSpeechActions(
            toggle: { controller.toggleHighlightedSpeech() },
            start: { selected in
                controller.bookTitle = title
                rebuild()
                controller.start(from: selected)
            }))
        .overlay(alignment: .bottom) {
            ReaderSpeechBar(controller: controller, openPanel: { isPresented = true })
        }
        // 进入阅读器即回收遗留的跨页会话；这里的控制器随之成为唯一会话。
        .onAppear {
            if speechHandoff?.openRequest == nil { speechHandoff?.release() }
            controller.bookRoute = bookRoute
            controller.bookKey = bookKey
            controller.onJumpToSpoken = jumpToSpoken
            controller.chapterTitleProvider = chapterTitle
            controller.refreshSavedResume()
        }
        .task(id: isReady ? bookKey : nil) {
            guard isReady, let bookKey else { return }
            controller.bookKey = bookKey
            controller.bookRoute = bookRoute
            controller.refreshSavedResume()
            controller.chapterTitleProvider = chapterTitle
            if speechHandoff?.pendingResume?.bookKey == bookKey {
                controller.bookTitle = title
                rebuild()
                if let playback = speechHandoff?.takePendingResume(bookKey: bookKey, into: controller), !playback.retainedPlayback {
                    controller.start(from: playback.anchor, readiumLocator: playback.locator)
                }
            }
        }
        .onValueChange(of: scenePhase) { _, phase in
            if phase != .active { controller.flushResumePoint() }
        }
        .onDisappear { controller.cancelVoicePreviewRecovery(); controller.flushResumePoint(); handOffOnExit() }
        .onValueChange(of: isPresented) { _, shown in
            if shown {
                controller.bookTitle = title
                controller.bookKey = bookKey
                controller.refreshSavedResume()
                if !controller.isAvailable || !controller.isActive { rebuild() }
            }
        }
        .sheet(isPresented: $isPresented) {
            SpeechControlView(controller: controller, session: controller.session,
                              anchor: anchor(), title: title, onEngineChange: rebuild,
                              onStart: { controller.start(from: anchor()) },
                              onResumeSaved: onResumeSaved)
        }
    }

    /// 退出阅读器：系统/云端引擎只依赖正文闭包，交给 App 迷你条继续；Readium 引擎绑定导航器，只能停止。
    private func handOffOnExit() {
        guard controller.isActive else { return }
        if controller.engineKind == .readium {
            controller.stop()
        } else {
            speechHandoff?.adopt(controller)
        }
    }
    private func rebuild() {
        controller.reloadSettings()
        let local = makeEngine()
        if let system = local as? SystemSpeechEngine {
            controller.attach(services.speech.select(local: system, chapterCount: system.chapterCount,
                                                     onReadingPosition: system.onReadingPosition,
                                                     chapterText: system.chapterText))
        } else { controller.attach(local) }
    }
}

/// 跨页面朗读会话：阅读器退出时把仍在播放的系统／云端引擎控制器移交到这里，
/// 由根视图的迷你条接管；同书返回时移交运行中的系统/云端音频对象，不重新起播。
/// Readium 官方引擎随阅读模型一并保留导航器。每台 App 只有一个活动会话。
@MainActor
final class SpeechHandoffStore: ObservableObject {
    @Published private(set) var session: SpeechPlaybackController?

    /// 阅读器退出时接管的会话。`retained` 用来保住引擎依赖的对象——
    /// Readium 官方引擎绑定导航器，模型被释放就会失效，必须一并保留。
    private var retained: AnyObject?

    /// 迷你条上「回到书内朗读处」的请求：由根视图切回书库、由书库打开对应书籍，
    /// 书籍打开后取走 `pendingResume` 并从该位置继续朗读（高亮随朗读就位）。
    struct OpenRequest: Hashable, Identifiable {
        let bookKey: String
        let route: SpeechBookRoute?
        let id = UUID()
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    struct PendingPlayback {
        let anchor: SpeechAnchor
        let locator: Locator?
        var retainedPlayback = false
    }
    private var pendingPlayback: PendingPlayback?
    @Published private(set) var openRequest: OpenRequest?
    private(set) var pendingResume: SpeechResumePoint?

    /// 发起打开请求；没有书籍身份时不处理。
    func requestOpen() {
        guard let bookKey = session?.bookKey, !bookKey.isEmpty else { return }
        // 优先用实时位置；没有实时位置再退回已落盘的续听记录。
        pendingResume = session?.currentResumePoint ?? session?.savedResume
        pendingPlayback = session.map { PendingPlayback(anchor: $0.currentPlaybackAnchor, locator: $0.currentSpokenLocator) }
        openRequest = OpenRequest(bookKey: bookKey, route: session?.bookRoute)
    }
    /// 新宿主优先接管同书的运行中音频；不能接管时才停止旧会话并按锚点重建。
    func takePendingResume(bookKey: String, into receiver: SpeechPlaybackController? = nil) -> PendingPlayback? {
        guard let pending = pendingResume, pending.bookKey == bookKey,
              let playback = pendingPlayback else { return nil }
        pendingResume = nil
        pendingPlayback = nil
        openRequest = nil
        var result = playback
        if let session, let receiver, receiver.adoptLivePlayback(from: session) {
            result.retainedPlayback = true
            clearIfSame(session)
        } else { release() }
        return result
    }
    func consumeOpenRequest() { openRequest = nil; pendingResume = nil; pendingPlayback = nil }

    func adopt(_ controller: SpeechPlaybackController, retained owner: AnyObject? = nil) {
        session = controller
        self.retained = owner
    }
    /// 阅读器接管前停止遗留会话；同一控制器回到阅读器时无需重复停止。
    func release() {
        guard let session else { return }
        session.stop()
        self.session = nil
        retained = nil
    }
    func clearIfSame(_ controller: SpeechPlaybackController) {
        guard session === controller else { return }
        session = nil
        retained = nil
    }
}

/// 导航身份独立于正文位置键；书库使用记录 ID，在线阅读保留打开时的小说描述。
enum SpeechBookRoute {
    case library(String)
    case online(Novel)
}
private struct SpeechBookRouteKey: EnvironmentKey {
    static let defaultValue: SpeechBookRoute? = nil
}
extension EnvironmentValues {
    var speechBookRoute: SpeechBookRoute? {
        get { self[SpeechBookRouteKey.self] }
        set { self[SpeechBookRouteKey.self] = newValue }
    }
}
/// 移交存储经环境传给各阅读器宿主，实例由 App 持有。
private struct SpeechHandoffKey: EnvironmentKey {
    static let defaultValue: SpeechHandoffStore? = nil
}
extension EnvironmentValues {
    var speechHandoff: SpeechHandoffStore? {
        get { self[SpeechHandoffKey.self] }
        set { self[SpeechHandoffKey.self] = newValue }
    }
}

/// 对已有正文附加句子底色；不改变正文、字体或字符偏移，保留选字与链接渲染入口。
enum SpeechTextHighlight {
    static func apply(_ range: Range<Int>?, text: String, to value: inout AttributedString) {
        guard let range, range.lowerBound >= 0, range.upperBound <= text.utf16.count,
              let stringRange = Range(NSRange(location: range.lowerBound, length: range.count), in: text),
              let lower = AttributedString.Index(stringRange.lowerBound, within: value),
              let upper = AttributedString.Index(stringRange.upperBound, within: value) else { return }
        value[lower..<upper].backgroundColor = Color.yellow.opacity(0.30)
        value[lower..<upper].link = URL(string: "novelia-speech://toggle")
    }
}
