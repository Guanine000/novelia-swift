import Foundation

/// 朗读引擎的统一契约：阅读界面只依赖这里的状态、能力与命令，不认识具体合成实现。
/// 首个引擎是 Readium 官方 TTS（可按 Locator 跟读），系统 AVSpeechSynthesizer 作为兜底；
/// 以后接入 Edge TTS、大模型 TTS 等云端引擎时只新增一个实现，朗读面板与阅读器无需改动。
/// 云端引擎合成的是音频流，通常没有词级进度、也不离线，因此用 capabilities 声明能力，界面据此降级。
/// 本文件属于 Domain，不引用界面框架、音频框架或具体客户端；状态回调由实现保证在主线程触发。

/// 引擎标识用字符串持久化，新增引擎时保留旧 rawValue，已保存的用户选择不能受枚举顺序影响。
enum SpeechEngineKind: String, CaseIterable, Sendable {
    case readium
    case system
    case edge
    /// 用户自备 OpenAI 兼容服务（地址／密钥／模型／音色）；旧客户端无法识别该 rawValue，会安全回落本地。
    case openai
}

/// 第三方 API 的密钥不进偏好文件，与本项目的会话凭据同样走 Keychain。
/// 测试与验证组装注入内存实现。
protocol SpeechAPIKeyStoring: Sendable {
    func readKey() -> String?
    func writeKey(_ value: String?)
}

/// OpenAI 兼容语音接口的公开预设音色；兼容服务的音色集各不相同，允许用户直接填写自定义名称。
enum OpenAISpeechVoices {
    static let presets: [SpeechVoiceOption] = [
        .init(identifier: "alloy", name: "Alloy", language: "多语言"),
        .init(identifier: "echo", name: "Echo", language: "多语言"),
        .init(identifier: "fable", name: "Fable", language: "多语言"),
        .init(identifier: "onyx", name: "Onyx", language: "多语言"),
        .init(identifier: "nova", name: "Nova", language: "多语言"),
        .init(identifier: "shimmer", name: "Shimmer", language: "多语言"),
    ]

    /// 预设加当前自定义音色；超出预设的选择必须始终出现在列表里，否则 Picker 无法回显。
    static func options(selected: String) -> [SpeechVoiceOption] {
        guard !selected.isEmpty, !presets.contains(where: { $0.identifier == selected }) else { return presets }
        return presets + [.init(identifier: selected, name: selected, language: "自定义")]
    }

    static func isValidVoice(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
    }
}

struct SpeechCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let volumeControl = SpeechCapabilities(rawValue: 1 << 8)
    static let pitchControl = SpeechCapabilities(rawValue: 1 << 9)
    static let voiceSelection = SpeechCapabilities(rawValue: 1 << 0)
    static let sentenceNavigation = SpeechCapabilities(rawValue: 1 << 7)
    static let chapterNavigation = SpeechCapabilities(rawValue: 1 << 6)
    static let rateControl = SpeechCapabilities(rawValue: 1 << 1)
    /// 能逐词报告播放位置，用于跟读高亮与自动翻页；云端音频流通常不具备。
    static let wordLevelProgress = SpeechCapabilities(rawValue: 1 << 2)
    static let backgroundAudio = SpeechCapabilities(rawValue: 1 << 3)
    /// 无需把正文发到网络即可合成。
    static let offline = SpeechCapabilities(rawValue: 1 << 4)
    /// 阅读器已接通高亮与翻页；仅有词级回调不代表能控制阅读界面。
    static let readingFollow = SpeechCapabilities(rawValue: 1 << 5)
}

struct SpeechVoiceOption: Equatable, Sendable, Codable {
    let identifier: String
    let name: String
    let language: String
}

struct SpeechSettings: Equatable, Sendable {
    var voiceIdentifier: String?
    /// 归一化语速 0–1，默认 0.5；各引擎映射到自身范围。
    var rate: Double
    /// 朗读位置变化时自动翻到对应页；只有支持词级进度的引擎能精确做到。
    var followsReadingPosition: Bool
    var highlightsSpokenText: Bool
    /// system/readium 保留本地自动路由；edge 需另有明确的联网同意。
    var preferredEngine: SpeechEngineKind
    /// 定时停止分钟数，0 表示关闭；每次起播重新计时。
    var sleepTimerMinutes: Int
    var edgeVoiceIdentifier: String = EdgeSpeechVoices.defaultIdentifier
    /// 明确开启后才会提前发送下一分段正文；旧用户不自动扩大已同意的上传范围。
    var edgePrefetchEnabled: Bool = false
    var volume: Double = 1
    /// -1…1 表示低到高，系统转换为0.5…2倍，Edge转换为-50…50Hz；不是跨引擎的物理等价值。
    var pitch: Double = 0
    /// 第三方 API（OpenAI 兼容）服务地址，如 `https://api.openai.com/v1`；密钥存 Keychain，不在这里。
    var openAIBaseURL: String = ""
    var openAIModel: String = "tts-1"
    var openAIVoice: String = OpenAISpeechVoices.presets[0].identifier

    static let `default` = SpeechSettings(voiceIdentifier: nil, rate: 0.5,
                                          followsReadingPosition: true, highlightsSpokenText: true,
                                          preferredEngine: .system, sleepTimerMinutes: 0)

    /// 定时停止只提供固定档位，外部写入的任意整数收敛到最近档位。
    static let sleepTimerOptions: [Int] = [0, 15, 30, 45, 60, 90]

    static func normalizedSleepTimer(_ minutes: Int) -> Int {
        guard minutes > 0 else { return 0 }
        return sleepTimerOptions.filter { $0 > 0 }
            .min { abs($0 - minutes) < abs($1 - minutes) } ?? 0
    }

    static func sleepTimerTitle(minutes: Int) -> String {
        minutes > 0 ? "\(minutes) 分钟" : "关闭"
    }

    /// 外部设置或旧版本存档可能越界，落到引擎能处理的范围而不是让合成器报错。
    func clamped() -> SpeechSettings {
        var value = self
        value.rate = min(max(rate.isFinite ? rate : 0.5, 0), 1)
        value.volume = min(1, max(0, volume.isFinite ? volume : 1))
        value.pitch = min(1, max(-1, pitch.isFinite ? pitch : 0))
        value.sleepTimerMinutes = Self.normalizedSleepTimer(sleepTimerMinutes)
        value.openAIBaseURL = Self.normalizedEndpoint(value.openAIBaseURL)
        value.openAIModel = Self.normalizedField(value.openAIModel, fallback: "tts-1")
        value.openAIVoice = Self.normalizedField(value.openAIVoice, fallback: OpenAISpeechVoices.presets[0].identifier)
        return value
    }

    /// 服务地址只保留协议与主机语义；非法或非 HTTPS 的输入清空，请求端据此判断是否已配置。
    static func normalizedEndpoint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 2_048, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return "" }
        return scheme == "https" ? trimmed : ""
    }

    static func normalizedField(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return fallback }
        return trimmed
    }
}

/// 起播位置。章内比例与 UTF-16 长度沿用进度、书签、书内搜索的口径；
/// Readium 引擎会把比例换算成 Locator，片段队列引擎直接用 startIndexHint。
struct SpeechAnchor: Equatable, Sendable {
    let chapterIndex: Int
    let progression: Double
    let chapterUTF16Length: Int
    var startIndexHint: Int?
    /// 选句起播使用源文本坐标，章节加载后再换算，避免把页内比例当作选区位置。
    var sourceUTF16Offset: Int? = nil
    var startsAtVisibleOffset: Bool = false
    func resolvedProgression(length: Int) -> Double {
        guard let offset = sourceUTF16Offset, length > 0 else { return progression }
        return (Double(min(max(0, offset), length - 1)) + 0.1) / Double(length)
    }

    /// 片段队列引擎的起播片段下标；与 `SpeechText.startIndex` 同一套换算。
    func startIndex(in segments: [SpeechText.Segment]) -> Int {
        SpeechText.startIndex(in: segments, chapterUTF16Length: chapterUTF16Length,
                              progression: progression)
    }
}

/// 系统 TTS 的阅读位置：句子与当前词均使用阅读器源文本的 UTF-16 坐标。
struct SpeechReadingPosition: Equatable, Sendable {
    let chapterIndex: Int
    let sentenceRange: Range<Int>
    let currentOffset: Int
    let chapterUTF16Length: Int
}

struct SpeechUtterance: Equatable, Sendable {
    let text: String
    let chapterIndex: Int
    let utf16Offset: Int?
    /// 当前朗读到的词范围，云端引擎为 nil。
    let wordRange: Range<Int>?

    /// 只有声明了词级进度的引擎才提供可高亮范围；界面据此隐藏跟读高亮。
    func highlightRange(for capabilities: SpeechCapabilities) -> Range<Int>? {
        guard capabilities.contains(.wordLevelProgress) else { return nil }
        return wordRange
    }
}

enum SpeechPlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case playing(SpeechUtterance)
    case paused(SpeechUtterance)
    case finished
    case failed(String)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var utterance: SpeechUtterance? {
        switch self {
        case let .playing(utterance), let .paused(utterance): return utterance
        default: return nil
        }
    }
}

/// 一个可替换的合成实现。网络请求、凭据与缓存属于 Core 的 Infrastructure/API，
/// 由 App 层组装后注入引擎，不在阅读功能里直接发请求。
/// 引擎状态、回调与命令都在主线程：协议与实现保持同一隔离域，避免 Swift 6 下的一致性错误。
@MainActor
protocol SpeechEngine: AnyObject {
    var kind: SpeechEngineKind { get }
    var capabilities: SpeechCapabilities { get }
    var availableVoices: [SpeechVoiceOption] { get }
    var state: SpeechPlaybackState { get }
    var onStateChange: ((SpeechPlaybackState) -> Void)? { get set }

    func start(from anchor: SpeechAnchor) async
    func pause()
    func resume()
    func stop()
    func skipBackward()
    func skipForward()
    func update(settings: SpeechSettings)
    func retry() -> Bool
    func skipChapter(_ delta: Int)
}
extension SpeechEngine {
    func retry() -> Bool { false }
    func skipChapter(_ delta: Int) {}
}
