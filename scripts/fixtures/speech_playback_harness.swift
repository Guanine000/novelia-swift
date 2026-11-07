import Foundation

// 平台桩只保存调用与投递事件；下方插入的状态机、任务取消与命令路由均为实际 App 源码。
protocol ObservableObject: AnyObject {}
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
    func stopSpeaking(at: SpeechBoundary) {}
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
    func pause() {}
    func stop() {}
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
    func setActive(_ active: Bool, options: Options = []) throws {}
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
struct Locator { var marker: Int = 0 }
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
    var decorations: [Decoration] = []
    func firstVisibleElementLocator() async -> Locator? {
        if delaysLocator { return await withCheckedContinuation { locatorWaiter = $0 } }
        return Locator()
    }
    func apply(decorations: [Decoration], in group: String) { self.decorations = decorations }
    func go(to locator: Locator) async -> Bool { follows += 1; return true }
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
    func stop() { delegate?.publicationSpeechSynthesizer(self, stateDidChange: .stopped) }
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
        let selectedReadium = ReadiumSpeechEngine(publication: Publication(), navigator: selectedNavigator)!
        selectedController.attach(selectedReadium)
        selectedController.start(from: selectedAnchor, readiumLocator: Locator(marker: 42))
        await wait { PublicationSpeechSynthesizer.instances.last?.starts == 1 }
        check(PublicationSpeechSynthesizer.instances.last?.lastLocator?.marker == 42 && selectedNavigator.locatorWaiter == nil,
              "Readium 选句直接使用选区 Locator 而非可见页")
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
