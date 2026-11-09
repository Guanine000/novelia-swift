import Foundation

// 平台桩只保存调用与投递事件；下方插入的状态机、任务取消与命令路由均为实际 App 源码。
protocol ObservableObject: AnyObject {}
struct Novel {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
let AVSpeechUtteranceMinimumSpeechRate: Float = 0
let AVSpeechUtteranceMaximumSpeechRate: Float = 1
let AVSpeechUtteranceDefaultSpeechRate: Float = 0.5
enum SpeechBoundary { case word, immediate }
final class AVSpeechSynthesisVoice {
    let identifier: String
    let name = "测试语音", language = "zh"
    init?(identifier: String) { self.identifier = identifier }
    static func speechVoices() -> [AVSpeechSynthesisVoice] { [] }
}
final class AVSpeechUtterance {
    let text: String
    var volume: Float = 1
    var pitchMultiplier: Float = 1
    var rate: Float = 0.5
    var voice: AVSpeechSynthesisVoice?
    init(string: String) { text = string }
}
protocol AVSpeechSynthesizerDelegate: AnyObject {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance)
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance)
}
final class AVSpeechSynthesizer {
    static var instances: [AVSpeechSynthesizer] = []
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    var spoken: [AVSpeechUtterance] = []
    init() { Self.instances.append(self) }
    func pauseSpeaking(at: SpeechBoundary) {}
    func continueSpeaking() {}
    var stopCount = 0
    func stopSpeaking(at: SpeechBoundary) { stopCount += 1 }
    func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance) }
    func finish(_ utterance: AVSpeechUtterance) { delegate?.speechSynthesizer(self, didFinish: utterance) }
    func range(_ utterance: AVSpeechUtterance, location: Int = 0) {
        delegate?.speechSynthesizer(self, willSpeakRangeOfSpeechString: NSRange(location: location, length: 1), utterance: utterance)
    }
}
protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
}
final class AVAudioPlayer {
    static var instances: [AVAudioPlayer] = []
    weak var delegate: (any AVAudioPlayerDelegate)?
    var playCount = 0
    init(data: Data) throws { Self.instances.append(self) }
    var volume: Float = 1
    var currentTime: TimeInterval = 0
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { playCount += 1; return true }
    var pauseCount = 0
    var stopCount = 0
    func pause() { pauseCount += 1 }
    func stop() { stopCount += 1 }
    func finish() { delegate?.audioPlayerDidFinishPlaying(self, successfully: true) }
}

let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionOptionKey = "options"
let AVAudioSessionRouteChangeReasonKey = "reason"
final class AVAudioSession: NSObject {
    enum Category { case playback }; enum Mode { case spokenAudio }; enum Policy { case longFormAudio }
    struct Options: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = Self(rawValue: 1) }
    enum InterruptionType: UInt { case began, ended }
    struct InterruptionOptions: OptionSet { let rawValue: UInt; static let shouldResume = Self(rawValue: 1) }
    enum RouteChangeReason: UInt { case oldDeviceUnavailable }
    static let interruptionNotification = Notification.Name("test-interruption")
    static let routeChangeNotification = Notification.Name("test-route")
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    func setCategory(_ category: Category, mode: Mode, policy: Policy) throws {}
    var deactivations = 0
    func setActive(_ active: Bool, options: Options = []) throws { if !active { deactivations += 1 } }
}
enum MPRemoteCommandHandlerStatus { case success }
class MPRemoteCommand {
    var isEnabled = false
    var handlers: [UUID: () -> MPRemoteCommandHandlerStatus] = [:]
    func addTarget(handler: @escaping (Int) -> MPRemoteCommandHandlerStatus) -> Any {
        let id = UUID(); handlers[id] = { handler(0) }; return id
    }
    func removeTarget(_ target: Any) { handlers.removeValue(forKey: target as! UUID) }
    func fire() { if isEnabled { for handler in handlers.values { _ = handler() } } }
}
final class MPRemoteCommandCenter {
    static let instance = MPRemoteCommandCenter()
    static func shared() -> MPRemoteCommandCenter { instance }
    let playCommand = MPRemoteCommand(), pauseCommand = MPRemoteCommand(), togglePlayPauseCommand = MPRemoteCommand()
    let nextTrackCommand = MPRemoteCommand(), previousTrackCommand = MPRemoteCommand()
}
final class MPNowPlayingInfoCenter {
    static let instance = MPNowPlayingInfoCenter()
    static func `default`() -> MPNowPlayingInfoCenter { instance }
    var nowPlayingInfo: [String: Any]?
}
let MPMediaItemPropertyTitle = "title", MPMediaItemPropertyArtist = "artist", MPMediaItemPropertyAlbumTitle = "album"
let MPNowPlayingInfoPropertyMediaType = "type", MPNowPlayingInfoPropertyPlaybackRate = "rate"
enum MPNowPlayingInfoMediaType: Int { case audio }
struct Locator: Codable {
    var marker: Int = 0
    func jsonString() throws -> String { String(data: try JSONEncoder().encode(self), encoding: .utf8)! }
}
struct Publication {}
final class UIColor {
    static let systemYellow = UIColor()
    func withAlphaComponent(_ alpha: Double) -> UIColor { self }
}
struct Decoration {
    struct Style { init(id: String) {} }
    let id: String, locator: Locator, style: Style
}
@MainActor final class EPUBNavigatorViewController {
    var locatorWaiter: CheckedContinuation<Locator?, Never>?
    var delaysLocator = false
    var follows = 0
    var lastGoLocator: Locator?
    var decorations: [Decoration] = []
    func firstVisibleElementLocator() async -> Locator? {
        if delaysLocator { return await withCheckedContinuation { locatorWaiter = $0 } }
        return Locator()
    }
    func apply(decorations: [Decoration], in group: String) { self.decorations = decorations }
    func go(to locator: Locator) async -> Bool { follows += 1; lastGoLocator = locator; return true }
}
@MainActor protocol PublicationSpeechSynthesizerDelegate: AnyObject {
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, stateDidChange state: PublicationSpeechSynthesizer.State)
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, utterance: PublicationSpeechSynthesizer.Utterance, didFailWithError error: PublicationSpeechSynthesizer.Error)
}
@MainActor final class PublicationSpeechSynthesizer {
    struct Voice { let identifier: String, name: String, language: String }
    struct Utterance { let text: String; let locator: Locator }
    enum State { case stopped, paused(Utterance), playing(Utterance, range: Locator?) }
    enum Error: Swift.Error { case test }
    struct Config { var voiceIdentifier: String? }
    static var instances: [PublicationSpeechSynthesizer] = []
    static func canSpeak(publication: Publication) -> Bool { true }
    var availableVoices: [Voice] = []
    var config = Config()
    weak var delegate: (any PublicationSpeechSynthesizerDelegate)?
    var starts = 0
    init?(publication: Publication) { Self.instances.append(self) }
    var lastLocator: Locator?
    func start(from locator: Locator?) { starts += 1; lastLocator = locator }
    var stops = 0
    func stop() { stops += 1; delegate?.publicationSpeechSynthesizer(self, stateDidChange: .stopped) }
    func pause() {}
    func resume() {}
    func previous() {}
    func next() {}
}

// ACTUAL_PLAYBACK_SOURCES

@MainActor final class PendingChapters {
    var waiters: [Int: CheckedContinuation<String, Swift.Error>] = [:]
    func text(_ chapter: Int) async throws -> String {
        try await withCheckedThrowingContinuation { waiters[chapter] = $0 }
    }
    func resolve(_ chapter: Int, _ text: String = "第一句。第二句。") { waiters.removeValue(forKey: chapter)!.resume(returning: text) }
    func fail(_ chapter: Int) { waiters.removeValue(forKey: chapter)!.resume(throwing: NSError(domain: "test", code: 1)) }
}
actor CatalogCloudSpeech: CloudSpeechSynthesizing {
    func audio(text: String, voice: String, rate: Double) async throws -> Data { Data([1,2,3]) }
    func voices() async throws -> [SpeechVoiceOption] {
        [.init(identifier: "en-US-AriaNeural", name: "Aria", language: "en-US")]
    }
}
actor PitchCloudSpeech: CloudSpeechSynthesizing {
    var pitches: [Double] = []
    var texts: [String] = []
    func audio(text: String, voice: String, rate: Double) async throws -> Data { Data([1,2,3]) }
    func synthesis(text: String, voice: String, rate: Double, pitch: Double) async throws -> CloudSpeechAudio {
        pitches.append(pitch); texts.append(text); return CloudSpeechAudio(data: Data([1,2,3]), boundaries: [])
    }
}
actor RecordingCloudSpeech: CloudSpeechSynthesizing {
    private(set) var calls = 0
    func audio(text: String, voice: String, rate: Double) async throws -> Data { calls += 1; return Data([1,2,3]) }
}
actor TimedCloudSpeech: CloudSpeechSynthesizing {
    func audio(text: String, voice: String, rate: Double) async throws -> Data { Data([1,2,3]) }
    func synthesis(text: String, voice: String, rate: Double) async throws -> CloudSpeechAudio {
        CloudSpeechAudio(data: Data([1,2,3]), boundaries: [
            .init(time: 0.1, duration: 0.8, text: "甲 乙。"),
            .init(time: 1.2, duration: 0.8, text: "第二句。")])
    }
}
struct TestTransientFailure: CloudSpeechRetryableError { var shouldRetry: Bool { true } }
actor FaultCloudSpeech: CloudSpeechSynthesizing {
    var calls = 0
    var remainingFailures: Int
    init(failures: Int) { remainingFailures = failures }
    func audio(text: String, voice: String, rate: Double) async throws -> Data {
        calls += 1
        if remainingFailures > 0 { remainingFailures -= 1; throw TestTransientFailure() }
        return Data([1,2,3])
    }
}
actor PrefetchCloudSpeech: CloudSpeechSynthesizing {
    var texts: [String] = []
    var voices: [String] = []
    var waiter: CheckedContinuation<Data, Error>?
    var waiting: Bool { waiter != nil }
    func audio(text: String, voice: String, rate: Double) async throws -> Data {
        texts.append(text); voices.append(voice)
        if texts.count == 2 { return try await withCheckedThrowingContinuation { waiter = $0 } }
        return Data([1,2,3])
    }
    func resolve() { waiter?.resume(returning: Data([1,2,3])); waiter = nil }
}
actor PendingCloudSpeech: CloudSpeechSynthesizing {
    private var waiter: CheckedContinuation<Data, Error>?
    var isWaiting: Bool { waiter != nil }
    func audio(text: String, voice: String, rate: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func resolve() { waiter?.resume(returning: Data([1,2,3])); waiter = nil }
}

let speechHarnessSuite = "SpeechHarness-\(UUID())"
let speechHarnessDefaults = UserDefaults(suiteName: speechHarnessSuite)!

@main struct SpeechRegressionTests {
    @MainActor static func drain() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        fatalError("异步测试条件超时")
    }
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        print("PASS: \(label)")
    }
    @MainActor static func main() async {
        defer { speechHarnessDefaults.removePersistentDomain(forName: speechHarnessSuite) }
        let ux = SpeechPlaybackController()
        let uxSystem = SystemSpeechEngine(chapterCount: 1) { _ in "第一句。第二句。第三句。" }
        ux.bookKey = "txt:ux-\(UUID())"
        ux.attach(uxSystem)
        ux.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        await wait { ux.state.isPlaying }
        ux.skipForward(); await drain()
        let previewToken = ux.beginVoicePreview()!
        check(!ux.state.isPlaying && ux.currentPlaybackAnchor.sourceUTF16Offset == 4, "试听暂停原书并保留当前句")
        ux.finishVoicePreview(previewToken, restore: true)
        check(ux.state.isPlaying && ux.state.utterance?.text == "第二句。", "试听结束继续原来正在播放的句子")
        ux.pause()
        let pausedPreview = ux.beginVoicePreview()!
        ux.finishVoicePreview(pausedPreview, restore: true)
        check(!ux.state.isPlaying && ux.state.utterance != nil, "原来暂停的书在试听后仍保持暂停")
        ux.resume()
        var previewCancellations = 0
        let cancelledPreview = ux.beginVoicePreview(cancel: { previewCancellations += 1 })!
        ux.stop(); ux.finishVoicePreview(cancelledPreview, restore: true)
        check(ux.state == .idle, "明确停止后旧试听回调不能恢复书籍")
        check(previewCancellations == 1 && !ux.ownsVoicePreview(cancelledPreview), "明确操作同时取消试听音频与恢复令牌")
        ux.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 12, startIndexHint: nil, sourceUTF16Offset: 4))
        await wait { ux.state.isPlaying }
        let leavingPreview = ux.beginVoicePreview()!
        ux.finishVoicePreview(leavingPreview, restore: false)
        check(!ux.state.isPlaying, "离开试听设置取消自动恢复")
        ux.resume()
        ux.suspendFollow(true)
        var jumpCount = 0
        ux.onJumpToSpoken = { jumpCount += 1 }
        ux.returnToSpoken()
        check(ux.followSuspended && jumpCount == 1, "返回朗读处只定位不擅自恢复跟读")
        ux.resumeFollowing()
        check(!ux.followSuspended && jumpCount == 2, "显式恢复跟读解除临时挂起并定位")
        ux.settings.followsReadingPosition = false; ux.suspendFollow(true); ux.resumeFollowing()
        check(ux.followSuspended && !ux.settings.followsReadingPosition && jumpCount == 2,
              "全局关闭跟读时不会被恢复按钮擅自打开")
        ux.settings.followsReadingPosition = true
        ux.pause()
        ux.changeEngine(to: .edge)
        let switchedCloudService = RecordingCloudSpeech()
        let switchedCloud = EdgeSpeechEngine(service: switchedCloudService, chapterCount: 1) { _ in "第一句。第二句。第三句。" }
        ux.attach(switchedCloud)
        check(!ux.state.isPlaying && ux.state.utterance?.utf16Offset == 4 && switchedCloud.state == .idle,
              "暂停时换引擎保留句子且不启动合成或发声")
        let initialRequests = await switchedCloudService.calls
        check(initialRequests == 0, "暂停换到云端不会提前发送正文")
        check(MPRemoteCommandCenter.shared().playCommand.isEnabled, "暂停换引擎后锁屏播放命令仍注册")
        MPRemoteCommandCenter.shared().playCommand.fire(); await wait { ux.state.isPlaying }
        check(ux.state.utterance?.text.hasPrefix("第二句。") == true, "暂停切换后锁屏播放从原句开始")
        check(ux.followSuspended, "换引擎和继续播放不擅自解除用户挂起的跟读")
        ux.changeEngine(to: .system)
        let switchedSystem = SystemSpeechEngine(chapterCount: 1) { _ in "第一句。第二句。第三句。" }
        ux.attach(switchedSystem); await wait { ux.state.isPlaying }
        check(ux.state.utterance?.text == "第二句。", "播放中换回本地自动继续当前句")
        let transferNavigator = EPUBNavigatorViewController(); transferNavigator.delaysLocator = true
        let transferReadium = ReadiumSpeechEngine(publication: Publication(), navigator: transferNavigator,
            anchorForLocator: { _ in SpeechAnchor(chapterIndex: 0, progression: 0.1, chapterUTF16Length: 0, startIndexHint: nil) },
            locatorForAnchor: { _ in Locator(marker: 73) })!
        ux.changeEngine(to: .readium); ux.attach(transferReadium)
        await wait { PublicationSpeechSynthesizer.instances.last?.lastLocator?.marker == 73 }
        check(transferNavigator.locatorWaiter == nil, "换到Readium使用收听锚点而不是当前可见页")
        transferReadium.publicationSpeechSynthesizer(PublicationSpeechSynthesizer.instances.last!,
            stateDidChange: .playing(.init(text: "第二句。", locator: Locator(marker: 73)), range: nil))
        ux.changeEngine(to: .edge)
        ux.attach(EdgeSpeechEngine(service: RecordingCloudSpeech(), chapterCount: 1) { _ in "第一句。第二句。第三句。" })
        await wait { ux.state.isPlaying }
        check(ux.state.utterance?.text.hasPrefix("第二句。") == true,
              "Readium换到云端用当前句核对源偏移而非近似比例")
        let stalePreview = ux.beginVoicePreview()!
        ux.changeEngine(to: .system)
        ux.attach(SystemSpeechEngine(chapterCount: 1) { _ in "第一句。第二句。第三句。" })
        ux.finishVoicePreview(stalePreview, restore: true)
        check(!ux.state.isPlaying, "切换引擎后旧试听不能恢复已替换会话")
        ux.skipForward(); await wait { ux.state.utterance?.text == "第三句。" }
        check(ux.state.utterance?.text == "第三句。", "暂停换引擎后跳句先准备锚点再执行目标操作")
        ux.stop()
        var stages: [String] = []
        let staged = EdgeSpeechEngine(service: RecordingCloudSpeech(), chapterCount: 1) { _ in "阶段验证。" }
        staged.onStateChange = { state in if state == .preparing { stages.append(staged.preparationMessage) } }
        await staged.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        check(stages.contains(where: { $0.contains("加载朗读章节") }) && stages.contains(where: { $0.contains("请求Edge语音") }),
              "准备反馈区分章节加载与在线音频请求")
        staged.stop(); staged.onStateChange = nil
        SpeechSettingsStore().save(.default)
        let preparing = SpeechPlaybackController()
        preparing.bookKey = "txt:preparing-\(UUID())"
        preparing.attach(SystemSpeechEngine(chapterCount: 1) { _ in "准备中的正文。" })
        preparing.start(from: SpeechAnchor(chapterIndex: 0, progression: 0.4, chapterUTF16Length: 0, startIndexHint: nil))
        let preparingHandoff = SpeechHandoffStore()
        preparingHandoff.adopt(preparing)
        preparingHandoff.requestOpen()
        check(preparingHandoff.takePendingResume(bookKey: preparing.bookKey!)?.anchor.progression == 0.4,
              "首次准备阶段无存档也能从迷你条返回起播位置")
        check(SpeechResumeStore().load(bookKey: preparing.bookKey!) == nil,
              "准备阶段返回不会把未播放的位置覆盖进续听存档")
        let resumeSuite = "ResumeHarness-\(UUID())"
        let resumeDefaults = UserDefaults(suiteName: resumeSuite)!
        defer { resumeDefaults.removePersistentDomain(forName: resumeSuite) }
        let resumeStore = SpeechResumeStore(defaults: resumeDefaults)
        let resuming = SpeechPlaybackController(resumeStore: resumeStore)
        resuming.bookKey = "txt:restart"
        resuming.settings.followsReadingPosition = false
        var progressSaves = [SpeechResumePoint]()
        resuming.onProgressSave = { progressSaves.append($0) }
        let resumeEngine = SystemSpeechEngine(chapterCount: 2) { _ in "第一句。第二句。" }
        resuming.attach(resumeEngine)
        resuming.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        await wait { resuming.state.isPlaying }
        resuming.skipForward(); await drain()
        check(resuming.currentPlaybackAnchor.sourceUTF16Offset == 4 && resuming.currentPlaybackAnchor.progression > 0.4,
              "实时续听比例随句首前进")
        check(resumeStore.load(bookKey: "txt:restart")?.sourceUTF16Offset == 0, "同章逐句变化保持写盘节流")
        resuming.pause()
        check(resumeStore.load(bookKey: "txt:restart")?.sourceUTF16Offset == 4, "暂停立即补存最新句首")
        check(progressSaves.last?.sourceUTF16Offset == 4, "关闭跟读仍按实际朗读位置保存书籍进度")
        let progressSaveCount = progressSaves.count
        let pausedAt = resumeStore.load(bookKey: "txt:restart")?.updatedAt
        resuming.flushResumePoint()
        check(resumeStore.load(bookKey: "txt:restart")?.updatedAt == pausedAt, "重复暂停或后台补存不重复写盘")
        check(progressSaves.count == progressSaveCount, "重复补存不重复通知书籍进度")
        resuming.resume(); resuming.skipForward()
        await wait { resuming.state.utterance?.chapterIndex == 1 }
        resuming.skipForward(); await drain()
        resuming.stop()
        let stoppedPoint = resumeStore.load(bookKey: "txt:restart")!
        check(stoppedPoint.chapterIndex == 1 && stoppedPoint.sourceUTF16Offset == 4, "跨章停止保存新章当前句而非旧起播锚点")
        let restored = SpeechPlaybackController(resumeStore: resumeStore)
        restored.bookKey = "txt:restart"; restored.refreshSavedResume()
        let restoredEngine = SystemSpeechEngine(chapterCount: 2) { _ in "第一句。第二句。" }
        restored.attach(restoredEngine)
        check(resumeStore.load(bookKey: "txt:restart") == stoppedPoint, "重建引擎不覆盖上次续听位置")
        restored.start(from: restored.savedResume!.anchor)
        await wait { restored.state.isPlaying }
        check(restored.state.utterance?.chapterIndex == 1 && restored.state.utterance?.text == "第二句。",
              "重新创建控制器后从跨章保存的句子恢复")
        restored.skipBackward(); await drain(); restored.flushResumePoint()
        check(resumeStore.load(bookKey: "txt:restart")?.sourceUTF16Offset == 0, "后台补存当前位置并支持向前跳句")
        restored.stop()
        let handoffController = SpeechPlaybackController()
        handoffController.bookKey = "epub:hash"
        handoffController.bookRoute = .library("wenku:record")
        let handoffEngine = SystemSpeechEngine(chapterCount: 1) { _ in "第一句。第二句。" }
        handoffController.attach(handoffEngine)
        handoffController.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        await wait { handoffController.state.isPlaying }
        handoffController.skipForward()
        await drain()
        let handoff = SpeechHandoffStore()
        handoff.adopt(handoffController)
        handoff.requestOpen()
        if case .library(let key) = handoff.openRequest?.route {
            check(key == "wenku:record", "返回请求区分书库身份与正文哈希")
        } else { check(false, "返回请求保留书库身份") }
        let firstRequest = handoff.openRequest
        handoff.requestOpen()
        check(handoff.openRequest != firstRequest, "连续点击产生独立返回请求")
        check(handoff.takePendingResume(bookKey: "epub:other") == nil && handoff.session != nil,
              "错误书籍不消费返回请求或停止播放")
        let expectedOffset = handoffController.state.utterance?.utf16Offset
        let playback = handoff.takePendingResume(bookKey: "epub:hash")
        check(playback?.anchor.sourceUTF16Offset == expectedOffset && expectedOffset != nil,
              "返回书内保存实时朗读句偏移")
        check(handoff.session == nil && handoff.openRequest == nil && !handoffController.isActive,
              "新阅读器接管时停止旧会话并清除请求")
        check(handoff.takePendingResume(bookKey: "epub:hash") == nil, "续播请求只能消费一次")
        // 返回仍在运行的书籍时保留底层对象，句内进度和音频时间均不能重置。
        let liveSystem = SpeechPlaybackController()
        liveSystem.bookKey = "epub:live-system"
        let originalSystem = SystemSpeechEngine(chapterCount: 1) { _ in "这是一句还没有读完的长句。下一句。" }
        liveSystem.attach(originalSystem)
        liveSystem.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        await wait { liveSystem.state.isPlaying }
        let synthesizer = AVSpeechSynthesizer.instances.last!
        synthesizer.range(synthesizer.spoken.last!, location: 4); await drain()
        let spokenCount = synthesizer.spoken.count, systemStops = synthesizer.stopCount
        let retainedSession = liveSystem.session
        let systemStore = SpeechHandoffStore(); systemStore.adopt(liveSystem); systemStore.requestOpen()
        let resumedSystem = SpeechPlaybackController(); resumedSystem.bookKey = liveSystem.bookKey
        var newPositions = 0
        resumedSystem.attach(SystemSpeechEngine(chapterCount: 1, onReadingPosition: { _, _ in newPositions += 1 }) { _ in "这是一句还没有读完的长句。下一句。" })
        let systemResult = systemStore.takePendingResume(bookKey: resumedSystem.bookKey!, into: resumedSystem)
        check(systemResult?.retainedPlayback == true && resumedSystem.state.isPlaying && !liveSystem.isActive,
              "系统返回书内直接接管运行中的合成器")
        check(synthesizer.spoken.count == spokenCount && synthesizer.stopCount == systemStops,
              "系统返回不stop或speak，保留句内位置不重读句首")
        check(resumedSystem.session === retainedSession, "返回保留锁屏会话与定时截止时间")
        synthesizer.range(synthesizer.spoken.last!, location: 6); await drain()
        check(newPositions > 0, "接管后逐词高亮回调连接新阅读器")
        liveSystem.stop()
        check(resumedSystem.state.isPlaying, "旧阅读页销毁不停止已移交的合成器")
        resumedSystem.stop()

        let liveCloud = SpeechPlaybackController(); liveCloud.bookKey = "epub:live-edge"
        let liveService = RecordingCloudSpeech()
        liveCloud.attach(EdgeSpeechEngine(service: liveService, chapterCount: 1) { _ in "云端正在播放这一句。下一句。" })
        liveCloud.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        await wait { liveCloud.state.isPlaying }
        let retainedPlayer = AVAudioPlayer.instances.last!
        retainedPlayer.currentTime = 2.75
        let cloudStops = retainedPlayer.stopCount, cloudPauses = retainedPlayer.pauseCount
        let cloudCalls = await liveService.calls
        let audioDeactivations = AVAudioSession.instance.deactivations
        let cloudStore = SpeechHandoffStore(); cloudStore.adopt(liveCloud); cloudStore.requestOpen()
        let resumedCloud = SpeechPlaybackController(); resumedCloud.bookKey = liveCloud.bookKey
        resumedCloud.attach(EdgeSpeechEngine(service: liveService, chapterCount: 1) { _ in "旧临时正文" })
        resumedCloud.attach(EdgeSpeechEngine(service: liveService, chapterCount: 1) { _ in "云端正在播放这一句。下一句。" })
        check(AVAudioSession.instance.deactivations == audioDeactivations,
              "新阅读器空闲引擎重建不关闭正在播放的音频会话")
        let cloudResult = cloudStore.takePendingResume(bookKey: resumedCloud.bookKey!, into: resumedCloud)
        await drain()
        check(cloudResult?.retainedPlayback == true && resumedCloud.state.isPlaying,
              "Edge返回书内仍在播放，不隐式暂停")
        let remainingCalls = await liveService.calls
        check(retainedPlayer.currentTime == 2.75 && retainedPlayer.stopCount == cloudStops
              && retainedPlayer.pauseCount == cloudPauses && remainingCalls == cloudCalls,
              "Edge接管保留currentTime，不暂停不重取音频")
        resumedCloud.pause()
        cloudStore.adopt(resumedCloud); cloudStore.requestOpen()
        let pausedReceiver = SpeechPlaybackController(); pausedReceiver.bookKey = resumedCloud.bookKey
        pausedReceiver.attach(EdgeSpeechEngine(service: liveService, chapterCount: 1) { _ in "云端正在播放这一句。下一句。" })
        _ = cloudStore.takePendingResume(bookKey: pausedReceiver.bookKey!, into: pausedReceiver)
        check(!pausedReceiver.state.isPlaying && pausedReceiver.state.utterance != nil,
              "返回时原本暂停仍保持暂停")
        pausedReceiver.play()
        check(pausedReceiver.state.isPlaying && retainedPlayer.currentTime == 2.75,
              "接管后继续使用原音频播放器恢复")
        pausedReceiver.stop()

        let localReadium = SpeechPlaybackController(); localReadium.bookKey = "epub:live-readium"
        let oldNavigator = EPUBNavigatorViewController()
        let localReadiumEngine = ReadiumSpeechEngine(publication: Publication(), navigator: oldNavigator)!
        localReadium.attach(localReadiumEngine)
        localReadium.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        await wait { PublicationSpeechSynthesizer.instances.last!.starts == 1 }
        let localSynth = PublicationSpeechSynthesizer.instances.last!
        localReadiumEngine.publicationSpeechSynthesizer(localSynth,
            stateDidChange: .playing(.init(text: "Readium当前句正在中间朗读。", locator: Locator(marker: 105)), range: Locator(marker: 106)))
        await drain()
        let startsBeforeReturn = localSynth.starts, stopsBeforeReturn = localSynth.stops
        let readiumStore = SpeechHandoffStore(); readiumStore.adopt(localReadium); readiumStore.requestOpen()
        let newReadiumController = SpeechPlaybackController(); newReadiumController.bookKey = localReadium.bookKey
        let newNavigator = EPUBNavigatorViewController()
        let newReadiumEngine = ReadiumSpeechEngine(publication: Publication(), navigator: newNavigator)!
        var reboundLocator: Locator?
        newReadiumEngine.onSpokenLocator = { reboundLocator = $0 }
        newReadiumController.attach(newReadiumEngine)
        let localResult = readiumStore.takePendingResume(bookKey: newReadiumController.bookKey!, into: newReadiumController)
        await drain()
        check(localResult?.retainedPlayback == true && newReadiumController.state.isPlaying,
              "本地Readium返回接管原官方合成器而非Locator重起播")
        check(localSynth.starts == startsBeforeReturn && localSynth.stops == stopsBeforeReturn,
              "Readium句中返回不stop/start，不重读句首")
        check(newNavigator.lastGoLocator?.marker == 106 && reboundLocator?.marker == 105,
              "Readium新阅读页定位到当前词范围并接收当前句Locator")
        check(!newNavigator.decorations.isEmpty && oldNavigator.decorations.isEmpty,
              "Readium高亮从旧导航器移交新导航器")
        localReadium.stop()
        check(localSynth.stops == stopsBeforeReturn && newReadiumController.state.isPlaying,
              "旧Readium阅读模型退出不停止已接管的官方合成器")
        localReadiumEngine.publicationSpeechSynthesizer(localSynth,
            stateDidChange: .playing(.init(text: "下一句继续。", locator: Locator(marker: 205)), range: Locator(marker: 206)))
        check(newReadiumController.currentSentence == "下一句继续。" && reboundLocator?.marker == 205,
              "原Readium合成器后续事件驱动新控制器与新页面")
        newReadiumController.pause()
        readiumStore.adopt(newReadiumController); readiumStore.requestOpen()
        let pausedReadium = SpeechPlaybackController(); pausedReadium.bookKey = newReadiumController.bookKey
        let pausedNavigator = EPUBNavigatorViewController()
        pausedReadium.attach(ReadiumSpeechEngine(publication: Publication(), navigator: pausedNavigator)!)
        let pausedReadiumResult = readiumStore.takePendingResume(bookKey: pausedReadium.bookKey!, into: pausedReadium)
        await drain()
        check(pausedReadiumResult?.retainedPlayback == true && !pausedReadium.state.isPlaying
              && pausedReadium.state.utterance != nil && localSynth.starts == startsBeforeReturn,
              "暂停的Readium返回保持暂停且不重新合成")
        check(pausedNavigator.lastGoLocator?.marker == 206, "暂停Readium返回同样只定位页面")
        pausedReadium.stop()

        let visibleAnchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 8,
                                        startIndexHint: nil, sourceUTF16Offset: 4, startsAtVisibleOffset: true)
        let visibleSystem = SystemSpeechEngine(chapterCount: 1) { _ in "页面前半后半句。" }
        await visibleSystem.start(from: visibleAnchor)
        check(AVSpeechSynthesizer.instances.last!.spoken.last!.text == "后半句。", "系统从页首长句中部精确起播")
        visibleSystem.stop()
        let visibleService = PitchCloudSpeech()
        let visibleEdge = EdgeSpeechEngine(service: visibleService, chapterCount: 1) { _ in "页面前半后半句。" }
        await visibleEdge.start(from: visibleAnchor)
        let visibleTexts = await visibleService.texts
        check(visibleTexts == ["后半句。"], "Edge 合成请求从当前页可见偏移起播")
        visibleEdge.stop()
        let catalogSuite = "CatalogHarness-\(UUID())"
        let catalogDefaults = UserDefaults(suiteName: catalogSuite)!
        let catalogFactory = AppSpeechEngineFactory(service: CatalogCloudSpeech(), defaults: catalogDefaults)
        let catalog = try! await catalogFactory.refreshVoices()
        check(catalog.contains(where: { $0.identifier == "en-US-AriaNeural" })
              && SpeechSettingsStore(defaults: catalogDefaults).edgeVoices == catalog,
              "音色目录通过注入服务与App工厂写入同一偏好存储")
        catalogDefaults.removePersistentDomain(forName: catalogSuite)
        var sound = SpeechSettings.default; sound.volume = 0.25; sound.pitch = 1
        let soundSystem = SystemSpeechEngine(chapterCount: 1) { _ in "音量音高测试。" }
        soundSystem.update(settings: sound)
        let soundAnchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil)
        await soundSystem.start(from: soundAnchor)
        let soundUtterance = AVSpeechSynthesizer.instances.last!.spoken.last!
        check(soundUtterance.volume == 0.25 && soundUtterance.pitchMultiplier == 2, "系统独立音量与音高作用于实际utterance")
        soundSystem.stop()
        let pitchService = PitchCloudSpeech()
        let soundCloud = EdgeSpeechEngine(service: pitchService, chapterCount: 1) { _ in (0..<600).map { "声音缓存\($0)。" }.joined() }
        await soundCloud.start(from: soundAnchor)
        let soundPlayer = AVAudioPlayer.instances.last!
        soundCloud.update(settings: sound)
        check(soundPlayer.volume == 0.25, "Edge 音量立即作用于当前播放器")
        soundCloud.skipForward(); await wait { soundCloud.state.isPlaying }
        soundCloud.skipBackward(); await wait { soundCloud.state.isPlaying }
        let soundPitches = await pitchService.pitches
        check(soundPitches == [0,1,1], "音高进入合成和缓存键，改变后不复用旧音高音频")
        soundCloud.stop()
        let selectedAnchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0,
                                         startIndexHint: nil, sourceUTF16Offset: 4)
        let selectedSystem = SystemSpeechEngine(chapterCount: 1) { _ in "第一句。第二句。第三句。" }
        await selectedSystem.start(from: selectedAnchor)
        check(selectedSystem.state.utterance?.text == "第二句。", "系统选句起播使用源偏移而不是当前页开头")
        selectedSystem.stop()
        let selectedCloud = EdgeSpeechEngine(service: RecordingCloudSpeech(), chapterCount: 1) { _ in "第一句。第二句。第三句。" }
        await selectedCloud.start(from: selectedAnchor)
        check(selectedCloud.state.utterance?.text.hasPrefix("第二句。") == true, "Edge 选句强制分段边界并从所选句开始")
        selectedCloud.stop()
        let selectedController = SpeechPlaybackController()
        let selectedNavigator = EPUBNavigatorViewController(); selectedNavigator.delaysLocator = true
        let selectedReadium = ReadiumSpeechEngine(publication: Publication(), navigator: selectedNavigator,
            anchorForLocator: { locator in
                SpeechAnchor(chapterIndex: locator.marker == 84 ? 3 : 0, progression: 0.65,
                             chapterUTF16Length: 0, startIndexHint: nil)
            })!
        selectedController.attach(selectedReadium)
        selectedController.start(from: selectedAnchor, readiumLocator: Locator(marker: 42))
        await wait { PublicationSpeechSynthesizer.instances.last?.starts == 1 }
        check(PublicationSpeechSynthesizer.instances.last?.lastLocator?.marker == 42 && selectedNavigator.locatorWaiter == nil,
              "Readium 选句直接使用选区 Locator 而非可见页")
        selectedController.bookKey = "online:sample"
        selectedController.bookRoute = .online(Novel())
        selectedReadium.publicationSpeechSynthesizer(PublicationSpeechSynthesizer.instances.last!,
            stateDidChange: .playing(.init(text: "当前句", locator: Locator(marker: 84)), range: nil))
        handoff.adopt(selectedController)
        handoff.requestOpen()
        if case .online = handoff.openRequest?.route {
            check(true, "在线返回请求保留小说导航描述")
        } else { check(false, "在线返回请求保留小说导航描述") }
        selectedController.pause()
        // 平台桩不自动发暂停回调，直接调用停止前补存验证实际保存逻辑。
        selectedController.flushResumePoint()
        let readiumSaved = SpeechResumeStore().load(bookKey: "online:sample")
        check(readiumSaved?.chapterIndex == 3 && readiumSaved?.progression == 0.65,
              "Readium 根据当前Locator保存真实章号和比例")
        check(readiumSaved?.locatorJSON?.contains("84") == true, "Readium 当前句Locator写入持久化续听记录")
        let readiumPlayback = handoff.takePendingResume(bookKey: "online:sample")
        check(readiumPlayback?.locator?.marker == 84, "Readium 返回使用当前句 Locator 而非旧可见页")
        selectedController.stop()
        var selectionWaiter: CheckedContinuation<(SpeechAnchor, Locator?)?, Never>?
        selectedController.startSelection { await withCheckedContinuation { selectionWaiter = $0 } }
        await wait { selectionWaiter != nil }
        selectedController.stop(); selectionWaiter?.resume(returning: (selectedAnchor, Locator(marker: 43))); await drain()
        check(selectedController.state == .idle, "停止后迟到的选区解析不能起播")
        var reported: SpeechReadingPosition?
        var cleared = 0
        let following = SystemSpeechEngine(chapterCount: 1, onReadingPosition: { position, _ in
            reported = position
            if position == nil { cleared += 1 }
        }) { _ in "  甲   乙  。" }
        await following.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        let followingSynth = AVSpeechSynthesizer.instances.last!
        check(following.capabilities.contains(.readingFollow) && reported?.sentenceRange == 2..<10,
              "系统跟读使用未折叠空白的原文范围")
        followingSynth.range(followingSynth.spoken.last!, location: 2)
        await wait { reported?.currentOffset == 6 }
        check(reported?.chapterUTF16Length == 10, "词级回调映射回原文字符位置")
        following.stop()
        check(reported == nil && cleared > 0, "停止清除跟读高亮")
        var cloudPosition: SpeechReadingPosition?
        let timedCloud = EdgeSpeechEngine(service: TimedCloudSpeech(), chapterCount: 1,
                                         onReadingPosition: { position, _ in cloudPosition = position }) { _ in "  甲   乙。\n第二句。" }
        await timedCloud.start(from: SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil))
        let timedPlayer = AVAudioPlayer.instances.last!
        timedPlayer.currentTime = 0.05; timedCloud.refreshProgress()
        check(cloudPosition == nil, "Edge 首个真实时间点前不伪造高亮")
        timedPlayer.currentTime = 0.2; timedCloud.refreshProgress()
        check(cloudPosition?.sentenceRange == 2..<8, "Edge 时间轴映射折叠空白后的原文句子")
        timedCloud.pause(); timedPlayer.currentTime = 1.5; timedCloud.refreshProgress()
        check(cloudPosition?.sentenceRange == 2..<8, "Edge 暂停保留当前句且不推进")
        timedCloud.resume(); timedCloud.refreshProgress()
        check(cloudPosition?.sentenceRange == 9..<13 && timedCloud.state.utterance?.text == "第二句。", "Edge 第二句按播放器时间推进并显示当前句")
        timedCloud.skipBackward()
        check(timedCloud.state.utterance?.text == "甲 乙。" && AVAudioPlayer.instances.last === timedPlayer,
              "Edge 上一句在同一音频内定位而非重新合成")
        timedCloud.skipForward()
        check(timedCloud.state.utterance?.text == "第二句。", "Edge 下一句使用真实时间轴")
        timedCloud.stop(); timedCloud.refreshProgress()
        check(cloudPosition == nil && timedCloud.state == .idle, "Edge 停止清除高亮和时间轴")
        let bufferService = PrefetchCloudSpeech()
        let bufferEngine = EdgeSpeechEngine(service: bufferService, chapterCount: 1) { _ in (0..<600).map { "缓冲句子\($0)。" }.joined() }
        var bufferSettings = SpeechSettings.default; bufferSettings.edgePrefetchEnabled = true
        bufferEngine.update(settings: bufferSettings)
        let bufferAnchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil)
        await bufferEngine.start(from: bufferAnchor)
        for _ in 0..<10000 { if await bufferService.waiting { break }; await Task.yield() }
        let prefetchWaiting = await bufferService.waiting
        check(prefetchWaiting, "开启预取后播放期间提前准备下一段")
        let priorPlayers = AVAudioPlayer.instances.count
        bufferEngine.stop(); await bufferService.resolve(); await drain()
        check(bufferEngine.state == .idle && AVAudioPlayer.instances.count == priorPlayers,
              "停止后的预取迟到结果不会播放或恢复会话")
        let sharedService = PrefetchCloudSpeech()
        let sharedEngine = EdgeSpeechEngine(service: sharedService, chapterCount: 1) { _ in (0..<600).map { "预取合并\($0)。" }.joined() }
        sharedEngine.update(settings: bufferSettings); await sharedEngine.start(from: bufferAnchor)
        for _ in 0..<10000 { if await sharedService.waiting { break }; await Task.yield() }
        let expectedText = await sharedService.texts[1]
        AVAudioPlayer.instances.last!.finish(); await drain()
        await sharedService.resolve()
        await wait { sharedEngine.state.isPlaying && sharedEngine.state.utterance?.utf16Offset != 0 }
        let fetchedTexts = await sharedService.texts
        check(fetchedTexts.filter { $0 == expectedText }.count == 1, "播放下一段复用在途预取而非重复请求")
        sharedEngine.stop()
        let changedService = PrefetchCloudSpeech()
        let changedEngine = EdgeSpeechEngine(service: changedService, chapterCount: 1) { _ in (0..<600).map { "换音色\($0)。" }.joined() }
        changedEngine.update(settings: bufferSettings); await changedEngine.start(from: bufferAnchor)
        for _ in 0..<10000 { if await changedService.waiting { break }; await Task.yield() }
        var changedSettings = bufferSettings; changedSettings.edgeVoiceIdentifier = "zh-CN-YunxiNeural"
        changedEngine.update(settings: changedSettings)
        await changedService.resolve(); await drain()
        AVAudioPlayer.instances.last!.finish()
        await wait { changedEngine.state.isPlaying && changedEngine.state.utterance?.utf16Offset != 0 }
        let changedVoices = await changedService.voices
        check(changedVoices.count >= 3 && changedVoices[2] == "zh-CN-YunxiNeural", "更换音色取消旧预取并为下一段使用新音色")
        changedEngine.stop()
        let transient = FaultCloudSpeech(failures: 1)
        let resilient = EdgeSpeechEngine(service: transient, chapterCount: 2) { i in i == 0 ? "第一章。" : "第二章。" }
        await resilient.start(from: bufferAnchor)
        let recoveredCalls = await transient.calls
        check(resilient.state.isPlaying && recoveredCalls == 2, "临时合成错误仅有界重试一次")
        resilient.skipChapter(1); await wait { resilient.state.utterance?.chapterIndex == 1 }
        check(resilient.state.utterance?.text == "第二章。", "Edge 显式下一章从章首播放")
        resilient.stop()
        let persistent = FaultCloudSpeech(failures: 2)
        let retryEngine = EdgeSpeechEngine(service: persistent, chapterCount: 1) { _ in "不得漏掉的原段。" }
        await retryEngine.start(from: bufferAnchor)
        check(!retryEngine.state.isPlaying && retryEngine.retry(), "失败段保留并支持原地重试")
        await wait { retryEngine.state.isPlaying }
        check(retryEngine.state.utterance?.text == "不得漏掉的原段。", "失败段重试成功后不跳过正文")
        retryEngine.stop()
        let chapterSystem = SystemSpeechEngine(chapterCount: 2) { index in index == 0 ? "系统第一章。" : "系统第二章。" }
        await chapterSystem.start(from: bufferAnchor)
        chapterSystem.skipChapter(1); await wait { chapterSystem.state.utterance?.chapterIndex == 1 }
        check(chapterSystem.state.utterance?.text == "系统第二章。", "系统显式下一章从章首播放")
        chapterSystem.stop()
        let recordingCloud = RecordingCloudSpeech()
        let cloud = EdgeSpeechEngine(service: recordingCloud, chapterCount: 1) { _ in String(repeating: "云端分段正文。", count: 500) }
        let cloudAnchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil)
        await cloud.start(from: cloudAnchor)
        check(cloud.state.isPlaying && !cloud.capabilities.contains(.wordLevelProgress) && !cloud.capabilities.contains(.readingFollow),
              "云端音频播放成功且不声明虚假的精确跟读")
        let firstCloudText = cloud.state.utterance!.utf16Offset
        cloud.skipForward(); await wait { cloud.state.isPlaying && cloud.state.utterance?.utf16Offset != firstCloudText }
        let beforeBackCalls = await recordingCloud.calls
        cloud.skipBackward(); await wait { cloud.state.isPlaying && cloud.state.utterance?.utf16Offset == firstCloudText }
        let cachedCalls = await recordingCloud.calls
        check(cachedCalls == beforeBackCalls, "云端返回上一段复用会话音频缓存")
        cloud.pause(); check(!cloud.state.isPlaying, "云端播放器暂停")
        cloud.resume(); check(cloud.state.isPlaying, "云端播放器恢复")
        let oldPlayer = AVAudioPlayer.instances.last!
        cloud.stop(); oldPlayer.finish(); await drain()
        check(cloud.state == .idle, "停止后旧云端播放器回调不重新起播")
        await cloud.start(from: cloudAnchor)
        let restartedCalls = await recordingCloud.calls
        check(restartedCalls == cachedCalls + 1, "停止清空云端会话缓存")
        cloud.stop()

        let delayedCloud = PendingCloudSpeech()
        let delayedEngine = EdgeSpeechEngine(service: delayedCloud, chapterCount: 1) { _ in "延迟合成。" }
        let beforePlayers = AVAudioPlayer.instances.count
        let delayed = Task { await delayedEngine.start(from: cloudAnchor) }
        for _ in 0..<10000 { if await delayedCloud.isWaiting { break }; await Task.yield() }
        delayedEngine.stop(); await delayedCloud.resolve(); await delayed.value
        check(delayedEngine.state == .idle && AVAudioPlayer.instances.count == beforePlayers,
              "停止后迟到的云端音频不会创建播放器")
        let pendingPause = Task { await delayedEngine.start(from: cloudAnchor) }
        for _ in 0..<10000 { if await delayedCloud.isWaiting { break }; await Task.yield() }
        delayedEngine.pause(); await delayedCloud.resolve(); await pendingPause.value
        check(!delayedEngine.state.isPlaying && AVAudioPlayer.instances.last?.playCount == 0,
              "云端合成期间暂停不会在返回后偷偷播放")
        delayedEngine.resume(); check(delayedEngine.state.isPlaying, "云端合成期间暂停后可以恢复")
        delayedEngine.stop()

        let suite = "SpeechFactory-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let preferenceStore = SpeechSettingsStore(defaults: prefs)
        let factory = AppSpeechEngineFactory(service: recordingCloud, defaults: prefs)
        let localEngine = SystemSpeechEngine(chapterCount: 1) { _ in "本地正文。" }
        check(factory.select(local: localEngine, chapterCount: 1, chapterText: { _ in "一" }) === localEngine,
              "默认引擎工厂保留本地朗读，不创建云端引擎")
        var edgeSettings = SpeechSettings.default; edgeSettings.preferredEngine = .edge
        preferenceStore.save(edgeSettings)
        check(factory.select(local: localEngine, chapterCount: 1, chapterText: { _ in "一" }) === localEngine,
              "单改引擎偏好但未经同意不能启用联网")
        preferenceStore.setEdgeConsent(true)
        check(factory.select(local: localEngine, chapterCount: 1, chapterText: { _ in "一" })?.kind == .edge,
              "明确同意后引擎工厂接通 Edge")

        // 请求提供方故意忽略取消，验证代次守卫，而非依赖合作式取消。
        let pending = PendingChapters()
        let engine = SystemSpeechEngine(chapterCount: 2, chapterText: pending.text)
        let synth = AVSpeechSynthesizer.instances.last!
        let anchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0, startIndexHint: nil)
        let first = Task { await engine.start(from: anchor) }
        await wait { pending.waiters[0] != nil }
        engine.stop(); pending.resolve(0); await first.value
        check(engine.state == .idle && synth.spoken.isEmpty, "停止后迟到的正文不得起播")

        let old = Task { await engine.start(from: anchor) }
        await wait { pending.waiters[0] != nil }
        let secondAnchor = SpeechAnchor(chapterIndex: 1, progression: 0, chapterUTF16Length: 0, startIndexHint: nil)
        let newer = Task { await engine.start(from: secondAnchor) }
        await wait { pending.waiters[1] != nil }
        pending.resolve(1, "新会话。"); await newer.value
        pending.resolve(0, "旧会话。"); await old.value
        check(synth.spoken.map(\.text) == ["新会话。"], "重新起播后旧请求不能覆盖新会话")

        let previous = synth.spoken.last!
        engine.stop(); synth.finish(previous); synth.range(previous); await drain()
        check(engine.state == .idle && pending.waiters.isEmpty, "停止后的旧 delegate 不能跨章或更新状态")

        let retry = Task { await engine.start(from: anchor) }
        await wait { pending.waiters[0] != nil }
        pending.resolve(0); await retry.value
        let beforeSkip = synth.spoken.last!
        engine.skipForward()
        let afterSkip = synth.spoken.last!
        synth.finish(beforeSkip); synth.range(beforeSkip); await drain()
        check(synth.spoken.last === afterSkip && engine.state.utterance?.text == "第二句。", "跳句后的旧回调不能跳过当前句")
        synth.finish(afterSkip)
        await wait { pending.waiters[1] != nil }
        engine.stop(); pending.resolve(1); await drain()
        check(engine.state == .idle && synth.spoken.last === afterSkip, "跨章加载期间停止不会重新起播")

        let failTask = Task { await engine.start(from: anchor) }
        await wait { pending.waiters[0] != nil }
        engine.stop(); pending.fail(0); await failTask.value
        check(engine.state == .idle, "停止后迟到错误不能覆盖 idle")

        let navigator = EPUBNavigatorViewController(); navigator.delaysLocator = true
        let readium = ReadiumSpeechEngine(publication: Publication(), navigator: navigator)!
        let readiumSynth = PublicationSpeechSynthesizer.instances.last!
        let locating = Task { await readium.start(from: anchor) }
        await wait { navigator.locatorWaiter != nil }
        readium.stop(); navigator.locatorWaiter?.resume(returning: Locator()); await locating.value
        check(readium.state == .idle && readiumSynth.starts == 0, "Readium 定位期间停止不能迟到起播")
        navigator.delaysLocator = false
        await readium.start(from: anchor)
        let newReadiumSynth = PublicationSpeechSynthesizer.instances.last!
        readium.publicationSpeechSynthesizer(newReadiumSynth,
            stateDidChange: .playing(.init(text: "新 Readium 会话", locator: Locator()), range: nil))
        readium.publicationSpeechSynthesizer(readiumSynth, stateDidChange: .stopped)
        readium.publicationSpeechSynthesizer(readiumSynth,
            utterance: .init(text: "旧 Readium 会话", locator: Locator()), didFailWithError: .test)
        check(readium.state.isPlaying, "Readium 重新起播后旧合成器的状态与错误均被丢弃")
        readium.stop()
        check(readium.capabilities.contains(.readingFollow) && !engine.capabilities.contains(.readingFollow)
              && engine.capabilities.contains(.wordLevelProgress), "词级进度与阅读器跟读能力独立")

        var chapterWaiter: CheckedContinuation<Locator?, Never>?
        let chapterNavigator = EPUBNavigatorViewController()
        let chapterReadium = ReadiumSpeechEngine(publication: Publication(), navigator: chapterNavigator,
                                                chapterLocator: { _ in await withCheckedContinuation { chapterWaiter = $0 } })!
        chapterReadium.skipChapter(1)
        await wait { chapterWaiter != nil }
        chapterReadium.stop(); chapterWaiter?.resume(returning: Locator()); await drain()
        check(chapterReadium.state == .idle && chapterNavigator.follows == 0,
              "Readium 停止使迟到章节定位失效")
        let readyNavigator = EPUBNavigatorViewController()
        let readyReadium = ReadiumSpeechEngine(publication: Publication(), navigator: readyNavigator,
                                              chapterLocator: { _ in Locator() })!
        readyReadium.skipChapter(1)
        await wait { PublicationSpeechSynthesizer.instances.last?.starts == 1 }
        check(readyNavigator.follows == 1 && readyReadium.capabilities.contains(.chapterNavigation),
              "Readium 章节定位完成后从目标章节起播")
        readyReadium.stop()
        let controller = SpeechPlaybackController()
        let controllerPending = PendingChapters()
        let controlled = SystemSpeechEngine(chapterCount: 1, chapterText: controllerPending.text)
        controller.attach(controlled)
        controller.start(from: anchor)
        await wait { controllerPending.waiters[0] != nil }
        check(controller.showsQuickControls, "系统准备阶段显示悬浮控件")
        let staleObserver = controlled.onStateChange
        controller.stop()
        staleObserver?(.failed("旧状态"))
        check(!controller.showsQuickControls, "明确停止收起悬浮控件")
        controllerPending.resolve(0); await drain()
        check(controller.state == .idle && controlled.state == .idle, "控制器取消起播并拒绝旧观察者")

        controller.start(from: anchor)
        await wait { controllerPending.waiters[0] != nil }
        controllerPending.resolve(0, "读完。"); await wait { controller.state.isPlaying }
        let controllerSynth = AVSpeechSynthesizer.instances.last!
        controllerSynth.finish(controllerSynth.spoken.last!)
        await wait { controller.state == .finished }
        check(controller.showsQuickControls, "系统自然结束仍保留悬浮控件")
        MPRemoteCommandCenter.shared().playCommand.fire()
        await wait { controllerPending.waiters[0] != nil }
        controllerPending.resolve(0, "重播。"); await wait { controller.state.isPlaying }
        check(controllerSynth.spoken.last?.text == "重播。", "自然结束后真实锁屏 playCommand 重新起播")
        let count = controllerSynth.spoken.count
        MPRemoteCommandCenter.shared().playCommand.fire(); await drain()
        check(controllerSynth.spoken.count == count, "播放中的锁屏播放命令不重启")
        controller.pause(); MPRemoteCommandCenter.shared().playCommand.fire(); await drain()
        check(controller.state.isPlaying && controllerSynth.spoken.count == count, "锁屏播放从暂停恢复当前句")
        // 命令已经由系统投递，但主线程尚未执行时退出阅读器。
        MPRemoteCommandCenter.shared().playCommand.fire()
        controller.stop()
        await drain()
        check(controller.state == .idle && controllerPending.waiters.isEmpty,
              "注销前排队的远程播放命令不能恢复已停止会话")
        check(!MPRemoteCommandCenter.shared().playCommand.isEnabled && MPNowPlayingInfoCenter.default().nowPlayingInfo == nil,
              "停止后注销远程命令与锁屏信息")
        controller.skipForward(); controller.skipBackward(); await drain()
        check(controller.state == .idle && controllerSynth.spoken.count == count, "停止后上一句下一句均不隐式起播")
        print("Speech playback regression tests passed")
    }
}
